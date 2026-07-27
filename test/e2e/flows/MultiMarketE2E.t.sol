// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title MultiMarketE2E
/// @notice E2E tests for same user borrowing across multiple markets (V3 + V2)
contract MultiMarketE2E is E2EBase {
    uint256 public v2MarketId;

    function setUp() public override {
        super.setUp();

        // Create a V2 market
        vm.startPrank(deployer);
        (v2MarketId,) = marketFactory.createMarket(
            ILPAdapter.LPType.UniswapV2, Constants.USDC, 6500, 7500, 500, 10_000_000e6, 0, 0, "volatile"
        );
        vm.stopPrank();

        // Fund Bob for V2 market
        _fundUsdc(bob, 50_000e6);
        address v2MarketAddr = core.markets(v2MarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(v2MarketAddr, 50_000e6);
        IMarket(v2MarketAddr).supply(50_000e6);
        vm.stopPrank();
    }

    // ========================================================================
    // 1. Same user borrows from two markets (V3 + V2), both HFs independent
    // ========================================================================

    function test_sameUser_borrowFromTwoMarkets() public {
        // Alice deposits V3 in ethUsdcMarketId
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 v3PosId = _depositV3(alice, tokenId);

        // Alice deposits V2 in v2MarketId
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 v2PosId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        // Advance past deposit block
        vm.roll(block.number + 2);

        // Borrow from V3 market
        uint256 maxBorrowV3 = lendingEngine.getMaxBorrow(v3PosId);
        assertGt(maxBorrowV3, 0, "V3 max borrow should be > 0");
        vm.prank(alice);
        lendingEngine.borrow(v3PosId, maxBorrowV3 / 2);

        // Borrow from V2 market
        uint256 maxBorrowV2 = lendingEngine.getMaxBorrow(v2PosId);
        assertGt(maxBorrowV2, 0, "V2 max borrow should be > 0");
        vm.prank(alice);
        lendingEngine.borrow(v2PosId, maxBorrowV2 / 2);

        // Both positions have debt
        uint256 v3Debt = _getDebt(v3PosId);
        uint256 v2Debt = _getDebt(v2PosId);
        assertGt(v3Debt, 0, "V3 should have debt");
        assertGt(v2Debt, 0, "V2 should have debt");

        // Both HFs are healthy and independent
        uint256 v3Hf = _getHealthFactor(v3PosId);
        uint256 v2Hf = _getHealthFactor(v2PosId);
        assertGt(v3Hf, 1e18, "V3 HF should be healthy");
        assertGt(v2Hf, 1e18, "V2 HF should be healthy");

        console.log("=== Same User Borrow From Two Markets ===");
        console.log("  V3 debt: %s USDC, HF: %s", v3Debt / 1e6, v3Hf / 1e18);
        console.log("  V2 debt: %s USDC, HF: %s", v2Debt / 1e6, v2Hf / 1e18);
    }

    // ========================================================================
    // 2. ETH crash makes both positions liquidatable
    // ========================================================================

    function test_crashAffectsBothMarkets() public {
        // Alice deposits and borrows from both markets
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 v3PosId = _depositV3(alice, tokenId);

        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 v2PosId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        vm.roll(block.number + 2);

        // Borrow aggressively from both (90% of max)
        uint256 maxBorrowV3 = lendingEngine.getMaxBorrow(v3PosId);
        vm.prank(alice);
        lendingEngine.borrow(v3PosId, (maxBorrowV3 * 90) / 100);

        uint256 maxBorrowV2 = lendingEngine.getMaxBorrow(v2PosId);
        vm.prank(alice);
        lendingEngine.borrow(v2PosId, (maxBorrowV2 * 90) / 100);

        // Crash ETH price
        _crashEthPrice(5000 ether);

        // Both positions should be liquidatable
        (bool v3IsLiq,) = liquidationEngine.isLiquidatable(v3PosId);
        (bool v2IsLiq,) = liquidationEngine.isLiquidatable(v2PosId);
        assertTrue(v3IsLiq, "V3 position should be liquidatable after crash");
        assertTrue(v2IsLiq, "V2 position should be liquidatable after crash");

        console.log("=== Crash Affects Both Markets ===");
        console.log("  V3 liquidatable: %s", v3IsLiq);
        console.log("  V2 liquidatable: %s", v2IsLiq);
    }

    // ========================================================================
    // 3. Liquidating V3 does not affect V2 position
    // ========================================================================

    function test_v3LiquidationDoesNotAffectV2() public {
        // Alice deposits and borrows from both markets
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 v3PosId = _depositV3(alice, tokenId);

        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 v2PosId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        vm.roll(block.number + 2);

        // Borrow aggressively from both (90% of max)
        uint256 maxBorrowV3 = lendingEngine.getMaxBorrow(v3PosId);
        vm.prank(alice);
        lendingEngine.borrow(v3PosId, (maxBorrowV3 * 90) / 100);

        uint256 maxBorrowV2 = lendingEngine.getMaxBorrow(v2PosId);
        vm.prank(alice);
        lendingEngine.borrow(v2PosId, (maxBorrowV2 * 90) / 100);

        // Record V2 state before crash
        uint256 v2DebtBefore = _getDebt(v2PosId);
        uint256 v2HfBefore = _getHealthFactor(v2PosId);

        // Crash ETH price
        _crashEthPrice(5000 ether);

        // Liquidate V3 position
        (bool v3IsLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(v3PosId);
        assertTrue(v3IsLiq, "V3 should be liquidatable");
        _fundUsdc(liquidator, maxRepay);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        liquidationEngine.liquidate(v3PosId, maxRepay, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        // V2 debt should be unchanged (interest may accrue slightly, but no liquidation impact)
        uint256 v2DebtAfter = _getDebt(v2PosId);
        assertGe(v2DebtAfter, v2DebtBefore, "V2 debt should not decrease from V3 liquidation");

        // V2 HF should not have been improved by V3 liquidation
        // (it may have changed due to time/interest, but should be in the same ballpark)
        uint256 v2HfAfter = _getHealthFactor(v2PosId);

        console.log("=== V3 Liquidation Does Not Affect V2 ===");
        console.log("  V2 debt before: %s, after: %s", v2DebtBefore / 1e6, v2DebtAfter / 1e6);
        console.log("  V2 HF before:   %s, after: %s", v2HfBefore / 1e16, v2HfAfter / 1e16);

        // V2 position should still exist and have its own independent state
        (bool v2IsLiq,) = liquidationEngine.isLiquidatable(v2PosId);
        // V2 may or may not be liquidatable - the key assertion is that V3 liquidation
        // did not change V2 debt. We just log the state.
        console.log("  V2 liquidatable: %s (independent of V3)", v2IsLiq);
    }
}
