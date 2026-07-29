// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title MultiPosition
/// @notice Tests multiple positions from the same user across V2 and V3
contract MultiPosition is E2EBase {

    function setUp() public override {
        super.setUp();

        // Create a V2 market
        vm.startPrank(deployer);
        vm.stopPrank();

        // Fund Bob for V2 market
        _fundUsdc(bob, 50_000e6);
        address v2MarketAddr = address(usdcPool);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(v2MarketAddr, 50_000e6);
        ILendingPool(v2MarketAddr).supply(50_000e6);
        vm.stopPrank();
    }

    function test_sameUser_V3andV2_positions() public {
        // Alice creates V3 position
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 v3PositionId = _depositV3(alice, tokenId);

        // Alice creates V2 position
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 v2PositionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, usdcBorrowAsset);
        vm.stopPrank();

        // Both have value
        uint256 v3Value = _getPositionValue(v3PositionId);
        uint256 v2Value = _getPositionValue(v2PositionId);
        assertGt(v3Value, 0, "V3 should have value");
        assertGt(v2Value, 0, "V2 should have value");
        console.log("V3 value: $%s, V2 value: $%s", v3Value / 1e18, v2Value / 1e18);

        // Alice's positions should be tracked
        uint256[] memory positions = positionManager.getPositionsByOwner(alice);
        assertEq(positions.length, 2, "Alice should have 2 positions");

        // Borrow on V3
        vm.roll(block.number + 2);
        uint256 maxBorrowV3 = lendingEngine.getMaxBorrow(v3PositionId);
        vm.prank(alice);
        lendingEngine.borrow(v3PositionId, maxBorrowV3 / 3);

        // Borrow on V2
        uint256 maxBorrowV2 = lendingEngine.getMaxBorrow(v2PositionId);
        vm.prank(alice);
        lendingEngine.borrow(v2PositionId, maxBorrowV2 / 3);

        assertGt(_getDebt(v3PositionId), 0, "V3 should have debt");
        assertGt(_getDebt(v2PositionId), 0, "V2 should have debt");

        console.log("V3 debt: %s USDC", _getDebt(v3PositionId) / 1e6);
        console.log("V2 debt: %s USDC", _getDebt(v2PositionId) / 1e6);

        // Both healthy
        assertGt(_getHealthFactor(v3PositionId), 1e18, "V3 should be healthy");
        assertGt(_getHealthFactor(v2PositionId), 1e18, "V2 should be healthy");

        console.log("=== Multi-Position V3+V2 Test Passed ===");
    }

    function test_independentRepayAndWithdraw() public {
        // Alice has two V3 positions in same market
        uint256 tokenId1 = _createV3Position(alice, 0.5 ether, 1000e6);
        uint256 positionId1 = _depositV3(alice, tokenId1);

        uint256 tokenId2 = _createV3Position(alice, 0.5 ether, 1000e6);
        uint256 positionId2 = _depositV3(alice, tokenId2);

        vm.roll(block.number + 2);

        // Borrow on position 1
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId1);
        vm.prank(alice);
        lendingEngine.borrow(positionId1, maxBorrow / 3);

        // Position 2 has no debt — can withdraw immediately
        vm.prank(alice);
        positionManager.withdraw(positionId2);
        assertEq(nftManager.ownerOf(tokenId2), alice, "Alice should get NFT2 back");

        // Position 1 still has debt — cannot withdraw
        vm.prank(alice);
        vm.expectRevert("HAS_DEBT");
        positionManager.withdraw(positionId1);

        // Repay and withdraw position 1
        uint256 debt = _getDebt(positionId1);
        _fundUsdc(alice, debt);
        address marketAddr = address(usdcPool);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, type(uint256).max);
        lendingEngine.repay(positionId1, type(uint256).max);
        positionManager.withdraw(positionId1);
        vm.stopPrank();

        assertEq(nftManager.ownerOf(tokenId1), alice, "Alice should get NFT1 back");
        console.log("=== Independent Repay & Withdraw Test Passed ===");
    }

    function test_multiplePositions_differentCollateralTypes() public {
        // Alice deposits V3 collateral, borrowing USDC
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 v3PositionId = _depositV3(alice, tokenId);

        // ...and V2 collateral, borrowing the same USDC
        uint256 lpAmount = _createV2Position(alice, 0.3 ether, 600e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 v2PositionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, usdcBorrowAsset);
        vm.stopPrank();

        // Both draw on the one shared pool; only the collateral type differs.
        vm.roll(block.number + 2);

        uint256 maxV3 = lendingEngine.getMaxBorrow(v3PositionId);
        vm.prank(alice);
        lendingEngine.borrow(v3PositionId, maxV3 / 4);

        uint256 maxV2 = lendingEngine.getMaxBorrow(v2PositionId);
        vm.prank(alice);
        lendingEngine.borrow(v2PositionId, maxV2 / 4);

        // Verify positions are independent
        PositionManager.Position memory p1 = positionManager.getPosition(v3PositionId);
        PositionManager.Position memory p2 = positionManager.getPosition(v2PositionId);
        // Both V3 and V2 collateral borrow from the single shared USDC pool.
        assertEq(p1.borrowAsset, usdcBorrowAsset, "V3 should use the shared USDC pool");
        assertEq(p2.borrowAsset, usdcBorrowAsset, "V2 should use the shared USDC pool");

        console.log("Shared borrow asset: %s", p1.borrowAsset);
        console.log("=== Multiple Collateral Types, Shared Pool Test Passed ===");
    }
}
