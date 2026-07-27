// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title Emergency
/// @notice Tests emergency flows: global pause, circuit breaker pool pause, withdrawals during pause
contract Emergency is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    function test_globalPause_blocksDepositsAndBorrows() public {
        // Alice creates and deposits LP position before pause
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Create a second position for the deposit-blocked test
        uint256 tokenId2 = _createV3Position(alice, 1 ether, 2000e6);

        // Guardian pauses protocol
        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused(), "Should be paused");

        // Deposit should fail
        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId2);
        vm.expectRevert("PAUSED");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId2, 0, ethUsdcMarketId);
        vm.stopPrank();

        // Borrow should also fail
        vm.prank(alice);
        vm.expectRevert("PAUSED");
        lendingEngine.borrow(positionId, 100e6);

        console.log("=== Global Pause Blocks Deposits and Borrows ===");
    }

    function test_globalPause_allowsWithdrawAfterUnpause() public {
        // Alice deposits first
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        // Pause
        vm.prank(guardian);
        core.pause();

        // Withdraw should fail while paused
        vm.prank(alice);
        vm.expectRevert("PAUSED");
        positionManager.withdraw(positionId);

        // Unpause (requires PoolAdmin, not EmergencyAdmin)
        vm.prank(deployer);
        core.unpause();

        // Withdraw should work now
        vm.prank(alice);
        positionManager.withdraw(positionId);
        assertEq(nftManager.ownerOf(tokenId), alice, "Alice should get NFT back");

        console.log("=== Withdraw After Unpause Test Passed ===");
    }

    function test_circuitBreaker_poolPause_blocksNewDeposits() public {
        // Pause the WETH/USDC V3 pool via circuit breaker
        vm.prank(deployer);
        circuitBreaker.pausePool(Constants.UNI_V3_WETH_USDC_3000, "TVL anomaly detected");

        assertTrue(circuitBreaker.poolPaused(Constants.UNI_V3_WETH_USDC_3000), "Pool should be paused");

        // Alice tries to deposit — should be blocked by circuit breaker
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        vm.expectRevert("POOL_CIRCUIT_BREAKER");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);
        vm.stopPrank();

        console.log("=== Pool Circuit Breaker Blocks Deposits ===");
    }

    function test_circuitBreaker_poolPause_allowsWithdrawals() public {
        // Alice deposits first
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        // Pause the pool
        vm.prank(deployer);
        circuitBreaker.pausePool(Constants.UNI_V3_WETH_USDC_3000, "Price anomaly");

        // Withdrawal should still work (circuit breaker NOT in withdraw path)
        vm.prank(alice);
        positionManager.withdraw(positionId);
        assertEq(nftManager.ownerOf(tokenId), alice, "Alice should get NFT back");

        console.log("=== Pool Pause Allows Withdrawals ===");
    }

    function test_circuitBreaker_blocksBorrowsOnPausedPool() public {
        // Alice deposits and then pool gets paused
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Pause pool
        vm.prank(deployer);
        circuitBreaker.pausePool(Constants.UNI_V3_WETH_USDC_3000, "Emergency");

        // Borrow should fail
        vm.prank(alice);
        vm.expectRevert("POOL_CIRCUIT_BREAKER");
        lendingEngine.borrow(positionId, 100e6);

        // Unpause
        vm.prank(deployer);
        circuitBreaker.unpausePool(Constants.UNI_V3_WETH_USDC_3000);

        // Borrow should work now
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 3);

        assertGt(_getDebt(positionId), 0, "Should have debt after borrow");
        console.log("=== Pool Pause Blocks Borrows Then Unpauses ===");
    }

    function test_unauthorizedPause_reverts() public {
        // Alice (non-admin) cannot pause
        vm.prank(alice);
        vm.expectRevert();
        core.pause();

        // Alice cannot circuit-break a pool
        vm.prank(alice);
        vm.expectRevert("NOT_AUTHORIZED");
        circuitBreaker.pausePool(Constants.UNI_V3_WETH_USDC_3000, "hack");

        console.log("=== Unauthorized Pause Reverts ===");
    }
}
