// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {UniswapV3Oracle} from "../../src/oracle/UniswapV3Oracle.sol";
import {UniswapV2Oracle} from "../../src/oracle/UniswapV2Oracle.sol";
import {PoolLiquidityMonitor} from "../../src/oracle/PoolLiquidityMonitor.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {LendingPool} from "../../src/markets/LendingPool.sol";
import {PoolFactory} from "../../src/markets/PoolFactory.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {ILendingPool} from "../../src/interfaces/ILendingPool.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Constants} from "./Constants.sol";
import {RiskConfig} from "./RiskConfig.sol";

/// @title ForkTestBase
/// @notice Base contract for all fork tests — deploys the full protocol against forked mainnet
/// @dev Inherit this in your fork tests. Override `setUp()` to add chain-specific config.
///
/// Usage:
///   contract MyForkTest is ForkTestBase {
///       function setUp() public override {
///           super.setUp();
///           // Add your test-specific setup
///       }
///   }
abstract contract ForkTestBase is Test {
    // --- Protocol contracts ---
    ACLManager public aclManager;
    ProtocolCore public core;
    PositionManager public positionManager;
    LendingEngine public lendingEngine;
    LiquidationEngine public liquidationEngine;
    FeeCollector public feeCollector;
    LPOracleHub public oracleHub;
    UniswapV3Oracle public v3Oracle;
    UniswapV2Oracle public v2Oracle;
    PoolLiquidityMonitor public poolLiquidityMonitor;
    CircuitBreaker public circuitBreaker;
    RiskManager public riskManager;
    PriceFeedRegistry public priceFeedRegistry;
    TimelockController public timelock;
    PoolFactory public poolFactory;
    InterestRateModel public volatileModel;

    // --- Adapters ---
    UniswapV3Adapter public v3Adapter;
    UniswapV2Adapter public v2Adapter;

    // --- Shared pool ---
    /// @notice The single shared USDC lending pool's borrow asset (pool key).
    address public usdcBorrowAsset;
    LendingPool public usdcPool;

    // --- Test accounts ---
    address public deployer = makeAddr("deployer");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public liquidator = makeAddr("liquidator");

    // --- Fork ---
    uint256 public forkId;

    /// @dev The block every fork test reads mainnet at.
    ///
    ///      Left unpinned these ran against whatever the chain head happened to be, so each run
    ///      refetched thousands of state slots: Foundry's RPC cache is keyed by block, and a moving
    ///      head never hits it. CI leaned on the provider hard enough to start timing out mid-suite,
    ///      failing tests that had nothing wrong with them.
    ///
    ///      Pinning also makes a red run reproducible — same block, same state, same answer
    ///      tomorrow.
    uint256 internal constant FORK_BLOCK = 25_600_000;

    function setUp() public virtual {
        // Reuse existing fork from --fork-url (Anvil in CI, or local Anvil)
        forkId = vm.activeFork();
        vm.rollFork(FORK_BLOCK);

        vm.startPrank(deployer);

        // 1. Deploy ACLManager + ProtocolCore
        aclManager = new ACLManager(deployer);
        aclManager.addEmergencyAdmin(guardian);
        core = new ProtocolCore(deployer, address(aclManager));

        // 2. Deploy LPOracleHub (UUPS proxy)
        LPOracleHub oracleHubImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(oracleHubImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );

        // 3. Deploy PositionManager (UUPS proxy)
        PositionManager pmImpl = new PositionManager();
        positionManager = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        // 4. Deploy LendingEngine (UUPS proxy)
        LendingEngine leImpl = new LendingEngine();
        lendingEngine = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(positionManager)))
                )
            )
        );

        // 5. Deploy LiquidationEngine (UUPS proxy)
        LiquidationEngine liqImpl = new LiquidationEngine();
        liquidationEngine = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(liqImpl),
                    abi.encodeCall(
                        LiquidationEngine.initialize, (address(core), address(positionManager), address(lendingEngine))
                    )
                )
            )
        );

        // 6. FeeCollector
        feeCollector = new FeeCollector(address(core), deployer, deployer);

        // 7. Security
        circuitBreaker = new CircuitBreaker(address(core));
        riskManager = new RiskManager(address(core));
        priceFeedRegistry = new PriceFeedRegistry(address(core));
        poolLiquidityMonitor = new PoolLiquidityMonitor(address(core), address(circuitBreaker));

        // 7b. TimelockController (deployer keeps POOL_ADMIN for test convenience)
        {
            address[] memory proposers = new address[](1);
            proposers[0] = deployer;
            address[] memory executors = new address[](1);
            executors[0] = deployer;
            timelock = new TimelockController(48 hours, proposers, executors, address(0));
            aclManager.grantRole(aclManager.POOL_ADMIN(), address(timelock));
            aclManager.grantRole(aclManager.DEFAULT_ADMIN_ROLE(), address(timelock));
            // NOTE: deployer keeps POOL_ADMIN so existing tests work without scheduling
        }

        // 8. Oracles
        v3Oracle = new UniswapV3Oracle(address(core), Constants.UNI_V3_NFT_MANAGER);
        v2Oracle = new UniswapV2Oracle(address(core));

        // Register oracles in ProtocolCore (single source of truth — hub reads from core)
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(v3Oracle));
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(v2Oracle));

        // PriceFeedRegistry (for cross-decimal HF/LTV calculations). Every token that is a leg of a
        // whitelisted pool needs a feed here: the V2 oracle prices a pair by asking the registry for
        // both legs, so a pool whose second leg has no feed reverts on the first deposit rather than
        // at whitelist time.
        priceFeedRegistry.setPriceFeed(Constants.USDC, Constants.CL_USDC_USD);
        priceFeedRegistry.setPriceFeed(Constants.WETH, Constants.CL_ETH_USD);
        priceFeedRegistry.setPriceFeed(Constants.DAI, Constants.CL_DAI_USD);
        priceFeedRegistry.setPriceFeed(Constants.USDT, Constants.CL_USDT_USD);

        // 9. Adapters
        v3Adapter = new UniswapV3Adapter(Constants.UNI_V3_NFT_MANAGER, Constants.UNI_V3_FACTORY, address(core));
        v2Adapter = new UniswapV2Adapter(Constants.UNI_V2_FACTORY, Constants.UNI_V2_ROUTER, address(core));

        // Register adapters
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(v3Adapter));
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(v2Adapter));

        // 10. Whitelist LP pools — WETH against each of the three stablecoins, mirroring the local
        //     deploy profile so tests exercise the same set the fork serves.
        core.whitelistLpPool(Constants.UNI_V3_WETH_USDC_3000, ILPAdapter.LPType.UniswapV3);
        core.whitelistLpPool(Constants.UNI_V3_WETH_DAI_3000, ILPAdapter.LPType.UniswapV3);
        core.whitelistLpPool(Constants.UNI_V3_WETH_USDT_3000, ILPAdapter.LPType.UniswapV3);
        core.whitelistLpPool(Constants.UNI_V2_WETH_USDC, ILPAdapter.LPType.UniswapV2);
        core.whitelistLpPool(Constants.UNI_V2_WETH_DAI, ILPAdapter.LPType.UniswapV2);
        core.whitelistLpPool(Constants.UNI_V2_WETH_USDT, ILPAdapter.LPType.UniswapV2);

        // 11. Wire RiskManager + PriceFeedRegistry (via ProtocolCore) — RiskManager is the source of
        //     truth for collateral risk params in the shared-pool model, so wire it before the pool.
        core.setRiskManager(address(riskManager));
        core.setPriceFeedRegistry(address(priceFeedRegistry));

        // 12. Interest rate model + shared USDC pool via PoolFactory
        volatileModel = new InterestRateModel(200, 600, 10_000, 8000);
        LendingPool poolImpl = new LendingPool();
        poolFactory = new PoolFactory(address(core), address(poolImpl));
        poolFactory.setInterestRateModel("volatile", address(volatileModel));
        core.setPoolFactory(address(poolFactory));

        // PoolFactory forwards collateral configs to RiskManager and sets the pool reserve factor —
        // grant it PoolAdmin (createPool) and RiskAdmin (whitelistCollateral/setReserveFactor).
        aclManager.grantRole(aclManager.POOL_ADMIN(), address(poolFactory));
        aclManager.addRiskAdmin(address(poolFactory));

        // Create the single shared USDC pool (0 reserve factor by default)
        usdcBorrowAsset = Constants.USDC;
        usdcPool = LendingPool(poolFactory.createPool(Constants.USDC, "volatile", 0));

        // Whitelist V2/V3 collateral against the shared pool (65% LTV / 75% liq / 5% bonus / no haircut)
        poolFactory.whitelistCollateral(ILPAdapter.LPType.UniswapV3, RiskConfig.defaultConfig());
        poolFactory.whitelistCollateral(ILPAdapter.LPType.UniswapV2, RiskConfig.defaultConfig());

        // 13. Grant ACL roles
        aclManager.addLendingEngine(address(lendingEngine));
        aclManager.addLiquidationEngine(address(liquidationEngine));
        aclManager.addPositionManager(address(positionManager));
        positionManager.setLendingEngine(address(lendingEngine));
        positionManager.setCircuitBreaker(address(circuitBreaker));
        // The engine now requires a FeeCollector, matching the deploy script: without it the
        // protocol share of every liquidation bonus was skipped and a bad-debt writeoff paid the
        // swept fees to the defaulting borrower.
        liquidationEngine.setFeeCollector(address(feeCollector));
        // compoundFees only accepts this address as the protocol-fee recipient, so an unwired
        // PositionManager cannot compound with a protocol fee — same as the deploy script.
        positionManager.setFeeCollector(address(feeCollector));

        // 14. Grant KEEPER to PoolLiquidityMonitor (so it can call CircuitBreaker.pausePool)
        aclManager.addKeeper(address(poolLiquidityMonitor));

        vm.stopPrank();
    }

    // --- Helper functions for tests ---

    /// @notice Give ETH to an address
    function _fundEth(address to, uint256 amount) internal {
        vm.deal(to, amount);
    }

    /// @notice Give WETH to an address by impersonating a whale
    function _fundWeth(address to, uint256 amount) internal {
        vm.prank(Constants.WETH_WHALE);
        IERC20(Constants.WETH).transfer(to, amount);
    }

    /// @notice Give USDC to an address by impersonating a whale
    function _fundUsdc(address to, uint256 amount) internal {
        vm.prank(Constants.USDC_WHALE);
        IERC20(Constants.USDC).transfer(to, amount);
    }

    /// @notice Get the current ETH/USD price from Chainlink
    function _getEthPrice() internal view returns (uint256) {
        (, int256 price,,,) = IAggregatorV3(Constants.CL_ETH_USD).latestRoundData();
        return uint256(price) * 1e10; // Chainlink returns 8 decimals, normalize to 18
    }

    /// @notice Advance time and mine blocks
    function _advanceTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        vm.roll(block.number + seconds_ / 12); // ~12s per block on ETH
    }
}

// Minimal Chainlink interface for price reading
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
