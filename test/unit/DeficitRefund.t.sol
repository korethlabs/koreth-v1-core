// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {LendingPool} from "../../src/markets/LendingPool.sol";
import {ILendingPool} from "../../src/interfaces/ILendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TestPricing} from "../helpers/TestPricing.sol";

/// @notice An open deficit is paid back to lenders from the protocol's interest cut on every accrual.
contract DeficitRefundTest is Test {
    using stdStorage for StdStorage;

    ProtocolCore core;
    ACLManager acl;
    LendingPool pool;
    FeeCollector fc;
    MockERC20 usdc;
    InterestRateModel irm;

    address owner = makeAddr("owner");
    address engine = makeAddr("lendingEngine");
    address lender1 = makeAddr("lender1");
    address lender2 = makeAddr("lender2");
    address borrower = makeAddr("borrower");
    address attacker = makeAddr("attacker");

    uint256 constant LOSS = 100_000e6;
    uint256 constant RESERVE_FACTOR_BPS = 2000;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        acl = new ACLManager(owner);
        core = new ProtocolCore(owner, address(acl));
        irm = new InterestRateModel(200, 600, 10_000, 8000);
        fc = new FeeCollector(address(core), makeAddr("treasury"), makeAddr("insurance"));
        pool = LendingPool(
            address(
                new ERC1967Proxy(
                    address(new LendingPool()),
                    abi.encodeCall(
                        LendingPool.initialize,
                        (ILendingPool.PoolConfig({borrowAsset: address(usdc)}), address(irm), address(core))
                    )
                )
            )
        );
        vm.startPrank(owner);
        TestPricing.wireStable(core, address(usdc));
        acl.addLendingEngine(engine);
        core.registerLendingPool(address(usdc), address(pool));
        pool.setReserveFactor(RESERVE_FACTOR_BPS);
        pool.setFeeCollector(address(fc));
        vm.stopPrank();
    }

    function _supply(address who, uint256 amount) internal returns (uint256 sh) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        sh = pool.supply(amount);
        vm.stopPrank();
    }

    /// @dev 1M supplied by two lenders, `borrow` lent out.
    function _open(uint256 borrow) internal {
        _supply(lender1, 600_000e6);
        _supply(lender2, 400_000e6);
        vm.prank(engine);
        pool.transferOut(borrower, borrow);
    }

    function _lose(uint256 amount) internal {
        vm.prank(engine);
        pool.recordDeficit(amount);
    }

    /// @dev Interest the next accrual will book, from the pool's own stored rate.
    function _nextInterest(uint256 elapsed) internal view returns (uint256) {
        ILendingPool.PoolState memory s = pool.getPoolState();
        return (s.totalBorrow * s.borrowRate * elapsed) / 1e18;
    }

    function _checkBooks() internal view {
        ILendingPool.PoolState memory s = pool.getPoolState();
        assertEq(
            usdc.balanceOf(address(pool)) + s.totalBorrow,
            s.totalSupply + pool.protocolReserves(),
            "cash + debt == supply + reserves"
        );
        assertTrue(pool.deficit() == 0 || pool.protocolReserves() == 0, "deficit and reserves never both open");
    }

    // ========== The refund ==========

    function test_accrueInterest_paysTheWholeProtocolCutToLendersWhileDeficitIsOpen() public {
        _open(800_000e6);
        _lose(LOSS);
        assertEq(pool.deficit(), LOSS);
        assertEq(pool.protocolReserves(), 0);

        ILendingPool.PoolState memory s0 = pool.getPoolState();
        uint256 interest = _nextInterest(365 days);
        uint256 cut = (interest * RESERVE_FACTOR_BPS) / 10_000;
        vm.warp(vm.getBlockTimestamp() + 365 days);
        pool.accrueInterest();
        ILendingPool.PoolState memory s1 = pool.getPoolState();

        assertGt(cut, 0);
        assertLt(cut, LOSS);
        assertEq(s1.totalBorrow - s0.totalBorrow, interest, "borrowers owe the full interest");
        assertEq(s1.totalSupply - s0.totalSupply, interest, "lenders get all of it");
        assertEq(pool.deficit(), LOSS - cut, "deficit drops by exactly the protocol cut");
        assertEq(pool.protocolReserves(), 0, "protocol takes nothing");
        _checkBooks();
    }

    function test_distributeReserves_revertsWhileDeficitIsOpen() public {
        _open(800_000e6);
        _lose(LOSS);
        vm.warp(vm.getBlockTimestamp() + 365 days);

        vm.expectRevert("NO_RESERVES");
        pool.distributeReserves();
    }

    function test_accrueInterest_sendsOnlyTheRestOfTheCutToReservesWhenDeficitCloses() public {
        _open(800_000e6);
        _lose(1000e6);

        ILendingPool.PoolState memory s0 = pool.getPoolState();
        uint256 interest = _nextInterest(365 days);
        uint256 cut = (interest * RESERVE_FACTOR_BPS) / 10_000;
        assertGt(cut, 1000e6, "the cut is bigger than the deficit");
        vm.warp(vm.getBlockTimestamp() + 365 days);
        pool.accrueInterest();
        ILendingPool.PoolState memory s1 = pool.getPoolState();

        assertEq(pool.deficit(), 0, "deficit closed");
        assertEq(pool.protocolReserves(), cut - 1000e6, "only the rest of the cut reaches reserves");
        assertEq(s1.totalSupply - s0.totalSupply, interest - (cut - 1000e6), "lenders get their share plus the refund");
        _checkBooks();

        uint256 interest2 = _nextInterest(30 days);
        uint256 reserves1 = pool.protocolReserves();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        pool.accrueInterest();
        assertEq(
            pool.protocolReserves() - reserves1,
            (interest2 * RESERVE_FACTOR_BPS) / 10_000,
            "reserves build at the reserve factor again"
        );
        _checkBooks();
    }

    function test_depositInTheBlockOfTheAccrualEarnsNoRefund() public {
        _open(800_000e6);
        _lose(LOSS);
        vm.warp(vm.getBlockTimestamp() + 365 days);

        uint256 stake = pool.getPoolState().totalSupply * 9;
        uint256 sh = _supply(attacker, stake);
        pool.accrueInterest();
        vm.prank(attacker);
        uint256 out = pool.withdraw(sh);

        assertLe(out, stake, "the deposit earns nothing");
        assertLt(pool.deficit(), LOSS, "and the deficit still went down");
        _checkBooks();
    }

    function test_manySmallAccrualsRefundTheSameAsOneBig() public {
        _open(800_000e6);
        _lose(LOSS);
        uint256 snap = vm.snapshotState();

        vm.warp(vm.getBlockTimestamp() + 3650);
        pool.accrueInterest();
        uint256 paidOnce = LOSS - pool.deficit();

        vm.revertToState(snap);
        for (uint256 i = 0; i < 3650; i++) {
            vm.warp(vm.getBlockTimestamp() + 1);
            pool.accrueInterest();
        }
        uint256 paidEachSecond = LOSS - pool.deficit();

        assertGt(paidEachSecond, 0, "one second accruals still refund");
        assertApproxEqRel(paidEachSecond, paidOnce, 0.01e18, "rounding costs under 1%");
        _checkBooks();
    }

    function test_zeroReserveFactorNeverRefunds() public {
        _open(800_000e6);
        _lose(LOSS);
        vm.prank(owner);
        pool.setReserveFactor(0);
        vm.warp(vm.getBlockTimestamp() + 3650 days);
        pool.accrueInterest();

        assertEq(pool.deficit(), LOSS, "no cut, so the deficit stays open");
        assertEq(pool.protocolReserves(), 0);
    }

    // ========== Deficit and reserves are never both open ==========

    function test_recordDeficit_spendsReservesFirstAfterDeficitClosed() public {
        _open(800_000e6);
        _lose(1000e6);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        pool.accrueInterest();
        uint256 reserves = pool.protocolReserves();
        assertGt(reserves, 0);
        assertEq(pool.deficit(), 0);

        _lose(reserves / 2);
        assertEq(pool.deficit(), 0, "no deficit when reserves cover the loss");
        assertEq(pool.protocolReserves(), reserves - reserves / 2);
        _checkBooks();

        _lose(50_000e6);
        assertEq(pool.protocolReserves(), 0, "reserves are gone before lenders pay");
        assertEq(pool.deficit(), 50_000e6 - (reserves - reserves / 2));
        _checkBooks();
    }

    /// @dev Random walk over every call that moves reserves, deficit, supply or debt.
    function testFuzz_deficitAndReservesNeverBothOpen(uint256 seed) public {
        _open(500_000e6);
        for (uint256 i = 0; i < 60; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = seed % 8;
            uint256 r = seed >> 16;
            ILendingPool.PoolState memory s = pool.getPoolState();
            uint256 cash = usdc.balanceOf(address(pool));
            if (op == 0) {
                vm.warp(vm.getBlockTimestamp() + bound(r, 1, 400 days));
                pool.accrueInterest();
            } else if (op == 1 && s.totalBorrow > 0) {
                _lose(bound(r, 1, s.totalBorrow));
            } else if (op == 2 && s.totalSupply > 0) {
                usdc.mint(attacker, 1e12);
                vm.startPrank(attacker);
                usdc.approve(address(pool), 1e12);
                try pool.supply(bound(r, 1e6, 1e12)) {} catch {}
                vm.stopPrank();
            } else if (op == 3) {
                uint256 sh = pool.shares(lender1);
                if (sh > 0) {
                    vm.prank(lender1);
                    try pool.withdraw(bound(r, 1, sh)) {} catch {}
                }
            } else if (op == 4) {
                try pool.distributeReserves() {} catch {}
            } else if (op == 5 && cash > 0 && s.totalSupply > 0) {
                vm.prank(engine);
                pool.transferOut(borrower, bound(r, 1, cash));
            } else if (op == 6 && s.totalBorrow > 0) {
                uint256 amt = bound(r, 1, s.totalBorrow);
                usdc.mint(borrower, amt);
                vm.prank(borrower);
                usdc.approve(address(pool), amt);
                vm.prank(engine);
                pool.transferIn(borrower, amt);
            } else if (op == 7) {
                vm.prank(owner);
                pool.setReserveFactor(bound(r, 0, 5000));
            }
            _checkBooks();
        }
    }

    /// @dev A pool upgraded from the old code can hold reserves and a deficit together. The storage
    ///      write puts the pool in that state.
    function test_reservesHeldBeforeAnUpgradeAreNotRefunded() public {
        _open(800_000e6);
        _lose(LOSS);
        uint256 oldReserves = 10_000e6;
        stdstore.target(address(pool)).sig("protocolReserves()").checked_write(oldReserves);

        ILendingPool.PoolState memory s0 = pool.getPoolState();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        pool.accrueInterest();
        ILendingPool.PoolState memory s1 = pool.getPoolState();

        uint256 interest = s1.totalBorrow - s0.totalBorrow;
        assertGt(interest, 0);
        assertEq(pool.protocolReserves(), oldReserves, "old reserves stay where they are");
        assertEq(s1.totalSupply - s0.totalSupply, interest, "lenders only get the new interest");
        assertEq(pool.deficit(), LOSS - (interest * RESERVE_FACTOR_BPS) / 10_000, "deficit drops by the new cut only");
    }

    // ========== A fully wiped pool ==========

    function test_fullyWipedPoolDoesNotRecover() public {
        _open(1_000_000e6);
        _lose(1_000_000e6);
        ILendingPool.PoolState memory s = pool.getPoolState();
        assertEq(s.totalSupply, 0);
        assertEq(s.totalBorrow, 0);

        vm.warp(vm.getBlockTimestamp() + 365 days);
        pool.accrueInterest();
        assertEq(pool.getPoolState().totalSupply, 0, "no debt, so no interest, so no refund");
        assertEq(pool.deficit(), 1_000_000e6);

        usdc.mint(attacker, 10e6);
        vm.startPrank(attacker);
        usdc.approve(address(pool), 10e6);
        vm.expectRevert("MARKET_INSOLVENT");
        pool.supply(10e6);
        vm.stopPrank();
    }
}
