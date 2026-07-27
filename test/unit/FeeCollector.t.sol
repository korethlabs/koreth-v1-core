// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract FeeCollectorTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    FeeCollector public fc;
    MockERC20 public usdc;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public keeper = makeAddr("keeper");
    address public treasury = makeAddr("treasury");
    address public insurance = makeAddr("insurance");
    address public user = makeAddr("user");

    // Events
    event FeesCollected(address indexed token, uint256 amount, address indexed from, string feeType);
    event FeesDistributed(address indexed token, uint256 toTreasury, uint256 toInsurance);
    event ReserveFactorUpdated(ILPAdapter.LPType indexed lpType, uint256 oldValue, uint256 newValue);
    event DefaultReserveFactorUpdated(uint256 oldValue, uint256 newValue);
    event LiquidationFeeUpdated(uint256 oldValue, uint256 newValue);
    event InsuranceFundShareUpdated(uint256 oldValue, uint256 newValue);
    event TreasuryUpdated(address indexed oldAddr, address indexed newAddr);
    event InsuranceFundUpdated(address indexed oldAddr, address indexed newAddr);

    function setUp() public {
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));
        fc = new FeeCollector(address(core), treasury, insurance);
        usdc = new MockERC20("USDC", "USDC", 6);

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addKeeper(keeper);
        vm.stopPrank();
    }

    // ========== Constructor ==========

    function test_constructor_setsState() public view {
        assertEq(address(fc.core()), address(core));
        assertEq(fc.treasury(), treasury);
        assertEq(fc.insuranceFund(), insurance);
        assertEq(fc.defaultReserveFactorBps(), 2000);
        assertEq(fc.liquidationFeeBps(), 7000);
        // managementFeeBps deprecated — removed from public API
        assertEq(fc.insuranceFundShareBps(), 1000);
    }

    function test_constructor_setsReserveFactors() public view {
        assertEq(fc.reserveFactorBps(ILPAdapter.LPType.Curve), 1000);
        assertEq(fc.reserveFactorBps(ILPAdapter.LPType.UniswapV2), 2000);
        assertEq(fc.reserveFactorBps(ILPAdapter.LPType.UniswapV3), 2000);
        assertEq(fc.reserveFactorBps(ILPAdapter.LPType.Aerodrome), 2500);
    }

    function test_constructor_revertsZeroCore() public {
        vm.expectRevert("ZERO_CORE");
        new FeeCollector(address(0), treasury, insurance);
    }

    function test_constructor_revertsZeroTreasury() public {
        vm.expectRevert("ZERO_TREASURY");
        new FeeCollector(address(core), address(0), insurance);
    }

    function test_constructor_revertsZeroInsurance() public {
        vm.expectRevert("ZERO_INSURANCE");
        new FeeCollector(address(core), treasury, address(0));
    }

    // ========== collectFee (pulls tokens) ==========

    function test_collectFee_pullsTokens() public {
        // Source has USDC and approves FeeCollector
        address source = makeAddr("source");
        usdc.mint(source, 1000e6);
        vm.prank(source);
        usdc.approve(address(fc), 1000e6);

        vm.expectEmit(true, false, true, true);
        emit FeesCollected(address(usdc), 1000e6, source, "interest");

        vm.prank(keeper);
        fc.collectFee(address(usdc), 1000e6, source, "interest");

        assertEq(fc.accumulatedFees(address(usdc)), 1000e6);
        assertEq(usdc.balanceOf(address(fc)), 1000e6); // Tokens actually in FeeCollector
        assertEq(usdc.balanceOf(source), 0); // Pulled from source
    }

    function test_collectFee_revertsNotAuthorized() public {
        vm.prank(user);
        vm.expectRevert("NOT_AUTHORIZED");
        fc.collectFee(address(usdc), 1000e6, user, "interest");
    }

    function test_collectFee_revertsZeroAmount() public {
        vm.prank(keeper);
        vm.expectRevert("ZERO_AMOUNT");
        fc.collectFee(address(usdc), 0, makeAddr("x"), "interest");
    }

    function test_collectFee_revertsZeroFrom() public {
        vm.prank(keeper);
        vm.expectRevert("ZERO_FROM");
        fc.collectFee(address(usdc), 1000e6, address(0), "interest");
    }

    // ========== distribute ==========

    function test_distribute_splitCorrectly() public {
        // Collect real fees (tokens actually move)
        address source = makeAddr("source");
        usdc.mint(source, 10_000e6);
        vm.prank(source);
        usdc.approve(address(fc), 10_000e6);
        vm.prank(keeper);
        fc.collectFee(address(usdc), 10_000e6, source, "interest");

        vm.expectEmit(true, false, false, true);
        emit FeesDistributed(address(usdc), 9000e6, 1000e6);

        vm.prank(keeper);
        fc.distribute(address(usdc));

        assertEq(usdc.balanceOf(treasury), 9000e6);
        assertEq(usdc.balanceOf(insurance), 1000e6);
        assertEq(usdc.balanceOf(address(fc)), 0); // FeeCollector empty
        assertEq(fc.accumulatedFees(address(usdc)), 0);
    }

    function test_distribute_revertsNoFees() public {
        vm.prank(keeper);
        vm.expectRevert("NO_FEES");
        fc.distribute(address(usdc));
    }

    function test_distribute_multipleRounds() public {
        address source = makeAddr("source");
        usdc.mint(source, 20_000e6);
        vm.prank(source);
        usdc.approve(address(fc), 20_000e6);

        // Round 1
        vm.prank(keeper);
        fc.collectFee(address(usdc), 5000e6, source, "interest");
        vm.prank(keeper);
        fc.distribute(address(usdc));

        // Round 2
        vm.prank(keeper);
        fc.collectFee(address(usdc), 3000e6, source, "liquidation");
        vm.prank(keeper);
        fc.distribute(address(usdc));

        assertEq(usdc.balanceOf(treasury), 4500e6 + 2700e6); // 7200
        assertEq(usdc.balanceOf(insurance), 500e6 + 300e6); // 800
    }

    // ========== calculateInterestSplit ==========

    function test_calculateInterestSplit_curvePool() public view {
        // Curve reserve factor = 10%
        (uint256 protocolShare, uint256 lenderShare) = fc.calculateInterestSplit(10_000e18, ILPAdapter.LPType.Curve);
        assertEq(protocolShare, 1000e18); // 10%
        assertEq(lenderShare, 9000e18); // 90%
    }

    function test_calculateInterestSplit_uniswapV3() public view {
        // UniswapV3 reserve factor = 20%
        (uint256 protocolShare, uint256 lenderShare) = fc.calculateInterestSplit(10_000e18, ILPAdapter.LPType.UniswapV3);
        assertEq(protocolShare, 2000e18);
        assertEq(lenderShare, 8000e18);
    }

    function test_calculateInterestSplit_aerodrome() public view {
        // Aerodrome reserve factor = 25%
        (uint256 protocolShare, uint256 lenderShare) = fc.calculateInterestSplit(10_000e18, ILPAdapter.LPType.Aerodrome);
        assertEq(protocolShare, 2500e18);
        assertEq(lenderShare, 7500e18);
    }

    function test_calculateInterestSplit_sumEqualsTotal() public view {
        (uint256 p, uint256 l) = fc.calculateInterestSplit(12_345e18, ILPAdapter.LPType.UniswapV3);
        assertEq(p + l, 12_345e18);
    }

    // ========== calculateLiquidationFee ==========

    function test_calculateLiquidationFee_default70Percent() public view {
        // Default liquidation fee = 70% of bonus to protocol
        (uint256 protocolFee, uint256 liquidatorNet) = fc.calculateLiquidationFee(5000e18);
        assertEq(protocolFee, 3500e18); // 70%
        assertEq(liquidatorNet, 1500e18); // 30%
    }

    function test_calculateLiquidationFee_sumEqualsInput() public view {
        (uint256 fee, uint256 net) = fc.calculateLiquidationFee(7777e18);
        assertEq(fee + net, 7777e18);
    }

    function test_calculateLiquidationFee_zeroInput() public view {
        (uint256 fee, uint256 net) = fc.calculateLiquidationFee(0);
        assertEq(fee, 0);
        assertEq(net, 0);
    }

    // ========== Setters ==========

    function test_setReserveFactor_success() public {
        vm.prank(owner);
        fc.setReserveFactor(ILPAdapter.LPType.UniswapV3, 3000);
        assertEq(fc.reserveFactorBps(ILPAdapter.LPType.UniswapV3), 3000);
    }

    function test_setReserveFactor_revertsBounds() public {
        vm.prank(owner);
        vm.expectRevert("OUT_OF_BOUNDS");
        fc.setReserveFactor(ILPAdapter.LPType.UniswapV3, 400);

        vm.prank(owner);
        vm.expectRevert("OUT_OF_BOUNDS");
        fc.setReserveFactor(ILPAdapter.LPType.UniswapV3, 5100);
    }

    function test_setDefaultReserveFactor_success() public {
        vm.prank(owner);
        fc.setDefaultReserveFactor(1500);
        assertEq(fc.defaultReserveFactorBps(), 1500);
    }

    function test_setLiquidationFee_success() public {
        vm.prank(owner);
        fc.setLiquidationFee(1500);
        assertEq(fc.liquidationFeeBps(), 1500);
    }

    function test_setLiquidationFee_revertsTooHigh() public {
        vm.prank(owner);
        vm.expectRevert("OUT_OF_BOUNDS");
        fc.setLiquidationFee(9001); // Above MAX (9000)
    }

    function test_setLiquidationFee_revertsTooLow() public {
        vm.prank(owner);
        vm.expectRevert("OUT_OF_BOUNDS");
        fc.setLiquidationFee(49); // Below MIN_PROTOCOL_BONUS_SHARE (50 = 0.5%)
    }

    function test_setManagementFee_deprecated() public {
        vm.prank(owner);
        vm.expectRevert("DEPRECATED");
        fc.setManagementFee(50);
    }

    function test_setInsuranceFundShare_success() public {
        vm.prank(owner);
        fc.setInsuranceFundShare(2000);
        assertEq(fc.insuranceFundShareBps(), 2000);
    }

    function test_setTreasury_success() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        fc.setTreasury(newTreasury);
        assertEq(fc.treasury(), newTreasury);
    }

    function test_setInsuranceFund_success() public {
        address newIns = makeAddr("newIns");
        vm.prank(owner);
        fc.setInsuranceFund(newIns);
        assertEq(fc.insuranceFund(), newIns);
    }

    function test_setTreasury_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        fc.setTreasury(address(0));
    }

    // ========== Fuzz ==========

    function testFuzz_distribute_splitMath(uint256 total, uint256 insuranceShareBps) public {
        total = bound(total, 1, 1_000_000_000e6);
        insuranceShareBps = bound(insuranceShareBps, 0, 5000);

        vm.prank(owner);
        fc.setInsuranceFundShare(insuranceShareBps);

        address source = makeAddr("fuzzSource");
        usdc.mint(source, total);
        vm.prank(source);
        usdc.approve(address(fc), total);

        vm.prank(keeper);
        fc.collectFee(address(usdc), total, source, "test");

        vm.prank(keeper);
        fc.distribute(address(usdc));

        uint256 expectedInsurance = (total * insuranceShareBps) / 10_000;
        uint256 expectedTreasury = total - expectedInsurance;

        assertEq(usdc.balanceOf(insurance), expectedInsurance);
        assertEq(usdc.balanceOf(treasury), expectedTreasury);
        assertEq(usdc.balanceOf(insurance) + usdc.balanceOf(treasury), total);
    }

    function testFuzz_calculateInterestSplit_noLoss(uint256 interest, uint256 rfBps) public {
        interest = bound(interest, 0, type(uint128).max);
        rfBps = bound(rfBps, 500, 5000);

        vm.prank(owner);
        fc.setReserveFactor(ILPAdapter.LPType.UniswapV3, rfBps);

        (uint256 p, uint256 l) = fc.calculateInterestSplit(interest, ILPAdapter.LPType.UniswapV3);
        assertEq(p + l, interest, "Interest split must not lose tokens");
    }
}
