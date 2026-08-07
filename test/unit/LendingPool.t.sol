// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {LendingPool} from "../../src/markets/LendingPool.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {ILendingPool} from "../../src/interfaces/ILendingPool.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract LendingPoolTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    LendingPool public pool;
    MockERC20 public usdc;
    InterestRateModel public irm;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public le = makeAddr("lendingEngine"); // LendingEngine address
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    uint256 constant DEAD_SHARES = 1_000_000;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        irm = new InterestRateModel(200, 600, 10_000, 8000);
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        ILendingPool.PoolConfig memory config = ILendingPool.PoolConfig({borrowAsset: address(usdc)});

        LendingPool impl = new LendingPool();
        pool = LendingPool(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(LendingPool.initialize, (config, address(irm), address(core)))
                )
            )
        );

        // Grant le the LENDING_ENGINE role so it can call transferOut/transferIn
        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(le);
        vm.stopPrank();
    }

    function _fundAndApprove(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(pool), amount);
    }

    // ========== Initialization ==========

    function test_initialize_setsState() public view {
        assertEq(address(pool.core()), address(core));
        assertEq(pool.borrowIndex(), 1e27);
        assertEq(pool.borrowAsset(), address(usdc));
    }

    function test_initialize_revertsZeroBorrowAsset() public {
        ILendingPool.PoolConfig memory badConfig = ILendingPool.PoolConfig({borrowAsset: address(0)});
        LendingPool impl = new LendingPool();
        vm.expectRevert("ZERO_BORROW_ASSET");
        new ERC1967Proxy(
            address(impl), abi.encodeCall(LendingPool.initialize, (badConfig, address(irm), address(core)))
        );
    }

    // ========== First Deposit (dead shares) ==========

    function test_supply_firstDeposit_mintsDeadShares() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        uint256 shares = pool.supply(10_000e6);

        assertEq(shares, 10_000e6 - DEAD_SHARES);
        assertEq(pool.shares(address(0xdead)), DEAD_SHARES);
        assertEq(pool.totalShares(), 10_000e6);
    }

    function test_supply_firstDeposit_revertsBelowMinimum() public {
        _fundAndApprove(alice, 500);
        vm.prank(alice);
        vm.expectRevert("BELOW_MINIMUM_DEPOSIT");
        pool.supply(500);
    }

    // ========== MKT-1: Inflation Attack ==========

    function test_inflationAttack_blocked() public {
        _fundAndApprove(attacker, DEAD_SHARES + 1);
        vm.prank(attacker);
        pool.supply(DEAD_SHARES + 1);

        usdc.mint(address(pool), 10_000e6); // Donation

        _fundAndApprove(bob, 5000e6);
        vm.prank(bob);
        uint256 victimShares = pool.supply(5000e6);

        assertGt(victimShares, 0, "Victim must receive shares");
        assertEq(victimShares, 5000e6);
    }

    // ========== Normal Supply/Withdraw ==========

    function test_supply_secondDeposit_normalShares() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        pool.supply(10_000e6);

        _fundAndApprove(bob, 5000e6);
        vm.prank(bob);
        uint256 bobShares = pool.supply(5000e6);
        assertEq(bobShares, 5000e6);
    }

    function test_supply_revertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("ZERO_AMOUNT");
        pool.supply(0);
    }

    function test_withdraw_success() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        uint256 aliceShares = pool.supply(10_000e6);

        vm.prank(alice);
        uint256 received = pool.withdraw(aliceShares);
        assertEq(received, 10_000e6 - DEAD_SHARES);
        assertEq(pool.shares(alice), 0);
    }

    function test_withdraw_revertsInsufficientShares() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        pool.supply(10_000e6);

        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_SHARES");
        pool.withdraw(10_000e6);
    }

    function test_withdraw_revertsInsufficientLiquidity() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        uint256 aliceShares = pool.supply(10_000e6);

        vm.prank(le);
        pool.transferOut(makeAddr("borrower"), 8000e6);

        vm.prank(alice);
        vm.expectRevert("INSUFFICIENT_LIQUIDITY");
        pool.withdraw(aliceShares);
    }

    // ========== Interest Accrual ==========

    function test_accrueInterest_initialState() public view {
        assertEq(pool.borrowIndex(), 1e27);
    }

    function test_accrueInterest_noOpWhenNoBorrows() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        pool.supply(10_000e6);

        uint256 indexBefore = pool.borrowIndex();
        vm.warp(block.timestamp + 365 days);
        pool.accrueInterest();
        assertEq(pool.borrowIndex(), indexBefore);
    }

    function test_accrueInterest_indexGrowsWithBorrows() public {
        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        pool.supply(100_000e6);

        vm.prank(le);
        pool.transferOut(makeAddr("b"), 50_000e6);

        uint256 indexBefore = pool.borrowIndex();
        vm.warp(block.timestamp + 365 days);
        pool.accrueInterest();
        assertGt(pool.borrowIndex(), indexBefore);
    }

    function test_accrueInterest_idempotentSameBlock() public {
        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        pool.supply(100_000e6);

        vm.prank(le);
        pool.transferOut(makeAddr("b"), 50_000e6);

        vm.warp(block.timestamp + 100);
        pool.accrueInterest();
        uint256 index1 = pool.borrowIndex();
        pool.accrueInterest();
        assertEq(pool.borrowIndex(), index1);
    }

    // ========== TransferOut / TransferIn ==========

    function test_transferOut_success() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        pool.supply(10_000e6);

        address borrower = makeAddr("borrower");
        vm.prank(le);
        pool.transferOut(borrower, 5000e6);
        assertEq(usdc.balanceOf(borrower), 5000e6);
    }

    function test_transferOut_revertsNotLendingEngine() public {
        vm.prank(alice);
        vm.expectRevert("NOT_LENDING_ENGINE");
        pool.transferOut(alice, 1000e6);
    }

    function test_transferOut_revertsInsufficientLiquidity() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        pool.supply(10_000e6);

        vm.prank(le);
        vm.expectRevert("INSUFFICIENT_LIQUIDITY");
        pool.transferOut(makeAddr("b"), 11_000e6);
    }

    function test_transferIn_success() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        pool.supply(10_000e6);

        vm.prank(le);
        pool.transferOut(makeAddr("b"), 5000e6);

        address repayer = makeAddr("repayer");
        usdc.mint(repayer, 5000e6);
        vm.prank(repayer);
        usdc.approve(address(pool), 5000e6);

        vm.prank(le);
        pool.transferIn(repayer, 5000e6);
        assertEq(usdc.balanceOf(repayer), 0);
    }

    function test_transferIn_revertsNotLendingEngine() public {
        vm.prank(alice);
        vm.expectRevert("NOT_LENDING_ENGINE");
        pool.transferIn(alice, 1000e6);
    }

    // ========== ACLManager: LendingEngine Role ==========

    function test_lendingEngineRole_changeRole() public {
        address newLE = makeAddr("newLE");

        vm.startPrank(owner);
        aclManager.removeLendingEngine(le);
        aclManager.addLendingEngine(newLE);
        vm.stopPrank();

        // Old LE can no longer call
        vm.prank(le);
        vm.expectRevert("NOT_LENDING_ENGINE");
        pool.transferOut(makeAddr("x"), 100);

        // New LE can call
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        pool.supply(10_000e6);

        vm.prank(newLE);
        pool.transferOut(makeAddr("x"), 100);
    }

    function test_lendingEngineRole_revertsNotAdmin() public {
        bytes32 leRole = aclManager.LENDING_ENGINE();
        bytes32 adminRole = aclManager.DEFAULT_ADMIN_ROLE();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, adminRole));
        aclManager.grantRole(leRole, makeAddr("x"));
    }

    // ========== Admin (owner via ProtocolCore) ==========

    function test_setReserveFactor_success() public {
        vm.prank(owner);
        aclManager.addRiskAdmin(owner);
        vm.prank(owner);
        pool.setReserveFactor(2000);
        assertEq(pool.reserveFactorBps(), 2000);
    }

    function test_setReserveFactor_revertsNotRiskAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NOT_RISK_ADMIN");
        pool.setReserveFactor(2000);
    }

    function test_upgrade_onlyPoolAdmin() public {
        LendingPool newImpl = new LendingPool();
        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        pool.upgradeToAndCall(address(newImpl), "");

        vm.prank(owner);
        pool.upgradeToAndCall(address(newImpl), "");
    }

    // ========== Fuzz ==========

    function testFuzz_supply_alwaysGetsShares(uint256 amount) public {
        amount = bound(amount, DEAD_SHARES + 1, 1_000_000_000e6);
        _fundAndApprove(alice, amount);
        vm.prank(alice);
        uint256 shares = pool.supply(amount);
        assertGt(shares, 0);
    }

    function testFuzz_supplyWithdraw_roundTrip(uint256 amount) public {
        amount = bound(amount, DEAD_SHARES + 1, 1_000_000_000e6);
        _fundAndApprove(alice, amount);
        vm.prank(alice);
        uint256 aliceShares = pool.supply(amount);

        vm.prank(alice);
        uint256 received = pool.withdraw(aliceShares);
        assertLe(amount - received, DEAD_SHARES);
    }

    // ========== Interest Accrual — borrows always accrue ==========

    function test_accrueInterest_withBorrows_alwaysAccrues() public {
        vm.prank(owner);
        aclManager.addRiskAdmin(owner);
        vm.prank(owner);
        pool.setReserveFactor(2000); // 20%

        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        pool.supply(10_000e6);

        vm.prank(le);
        pool.transferOut(makeAddr("borrower"), 5000e6);

        ILendingPool.PoolState memory s = pool.getPoolState();
        assertGt(s.totalSupply, 0, "Must have supply");
        assertGt(s.totalBorrow, 0, "Must have borrows");

        uint256 totalBorrowBefore = s.totalBorrow;
        uint256 reservesBefore = pool.protocolReserves();

        vm.warp(block.timestamp + 30 days);
        pool.accrueInterest();

        ILendingPool.PoolState memory sAfter = pool.getPoolState();
        uint256 reservesAfter = pool.protocolReserves();

        assertGt(sAfter.totalBorrow, totalBorrowBefore, "Interest must accrue with outstanding borrows");
        assertGt(pool.borrowIndex(), 1e27, "BorrowIndex must grow");
        assertGt(reservesAfter, reservesBefore, "Reserves must grow from protocol share of interest");
        assertLe(sAfter.utilization, 10_000, "Utilization must be capped at 100%");
    }

    function test_accrueInterest_zeroBorrow_skips() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        pool.supply(10_000e6);

        uint256 indexBefore = pool.borrowIndex();
        vm.warp(block.timestamp + 30 days);
        pool.accrueInterest();

        assertEq(pool.borrowIndex(), indexBefore, "BorrowIndex must not change with zero borrows");
    }

    // ========== Bad Debt Socialization (Method A) ==========

    event DeficitRecorded(uint256 burned, uint256 reservesUsed, uint256 supplierLoss, uint256 totalDeficit);
    event DeficitEliminated(uint256 covered, uint256 refundedToSuppliers, uint256 remaining);

    /// @dev Redeemable value of a supplier's shares at the current share price.
    function _shareValue(address user) internal view returns (uint256) {
        return (pool.shares(user) * pool.getPoolState().totalSupply) / pool.totalShares();
    }

    /// @notice With no reserves, the whole write-off is socialized onto suppliers immediately:
    ///         totalSupply and totalBorrow both drop by the burn, and the share price falls pro-rata.
    function test_recordDeficit_socializesOntoSuppliersWhenNoReserves() public {
        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        pool.supply(100_000e6);

        // Move cash out as a borrow so there is outstanding debt to write off.
        vm.prank(le);
        pool.transferOut(makeAddr("borrower"), 60_000e6);

        assertEq(pool.protocolReserves(), 0, "no reserves accrued yet");
        uint256 priceBefore = _shareValue(alice);

        vm.prank(le);
        pool.recordDeficit(20_000e6);

        ILendingPool.PoolState memory s = pool.getPoolState();
        assertEq(s.totalSupply, 80_000e6, "totalSupply reduced by full loss");
        assertEq(s.totalBorrow, 40_000e6, "totalBorrow reduced by burn");
        assertEq(pool.deficit(), 20_000e6, "deficit tracks socialized supplier loss");
        assertEq(pool.protocolReserves(), 0, "reserves untouched (were zero)");
        assertLt(_shareValue(alice), priceBefore, "share price drops after socialization");
    }

    /// @notice The enriched event breaks the write-off into burn / reservesUsed / supplierLoss.
    function test_recordDeficit_emitsEnrichedEvent() public {
        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        pool.supply(100_000e6);
        vm.prank(le);
        pool.transferOut(makeAddr("borrower"), 60_000e6);

        vm.expectEmit(false, false, false, true, address(pool));
        emit DeficitRecorded(20_000e6, 0, 20_000e6, 20_000e6);
        vm.prank(le);
        pool.recordDeficit(20_000e6);
    }

    /// @notice The whole point of Method A: every remaining supplier eats the loss pro-rata in the
    ///         same transaction, so no one can exit at the stale price and dump the loss on others.
    function test_recordDeficit_lossIsProRataAcrossSuppliers() public {
        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        pool.supply(100_000e6);
        _fundAndApprove(bob, 100_000e6);
        vm.prank(bob);
        pool.supply(100_000e6);

        vm.prank(le);
        pool.transferOut(makeAddr("borrower"), 60_000e6);

        uint256 aliceBefore = _shareValue(alice);
        uint256 bobBefore = _shareValue(bob);

        vm.prank(le);
        pool.recordDeficit(40_000e6);

        uint256 aliceAfter = _shareValue(alice);
        uint256 bobAfter = _shareValue(bob);

        // Near-equal stakes lose the same fraction (~20%, 40k over 200k supply). They aren't exactly
        // equal because the first depositor (alice) absorbs the one-time dead-shares dilution, so
        // compare the loss *fraction* rather than absolute value.
        assertApproxEqRel(aliceAfter, bobAfter, 1e15, "equal suppliers lose ~equally (within dead-share dust)");
        assertApproxEqRel(aliceAfter, (aliceBefore * 80) / 100, 1e15, "alice lost ~20%");
        assertApproxEqRel(bobAfter, (bobBefore * 80) / 100, 1e15, "bob lost ~20%");
    }

    /// @notice Reserves absorb the loss first: a write-off fully covered by reserves leaves suppliers
    ///         untouched (totalSupply flat, deficit stays zero).
    function test_recordDeficit_reservesAbsorbFirst() public {
        vm.prank(owner);
        aclManager.addRiskAdmin(owner);
        vm.prank(owner);
        pool.setReserveFactor(2000); // 20% of interest → reserves

        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        pool.supply(100_000e6);
        vm.prank(le);
        pool.transferOut(makeAddr("borrower"), 80_000e6); // 80% utilization

        vm.warp(block.timestamp + 365 days);
        pool.accrueInterest();

        uint256 reservesBefore = pool.protocolReserves();
        assertGt(reservesBefore, 2, "interest built reserves");
        ILendingPool.PoolState memory sBefore = pool.getPoolState();
        uint256 burn = reservesBefore / 2; // strictly less than reserves

        vm.prank(le);
        pool.recordDeficit(burn);

        ILendingPool.PoolState memory sAfter = pool.getPoolState();
        assertEq(sAfter.totalSupply, sBefore.totalSupply, "suppliers untouched when reserves cover loss");
        assertEq(pool.deficit(), 0, "no socialized loss");
        assertEq(pool.protocolReserves(), reservesBefore - burn, "reserves absorbed the burn");
        assertEq(sAfter.totalBorrow, sBefore.totalBorrow - burn, "totalBorrow reduced by burn");
    }

    /// @notice When reserves only partially cover the write-off, reserves go first and suppliers
    ///         absorb exactly the remainder.
    function test_recordDeficit_reservesThenSuppliers() public {
        vm.prank(owner);
        aclManager.addRiskAdmin(owner);
        vm.prank(owner);
        pool.setReserveFactor(2000);

        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        pool.supply(100_000e6);
        vm.prank(le);
        pool.transferOut(makeAddr("borrower"), 80_000e6);

        vm.warp(block.timestamp + 365 days);
        pool.accrueInterest();

        uint256 reservesBefore = pool.protocolReserves();
        ILendingPool.PoolState memory sBefore = pool.getPoolState();
        uint256 extraSupplierLoss = 5000e6;
        uint256 burn = reservesBefore + extraSupplierLoss;

        vm.expectEmit(false, false, false, true, address(pool));
        emit DeficitRecorded(burn, reservesBefore, extraSupplierLoss, extraSupplierLoss);
        vm.prank(le);
        pool.recordDeficit(burn);

        assertEq(pool.protocolReserves(), 0, "reserves fully spent first");
        assertEq(pool.deficit(), extraSupplierLoss, "suppliers absorb only the remainder");
        assertEq(pool.getPoolState().totalSupply, sBefore.totalSupply - extraSupplierLoss, "supply drops by remainder");
    }

    /// @notice eliminateDeficit credits reserves back into totalSupply, restoring the share price for
    ///         the suppliers who ate the loss (the symmetric inverse of socialization).
    function test_eliminateDeficit_refundsSuppliers() public {
        vm.prank(owner);
        aclManager.addRiskAdmin(owner);

        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        pool.supply(100_000e6);
        vm.prank(le);
        pool.transferOut(makeAddr("borrower"), 60_000e6);

        // Socialize a loss while there are no reserves.
        vm.prank(le);
        pool.recordDeficit(40_000e6);
        assertEq(pool.deficit(), 40_000e6, "loss socialized");

        // Now let interest build reserves that can repay the socialized loss.
        vm.prank(owner);
        pool.setReserveFactor(2000);
        vm.warp(block.timestamp + 365 days);
        pool.accrueInterest();

        uint256 reservesBefore = pool.protocolReserves();
        uint256 deficitBefore = pool.deficit();
        uint256 supplyBefore = pool.getPoolState().totalSupply;
        uint256 coverage = reservesBefore < deficitBefore ? reservesBefore : deficitBefore;
        assertGt(coverage, 0, "reserves available to refund");

        vm.expectEmit(false, false, false, true, address(pool));
        emit DeficitEliminated(coverage, coverage, deficitBefore - coverage);
        vm.prank(owner);
        pool.eliminateDeficit();

        assertEq(pool.getPoolState().totalSupply, supplyBefore + coverage, "supply credited back to lenders");
        assertEq(pool.deficit(), deficitBefore - coverage, "deficit reduced by coverage");
        assertEq(pool.protocolReserves(), reservesBefore - coverage, "reserves spent on refund");
    }

    function test_eliminateDeficit_revertsNoDeficit() public {
        vm.prank(owner);
        aclManager.addRiskAdmin(owner);
        vm.prank(owner);
        vm.expectRevert("NO_DEFICIT");
        pool.eliminateDeficit();
    }

    function test_eliminateDeficit_revertsNotRiskAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NOT_RISK_ADMIN");
        pool.eliminateDeficit();
    }

    function test_recordDeficit_revertsNotLendingEngine() public {
        vm.prank(alice);
        vm.expectRevert("NOT_LENDING_ENGINE");
        pool.recordDeficit(1000e6);
    }

    function test_recordDeficit_revertsZeroAmount() public {
        vm.prank(le);
        vm.expectRevert("ZERO_AMOUNT");
        pool.recordDeficit(0);
    }

    function test_recordDeficit_revertsNoBorrowToBurn() public {
        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        pool.supply(100_000e6);
        // No borrows outstanding → nothing to write off.
        vm.prank(le);
        vm.expectRevert("NO_BORROW_TO_BURN");
        pool.recordDeficit(1000e6);
    }

    /// @notice A total default (100% utilization, no reserves) can socialize the loss all the way to
    ///         totalSupply == 0. In that insolvent state deposits are refused (would otherwise revert
    ///         on divide-by-zero and gift the deposit to worthless legacy shares) while existing
    ///         holders can still burn their now-zero-value shares.
    function test_recordDeficit_fullWipe_marketBecomesInsolvent() public {
        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        pool.supply(100_000e6);

        // Lend out the entire balance so the pool holds no cash and totalBorrow == totalSupply.
        vm.prank(le);
        pool.transferOut(makeAddr("borrower"), 100_000e6);

        // Every borrower defaults: write off the whole outstanding debt.
        vm.prank(le);
        pool.recordDeficit(100_000e6);

        ILendingPool.PoolState memory s = pool.getPoolState();
        assertEq(s.totalSupply, 0, "supply fully wiped");
        assertEq(s.totalBorrow, 0, "borrow fully written off");
        assertEq(pool.deficit(), 100_000e6, "entire loss socialized as deficit");

        // New deposits are refused while insolvent (clear error, not a divide-by-zero panic).
        _fundAndApprove(bob, 10_000e6);
        vm.prank(bob);
        vm.expectRevert("MARKET_INSOLVENT");
        pool.supply(10_000e6);

        // Existing holder can still burn worthless shares without reverting; they redeem to zero.
        uint256 aliceShares = pool.shares(alice);
        vm.prank(alice);
        uint256 received = pool.withdraw(aliceShares);
        assertEq(received, 0, "wiped shares redeem to nothing");
    }
}
