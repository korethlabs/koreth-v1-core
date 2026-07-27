// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title V3HappyPath
/// @notice Full lifecycle test with real Uniswap V3 on forked mainnet
/// @dev Deposit V3 NFT → Borrow USDC → Time passes → Repay → Withdraw
contract V3HappyPath is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    function test_fullLifecycle_V3() public {
        // 1. Alice creates a V3 WETH/USDC position
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        assertGt(tokenId, 0, "Should get a V3 NFT");

        // Verify Alice owns it
        assertEq(nftManager.ownerOf(tokenId), alice);

        // 2. Deposit into protocol
        uint256 positionId = _depositV3(alice, tokenId);
        // positionId starts at 0 (first position in fresh deployment) — that's valid

        // NFT is now held by the adapter
        assertEq(nftManager.ownerOf(tokenId), address(v3Adapter));

        // Position has value
        uint256 value = _getPositionValue(positionId);
        assertGt(value, 0, "Position should have value");
        console.log("Position value: $%s", value / 1e18);

        // 3. Borrow USDC (50% of max)
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        assertGt(maxBorrow, 0, "Should be able to borrow");
        console.log("Max borrow: %s USDC", maxBorrow / 1e6);

        uint256 borrowAmount = maxBorrow / 2;
        vm.roll(block.number + 2); // cooldown

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        uint256 debt = _getDebt(positionId);
        assertEq(debt, borrowAmount, "Debt should match borrow");
        console.log("Borrowed: %s USDC", borrowAmount / 1e6);

        // Alice received USDC
        assertGt(IERC20(Constants.USDC).balanceOf(alice), 0, "Alice should have USDC");

        // 4. Time passes — interest accrues
        _advanceTime(1 hours); // keep within Chainlink staleness window (24h)
        lendingEngine.accrueInterest(ethUsdcMarketId);

        uint256 debtAfterInterest = _getDebt(positionId);
        assertGe(debtAfterInterest, borrowAmount, "Debt should not decrease");
        console.log("Debt after 1 hour: %s USDC", debtAfterInterest / 1e6);

        // 5. Repay all debt
        _fundUsdc(alice, debtAfterInterest); // fund extra for interest
        vm.startPrank(alice);
        address marketAddr = core.markets(ethUsdcMarketId);
        IERC20(Constants.USDC).approve(marketAddr, type(uint256).max);
        lendingEngine.repay(positionId, type(uint256).max);
        vm.stopPrank();

        assertEq(_getDebt(positionId), 0, "Debt should be zero");

        // 6. Withdraw — get NFT back
        vm.prank(alice);
        positionManager.withdraw(positionId);

        // Alice has her NFT back
        assertEq(nftManager.ownerOf(tokenId), alice, "Alice should have NFT back");
        console.log("=== V3 Happy Path Complete ===");
    }

    function test_deposit_and_withdraw_noDebt() public {
        // Simple deposit + withdraw without borrowing
        uint256 tokenId = _createV3Position(alice, 0.5 ether, 1000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        assertGt(_getPositionValue(positionId), 0);

        vm.prank(alice);
        positionManager.withdraw(positionId);

        assertEq(nftManager.ownerOf(tokenId), alice);
    }

    function test_healthFactor_healthy() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = maxBorrow / 3; // borrow 33% of max — should be healthy

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        uint256 hf = _getHealthFactor(positionId);
        assertGt(hf, 1e18, "Health factor should be above 1.0");
        console.log("Health factor: %s", hf / 1e16); // print as percentage * 100
    }
}
