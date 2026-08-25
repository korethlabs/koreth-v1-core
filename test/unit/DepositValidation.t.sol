// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockLendingPool} from "../mocks/MockLendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RiskConfig} from "../helpers/RiskConfig.sol";
import {TestPricing} from "../helpers/TestPricing.sol";
import {TestPools} from "../helpers/TestPools.sol";

/// @title DepositValidationTest
/// @notice Tests for deposit-time validations: circuit breaker warning, oracle health check
contract DepositValidationTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LPOracleHub public oracleHub;
    CircuitBreaker public circuitBreaker;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockLendingPool public market;
    RiskManager public riskManager;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public lpToken = makeAddr("lpToken");
    address public borrowAsset;

    function setUp() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 18);
        borrowAsset = address(usdc);
        InterestRateModel irm = new InterestRateModel(200, 600, 10_000, 8000);

        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        LPOracleHub ohImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(ohImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );

        PositionManager pmImpl = new PositionManager();
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        LendingEngine leImpl = new LendingEngine();
        LendingEngine le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV2);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        market = new MockLendingPool(address(usdc), address(irm));
        circuitBreaker = new CircuitBreaker(address(core));
        riskManager = new RiskManager(address(core));

        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        aclManager.addRiskAdmin(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(oracle));
        core.whitelistLpPool(TestPools.asContract(lpToken), ILPAdapter.LPType.UniswapV2);
        TestPricing.wireStable(core, address(usdc));
        core.registerLendingPool(address(usdc), address(market));
        core.setRiskManager(address(riskManager));
        // Enable UniswapV2 collateral (the type the mock adapter detects)
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV2, RiskConfig.defaultConfig());
        pm.setCircuitBreaker(address(circuitBreaker));
        pm.setLendingEngine(address(le));
        vm.stopPrank();
    }

    // ========== Collateral Not Enabled ==========

    /// @notice Depositing an LP whose collateral type is not enabled in RiskManager reverts.
    /// @dev Replaces the legacy per-market LP_TYPE_MISMATCH check (risk config is now per lpType).
    function test_deposit_revertsCollateralNotEnabled() public {
        // Disable the UniswapV2 collateral type in the registry.
        vm.prank(owner);
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV2, RiskConfig.config(6500, 7500, 500, 0, 0, false));

        vm.prank(alice);
        vm.expectRevert("COLLATERAL_NOT_ENABLED");
        pm.deposit(lpToken, 0, 100e18, borrowAsset);
    }

    // ========== Zero-value deposit rejection ==========

    /// @notice A position the oracle prices at 0 is rejected by the generic ZERO_VALUE guard.
    ///         (Under principal-only valuation this is exactly what a fee-only / liquidity-less V3
    ///         position prices to — no separate NO_PRINCIPAL guard needed.) Here we model that
    ///         generically by forcing the mock oracle's totalValue to 0.
    function test_deposit_revertsZeroValue() public {
        oracle.setPrice(0); // mock oracle → totalValue == 0

        vm.prank(alice);
        vm.expectRevert("ZERO_VALUE");
        pm.deposit(lpToken, 0, 100e18, borrowAsset);
    }

    /// @notice A normal position (principal > 0) deposits fine.
    function test_deposit_succeedsWithPrincipal() public {
        oracle.setPrice(100e18);

        vm.prank(alice);
        pm.deposit(lpToken, 0, 100e18, borrowAsset);
    }

    // ========== CircuitBreaker ==========

    /// @dev A deposit used to proceed with no circuit breaker attached, warning via an event that
    ///      nothing reads. It cannot happen any more: the breaker is mandatory, so there is no
    ///      configuration in which a paused pool or a frozen collateral type still takes deposits.
    function test_setCircuitBreaker_rejectsZero() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        pm.setCircuitBreaker(address(0));

        assertTrue(address(pm.circuitBreaker()) != address(0), "breaker must survive the attempt");
    }

    function test_deposit_blockedWhenCollateralFrozen() public {
        // Resolved before the prank: as part of the call it would consume it, and freezeCollateral
        // would arrive from the test contract rather than from the admin.
        CircuitBreaker breaker = pm.circuitBreaker();

        vm.prank(owner);
        breaker.freezeCollateral(ILPAdapter.LPType.UniswapV2, "oracle under review");

        vm.prank(alice);
        vm.expectRevert("COLLATERAL_FROZEN");
        pm.deposit(lpToken, 0, 100e18, borrowAsset);
    }

    // ========== Oracle Health Check ==========

    function test_deposit_blockedWhenOracleUnhealthy() public {
        vm.prank(owner);
        pm.setCircuitBreaker(address(circuitBreaker));

        oracle.setHealthy(false);

        vm.prank(alice);
        vm.expectRevert("ORACLE_UNHEALTHY");
        pm.deposit(lpToken, 0, 100e18, borrowAsset);
    }

    function test_deposit_worksWhenOracleHealthy() public {
        vm.prank(owner);
        pm.setCircuitBreaker(address(circuitBreaker));

        oracle.setHealthy(true);

        vm.prank(alice);
        pm.deposit(lpToken, 0, 100e18, borrowAsset);
    }
}
