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
}
