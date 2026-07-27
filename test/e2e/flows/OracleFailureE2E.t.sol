// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title OracleFailureE2E
/// @notice E2E tests for oracle staleness and failure handling with real positions
contract OracleFailureE2E is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    // ========================================================================
    // 1. Stale price blocks borrow
    // ========================================================================

    function test_stalePriceBlocksBorrow() public {
        // Alice deposits V3 position
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 posId = _depositV3(alice, tokenId);

        vm.roll(block.number + 2);

        // Verify borrow works before staleness
        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        assertGt(maxBorrow, 0, "Should have borrowing capacity");

        // Advance time past staleness threshold (24h) without refreshing Chainlink mocks
        _advanceTime(2 days);

        // Borrow should revert with STALE_PRICE
        vm.prank(alice);
        vm.expectRevert("STALE_PRICE");
        lendingEngine.borrow(posId, 100e6);

        console.log("=== Stale Price Blocks Borrow ===");
    }

    // ========================================================================
    // 2. Stale price blocks liquidation check
    // ========================================================================

    function test_stalePriceBlocksLiquidation() public {
        // Alice deposits and borrows
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 posId = _depositV3(alice, tokenId);

        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, (maxBorrow * 80) / 100);

        // Advance time past staleness threshold without refreshing Chainlink mocks
        _advanceTime(2 days);

        // isLiquidatable should revert due to stale price
        vm.expectRevert("STALE_PRICE");
        liquidationEngine.isLiquidatable(posId);

        console.log("=== Stale Price Blocks Liquidation ===");
    }

    // ========================================================================
    // 3. Oracle deviation blocks operations
    // ========================================================================

    function test_oracleDeviationBlocksOperations() public {
        // Alice deposits V3 position
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 posId = _depositV3(alice, tokenId);

        vm.roll(block.number + 2);

        // Mock Chainlink ETH/USD to return $1 (wildly different from pool TWAP ~$2000+)
        vm.mockCall(
            Constants.CL_ETH_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), int256(100_000_000), block.timestamp, block.timestamp, uint80(1))
        );

        // Borrow should revert with ORACLE_DEVIATION (Chainlink says $1, TWAP says ~$2000+)
        vm.prank(alice);
        vm.expectRevert("ORACLE_DEVIATION");
        lendingEngine.borrow(posId, 100e6);

        console.log("=== Oracle Deviation Blocks Operations ===");
    }

    // ========================================================================
    // 4. Refreshed oracle restores operations
    // ========================================================================

    function test_refreshedOracleRestoresOperations() public {
        // Alice deposits V3 position
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 posId = _depositV3(alice, tokenId);

        vm.roll(block.number + 2);

        // Advance time past staleness threshold
        _advanceTime(2 days);

        // Verify borrow is blocked
        vm.prank(alice);
        vm.expectRevert("STALE_PRICE");
        lendingEngine.borrow(posId, 100e6);

        // Refresh Chainlink mocks with current timestamps
        int256 ethPrice = _readPoolPriceAsChainlink();
        _mockChainlinkFeeds(ethPrice);

        // Advance TWAP window so pool TWAP and Chainlink align
        _advanceTime(35 minutes);

        // Re-mock Chainlink with updated timestamp (after the 35 min advance)
        ethPrice = _readPoolPriceAsChainlink();
        _mockChainlinkFeeds(ethPrice);

        // Borrow should now succeed
        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        assertGt(maxBorrow, 0, "Should have borrowing capacity after refresh");

        vm.prank(alice);
        lendingEngine.borrow(posId, 100e6);

        uint256 debt = _getDebt(posId);
        assertGe(debt, 100e6, "Should have debt after borrow");

        console.log("=== Refreshed Oracle Restores Operations ===");
        console.log("  Borrowed 100 USDC successfully after oracle refresh");
    }
}
