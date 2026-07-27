// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";
import {PoolHealthMonitor} from "../../src/security/PoolHealthMonitor.sol";
import {Market} from "../../src/markets/Market.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {IMarket} from "../../src/interfaces/IMarket.sol";
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
    PoolHealthMonitor public phm;
    Market public market;
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
        phm = new PoolHealthMonitor(address(core), address(cb));
        registry = new PriceFeedRegistry(address(core));

        IMarket.MarketConfig memory config = IMarket.MarketConfig({
            lpType: ILPAdapter.LPType.UniswapV3,
            borrowAsset: address(usdc),
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            borrowCap: 10_000_000e6,
            minPoolTvl: 5_000_000e18,
            minPoolAge: 0
        });

        Market impl = new Market();
        market = Market(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(Market.initialize, (config, address(irm), address(core)))
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

    function test_setMarketSupplyCap_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        rm.setMarketSupplyCap(0, 100_000e18);
    }

    // ========== CircuitBreaker — onlyGuardianOrKeeper ==========

    function test_pausePool_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_AUTHORIZED");
        cb.pausePool(makeAddr("pool"), "test");
    }

    function test_freezeMarket_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_AUTHORIZED");
        cb.freezeMarket(0, "test");
    }

    // ========== CircuitBreaker — onlyPoolAdmin ==========

    function test_unpausePool_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        cb.unpausePool(makeAddr("pool"));
    }

    function test_unfreezeMarket_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        cb.unfreezeMarket(0);
    }

    // ========== Market — onlyRiskAdmin ==========

    function test_marketSetReserveFactor_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        market.setReserveFactor(2000);
    }

    function test_updateConfig_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_RISK_ADMIN");
        market.updateConfig(6500, 7500, 500, 10_000_000e6);
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

    // ========== PoolHealthMonitor — onlyPoolAdmin ==========

    function test_setTvlDropThreshold_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        phm.setTvlDropThreshold(2000);
    }

    function test_setCriticalTvlDrop_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        phm.setCriticalTvlDrop(6000);
    }

    function test_setMinTvl_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_POOL_ADMIN");
        phm.setMinTvl(makeAddr("pool"), 1_000_000e18);
    }
}
