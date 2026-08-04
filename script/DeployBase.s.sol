// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACLManager} from "../src/core/ACLManager.sol";
import {ProtocolCore} from "../src/core/ProtocolCore.sol";
import {PositionManager} from "../src/core/PositionManager.sol";
import {LendingEngine} from "../src/core/LendingEngine.sol";
import {LiquidationEngine} from "../src/core/LiquidationEngine.sol";
import {FeeCollector} from "../src/core/FeeCollector.sol";
import {LPOracleHub} from "../src/oracle/LPOracleHub.sol";
import {UniswapV3Oracle} from "../src/oracle/UniswapV3Oracle.sol";
import {UniswapV2Oracle} from "../src/oracle/UniswapV2Oracle.sol";
import {PriceFeedRegistry} from "../src/oracle/PriceFeedRegistry.sol";
import {PoolLiquidityMonitor} from "../src/oracle/PoolLiquidityMonitor.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {UniswapV2Adapter} from "../src/adapters/UniswapV2Adapter.sol";
import {InterestRateModel} from "../src/markets/InterestRateModel.sol";
import {LendingPool} from "../src/markets/LendingPool.sol";
import {PoolFactory} from "../src/markets/PoolFactory.sol";
import {CircuitBreaker} from "../src/security/CircuitBreaker.sol";
import {RiskManager} from "../src/security/RiskManager.sol";
import {ILPAdapter} from "../src/interfaces/ILPAdapter.sol";

