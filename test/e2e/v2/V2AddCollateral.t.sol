// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IUniswapV2Pair} from "../../../src/interfaces/external/IUniswapV2.sol";

/// @title V2AddCollateral
/// @notice E2E tests for addCollateral on V2 LP positions.
contract V2AddCollateral is E2EBase {
    function setUp() public override {
        super.setUp();

        _fundUsdc(bob, 50_000e6);
        address poolAddr = address(usdcPool);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(poolAddr, 50_000e6);
        ILendingPool(poolAddr).supply(50_000e6);
        vm.stopPrank();
    }

    /// @notice Add collateral to V2 position — increases value and improves HF
    function test_addCollateral_V2() public {
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 posId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, usdcBorrowAsset);
        vm.stopPrank();
        vm.roll(block.number + 2);

        // Borrow to create debt
        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, maxBorrow / 2);

        uint256 hfBefore = _getHealthFactor(posId);
        uint256 valueBefore = _getPositionValue(posId);

        // Add more collateral — fund alice with more tokens
        _fundWeth(alice, 0.3 ether);
        _fundUsdc(alice, 600e6);

        vm.startPrank(alice);
        IERC20(Constants.WETH).approve(address(positionManager), 0.3 ether);
        IERC20(Constants.USDC).approve(address(positionManager), 600e6);
        positionManager.addCollateral(posId, 600e6, 0.3 ether, 0, 0);
        vm.stopPrank();

        uint256 hfAfter = _getHealthFactor(posId);
        uint256 valueAfter = _getPositionValue(posId);

        assertGt(valueAfter, valueBefore, "Position value must increase");
        assertGt(hfAfter, hfBefore, "Health factor must improve");
        console.log("Value: $%s -> $%s", valueBefore / 1e18, valueAfter / 1e18);
        console.log("HF: %s -> %s", hfBefore / 1e16, hfAfter / 1e16);
    }

    /// @notice Remove collateral from V2 position with no debt
    function test_removeCollateral_V2_noDebt() public {
        uint256 lpAmount = _createV2Position(alice, 1 ether, 2000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 posId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, usdcBorrowAsset);
        vm.stopPrank();
        vm.roll(block.number + 2);

        uint256 valueBefore = _getPositionValue(posId);

        // Remove 30% of liquidity
        uint128 removeAmt = uint128(lpAmount / 3);
        vm.prank(alice);
        positionManager.removeCollateral(posId, removeAmt, 0, 0);

        uint256 valueAfter = _getPositionValue(posId);
        assertLt(valueAfter, valueBefore, "Value must decrease after removing collateral");
    }

    /// @notice Remove collateral from V2 position with debt — must stay healthy
    function test_removeCollateral_V2_withDebt() public {
        uint256 lpAmount = _createV2Position(alice, 1 ether, 2000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 posId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, usdcBorrowAsset);
        vm.stopPrank();
        vm.roll(block.number + 2);

        // Borrow small amount
        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, maxBorrow / 4);

        // Remove small portion of collateral — should succeed if still healthy
        uint128 removeAmt = uint128(lpAmount / 10);
        vm.prank(alice);
        positionManager.removeCollateral(posId, removeAmt, 0, 0);

        uint256 hf = _getHealthFactor(posId);
        assertGe(hf, 1e18, "Must remain healthy after partial removal");
    }

    /// @notice Add collateral to a V2 position — real addLiquidity on forked Uniswap
    function test_addCollateral_V2_realAddLiquidity() public {
        uint256 lpAmount = _createV2Position(alice, 0.3 ether, 600e6);

        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, usdcBorrowAsset);
        vm.stopPrank();
        vm.roll(block.number + 2);

        // Borrow
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 3);

        uint256 amountBefore = positionManager.getPosition(positionId).amount;
        uint256 hfBefore = _getHealthFactor(positionId);

        // Add collateral — V2 pair is WETH/USDC
        PositionManager.Position memory pos = positionManager.getPosition(positionId);

        uint256 addAmount0 = 300e6; // USDC (token0)
        uint256 addAmount1 = 0.15 ether; // WETH (token1)

        _fundUsdc(alice, addAmount0);
        _fundWeth(alice, addAmount1);

        vm.startPrank(alice);
        IERC20(pos.token0).approve(address(positionManager), addAmount0);
        IERC20(pos.token1).approve(address(positionManager), addAmount1);
        positionManager.addCollateral(positionId, addAmount0, addAmount1, 0, 0);
        vm.stopPrank();

        // V2: pos.amount should increase
        uint256 amountAfter = positionManager.getPosition(positionId).amount;
        assertGt(amountAfter, amountBefore, "V2 amount must increase");

        // HF should improve
        uint256 hfAfter = _getHealthFactor(positionId);
        assertGt(hfAfter, hfBefore, "HF must improve");

        console.log("Amount before: %s, after: %s", amountBefore, amountAfter);
        console.log("HF before: %s, after: %s", hfBefore / 1e16, hfAfter / 1e16);
        console.log("=== addCollateral V2 Passed ===");
    }
}
