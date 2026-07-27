// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";

/// @title AccrualEdgeCaseE2E
/// @notice E2E test verifying interest accrues correctly even at extreme utilization
///         (all liquidity borrowed, near-zero available cash).
contract AccrualEdgeCaseE2E is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Verify interest accrues correctly with active borrows
    /// @dev Simulates: deposit LP → borrow → advance time → verify debt grew.
    ///      Validates the core fix: accrueInterest only skips when totalBorrow==0.
    function test_interestAccrues_atMaxUtilization() public {
        // 1. Alice creates V3 position and deposits
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // 2. Set reserve factor so protocol gets interest share
        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);
        vm.prank(deployer);
        market.setReserveFactor(2000); // 20%

        // 3. Borrow near max to push utilization high
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 90) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // 4. Record state before accrual
        uint256 debtBefore = _getDebt(positionId);
        IMarket.MarketState memory stateBefore = market.getMarketState();
        uint256 reservesBefore = market.protocolReserves();
        uint256 indexBefore = market.borrowIndex();

        assertGt(debtBefore, 0, "Must have debt");
        assertGt(stateBefore.utilization, 0, "Utilization must be > 0");

        console.log("=== Before Accrual ===");
        console.log("Debt: %s USDC", debtBefore / 1e6);
        console.log("Utilization: %s bps", stateBefore.utilization);
        console.log("BorrowIndex: %s", indexBefore);

        // 5. Advance 1 hour (within staleness window)
        _advanceTime(1 hours);
        market.accrueInterest();

        // 6. Verify interest accrued
        uint256 debtAfter = _getDebt(positionId);
        IMarket.MarketState memory stateAfter = market.getMarketState();
        uint256 reservesAfter = market.protocolReserves();
        uint256 indexAfter = market.borrowIndex();

        assertGt(debtAfter, debtBefore, "Debt must grow from interest");
        assertGt(stateAfter.totalBorrow, stateBefore.totalBorrow, "totalBorrow must increase");
        assertGt(indexAfter, indexBefore, "BorrowIndex must increase");
        assertGt(reservesAfter, reservesBefore, "Protocol reserves must grow");
        assertLe(stateAfter.utilization, 10_000, "Utilization capped at 100%");

        console.log("=== After 1 Hour Accrual ===");
        console.log("Debt: %s USDC (+%s)", debtAfter / 1e6, (debtAfter - debtBefore) / 1e6);
        console.log("Reserves: %s USDC (+%s)", reservesAfter / 1e6, (reservesAfter - reservesBefore) / 1e6);
        console.log("BorrowIndex: %s", indexAfter);
    }

    /// @notice Full cycle: borrow at high util → accrue → repay → withdraw
    ///         Verifies the entire lifecycle works when market is near-empty.
    function test_fullCycle_highUtilization_borrowAccrueRepayWithdraw() public {
        // 1. Alice deposits
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // 2. Borrow
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 80) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // 3. Advance 1 hour
        _advanceTime(1 hours);

        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);
        market.accrueInterest();

        // 4. Debt should have grown
        uint256 currentDebt = _getDebt(positionId);
        assertGt(currentDebt, borrowAmount, "Debt must include accrued interest");

        // 5. Repay all
        _fundUsdc(alice, currentDebt);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, type(uint256).max);
        lendingEngine.repay(positionId, type(uint256).max);
        vm.stopPrank();

        assertEq(_getDebt(positionId), 0, "Debt must be 0 after full repay");

        // 6. Withdraw
        vm.prank(alice);
        positionManager.withdraw(positionId);

        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Closed), "Position must be Closed");

        console.log("=== Full Cycle at High Utilization: Passed ===");
        console.log("Interest paid: %s USDC", (currentDebt - borrowAmount) / 1e6);
    }

    /// @notice Verify accrual with zero borrows is a no-op (no index change)
    function test_accrual_zeroBorrows_noIndexChange() public {
        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);
        uint256 indexBefore = market.borrowIndex();

        // Advance time with no borrows
        _advanceTime(1 hours);
        market.accrueInterest();

        uint256 indexAfter = market.borrowIndex();
        assertEq(indexAfter, indexBefore, "BorrowIndex must not change with zero borrows");

        console.log("=== Zero Borrows Accrual No-Op: Passed ===");
    }
}
