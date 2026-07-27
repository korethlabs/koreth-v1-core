// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract LendingEngineTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    LPOracleHub public oracleHub;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockMarket public market;
    MockERC20 public usdc;
    InterestRateModel public irm;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public liquidationEngine = makeAddr("liquidationEngine");
    address public lpToken = makeAddr("lpToken");

    uint256 public marketId;

    // Events
    event Borrowed(uint256 indexed positionId, address indexed borrower, uint256 amount, uint256 totalDebt);
    event Repaid(uint256 indexed positionId, address indexed repayer, uint256 amount, uint256 remainingDebt);
    event InterestAccrued(uint256 indexed marketId, uint256 interestAmount, uint256 timestamp);

    function setUp() public {
        // Deploy tokens
        usdc = new MockERC20("USDC", "USDC", 18);
        irm = new InterestRateModel(200, 600, 10_000, 8000);

        // Deploy ACLManager and core
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        // Deploy OracleHub (UUPS proxy)
        LPOracleHub ohImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(ohImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );

        // Deploy PositionManager (UUPS proxy)
        PositionManager pmImpl = new PositionManager();
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        // Deploy LendingEngine (UUPS proxy)
        LendingEngine leImpl = new LendingEngine();
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        // Deploy mocks
        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        oracle.setPrice(50_000e18); // $50K collateral
        market = new MockMarket(address(usdc), address(irm));

        // Register everything and grant roles via ACLManager
        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(address(le));
        aclManager.addLiquidationEngine(liquidationEngine);
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
        vm.stopPrank();

        // Fund market with USDC (use 18 decimals to match oracle/debt accounting)
        // In production, decimals conversion would be handled. For testing, use same scale.
        usdc.mint(address(market), 1_000_000e18);
    }

    // --- Helpers ---

    function _depositPosition(address user) internal returns (uint256 posId) {
        vm.prank(user);
        posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2); // Advance past borrow cooldown
    }

    function _depositAndBorrow(address user, uint256 borrowAmount) internal returns (uint256 posId) {
        posId = _depositPosition(user);
        vm.prank(user);
        le.borrow(posId, borrowAmount);
    }

    // ========== Initialization ==========

    function test_initialize_setsState() public view {
        assertEq(address(le.core()), address(core));
        assertEq(address(le.positionManager()), address(pm));
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        le.initialize(address(core), address(pm));
    }

    // ========== borrow ==========

    function test_borrow_success() public {
        uint256 posId = _depositPosition(alice);

        // $50K collateral * 65% LTV = $32,500 max borrow
        vm.prank(alice);
        le.borrow(posId, 20_000e18);

        assertEq(le.getDebt(posId), 20_000e18);
        assertEq(usdc.balanceOf(alice), 20_000e18); // Alice received USDC
    }

    function test_borrow_emitsEvent() public {
        uint256 posId = _depositPosition(alice);

        vm.expectEmit(true, true, false, true);
        emit Borrowed(posId, alice, 10_000e18, 10_000e18);

        vm.prank(alice);
        le.borrow(posId, 10_000e18);
    }

    function test_borrow_multipleBorrows() public {
        uint256 posId = _depositPosition(alice);

        vm.startPrank(alice);
        le.borrow(posId, 10_000e18);
        le.borrow(posId, 5000e18);
        vm.stopPrank();

        assertEq(le.getDebt(posId), 15_000e18);
        assertEq(usdc.balanceOf(alice), 15_000e18);
    }

    function test_borrow_updatesPositionStatus() public {
        uint256 posId = _depositPosition(alice);

        IPositionManager.Position memory posBefore = pm.getPosition(posId);
        assertEq(uint8(posBefore.status), uint8(IPositionManager.PositionStatus.Active));

        vm.prank(alice);
        le.borrow(posId, 10_000e18);

        IPositionManager.Position memory posAfter = pm.getPosition(posId);
        assertEq(uint8(posAfter.status), uint8(IPositionManager.PositionStatus.Borrowed));
    }

    function test_borrow_revertsNotOwner() public {
        uint256 posId = _depositPosition(alice);

        vm.prank(bob);
        vm.expectRevert("NOT_POSITION_OWNER");
        le.borrow(posId, 10_000e18);
    }

    function test_borrow_revertsExceedsLTV() public {
        uint256 posId = _depositPosition(alice);

        // $50K * 65% = $32,500 max. Try $40K
        vm.prank(alice);
        vm.expectRevert("EXCEEDS_MAX_LTV");
        le.borrow(posId, 40_000e18);
    }

    function test_borrow_revertsZeroAmount() public {
        uint256 posId = _depositPosition(alice);

        vm.prank(alice);
        vm.expectRevert("ZERO_AMOUNT");
        le.borrow(posId, 0);
    }

    function test_borrow_revertsWhenPaused() public {
        uint256 posId = _depositPosition(alice);

        vm.prank(guardian);
        core.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        le.borrow(posId, 10_000e18);
    }

    function test_borrow_revertsClosedPosition() public {
        uint256 posId = _depositPosition(alice);

        vm.prank(alice);
        pm.withdraw(posId);

        vm.prank(alice);
        vm.expectRevert("POSITION_NOT_ACTIVE");
        le.borrow(posId, 10_000e18);
    }

    // ========== repay ==========

    function test_repay_partial() public {
        uint256 posId = _depositAndBorrow(alice, 20_000e18);

        // Approve market to pull USDC from Alice
        vm.prank(alice);
        usdc.approve(address(market), 10_000e18);

        vm.prank(alice);
        le.repay(posId, 10_000e18);

        assertEq(le.getDebt(posId), 10_000e18);
    }

    function test_repay_full() public {
        uint256 posId = _depositAndBorrow(alice, 20_000e18);

        vm.prank(alice);
        usdc.approve(address(market), 20_000e18);

        vm.prank(alice);
        le.repay(posId, type(uint256).max);

        assertEq(le.getDebt(posId), 0);

        // Position should be back to Active
        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Active));
    }

    function test_repay_emitsEvent() public {
        uint256 posId = _depositAndBorrow(alice, 20_000e18);

        vm.prank(alice);
        usdc.approve(address(market), 5000e18);

        vm.expectEmit(true, true, false, true);
        emit Repaid(posId, alice, 5000e18, 15_000e18);

        vm.prank(alice);
        le.repay(posId, 5000e18);
    }

    function test_repay_revertsNoDebt() public {
        uint256 posId = _depositPosition(alice);

        vm.prank(alice);
        vm.expectRevert("NO_DEBT");
        le.repay(posId, 1000e18);
    }

    function test_repay_revertsExceedsDebt() public {
        uint256 posId = _depositAndBorrow(alice, 10_000e18);

        vm.prank(alice);
        usdc.approve(address(market), 20_000e18);

        vm.prank(alice);
        vm.expectRevert("REPAY_EXCEEDS_DEBT");
        le.repay(posId, 20_000e18);
    }

    function test_repay_revertsWhenPaused() public {
        uint256 posId = _depositAndBorrow(alice, 10_000e18);

        vm.prank(guardian);
        core.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        le.repay(posId, 5000e18);
    }

    // ========== repayOnBehalf ==========

    function test_repayOnBehalf_success() public {
        uint256 posId = _depositAndBorrow(alice, 20_000e18);

        // Give liquidationEngine USDC and approve market
        usdc.mint(liquidationEngine, 10_000e18);
        vm.prank(liquidationEngine);
        usdc.approve(address(market), 10_000e18);

        vm.prank(liquidationEngine);
        le.repayOnBehalf(posId, 10_000e18);

        assertEq(le.getDebt(posId), 10_000e18);
    }

    function test_repayOnBehalf_revertsNotLiquidationEngine() public {
        uint256 posId = _depositAndBorrow(alice, 20_000e18);

        vm.prank(bob);
        vm.expectRevert("NOT_LIQUIDATION_ENGINE");
        le.repayOnBehalf(posId, 5000e18);
    }

    // ========== PM-5: Borrow Cooldown ==========

    function test_borrow_revertsSameBlock() public {
        // Deposit WITHOUT advancing block (bypass helper)
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        // DO NOT advance block — same block as deposit

        vm.prank(alice);
        vm.expectRevert("BORROW_COOLDOWN");
        le.borrow(posId, 10_000e18);
    }

    function test_borrow_revertsOneBlockLater() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        // Advance only 1 block — still within cooldown (need > depositBlock + 1)
        vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert("BORROW_COOLDOWN");
        le.borrow(posId, 10_000e18);
    }

    function test_borrow_succeedsAfterCooldown() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        // Advance 2 blocks — past cooldown (block.number > depositBlock + 1)
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 10_000e18);
        assertEq(le.getDebt(posId), 10_000e18);
    }

    function test_borrow_respectsCustomCooldown() public {
        // Set cooldown to 5 blocks
        vm.prank(owner);
        le.setBorrowCooldown(5);

        vm.roll(100); // Start at known block
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        // pos.depositBlock = 100

        // Block 103 — still within cooldown (need > 100 + 5 = 105)
        vm.roll(103);
        vm.prank(alice);
        vm.expectRevert("BORROW_COOLDOWN");
        le.borrow(posId, 10_000e18);

        // Block 105 — exactly at boundary, still blocked (105 > 105 is false)
        vm.roll(105);
        vm.prank(alice);
        vm.expectRevert("BORROW_COOLDOWN");
        le.borrow(posId, 10_000e18);

        // Block 106 — past cooldown (106 > 105 is true)
        vm.roll(106);
        vm.prank(alice);
        le.borrow(posId, 10_000e18);
        assertEq(le.getDebt(posId), 10_000e18);
    }

    function test_setBorrowCooldown_success() public {
        vm.prank(owner);
        le.setBorrowCooldown(10);
        assertEq(le.borrowCooldownBlocks(), 10);
    }

    function test_setBorrowCooldown_revertsBelowMin() public {
        vm.prank(owner);
        vm.expectRevert("OUT_OF_BOUNDS");
        le.setBorrowCooldown(0);
    }

    function test_setBorrowCooldown_revertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert("OUT_OF_BOUNDS");
        le.setBorrowCooldown(51);
    }

    function test_setBorrowCooldown_revertsNotPoolAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        le.setBorrowCooldown(5);
    }

    // ========== Interest accrual (reads from Market.borrowIndex) ==========

    function test_borrowIndex_initializedToRAY() public view {
        // Market borrowIndex starts at 1e27 (RAY = 1.0)
        assertEq(market.borrowIndex(), 1e27);
    }

    function test_accrueInterest_delegatesToMarket() public {
        // accrueInterest on LendingEngine just calls Market.accrueInterest()
        // Since MockMarket's accrueInterest is a no-op, index stays at RAY
        le.accrueInterest(marketId);
        assertEq(market.borrowIndex(), 1e27);
    }

    function test_debt_growsWhenBorrowIndexIncreases() public {
        uint256 posId = _depositAndBorrow(alice, 20_000e18);

        // Debt at borrow time
        assertEq(le.getDebt(posId), 20_000e18);

        // Simulate interest: Market.borrowIndex increases by 10%
        // New index = 1e27 * 1.1 = 1.1e27
        market.setBorrowIndex(1.1e27);

        // Debt should now be 20_000 * 1.1 = 22_000
        uint256 debtAfter = le.getDebt(posId);
        assertEq(debtAfter, 22_000e18);
    }

    function test_debt_correctAfterMultipleIndexUpdates() public {
        uint256 posId = _depositAndBorrow(alice, 10_000e18);

        // 5% interest
        market.setBorrowIndex(1.05e27);
        assertEq(le.getDebt(posId), 10_500e18);

        // Another 10% (compound: 1.05 * 1.1 = 1.155)
        market.setBorrowIndex(1.155e27);
        assertEq(le.getDebt(posId), 11_550e18);
    }

    // ========== getDebt ==========

    function test_debt_growsWithInterest() public {
        uint256 posId = _depositAndBorrow(alice, 20_000e18);
        assertEq(le.getDebt(posId), 20_000e18);

        // Simulate 8% annual interest (borrowIndex increases by 8%)
        market.setBorrowIndex(1.08e27);

        uint256 debtAfter = le.getDebt(posId);
        assertEq(debtAfter, 21_600e18); // 20_000 * 1.08
        assertGt(debtAfter, 20_000e18);
    }

    function test_debt_zeroForNoDebt() public {
        uint256 posId = _depositPosition(alice);
        assertEq(le.getDebt(posId), 0);
    }

    // ========== getMaxBorrow ==========

    function test_getMaxBorrow_basedOnLTV() public {
        oracle.setPrice(100_000e18); // $100K collateral
        uint256 posId = _depositPosition(alice);

        // 100K * 65% LTV = 65K max borrow
        assertEq(le.getMaxBorrow(posId), 65_000e18);
    }

    function test_getMaxBorrow_changesWithOraclePrice() public {
        uint256 posId = _depositPosition(alice);

        uint256 max1 = le.getMaxBorrow(posId);

        oracle.setPrice(100_000e18); // Price doubles
        uint256 max2 = le.getMaxBorrow(posId);

        assertGt(max2, max1);
    }

    // ========== UUPS Upgrade ==========

    function test_upgrade_onlyPoolAdmin() public {
        LendingEngine newImpl = new LendingEngine();

        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        le.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_preservesDebt() public {
        uint256 posId = _depositAndBorrow(alice, 15_000e18);

        LendingEngine newImpl = new LendingEngine();
        vm.prank(owner);
        le.upgradeToAndCall(address(newImpl), "");

        // Debt preserved after upgrade
        assertEq(le.getDebt(posId), 15_000e18);
    }

    // ========== Full Lifecycle ==========

    function test_lifecycle_borrowRepayBorrowAgain() public {
        uint256 posId = _depositPosition(alice);

        // Borrow
        vm.prank(alice);
        le.borrow(posId, 10_000e18);
        assertEq(le.getDebt(posId), 10_000e18);

        // Full repay
        vm.prank(alice);
        usdc.approve(address(market), 10_000e18);
        vm.prank(alice);
        le.repay(posId, type(uint256).max);
        assertEq(le.getDebt(posId), 0);

        // Borrow again
        vm.prank(alice);
        le.borrow(posId, 5000e18);
        assertEq(le.getDebt(posId), 5000e18);
    }

    // ========== Fuzz Tests ==========

    function testFuzz_borrow_withinLTV(uint256 amount) public {
        oracle.setPrice(100_000e18); // $100K
        uint256 posId = _depositPosition(alice);
        // Max = 65,000
        amount = bound(amount, 1e18, 65_000e18);

        vm.prank(alice);
        le.borrow(posId, amount);

        assertEq(le.getDebt(posId), amount);
    }

    function testFuzz_borrow_revertsAboveLTV(uint256 amount) public {
        oracle.setPrice(100_000e18);
        uint256 posId = _depositPosition(alice);
        amount = bound(amount, 65_001e18, 200_000e18);

        vm.prank(alice);
        vm.expectRevert("EXCEEDS_MAX_LTV");
        le.borrow(posId, amount);
    }

    function testFuzz_repay_anyValidAmount(uint256 borrowAmt, uint256 repayAmt) public {
        oracle.setPrice(100_000e18);
        borrowAmt = bound(borrowAmt, 1e18, 65_000e18);
        uint256 posId = _depositPosition(alice);

        vm.prank(alice);
        le.borrow(posId, borrowAmt);

        repayAmt = bound(repayAmt, 1, borrowAmt);

        vm.prank(alice);
        usdc.approve(address(market), repayAmt);
        vm.prank(alice);
        le.repay(posId, repayAmt);

        assertEq(le.getDebt(posId), borrowAmt - repayAmt);
    }
}
