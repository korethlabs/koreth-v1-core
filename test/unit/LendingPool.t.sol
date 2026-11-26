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
import {MockFeeOnTransferERC20} from "../mocks/MockFeeOnTransferERC20.sol";

contract LendingPoolTest is Test {
    using stdStorage for StdStorage;

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

    /// @notice Debt derives from borrowIndex and can exceed totalBorrow by the interest each accrual
    ///         floored away. Delivering it zeroes totalBorrow, and the part totalBorrow never held goes
    ///         to reserves, so `balance + totalBorrow == totalSupply + protocolReserves` still holds.
    function test_transferIn_aboveTotalBorrow_creditsExcessToReserves() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        pool.supply(10_000e6);

        vm.prank(le);
        pool.transferOut(makeAddr("b"), 5000e6);

        address repayer = makeAddr("repayer");
        usdc.mint(repayer, 5000e6 + 7);
        vm.prank(repayer);
        usdc.approve(address(pool), 5000e6 + 7);

        vm.prank(le);
        pool.transferIn(repayer, 5000e6 + 7);

        ILendingPool.PoolState memory s = pool.getPoolState();
        assertEq(usdc.balanceOf(repayer), 0, "full amount delivered");
        assertEq(s.totalBorrow, 0, "totalBorrow floors at zero");
        assertEq(pool.protocolReserves(), 7, "excess into reserves");
        assertEq(s.totalSupply, 10_000e6, "suppliers untouched");
        assertEq(usdc.balanceOf(address(pool)) + s.totalBorrow, s.totalSupply + pool.protocolReserves(), "identity");
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

    /// @notice A write-off that finds totalBorrow empty changes nothing and does not revert: it runs
    ///         inside liquidate(), and the debt it was handed was never on the pool's books.
    function test_recordDeficit_nothingToBurn_isNoOp() public {
        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        pool.supply(100_000e6);

        vm.expectEmit(address(pool));
        emit LendingPool.DeficitRecorded(0, 0, 0, 0);
        vm.prank(le);
        pool.recordDeficit(1000e6);

        assertEq(pool.deficit(), 0, "no deficit");
        assertEq(pool.getPoolState().totalSupply, 100_000e6, "suppliers untouched");
    }

    /// @notice A total default (100% utilization, no reserves) can socialize the loss all the way to
    ///         totalSupply == 0. In that insolvent state both sides of the lender interface are
    ///         refused: deposits (which would divide by zero and gift the deposit to worthless legacy
    ///         shares) and withdrawals (which would burn the shares for no tokens at all).
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

        // Withdrawals are refused too: the shares redeem to nothing, so burning them would destroy
        // the holder's claim for no tokens in return.
        uint256 aliceShares = pool.shares(alice);
        vm.prank(alice);
        vm.expectRevert("ZERO_REDEEM_VALUE");
        pool.withdraw(aliceShares);
        assertEq(pool.shares(alice), aliceShares, "shares survive the refused withdrawal");
    }

    // ========== Insolvent-market withdrawals ==========

    /// @dev Drives the market to totalSupply == 0 while shares stay outstanding, and returns the
    ///      shares alice is left holding. The solvency identity forces the fully-drained shape:
    ///      totalSupply == totalBorrow == protocolReserves == 0 and no cash in the pool.
    function _wipeMarket() internal returns (uint256 aliceShares) {
        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        aliceShares = pool.supply(100_000e6);

        vm.prank(le);
        pool.transferOut(makeAddr("borrower"), 100_000e6);

        vm.prank(le);
        pool.recordDeficit(100_000e6);

        assertEq(pool.getPoolState().totalSupply, 0, "market is insolvent");
        assertGt(pool.totalShares(), 0, "shares still outstanding (dead shares guarantee this)");
    }

    /// @notice A withdrawal that redeems to zero must revert instead of burning the shares.
    ///         Pre-fix this call succeeded: it burned every share, transferred nothing and emitted
    ///         Withdraw(alice, 0, shares) — silently forfeiting the lender's claim on any later
    ///         eliminateDeficit() recovery. `supply` already refuses this same state; `withdraw` did not.
    function test_withdraw_insolventMarket_revertsInsteadOfBurningSharesForNothing() public {
        uint256 aliceShares = _wipeMarket();

        vm.prank(alice);
        try pool.withdraw(aliceShares) returns (uint256 received) {
            emit log_string("PRE-FIX BEHAVIOUR: withdraw() succeeded in an insolvent market");
            emit log_named_uint("  tokens received by alice", received);
            emit log_named_uint("  shares burned", aliceShares);
            emit log_named_uint("  shares alice has left", pool.shares(alice));
            fail("withdraw must revert when the shares redeem to zero");
        } catch Error(string memory reason) {
            assertEq(reason, "ZERO_REDEEM_VALUE", "must fail closed with a named reason");
        }

        assertEq(pool.shares(alice), aliceShares, "alice keeps her shares");
        assertEq(usdc.balanceOf(alice), 0, "and received nothing, as expected");
    }

    /// @notice The point of reverting: the blocked lender's claim survives, so when eliminateDeficit()
    ///         credits recovered reserves back into totalSupply she can withdraw a non-zero amount.
    ///         Pre-fix her shares would already be gone and the whole recovery would accrue to holders
    ///         who happened not to call withdraw.
    function test_withdraw_insolventMarket_claimSurvivesEliminateDeficit() public {
        vm.prank(owner);
        aclManager.addRiskAdmin(owner);

        uint256 aliceShares = _wipeMarket();
        uint256 outstandingDeficit = pool.deficit();

        // The withdrawal is refused while insolvent.
        vm.prank(alice);
        vm.expectRevert("ZERO_REDEEM_VALUE");
        pool.withdraw(aliceShares);

        // Recovery arrives. A fully wiped pool holds no cash and no outstanding debt, so it cannot
        // rebuild reserves from interest on its own, and the pool has no entrypoint for external
        // recapitalisation — so credit the reserves directly (slot resolved via the getter, not
        // hardcoded) and fund the matching cash.
        uint256 recovered = 30_000e6;
        stdstore.target(address(pool)).sig(pool.protocolReserves.selector).checked_write(recovered);
        assertEq(pool.protocolReserves(), recovered, "reserves credited");
        usdc.mint(address(pool), recovered);

        vm.prank(owner);
        pool.eliminateDeficit();
        assertEq(pool.getPoolState().totalSupply, recovered, "recovery lands back in totalSupply");
        assertEq(pool.deficit(), outstandingDeficit - recovered, "deficit reduced by the recovery");

        vm.prank(alice);
        uint256 received = pool.withdraw(aliceShares);
        assertGt(received, 0, "the preserved claim now redeems for real tokens");
        assertEq(usdc.balanceOf(alice), received, "tokens actually reached alice");
    }

    /// @notice The same check also covers dust rounding down to zero in a market that is still
    ///         solvent — a case a `totalSupply > 0` guard would miss entirely.
    function test_withdraw_revertsWhenDustRoundsToZero() public {
        _fundAndApprove(alice, 100_000e6);
        vm.prank(alice);
        pool.supply(100_000e6);

        vm.prank(le);
        pool.transferOut(makeAddr("borrower"), 100_000e6);

        // Socialize everything but one unit: share price is now 1 wei per 1e11 shares.
        vm.prank(le);
        pool.recordDeficit(100_000e6 - 1);
        assertEq(pool.getPoolState().totalSupply, 1, "market is solvent, just tiny");

        vm.prank(alice);
        vm.expectRevert("ZERO_REDEEM_VALUE");
        pool.withdraw(1);
    }

    // ========== transferIn: exact settlement only ==========

    MockFeeOnTransferERC20 public fotToken;
    LendingPool public fotPool;

    /// @dev A second pool whose borrow asset misbehaves on transfer. `feeBps` short-delivers,
    ///      `bonusBps` over-delivers; both are zero unless a test opts in.
    function _setUpFotPool(uint256 feeBps) internal {
        fotToken = new MockFeeOnTransferERC20("Fee USD", "fUSD", 6, feeBps);
        ILendingPool.PoolConfig memory cfg = ILendingPool.PoolConfig({borrowAsset: address(fotToken)});
        LendingPool impl = new LendingPool();
        fotPool = LendingPool(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(LendingPool.initialize, (cfg, address(irm), address(core)))
                )
            )
        );

        address lender = makeAddr("fotLender");
        fotToken.mint(lender, 100_000e6);
        vm.startPrank(lender);
        fotToken.approve(address(fotPool), 100_000e6);
        fotPool.supply(100_000e6);
        vm.stopPrank();

        vm.prank(le);
        fotPool.transferOut(makeAddr("fotBorrower"), 50_000e6);
    }

    /// @notice LendingEngine._repay writes the borrower's debt down by the *requested* repayAmount
    ///         before calling transferIn. With a fee-on-transfer borrow asset the pool receives less
    ///         than that, so the difference is debt forgiven at the lenders' expense — repeatably.
    ///         transferIn must refuse the asset outright, exactly as LiquidationEngine's repayment
    ///         path already does.
    function test_transferIn_feeOnTransferAsset_reverts() public {
        _setUpFotPool(100); // 1% fee on every transfer

        address repayer = makeAddr("fotRepayer");
        uint256 repayAmount = 5000e6;
        fotToken.mint(repayer, repayAmount);
        vm.prank(repayer);
        fotToken.approve(address(fotPool), repayAmount);

        uint256 poolBalBefore = fotToken.balanceOf(address(fotPool));
        uint256 borrowBefore = fotPool.getPoolState().totalBorrow;

        vm.prank(le);
        try fotPool.transferIn(repayer, repayAmount) {
            uint256 actuallyReceived = fotToken.balanceOf(address(fotPool)) - poolBalBefore;
            uint256 borrowAfter = fotPool.getPoolState().totalBorrow;
            emit log_string("PRE-FIX BEHAVIOUR: transferIn() accepted a short delivery");
            emit log_named_uint("  repayAmount the caller already credited the borrower", repayAmount);
            emit log_named_uint("  tokens the pool actually received", actuallyReceived);
            emit log_named_uint("  debt forgiven for free (repayAmount - received)", repayAmount - actuallyReceived);
            emit log_named_uint("  pool totalBorrow before", borrowBefore);
            emit log_named_uint("  pool totalBorrow after", borrowAfter);
            fail("transferIn must refuse a fee-on-transfer borrow asset");
        } catch Error(string memory reason) {
            assertEq(reason, "FEE_ON_TRANSFER_UNSUPPORTED", "same refusal, same name as LiquidationEngine");
        }

        assertEq(fotPool.getPoolState().totalBorrow, borrowBefore, "no debt written off");
        assertEq(fotToken.balanceOf(address(fotPool)), poolBalBefore, "no tokens moved");
    }

    /// @notice The mirror case: an asset that delivers MORE than requested (rebase, or a donation
    ///         landing mid-call) used to pass the old `received <= amount` bound only when it was
    ///         short, and silently understated totalBorrow when it was long.
    function test_transferIn_overDeliveringAsset_reverts() public {
        _setUpFotPool(0);
        fotToken.setBonusBps(100); // delivers 1% more than requested

        address repayer = makeAddr("fotRepayer");
        uint256 repayAmount = 5000e6;
        fotToken.mint(repayer, repayAmount);
        vm.prank(repayer);
        fotToken.approve(address(fotPool), repayAmount);

        vm.prank(le);
        vm.expectRevert("FEE_ON_TRANSFER_UNSUPPORTED");
        fotPool.transferIn(repayer, repayAmount);
    }

    /// @notice Happy path guard: with a well-behaved asset the equality holds, so supply, borrow,
    ///         repay and withdraw all still settle exactly.
    function test_transferIn_wellBehavedAsset_fullRoundTripStillWorks() public {
        _setUpFotPool(0); // no fee, no bonus — an ordinary ERC20

        address repayer = makeAddr("fotRepayer");
        uint256 repayAmount = 5000e6;
        fotToken.mint(repayer, repayAmount);
        vm.prank(repayer);
        fotToken.approve(address(fotPool), repayAmount);

        uint256 borrowBefore = fotPool.getPoolState().totalBorrow;
        vm.prank(le);
        fotPool.transferIn(repayer, repayAmount);

        assertEq(fotPool.getPoolState().totalBorrow, borrowBefore - repayAmount, "debt settles exactly");
        assertEq(fotToken.balanceOf(repayer), 0, "repayer paid exactly the requested amount");

        // Half the shares: the rest of the lender's capital is still lent out.
        address lender = makeAddr("fotLender");
        uint256 lenderShares = fotPool.shares(lender) / 2;
        vm.prank(lender);
        uint256 withdrawn = fotPool.withdraw(lenderShares);
        assertGt(withdrawn, 0, "lender still withdraws normally");
        assertEq(fotToken.balanceOf(lender), withdrawn, "tokens reached the lender");
    }

    /// @notice The original well-behaved-token path, now asserting the accounting and not just the
    ///         token movement.
    function test_transferIn_reducesTotalBorrowExactly() public {
        _fundAndApprove(alice, 10_000e6);
        vm.prank(alice);
        pool.supply(10_000e6);

        vm.prank(le);
        pool.transferOut(makeAddr("b"), 5000e6);
        assertEq(pool.getPoolState().totalBorrow, 5000e6);

        address repayer = makeAddr("repayer");
        usdc.mint(repayer, 3000e6);
        vm.prank(repayer);
        usdc.approve(address(pool), 3000e6);

        vm.prank(le);
        pool.transferIn(repayer, 3000e6);
        assertEq(pool.getPoolState().totalBorrow, 2000e6, "totalBorrow drops by exactly the amount");
        assertEq(usdc.balanceOf(address(pool)), 8000e6, "pool cash matches");
    }
}
