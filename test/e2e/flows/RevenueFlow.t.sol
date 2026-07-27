// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title RevenueFlow
/// @notice Tests the full revenue flow: Borrower interest → Market reserves → FeeCollector → Treasury
contract RevenueFlow is E2EBase {
    function setUp() public override {
        super.setUp();

        vm.startPrank(deployer);

        // Set reserve factor (20% of interest goes to protocol)
        address marketAddr = core.markets(ethUsdcMarketId);
        Market(marketAddr).setReserveFactor(2000);

        // Wire FeeCollector to Market
        Market(marketAddr).setFeeCollector(address(feeCollector));

        vm.stopPrank();
    }

    function test_fullRevenueFlow() public {
        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);

        // 1. Alice borrows
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 2);
        console.log("Borrowed: %s USDC", (maxBorrow / 2) / 1e6);

        // 2. Time passes — interest accrues
        _advanceTime(1 hours);
        market.accrueInterest();

        uint256 reserves = market.protocolReserves();
        assertGt(reserves, 0, "Protocol reserves should accumulate");
        console.log("Protocol reserves after 1h: %s USDC", reserves / 1e6);

        // 3. Distribute reserves to FeeCollector
        uint256 feeCollectorBefore = IERC20(Constants.USDC).balanceOf(address(feeCollector));
        market.distributeReserves();
        uint256 feeCollectorAfter = IERC20(Constants.USDC).balanceOf(address(feeCollector));

        uint256 feeCollectorReceived = feeCollectorAfter - feeCollectorBefore;
        assertGt(feeCollectorReceived, 0, "FeeCollector should receive reserves");
        console.log("FeeCollector received: %s USDC", feeCollectorReceived / 1e6);

        // Reserves should be cleared (or reduced)
        uint256 remainingReserves = market.protocolReserves();
        assertLt(remainingReserves, reserves, "Reserves should decrease after distribution");

        // 4. Distribute from FeeCollector to Treasury + Insurance
        uint256 accFees = feeCollector.accumulatedFees(Constants.USDC);
        assertGt(accFees, 0, "Accumulated fees should be tracked");

        uint256 treasuryBefore = IERC20(Constants.USDC).balanceOf(deployer); // treasury = deployer in test

        vm.prank(deployer);
        feeCollector.distribute(Constants.USDC);

        uint256 treasuryAfter = IERC20(Constants.USDC).balanceOf(deployer);
        // Since treasury and insurance are both deployer, just check total increased
        assertGt(treasuryAfter, treasuryBefore, "Treasury should receive fees");
        console.log("Treasury received: %s USDC", (treasuryAfter - treasuryBefore) / 1e6);

        // Accumulated fees should be cleared
        assertEq(feeCollector.accumulatedFees(Constants.USDC), 0, "Fees should be cleared");

        console.log("=== Full Revenue Flow Test Passed ===");
    }

    function test_reservesSurviveRepayment() public {
        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);

        // Borrow
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = maxBorrow / 2;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Accrue interest
        _advanceTime(1 hours);
        market.accrueInterest();

        uint256 reservesBefore = market.protocolReserves();
        assertGt(reservesBefore, 0);

        // Repay fully
        uint256 debt = lendingEngine.getDebt(positionId);
        _fundUsdc(alice, debt);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, type(uint256).max);
        lendingEngine.repay(positionId, type(uint256).max);
        vm.stopPrank();

        // Reserves should survive repayment
        uint256 reservesAfter = market.protocolReserves();
        assertGe(reservesAfter, reservesBefore, "Reserves should not decrease on repayment");
        console.log("Reserves after repay: %s USDC", reservesAfter / 1e6);

        // Distribute remaining reserves
        market.distributeReserves();
        console.log("=== Reserves Survive Repayment Test Passed ===");
    }
}
