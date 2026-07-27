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
import {PriceValidator} from "../../src/oracle/PriceValidator.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {Market} from "../../src/markets/Market.sol";
import {MarketFactory} from "../../src/markets/MarketFactory.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IMarket} from "../../src/interfaces/IMarket.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Constants} from "./Constants.sol";

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
    PriceValidator public priceValidator;
    CircuitBreaker public circuitBreaker;
    RiskManager public riskManager;
    PriceFeedRegistry public priceFeedRegistry;
    TimelockController public timelock;
    MarketFactory public marketFactory;
    InterestRateModel public volatileModel;

    // --- Adapters ---
    UniswapV3Adapter public v3Adapter;
    UniswapV2Adapter public v2Adapter;

    // --- Market ---
    uint256 public ethUsdcMarketId;

    // --- Test accounts ---
    address public deployer = makeAddr("deployer");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public liquidator = makeAddr("liquidator");

    // --- Fork ---
    uint256 public forkId;

    function setUp() public virtual {
        // Reuse existing fork from --fork-url (Anvil in CI, or local Anvil)
        forkId = vm.activeFork();

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
        priceValidator = new PriceValidator(address(core), address(circuitBreaker));

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
        v3Oracle = new UniswapV3Oracle(address(core), Constants.UNI_V3_NFT_MANAGER, address(priceFeedRegistry));
        v2Oracle = new UniswapV2Oracle(address(core), address(priceFeedRegistry));

        // Register oracles in ProtocolCore (single source of truth — hub reads from core)
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(v3Oracle));
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(v2Oracle));

        // PriceFeedRegistry (for cross-decimal HF/LTV calculations)
        priceFeedRegistry.setPriceFeed(Constants.USDC, Constants.CL_USDC_USD);
        priceFeedRegistry.setPriceFeed(Constants.WETH, Constants.CL_ETH_USD);

        // 9. Adapters
        v3Adapter = new UniswapV3Adapter(Constants.UNI_V3_NFT_MANAGER, Constants.UNI_V3_FACTORY, address(core));
        v2Adapter = new UniswapV2Adapter(Constants.UNI_V2_FACTORY, Constants.UNI_V2_ROUTER, address(core));

        // Register adapters
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(v3Adapter));
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(v2Adapter));

        // 10. Whitelist pools
        core.whitelistPool(Constants.UNI_V3_WETH_USDC_3000);
        core.whitelistPool(Constants.UNI_V2_WETH_USDC);

        // 11. Interest rate model + Market
        volatileModel = new InterestRateModel(200, 600, 10_000, 8000);
        Market marketImpl = new Market();
        marketFactory = new MarketFactory(address(core), address(marketImpl));
        marketFactory.setInterestRateModel("volatile", address(volatileModel));
        core.setMarketFactory(address(marketFactory));

        // Create ETH/USDC market
        (ethUsdcMarketId,) = marketFactory.createMarket(
            ILPAdapter.LPType.UniswapV3,
            Constants.USDC,
            6500, // 65% max LTV
            7500, // 75% liquidation threshold
            500, // 5% liquidation bonus
            10_000_000e6, // $10M borrow cap
            5_000_000e18, // $5M min pool TVL
            0, // 0 min pool age (for testing)
            "volatile"
        );

        // 12. Grant ACL roles
        aclManager.addLendingEngine(address(lendingEngine));
        aclManager.addLiquidationEngine(address(liquidationEngine));
        aclManager.addPositionManager(address(positionManager));
        positionManager.setLendingEngine(address(lendingEngine));

        // 14. Wire RiskManager + PriceFeedRegistry (via ProtocolCore)
        core.setRiskManager(address(riskManager));
        core.setPriceFeedRegistry(address(priceFeedRegistry));
        positionManager.setCircuitBreaker(address(circuitBreaker));

        // 15. Grant KEEPER to PriceValidator (so it can call CircuitBreaker.pausePool)
        aclManager.addKeeper(address(priceValidator));

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
