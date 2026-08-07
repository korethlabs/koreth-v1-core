// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";
import {PoolLiquidityMonitor} from "../../src/oracle/PoolLiquidityMonitor.sol";
import {LendingPool} from "../../src/markets/LendingPool.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {ILendingPool} from "../../src/interfaces/ILendingPool.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title AccessControlNegativeTest
/// @notice Verifies UNAUTHORIZED callers are REJECTED for every privileged setter.
///         Only tests the caller-authorization revert (not value bounds).
contract AccessControlNegativeTest is Test {
    ACLManager public aclManager;
    ProtocolCore public core;
    FeeCollector public fc;
    RiskManager public rm;
    CircuitBreaker public cb;
    PoolLiquidityMonitor public liquidityMonitor;
    LendingPool public market;
    PriceFeedRegistry public registry;
    InterestRateModel public irm;
    MockERC20 public usdc;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public insurance = makeAddr("insurance");
    address public attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        irm = new InterestRateModel(200, 600, 10_000, 8000);

        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));
        fc = new FeeCollector(address(core), treasury, insurance);
        rm = new RiskManager(address(core));
        cb = new CircuitBreaker(address(core));
        liquidityMonitor = new PoolLiquidityMonitor(address(core), address(cb));
        registry = new PriceFeedRegistry(address(core));

        ILendingPool.PoolConfig memory config = ILendingPool.PoolConfig({borrowAsset: address(usdc)});

        LendingPool impl = new LendingPool();
        market = LendingPool(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(LendingPool.initialize, (config, address(irm), address(core)))
                )
            )
        );
    }

    // ========== FeeCollector — onlyRiskAdmin ==========

    function test_setReserveFactor_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        fc.setReserveFactor(ILPAdapter.LPType.UniswapV3, 3000);
    }

    function test_setDefaultReserveFactor_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        fc.setDefaultReserveFactor(1500);
    }

    function test_setLiquidationFee_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        fc.setLiquidationFee(1500);
    }

    function test_setInsuranceFundShare_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        fc.setInsuranceFundShare(2000);
    }

    // ========== FeeCollector — onlyPoolAdmin ==========

    function test_setTreasury_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        fc.setTreasury(makeAddr("newTreasury"));
    }

    function test_setInsuranceFund_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        fc.setInsuranceFund(makeAddr("newIns"));
    }

    function test_sweepExcess_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        fc.sweepExcess(address(usdc), attacker);
    }

    // ========== RiskManager — onlyRiskAdmin ==========

    function test_setGlobalBorrowCap_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        rm.setGlobalBorrowCap(50_000e18);
    }

    function test_setDailyBorrowIncreaseLimit_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        rm.setDailyBorrowIncreaseLimit(30_000e18);
    }

    function test_setLPTypeBorrowCap_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        rm.setLPTypeBorrowCap(ILPAdapter.LPType.UniswapV3, 30_000e18);
    }

    function test_setMaxPositionValue_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        rm.setMaxPositionValue(5000e18);
    }

    function test_setMaxPositionsPerUser_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        rm.setMaxPositionsPerUser(5);
    }

    function test_setPoolSupplyCap_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        rm.setPoolSupplyCap(makeAddr("pool"), 100_000e18);
    }

    // ========== CircuitBreaker — onlyGuardianOrKeeper ==========

    function test_pausePool_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_AUTHORIZED");
        cb.pausePool(makeAddr("pool"), "test");
    }

    function test_freezeCollateral_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_AUTHORIZED");
        cb.freezeCollateral(ILPAdapter.LPType.UniswapV3, "test");
    }

    // ========== CircuitBreaker — onlyPoolAdmin ==========

    function test_unpausePool_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        cb.unpausePool(makeAddr("pool"));
    }

    function test_unfreezeCollateral_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        cb.unfreezeCollateral(ILPAdapter.LPType.UniswapV3);
    }

    // ========== LendingPool — onlyRiskAdmin ==========

    function test_marketSetReserveFactor_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        market.setReserveFactor(2000);
    }

    function test_eliminateDeficit_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        market.eliminateDeficit();
    }

    // ========== Market — onlyPoolAdmin ==========

    function test_setInterestRateModel_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        market.setInterestRateModel(address(irm));
    }

    function test_setFeeCollector_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        market.setFeeCollector(address(fc));
    }

    // ========== PriceFeedRegistry — onlyPoolAdmin ==========

    function test_setPriceFeed_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        registry.setPriceFeed(address(usdc), makeAddr("feed"));
    }

    function test_setMaxStaleness_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        registry.setMaxStaleness(7200);
    }

    // ========== PoolLiquidityMonitor — onlyRiskAdmin ==========

    function test_setMinPoolTvl_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        liquidityMonitor.setMinPoolTvl(1_000_000e18);
    }
}
