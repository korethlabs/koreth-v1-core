// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title CircuitBreakerModes
/// @notice E2E fork tests covering the differences between pauseMarket, pausePool, and freezeMarket
///         on real Uniswap V3 positions with active borrows.
contract CircuitBreakerModes is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    // ========== 1. freezeMarket blocks deposits but allows withdraw ==========

    function test_freezeMarket_blocksDepositsButAllowsWithdraw() public {
        // Create a position and deposit BEFORE freeze (so we have something to withdraw)
        uint256 tokenId1 = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId1);

        // Freeze market
        vm.prank(guardian);
        circuitBreaker.freezeMarket(ethUsdcMarketId, "Oracle anomaly");

        // New deposit should revert
        _fundWeth(alice, 1 ether);
        _fundUsdc(alice, 2000e6);
        uint256 tokenId2 = _createV3Position(alice, 1 ether, 2000e6);
        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId2);
        vm.expectRevert("MARKET_FROZEN");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId2, 0, ethUsdcMarketId);
        vm.stopPrank();

        // Withdraw should still work (risk-reducing)
        vm.prank(alice);
        positionManager.withdraw(positionId);
        assertEq(nftManager.ownerOf(tokenId1), alice, "Alice should get NFT back");

        console.log("=== freezeMarket: deposits blocked, withdraw allowed ===");
    }

    // ========== 2. freezeMarket blocks borrow but allows repay ==========

    function test_freezeMarket_blocksBorrowButAllowsRepay() public {
        // Create and deposit position, then borrow
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 4);

        uint256 debtBefore = _getDebt(positionId);
        assertGt(debtBefore, 0, "Should have debt");

        // Freeze market
        vm.prank(guardian);
        circuitBreaker.freezeMarket(ethUsdcMarketId, "Token depeg");

        // New borrow should revert
        vm.prank(alice);
        vm.expectRevert("MARKET_FROZEN");
        lendingEngine.borrow(positionId, 100e6);

        // Repay should still work (risk-reducing)
        _fundUsdc(alice, debtBefore);
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, type(uint256).max);
        lendingEngine.repay(positionId, type(uint256).max);
        vm.stopPrank();

        assertEq(_getDebt(positionId), 0, "Debt should be zero after repay");

        console.log("=== freezeMarket: borrow blocked, repay allowed ===");
    }

    // ========== 3. freezeMarket allows liquidation ==========

    function test_freezeMarket_allowsLiquidation() public {
        // Create leveraged position
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        // Freeze market
        vm.prank(guardian);
        circuitBreaker.freezeMarket(ethUsdcMarketId, "Emergency response");

        // Crash ETH price to make position liquidatable
        _crashEthPrice(5000 ether);

        // Verify position is liquidatable
        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable");
        assertGt(maxRepay, 0, "Max repay must be > 0");

        // Liquidation should succeed even though market is frozen
        _fundUsdc(liquidator, maxRepay);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp + 1 hours, 0, 0);
        vm.stopPrank();

        console.log("=== freezeMarket: liquidation still works ===");
    }

    // ========== 4. global core.pause() blocks all operations ==========

    /// @notice The full protocol halt is core.pause() (whenNotPaused). There is deliberately no
    ///         per-market "block-everything" switch — a per-market halt that blocked withdraw/repay
    ///         would trap user funds. Per-market risk halts use freezeMarket (tested above).
    function test_globalPause_blocksEverything() public {
        // Create position and borrow before pause
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 4);

        // Global pause halts all operations
        vm.prank(guardian);
        core.pause();

        // Deposit should revert
        _fundWeth(alice, 1 ether);
        _fundUsdc(alice, 2000e6);
        uint256 tokenId2 = _createV3Position(alice, 1 ether, 2000e6);
        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId2);
        vm.expectRevert("PAUSED");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId2, 0, ethUsdcMarketId);
        vm.stopPrank();

        // Borrow should revert
        vm.prank(alice);
        vm.expectRevert("PAUSED");
        lendingEngine.borrow(positionId, 100e6);

        // Withdraw should revert
        vm.prank(alice);
        vm.expectRevert("PAUSED");
        positionManager.withdraw(positionId);

        // Repay should revert
        _fundUsdc(alice, 1000e6);
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, type(uint256).max);
        vm.expectRevert("PAUSED");
        lendingEngine.repay(positionId, 100e6);
        vm.stopPrank();

        // Unpause: deployer (poolAdmin) unpauses core, operations resume
        vm.prank(deployer);
        core.unpause();

        // A borrow now succeeds (position still healthy with capacity)
        vm.prank(alice);
        lendingEngine.borrow(positionId, 100e6);

        console.log("=== core.pause: all operations blocked, resume after unpause ===");
    }

    // ========== 5. pausePool blocks pool-specific operations ==========

    function test_pausePool_blocksPoolSpecificOperations() public {
        // Pause the V3 WETH/USDC pool
        vm.prank(guardian);
        circuitBreaker.pausePool(Constants.UNI_V3_WETH_USDC_3000, "Pool exploit");

        // Depositing LP from that pool should revert
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        vm.expectRevert("POOL_CIRCUIT_BREAKER");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);
        vm.stopPrank();

        // Verify isPoolOperationAllowed returns false
        assertFalse(
            circuitBreaker.isPoolOperationAllowed(Constants.UNI_V3_WETH_USDC_3000),
            "Pool operation should not be allowed"
        );

        // Unpause pool and verify deposit works
        vm.prank(deployer);
        circuitBreaker.unpausePool(Constants.UNI_V3_WETH_USDC_3000);

        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        uint256 posId = positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);
        vm.stopPrank();

        assertGt(_getPositionValue(posId), 0, "Position should have value after unpause");

        console.log("=== pausePool: pool deposits blocked, unblocked after unpause ===");
    }

    // ========== 6. unfreeze requires poolAdmin ==========

    function test_unfreezeRequiresAdmin() public {
        // Guardian can freeze
        vm.prank(guardian);
        circuitBreaker.freezeMarket(ethUsdcMarketId, "Emergency");
        assertTrue(circuitBreaker.marketFrozen(ethUsdcMarketId), "Market should be frozen");

        // Guardian cannot unfreeze
        vm.prank(guardian);
        vm.expectRevert("NOT_POOL_ADMIN");
        circuitBreaker.unfreezeMarket(ethUsdcMarketId);

        // Alice (random user) cannot unfreeze
        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        circuitBreaker.unfreezeMarket(ethUsdcMarketId);

        // Market is still frozen
        assertTrue(circuitBreaker.marketFrozen(ethUsdcMarketId), "Market should still be frozen");

        // Deployer (poolAdmin) can unfreeze
        vm.prank(deployer);
        circuitBreaker.unfreezeMarket(ethUsdcMarketId);
        assertFalse(circuitBreaker.marketFrozen(ethUsdcMarketId), "Market should be unfrozen");

        console.log("=== unfreeze: only poolAdmin can unfreeze ===");
    }
}