/// @title DeployBase
/// @notice Shared deployment logic for all chains. Subclass sets chain-specific config.
/// @dev Usage: forge script script/deploy/Sepolia.s.sol --rpc-url $RPC --broadcast --verify
abstract contract DeployBase is Script {
    // --- Chain Config (set by subclass) ---

    struct ChainConfig {
        // Roles
        address deployer;
        address guardian;
        address riskAdmin;
        // V2 DEX (address(0) = skip)
        address v2Factory;
        address v2Router;
        // V3 DEX (address(0) = skip)
        address v3Factory;
        address v3NftManager;
        // Tokens
        address weth; // native wrapped token (WETH, WBNB, etc.)
        address stablecoin; // primary borrow asset (USDC, BUSD, etc.)
        // Chainlink feeds
        address clNativeUsd; // ETH/USD, BNB/USD, etc.
        address clStablecoinUsd; // USDC/USD, BUSD/USD, etc.
        // L2 sequencer uptime feed. A required field, not an optional setter, because the check it
        // drives disables itself when unset: an L2 deployment that simply forgot it would price
        // through an outage with no revert, no event and no failing test. Stating address(0) is a
        // decision ("this chain has no sequencer"); omitting it was an accident waiting to happen.
        address clSequencerUptime;
        // Pools to whitelist
        address v2Pool; // V2 pair to whitelist (address(0) = skip)
        address v3Pool; // V3 pool to whitelist (address(0) = skip)
        // Collateral risk params
        uint256 maxLtv; // bps (e.g., 6500 = 65%)
        uint256 liquidationThreshold; // bps
        uint256 liquidationBonus; // bps
        uint256 haircut; // bps discount applied to collateral value (0 = none)
        // Per-collateral borrow cap, in 18-dec USD — NOT stablecoin decimals. RiskManager compares
        // this against amounts converted by LendingEngine._toUsd, so a 6-dec value would cap the
        // type 1e12 too low and revert every borrow.
        uint256 borrowCap;
    }

    // --- Deployed Contracts ---
    ACLManager public aclManager;
    ProtocolCore public core;
    LPOracleHub public oracleHub;
    PositionManager public positionManager;
    LendingEngine public lendingEngine;
    LiquidationEngine public liquidationEngine;
    FeeCollector public feeCollector;
    CircuitBreaker public circuitBreaker;
    RiskManager public riskManager;
    PriceFeedRegistry public priceFeedRegistry;
    PoolLiquidityMonitor public poolLiquidityMonitor;
    PoolFactory public poolFactory;

    // --- Abstract: subclass provides config ---
    function _config() internal virtual returns (ChainConfig memory);

    // --- Entry Point ---
    function run() external {
        ChainConfig memory cfg = _config();

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(vm.addr(deployerKey) == cfg.deployer, "DEPLOYER_KEY_MISMATCH");

        vm.startBroadcast(deployerKey);

        _deployCore(cfg);
        _deployProxies();
        _deploySecurity(cfg);
        _deployOracles(cfg);
        _deployAdapters(cfg);
        _deployPoolFactory(cfg);
        _configureRoles(cfg);
        _createPools(cfg);
        _afterDeploy(cfg);

        vm.stopBroadcast();

        _logAddresses(cfg);
        _afterRun(cfg);
    }

    /// @notice Optional post-deploy hook (default no-op). Subclasses may override to
    ///         persist deployed addresses (e.g. Local writes a deployments JSON for tooling).
    function _afterRun(ChainConfig memory cfg) internal virtual {}

    /// @notice Optional hook run after market creation, as the last step of the deploy (default
    ///         no-op). Local uses it to relax oracle staleness for the fork, where real feeds can
    ///         lag well past the 1h default.
    function _afterDeploy(ChainConfig memory cfg) internal virtual {}

    /// @notice Optional hook run at the end of _deployOracles (default no-op). Local registers
    ///         extra stablecoin price feeds (USDT/DAI) here so their markets can be valued.
    function _afterOracles(ChainConfig memory cfg) internal virtual {}

    /// @notice Optional hook run at the end of _createPools (default no-op). Local creates the
    ///         extra borrow-asset markets (V2->USDT, V2->DAI) here.
    function _afterPools(ChainConfig memory cfg) internal virtual {}

    // --- Deploy Steps ---

    function _deployCore(ChainConfig memory cfg) internal {
        // TODO: Post-deploy, transfer ACLManager and ProtocolCore ownership from the
        // deployer EOA to a multisig. The deployer should not retain admin privileges.
        aclManager = new ACLManager(cfg.deployer);
        core = new ProtocolCore(cfg.deployer, address(aclManager));

        LPOracleHub ohImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(ohImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );
    }

    function _deployProxies() internal {
        PositionManager pmImpl = new PositionManager();
        positionManager = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        LendingEngine leImpl = new LendingEngine();
        lendingEngine = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(positionManager)))
                )
            )
        );

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
    }

    function _deploySecurity(ChainConfig memory cfg) internal {
        feeCollector = new FeeCollector(address(core), cfg.deployer, cfg.deployer);
        circuitBreaker = new CircuitBreaker(address(core));
        riskManager = new RiskManager(address(core));
        priceFeedRegistry = new PriceFeedRegistry(address(core));
        poolLiquidityMonitor = new PoolLiquidityMonitor(address(core), address(circuitBreaker));
    }

    function _deployOracles(ChainConfig memory cfg) internal {
        // V3 Oracle
        if (cfg.v3NftManager != address(0)) {
            UniswapV3Oracle v3Oracle = new UniswapV3Oracle(address(core), cfg.v3NftManager, address(priceFeedRegistry));
            core.registerOracle(ILPAdapter.LPType.UniswapV3, address(v3Oracle));
        }

        // V2 Oracle
        if (cfg.v2Factory != address(0)) {
            UniswapV2Oracle v2Oracle = new UniswapV2Oracle(address(core), address(priceFeedRegistry));
            core.registerOracle(ILPAdapter.LPType.UniswapV2, address(v2Oracle));
        }

        // PriceFeedRegistry (for cross-decimal HF/LTV)
        priceFeedRegistry.setPriceFeed(cfg.stablecoin, cfg.clStablecoinUsd);
        priceFeedRegistry.setPriceFeed(cfg.weth, cfg.clNativeUsd);
        // Called unconditionally, including with address(0). Skipping it when disabled would leave
        // no event and no way to tell a deliberate "this chain has no sequencer" apart from someone
        // forgetting the field — which is the whole distinction this config exists to record.
        priceFeedRegistry.setSequencerUptimeFeed(cfg.clSequencerUptime);

        _afterOracles(cfg);
    }

    function _deployAdapters(ChainConfig memory cfg) internal {
        if (cfg.v3NftManager != address(0)) {
            UniswapV3Adapter v3Adapter = new UniswapV3Adapter(cfg.v3NftManager, cfg.v3Factory, address(core));
            core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(v3Adapter));
        }

        if (cfg.v2Factory != address(0)) {
            UniswapV2Adapter v2Adapter = new UniswapV2Adapter(cfg.v2Factory, cfg.v2Router, address(core));
            core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(v2Adapter));
        }
    }

    function _deployPoolFactory(ChainConfig memory cfg) internal {
        InterestRateModel stableModel = new InterestRateModel(100, 400, 7500, 8500);
        InterestRateModel volatileModel = new InterestRateModel(200, 600, 10_000, 8000);

        LendingPool poolImpl = new LendingPool();
        poolFactory = new PoolFactory(address(core), address(poolImpl));

        poolFactory.setInterestRateModel("stable", address(stableModel));
        poolFactory.setInterestRateModel("volatile", address(volatileModel));

        core.setPoolFactory(address(poolFactory));
    }

    function _configureRoles(ChainConfig memory cfg) internal {
        // Contract roles
        aclManager.addLendingEngine(address(lendingEngine));
        aclManager.addLiquidationEngine(address(liquidationEngine));
        aclManager.addPositionManager(address(positionManager));

        // Human roles
        if (cfg.guardian != address(0)) {
            aclManager.addEmergencyAdmin(cfg.guardian);
        }
        if (cfg.riskAdmin != address(0)) {
            aclManager.addRiskAdmin(cfg.riskAdmin);
        }

        // Wire references
        positionManager.setLendingEngine(address(lendingEngine));
        positionManager.setCircuitBreaker(address(circuitBreaker));
        // Only LendingPool used to get this, so LiquidationEngine ran unwired on every deployment:
        // the protocol's share of each liquidation bonus went entirely to the liquidator, and a
        // bad-debt writeoff paid the swept fees to the defaulting borrower.
        liquidationEngine.setFeeCollector(address(feeCollector));
        core.setPriceFeedRegistry(address(priceFeedRegistry));
        core.setRiskManager(address(riskManager));

        // No swap router needed — liquidation sends underlying tokens directly to liquidator.
        // FlashloanLiquidator (periphery) handles swaps outside the core protocol.

        // Grant KEEPER to security contracts so they can trigger CircuitBreaker.pausePool()
        aclManager.addKeeper(address(poolLiquidityMonitor));

        // PoolFactory needs RISK_ADMIN only: whitelistCollateral→setCollateralConfig, and
        // setReserveFactor on freshly created pools (LendingPool.onlyRiskAdmin). It does NOT
        // need POOL_ADMIN — core.registerLendingPool authorizes `msg.sender == poolFactory` directly,
        // so granting it would only widen the factory's blast radius if it were compromised.
        aclManager.addRiskAdmin(address(poolFactory));
    }

    function _createPools(ChainConfig memory cfg) internal {
        // Whitelist collateral pools (the underlying LP pools, not the lending pool)
        if (cfg.v3Pool != address(0)) core.whitelistLpPool(cfg.v3Pool);
        if (cfg.v2Pool != address(0)) core.whitelistLpPool(cfg.v2Pool);

        // Shared-pool model: create ONE lending pool for the primary stablecoin, then whitelist
        // each configured collateral type against it (borrow cap is per-collateral in RiskManager).
        _ensurePool(cfg.stablecoin);

        if (cfg.v3NftManager != address(0)) {
            _whitelistCollateral(ILPAdapter.LPType.UniswapV3, cfg);
        }
        if (cfg.v2Factory != address(0)) {
            _whitelistCollateral(ILPAdapter.LPType.UniswapV2, cfg);
        }

        _afterPools(cfg);
    }

    /// @notice Ensure a shared lending pool exists for a borrow asset (idempotent); wire FeeCollector.
    /// @dev Subclasses (e.g. Local) call this from _afterPools to add extra borrow assets. Collateral
    ///      does NOT need re-whitelisting per pool: CollateralConfig is keyed by LPType alone, so one
    ///      _whitelistCollateral call covers that type against every borrow asset.
    function _ensurePool(address borrowAsset) internal returns (address poolAddr) {
        poolAddr = core.lendingPool(borrowAsset);
        if (poolAddr == address(0)) {
            poolAddr = poolFactory.createPool(borrowAsset, "volatile", 0);
            LendingPool(poolAddr).setFeeCollector(address(feeCollector));
        }
    }

    /// @notice Whitelist a collateral type against the shared pool (risk params via RiskManager).
    function _whitelistCollateral(ILPAdapter.LPType lpType, ChainConfig memory cfg) internal {
        poolFactory.whitelistCollateral(
            lpType,
            RiskManager.CollateralConfig({
                maxLtv: cfg.maxLtv,
                liquidationThreshold: cfg.liquidationThreshold,
                liquidationBonus: cfg.liquidationBonus,
                haircut: cfg.haircut,
                borrowCap: cfg.borrowCap,
                enabled: true
            })
        );
    }

    function _logAddresses(ChainConfig memory) internal view {
        console.log("=== Koreth Protocol Deployed ===");
        console.log("");
        console.log("ACLManager:             ", address(aclManager));
        console.log("ProtocolCore:           ", address(core));
        console.log("PositionManager:        ", address(positionManager));
        console.log("LendingEngine:          ", address(lendingEngine));
        console.log("LiquidationEngine:      ", address(liquidationEngine));
        console.log("LPOracleHub:            ", address(oracleHub));
        console.log("FeeCollector:           ", address(feeCollector));
        console.log("CircuitBreaker:         ", address(circuitBreaker));
        console.log("RiskManager:            ", address(riskManager));
        console.log("PriceFeedRegistry:      ", address(priceFeedRegistry));
        console.log("PoolLiquidityMonitor:   ", address(poolLiquidityMonitor));
        console.log("PoolFactory:            ", address(poolFactory));
    }
}
