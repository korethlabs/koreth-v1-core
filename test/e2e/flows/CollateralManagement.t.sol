// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IUniswapV2Pair} from "../../../src/interfaces/external/IUniswapV2.sol";
import {INonfungiblePositionManager} from "../../../src/interfaces/external/IUniswapV3.sol";

/// @title CollateralManagement
/// @notice E2E tests for addCollateral and removeCollateral called directly by position owner
///         (not via transform). Also covers V2 removeCollateral, health factor enforcement,
///         and circuit breaker blocking.
contract CollateralManagement is E2EBase {
    uint256 public v2MarketId;

    function setUp() public override {
        super.setUp();

        // Create V2 market for V2-specific tests
        vm.startPrank(deployer);
        (v2MarketId,) = marketFactory.createMarket(
            ILPAdapter.LPType.UniswapV2, Constants.USDC, 6500, 7500, 500, 10_000_000e6, 0, 0, "volatile"
        );
        vm.stopPrank();

        _fundUsdc(bob, 50_000e6);
        address v2MarketAddr = core.markets(v2MarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(v2MarketAddr, 50_000e6);
        IMarket(v2MarketAddr).supply(50_000e6);
        vm.stopPrank();
    }

    // ========== addCollateral standalone ==========

    /// @notice Owner adds collateral directly (not via transform)
    function test_addCollateral_standalone_V3() public {
        // 1. Create and deposit a V3 position
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        uint256 valueBefore = _getPositionValue(positionId);
        console.log("Position value before addCollateral: $%s", valueBefore / 1e18);

        // 2. Fund alice with more tokens and add collateral directly
        _fundWeth(alice, 0.5 ether);
        _fundUsdc(alice, 1000e6);

        vm.startPrank(alice);
        IERC20(Constants.WETH).approve(address(positionManager), 0.5 ether);
        IERC20(Constants.USDC).approve(address(positionManager), 1000e6);
        positionManager.addCollateral(positionId, 1000e6, 0.5 ether, 0, 0);
        vm.stopPrank();

        // 3. Verify value increased
        uint256 valueAfter = _getPositionValue(positionId);
        console.log("Position value after addCollateral: $%s", valueAfter / 1e18);
        assertGt(valueAfter, valueBefore, "Value should increase after adding collateral");
    }

    // ========== removeCollateral standalone ==========

    /// @notice Owner removes collateral directly from a V3 position (no debt)
    function test_removeCollateral_standalone_V3_noDebt() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        uint256 valueBefore = _getPositionValue(positionId);
        console.log("Position value before remove: $%s", valueBefore / 1e18);

        // Get current liquidity
        (,,,,,,, uint128 currentLiquidity,,,,) = nftManager.positions(tokenId);

        // Remove 20% of liquidity
        uint128 toRemove = currentLiquidity / 5;

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = positionManager.removeCollateral(positionId, toRemove, 0, 0);

        uint256 valueAfter = _getPositionValue(positionId);
        console.log("Position value after remove: $%s", valueAfter / 1e18);
        console.log("Received: %s USDC + %s WETH", amount0 / 1e6, amount1 / 1e18);

        assertLt(valueAfter, valueBefore, "Value should decrease after removing collateral");
        assertGt(amount0 + amount1, 0, "Should receive tokens");

        // Alice should have received the tokens
        assertGt(
            IERC20(Constants.USDC).balanceOf(alice) + IERC20(Constants.WETH).balanceOf(alice),
            0,
            "Alice should have tokens"
        );
    }

    /// @notice Owner removes collateral from a V3 position with debt — health factor stays healthy
    function test_removeCollateral_V3_withDebt_healthy() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Borrow 20% of max — leaves plenty of room for collateral removal
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 5);

        uint256 hfBefore = _getHealthFactor(positionId);
        console.log("HF before remove: %s", hfBefore / 1e16);

        // Remove 10% of liquidity — should be fine with low debt
        (,,,,,,, uint128 currentLiquidity,,,,) = nftManager.positions(tokenId);
        uint128 toRemove = currentLiquidity / 10;

        vm.prank(alice);
        positionManager.removeCollateral(positionId, toRemove, 0, 0);

        uint256 hfAfter = _getHealthFactor(positionId);
        console.log("HF after remove: %s", hfAfter / 1e16);

        assertGe(hfAfter, 1e18, "Health factor must remain >= 1.0");
        assertLt(hfAfter, hfBefore, "Health factor should decrease");
    }

    /// @notice Removing too much collateral from a borrowed position reverts
    function test_revert_removeCollateral_unhealthy() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Borrow 80% of max — near the edge
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 80) / 100);

        // Try to remove 50% of liquidity — should make position unhealthy
        (,,,,,,, uint128 currentLiquidity,,,,) = nftManager.positions(tokenId);
        uint128 toRemove = currentLiquidity / 2;

        vm.prank(alice);
        vm.expectRevert("UNHEALTHY_AFTER_REMOVAL");
        positionManager.removeCollateral(positionId, toRemove, 0, 0);
    }

    /// @notice Exceeding available V3 liquidity reverts
    function test_revert_removeCollateral_exceedsLiquidity_V3() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        (,,,,,,, uint128 currentLiquidity,,,,) = nftManager.positions(tokenId);

        // Try to remove more than available
        vm.prank(alice);
        vm.expectRevert("EXCEEDS_AVAILABLE_LIQUIDITY");
        positionManager.removeCollateral(positionId, currentLiquidity + 1, 0, 0);
    }

    // ========== V2 removeCollateral ==========

    /// @notice Remove collateral from a V2 position — pos.amount decreases
    function test_removeCollateral_V2() public {
        // Create V2 position
        uint256 lpAmount = _createV2Position(alice, 1 ether, 2000e6);

        // Deposit
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        uint256 valueBefore = _getPositionValue(positionId);

        // Remove 30% of LP tokens
        uint128 toRemove = uint128(lpAmount / 3);

        vm.prank(alice);
        positionManager.removeCollateral(positionId, toRemove, 0, 0);

        uint256 valueAfter = _getPositionValue(positionId);
        assertLt(valueAfter, valueBefore, "Value should decrease");

        // Check pos.amount was updated
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        assertEq(pos.amount, lpAmount - uint256(toRemove), "pos.amount should decrease for V2");
    }

    /// @notice V2: removing more than pos.amount reverts
    function test_revert_removeCollateral_V2_exceedsAmount() public {
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);

        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert("EXCEEDS_POSITION_AMOUNT");
        positionManager.removeCollateral(positionId, uint128(lpAmount + 1), 0, 0);
    }

    // ========== Circuit breaker ==========

    /// @notice Frozen market blocks removeCollateral
    function test_revert_removeCollateral_frozenMarket() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        // Freeze the market
        vm.prank(deployer);
        circuitBreaker.freezeMarket(ethUsdcMarketId, "test freeze");

        (,,,,,,, uint128 currentLiquidity,,,,) = nftManager.positions(tokenId);

        vm.prank(alice);
        vm.expectRevert("MARKET_FROZEN");
        positionManager.removeCollateral(positionId, currentLiquidity / 5, 0, 0);

        // Unfreeze
        vm.prank(deployer);
        circuitBreaker.unfreezeMarket(ethUsdcMarketId);
    }

    // ========== Slippage protection ==========

    /// @notice Slippage check catches low output
    function test_revert_removeCollateral_slippage() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        (,,,,,,, uint128 currentLiquidity,,,,) = nftManager.positions(tokenId);
        uint128 toRemove = currentLiquidity / 5;

        // Set impossibly high min amounts
        vm.prank(alice);
        vm.expectRevert("SLIPPAGE_AMOUNT0");
        positionManager.removeCollateral(positionId, toRemove, type(uint256).max, 0);
    }
}
