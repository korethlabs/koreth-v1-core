// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title V3Liquidation
/// @notice Liquidation tests with real V3 positions on forked mainnet
/// @dev Uses oracle mocking to simulate price drops (avoids TWAP/Chainlink deviation issues)
contract V3Liquidation is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    function test_liquidatable_V3() public {
        // 1. Alice creates V3 position and borrows near max
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 90) / 100; // 90% of max — aggressive

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        uint256 hfBefore = _getHealthFactor(positionId);
        console.log("HF before drop: %s", hfBefore / 1e16);

        // 2. Simulate price drop by mocking oracleHub to return lower collateral value
        //    We mock at the oracleHub level to avoid TWAP/Chainlink deviation issues.
        //    This tests the liquidation mechanics, not the oracle.
        uint256 originalValue = _getPositionValue(positionId);
        uint256 droppedValue = (originalValue * 40) / 100; // 60% drop

        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, droppedValue);

        uint256 hfAfter = _getHealthFactor(positionId);
        console.log("HF after drop: %s", hfAfter / 1e16);
        assertLt(hfAfter, 1e18, "Should be liquidatable");

        // 3. Liquidator liquidates
        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Must be liquidatable");
        assertGt(maxRepay, 0);

        console.log("=== V3 Full Liquidation Test Passed (HF check) ===");
    }

    function test_partialLiquidation_V3() public {
        // 1. Alice deposits and borrows moderately
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 80) / 100;

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // 2. Moderate drop — target HF ~ 0.97 for partial liquidation
        //    HF = (value * liqThreshold) / (debtUsd * 10000)
        //    debtUsd = borrowAmount * 1e12 (USDC 6dec → 18dec)
        //    For HF=0.97: value = 0.97 * debtUsd * 10000 / 7500
        uint256 debtUsd = uint256(borrowAmount) * 1e12;
        uint256 targetValue = (debtUsd * 10_000 * 97) / (7500 * 100);

        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, targetValue);

        uint256 hf = _getHealthFactor(positionId);
        console.log("HF after moderate drop: %s", hf / 1e16);
        assertLt(hf, 1e18, "HF should be below 1.0 after price drop");

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Should be liquidatable");

        uint256 totalDebt = _getDebt(positionId);
        assertLt(maxRepay, totalDebt, "Should be partial liquidation (maxRepay < totalDebt)");
        console.log("Max repay: %s USDC (of %s total)", maxRepay / 1e6, totalDebt / 1e6);

        vm.clearMockedCalls();
        console.log("=== V3 Partial Liquidation Test Passed ===");
    }

    function test_borrowMax_healthFactor_V3() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);

        // Borrow exactly at max LTV
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow);

        uint256 hf = _getHealthFactor(positionId);
        console.log("HF at max borrow: %s", hf / 1e16);

        // HF should be around liquidationThreshold/maxLtv = 7500/6500 ≈ 1.15
        assertGt(hf, 1e18, "Should still be above 1.0 at max LTV");
        assertLt(hf, 1.5e18, "Should be close to threshold");

        // Cannot borrow more
        vm.prank(alice);
        vm.expectRevert("EXCEEDS_MAX_LTV");
        lendingEngine.borrow(positionId, 1);

        console.log("=== V3 Borrow Max Test Passed ===");
    }
}
