// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {Market} from "../../../src/markets/Market.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";

/// @title AdminOperations
/// @notice E2E tests for admin/governance operations on forked mainnet.
/// @dev Covers: Market.updateConfig, Market.eliminateDeficit, RiskManager caps,
///      LiquidationEngine admin setters, FeeCollector.sweepExcess, oracle config.
contract AdminOperations is E2EBase {
    function setUp() public override {
        super.setUp();

        // Grant RISK_ADMIN to deployer for admin tests
        vm.prank(deployer);
        aclManager.addRiskAdmin(deployer);
    }

    // ========== Market.updateConfig ==========

    /// @notice Update LTV/threshold mid-lifecycle with active positions
    function test_updateConfig_midLifecycle() public {
        // Alice deposits and borrows
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 5);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 3);

        uint256 hfBefore = _getHealthFactor(positionId);
        console.log("HF before config change: %s", hfBefore / 1e16);

        // Admin reduces LTV from 65% to 50%
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.prank(deployer);
        Market(marketAddr).updateConfig(5000, 6000, 500, 10_000_000e6);

        // HF should change (liquidation threshold changed from 75% to 60%)
        uint256 hfAfter = _getHealthFactor(positionId);
        console.log("HF after config change: %s", hfAfter / 1e16);
        assertLt(hfAfter, hfBefore, "HF should decrease with lower liq threshold");

        // Max borrow should be lower now
        uint256 maxBorrowAfter = lendingEngine.getMaxBorrow(positionId);
        console.log("Max borrow before: %s, after: %s", maxBorrow / 1e6, maxBorrowAfter / 1e6);
        assertLt(maxBorrowAfter, maxBorrow, "Max borrow should decrease with lower LTV");
    }

    /// @notice updateConfig reverts with invalid params
    function test_revert_updateConfig_invalidParams() public {
        address marketAddr = core.markets(ethUsdcMarketId);

        // LTV >= liquidation threshold
        vm.prank(deployer);
        vm.expectRevert("LTV_MUST_BE_BELOW_LIQ_THRESHOLD");
        Market(marketAddr).updateConfig(8000, 7500, 500, 10_000_000e6);

        // LTV too high
        vm.prank(deployer);
        vm.expectRevert("LTV_TOO_HIGH");
        Market(marketAddr).updateConfig(9600, 9800, 500, 10_000_000e6);

        // Non-admin blocked
        vm.prank(alice);
        vm.expectRevert();
        Market(marketAddr).updateConfig(5000, 6000, 500, 10_000_000e6);
    }

    // ========== Market.eliminateDeficit ==========

    /// @notice eliminateDeficit when no deficit reverts
    function test_revert_eliminateDeficit_noDeficit() public {
        address marketAddr = core.markets(ethUsdcMarketId);

        vm.prank(deployer);
        vm.expectRevert("NO_DEFICIT");
        Market(marketAddr).eliminateDeficit();
    }

    // ========== RiskManager supply cap ==========

    /// @notice Market supply cap blocks new deposits when reached
    function test_riskManager_supplyCap_enforced() public {
        // Set a tight supply cap on the market ($5K)
        vm.prank(deployer);
        riskManager.setMarketSupplyCap(ethUsdcMarketId, 5000e18); // $5K in 18-dec USD

        // Alice deposits a $7K+ position -- should fail
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);

        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        vm.expectRevert("SUPPLY_CAP_REACHED");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);
        vm.stopPrank();

        // Raise cap -- deposit succeeds
        vm.prank(deployer);
        riskManager.setMarketSupplyCap(ethUsdcMarketId, 100_000e18);

        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        uint256 posId = positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);
        vm.stopPrank();

        assertGt(_getPositionValue(posId), 0);
        console.log("Deposit succeeded after raising cap");
    }

    // ========== LiquidationEngine admin ==========

    /// @notice setMaxLiquidationPortion limits seizure amount
    function test_setMaxLiquidationPortion() public {
        // Default is usually 5000 (50%). Set to 2500 (25%)
        vm.prank(deployer);
        liquidationEngine.setMaxLiquidationPortion(2500);

        // Create leveraged position
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 5);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 85) / 100);

        // Mock oracle so HF is ~0.97 (below 1.0 but above CRITICAL_HF 0.95)
        // This ensures the maxLiquidationPortion cap applies (not full-debt mode)
        // HF = (value * liqThreshold) / debtUsd → value = HF * debtUsd * 10000 / liqThreshold
        uint256 debt = _getDebt(positionId);
        uint256 debtUsd = uint256(debt) * 1e12; // 6-dec USDC to 18-dec USD
        uint256 crashedValue = (debtUsd * 9700 * 10_000) / (7500 * 10_000); // HF ~0.97
        _mockOraclePrice(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ILPAdapter.LPType.UniswapV3, crashedValue);

        (bool isLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(isLiq, "Position must be liquidatable");

        // maxRepay should be limited to 25% of debt (2500 bps)
        uint256 expectedMax = (debt * 2500) / 10_000;
        console.log("Debt: %s, maxRepay: %s, expected max ~%s", debt / 1e6, maxRepay / 1e6, expectedMax / 1e6);
        assertLe(maxRepay, expectedMax + expectedMax / 100, "maxRepay should be capped at 25%");
    }

    /// @notice setMaxLiquidationPortion bounds enforcement
    function test_revert_setMaxLiquidationPortion_bounds() public {
        // Below min
        vm.prank(deployer);
        vm.expectRevert("BELOW_MIN");
        liquidationEngine.setMaxLiquidationPortion(0);

        // Above max
        vm.prank(deployer);
        vm.expectRevert("ABOVE_MAX");
        liquidationEngine.setMaxLiquidationPortion(10_001);
    }

    /// @notice rescueTokens recovers stuck tokens
    function test_rescueTokens() public {
        // Send some USDC directly to LiquidationEngine (simulating stuck tokens)
        _fundUsdc(address(liquidationEngine), 1000e6);

        uint256 balBefore = IERC20(Constants.USDC).balanceOf(deployer);

        vm.prank(deployer);
        liquidationEngine.rescueTokens(Constants.USDC, deployer, 1000e6);

        uint256 balAfter = IERC20(Constants.USDC).balanceOf(deployer);
        assertEq(balAfter - balBefore, 1000e6, "Should recover 1000 USDC");
    }

    // ========== FeeCollector.sweepExcess ==========

    /// @notice sweepExcess recovers accidentally sent tokens
    function test_sweepExcess() public {
        // Send USDC directly to FeeCollector (not via collectFee)
        _fundUsdc(address(feeCollector), 500e6);

        uint256 excess =
            IERC20(Constants.USDC).balanceOf(address(feeCollector)) - feeCollector.accumulatedFees(Constants.USDC);
        assertGt(excess, 0, "Should have excess");

        vm.prank(deployer);
        feeCollector.sweepExcess(Constants.USDC, deployer);

        uint256 newExcess =
            IERC20(Constants.USDC).balanceOf(address(feeCollector)) - feeCollector.accumulatedFees(Constants.USDC);
        assertEq(newExcess, 0, "Excess should be swept");
    }

    /// @notice sweepExcess reverts when no excess
    function test_revert_sweepExcess_noExcess() public {
        vm.prank(deployer);
        vm.expectRevert("NO_EXCESS");
        feeCollector.sweepExcess(Constants.USDC, deployer);
    }

    // ========== Oracle config ==========

    /// @notice Admin changes TWAP period and max deviation
    function test_oracleConfig_changes() public {
        // Default TWAP is 30 min (1800s), default deviation is 300 bps (3%)
        vm.startPrank(deployer);

        // Change TWAP to 15 min
        v3Oracle.setTwapPeriod(900);
        // Change max deviation to 5%
        v3Oracle.setMaxDeviation(500);

        vm.stopPrank();

        // Verify position values still work with new oracle config
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        uint256 value = _getPositionValue(positionId);
        assertGt(value, 0, "Position should have value with new oracle config");
        console.log("Position value with 15min TWAP + 5%% deviation: $%s", value / 1e18);
    }

    // ========== PositionManager.getActivePositionsByOwner ==========

    /// @notice getActivePositionsByOwner filters closed/liquidated positions
    function test_getActivePositionsByOwner_filters() public {
        // Create 3 positions
        uint256 tokenId1 = _createV3Position(alice, 1 ether, 2000e6);
        _depositV3(alice, tokenId1);

        _fundWeth(alice, 1 ether);
        _fundUsdc(alice, 2000e6);
        uint256 tokenId2 = _createV3Position(alice, 1 ether, 2000e6);
        uint256 posId2 = _depositV3(alice, tokenId2);

        _fundWeth(alice, 1 ether);
        _fundUsdc(alice, 2000e6);
        uint256 tokenId3 = _createV3Position(alice, 1 ether, 2000e6);
        _depositV3(alice, tokenId3);

        // All 3 should be active
        uint256[] memory active = positionManager.getActivePositionsByOwner(alice);
        assertEq(active.length, 3, "Should have 3 active positions");

        // Close position 2
        vm.prank(alice);
        positionManager.withdraw(posId2);

        // Now only 2 active
        active = positionManager.getActivePositionsByOwner(alice);
        assertEq(active.length, 2, "Should have 2 active positions after closing 1");
        console.log("Active positions after closing 1: %s", active.length);
    }

    // ========== compoundFees ACL ==========

    /// @notice Non-keeper/non-admin cannot call compoundFees
    function test_revert_compoundFees_unauthorized() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        vm.prank(alice); // alice is not keeper or pool admin
        vm.expectRevert("NOT_AUTHORIZED");
        positionManager.compoundFees(
            IPositionManager.CompoundFeesParams({
                positionId: positionId,
                protocolFeeRecipient: address(feeCollector),
                protocolFeeBps: 200,
                callerRewardRecipient: alice,
                callerRewardBps: 50,
                minFeeThreshold: 0,
                dustRefundTo: alice,
                maxSlippageBps: 0
            })
        );
    }
}
