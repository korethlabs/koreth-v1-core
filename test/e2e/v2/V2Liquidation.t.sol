// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title V2Liquidation
/// @notice Liquidation tests with real V2 LP positions on forked mainnet
contract V2Liquidation is E2EBase {
    uint256 public v2MarketId;

    function setUp() public override {
        super.setUp();

        // Create a V2 market
        vm.startPrank(deployer);
        (v2MarketId,) = marketFactory.createMarket(
            ILPAdapter.LPType.UniswapV2, Constants.USDC, 6500, 7500, 500, 10_000_000e6, 0, 0, "volatile"
        );
        vm.stopPrank();

        // Fund Bob with extra USDC and supply to V2 market
        _fundUsdc(bob, 50_000e6);
        address v2MarketAddr = core.markets(v2MarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(v2MarketAddr, 50_000e6);
        IMarket(v2MarketAddr).supply(50_000e6);
        vm.stopPrank();
    }

    function test_liquidatable_V2() public {
        // 1. Alice creates V2 LP position and borrows aggressively
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);

        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 90) / 100;

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        uint256 hfBefore = _getHealthFactor(positionId);
        console.log("V2 HF before drop: %s", hfBefore / 1e16);

        // 2. Simulate price drop via oracle mock
        uint256 originalValue = _getPositionValue(positionId);
        uint256 droppedValue = (originalValue * 40) / 100; // 60% drop

        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, droppedValue);

        uint256 hfAfter = _getHealthFactor(positionId);
        console.log("V2 HF after drop: %s", hfAfter / 1e16);
        assertLt(hfAfter, 1e18, "Should be liquidatable");

        // 3. Verify liquidatability
        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Must be liquidatable");
        assertGt(maxRepay, 0);

        console.log("=== V2 Full Liquidation Test Passed ===");
    }

    function test_partialLiquidation_V2() public {
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);

        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 80) / 100;

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Target HF ~ 0.97 for partial liquidation
        uint256 debtUsd = uint256(borrowAmount) * 1e12;
        uint256 targetValue = (debtUsd * 10_000 * 97) / (7500 * 100);

        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, targetValue);

        uint256 hf = _getHealthFactor(positionId);
        console.log("V2 HF after moderate drop: %s", hf / 1e16);
        assertLt(hf, 1e18, "HF should be below 1.0 after price drop");

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Should be liquidatable");

        uint256 totalDebt = _getDebt(positionId);
        assertLt(maxRepay, totalDebt, "Should be partial liquidation (maxRepay < totalDebt)");
        console.log("V2 Max repay: %s USDC (of %s total)", maxRepay / 1e6, totalDebt / 1e6);

        vm.clearMockedCalls();
        console.log("=== V2 Partial Liquidation Test Passed ===");
    }

    function test_borrowMax_healthFactor_V2() public {
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);

        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);

        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow);

        uint256 hf = _getHealthFactor(positionId);
        console.log("V2 HF at max borrow: %s", hf / 1e16);

        assertGt(hf, 1e18, "Should still be above 1.0 at max LTV");
        assertLt(hf, 1.5e18, "Should be close to threshold");

        vm.prank(alice);
        vm.expectRevert("EXCEEDS_MAX_LTV");
        lendingEngine.borrow(positionId, 1);

        console.log("=== V2 Borrow Max Test Passed ===");
    }
}
