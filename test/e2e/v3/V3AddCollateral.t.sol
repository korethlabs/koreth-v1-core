// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title V3AddCollateral
/// @notice E2E tests for addCollateral on V3 LP positions.
contract V3AddCollateral is E2EBase {
    function setUp() public override {
        super.setUp();

        _fundUsdc(bob, 50_000e6);
        address poolAddr = address(usdcPool);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(poolAddr, 50_000e6);
        ILendingPool(poolAddr).supply(50_000e6);
        vm.stopPrank();
    }

    /// @notice Add collateral to a V3 position — real increaseLiquidity on forked Uniswap
    function test_addCollateral_V3_realIncreaseLiquidity() public {
        uint256 tokenId = _createV3Position(alice, 0.5 ether, 1000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Borrow to make position Borrowed
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 3);

        uint256 valueBefore = _getPositionValue(positionId);
        uint256 hfBefore = _getHealthFactor(positionId);

        // Add collateral — send underlying tokens
        // token0 = USDC (lower address), token1 = WETH
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        address token0 = pos.token0; // USDC
        address token1 = pos.token1; // WETH

        uint256 addAmount0 = 500e6; // 500 USDC
        uint256 addAmount1 = 0.25 ether; // 0.25 WETH

        _fundUsdc(alice, addAmount0);
        _fundWeth(alice, addAmount1);

        vm.startPrank(alice);
        IERC20(token0).approve(address(positionManager), addAmount0);
        IERC20(token1).approve(address(positionManager), addAmount1);
        positionManager.addCollateral(positionId, addAmount0, addAmount1, 0, 0);
        vm.stopPrank();

        // Position value should increase
        uint256 valueAfter = _getPositionValue(positionId);
        assertGt(valueAfter, valueBefore, "Position value must increase after addCollateral");

        // Health factor should improve
        uint256 hfAfter = _getHealthFactor(positionId);
        assertGt(hfAfter, hfBefore, "HF must improve after adding collateral");

        // V3: pos.amount stays 0 (liquidity in NFT)
        pos = positionManager.getPosition(positionId);
        assertEq(pos.amount, 0, "V3 amount stays 0");

        console.log("Value before: $%s, after: $%s", valueBefore / 1e18, valueAfter / 1e18);
        console.log("HF before: %s, after: %s", hfBefore / 1e16, hfAfter / 1e16);
        console.log("=== addCollateral V3 Passed ===");
    }
}
