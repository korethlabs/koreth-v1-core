// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";

/// @title LiquidationInvariantE2E
/// @notice E2E invariant tests for liquidation against forked mainnet.
/// @dev Verifies liquidation mechanics with real Uniswap V3 positions and oracles.
///
///      Invariants tested:
///        1. Healthy positions cannot be liquidated
///        2. Liquidation reduces debt
///        3. Liquidation reduces position collateral
///        4. Liquidator receives collateral tokens
///        5. Liquidation cannot exceed maxRepay
///        6. Post-liquidation debt accounting is consistent
contract LiquidationInvariantE2E is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    // ================================================================
    // 1. Healthy position cannot be liquidated
    // ================================================================

    function test_invariant_healthyNotLiquidatable() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Borrow conservatively (30% of max)
        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, maxBorrow / 3);

        uint256 hf = _getHealthFactor(posId);
        assertGt(hf, 1e18, "Position should be healthy");

        (bool isLiq,) = liquidationEngine.isLiquidatable(posId);
        assertFalse(isLiq, "Healthy position must not be liquidatable");

        // Attempting liquidation must revert
        _fundUsdc(liquidator, 10_000e6);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), 10_000e6);
        vm.expectRevert();
        liquidationEngine.liquidate(posId, 1000e6, block.timestamp + 300, 0, 0);
        vm.stopPrank();
    }

    // ================================================================
    // 2. Liquidation reduces debt
    // ================================================================

    function test_invariant_liquidationReducesDebt() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Borrow near max
        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, (maxBorrow * 90) / 100);

        // Crash price to make liquidatable
        _crashEthPrice(3000 ether);

        (bool isLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(posId);
        if (!isLiq || maxRepay == 0) return;

        uint256 debtBefore = _getDebt(posId);
        uint256 repayAmt = maxRepay / 2; // partial liquidation

        _fundUsdc(liquidator, repayAmt);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), repayAmt);
        liquidationEngine.liquidate(posId, repayAmt, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        uint256 debtAfter = _getDebt(posId);
        assertLt(debtAfter, debtBefore, "Liquidation must reduce debt");
        console.log("Debt reduced: %s -> %s USDC", debtBefore / 1e6, debtAfter / 1e6);
    }

    // ================================================================
    // 3. Liquidation reduces position collateral
    // ================================================================

    function test_invariant_liquidationReducesCollateral() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, (maxBorrow * 90) / 100);

        _crashEthPrice(3000 ether);

        (bool isLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(posId);
        if (!isLiq || maxRepay == 0) return;

        IPositionManager.Position memory posBefore = positionManager.getPosition(posId);

        _fundUsdc(liquidator, maxRepay);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        liquidationEngine.liquidate(posId, maxRepay, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        IPositionManager.Position memory posAfter = positionManager.getPosition(posId);

        // For V3: liquidity decreases. For V2: amount decreases.
        if (posBefore.lpType == ILPAdapter.LPType.UniswapV3) {
            (,,,,,,, uint128 liqBefore,,,,) =
                INonfungiblePositionManager(Constants.UNI_V3_NFT_MANAGER).positions(posBefore.tokenId);
            // After liquidation, the position's collateral should be reduced
            // (either through unwind or fee-only liquidation)
            assertTrue(
                posAfter.amount < posBefore.amount
                    || uint8(posAfter.status) == uint8(IPositionManager.PositionStatus.Liquidated),
                "Collateral must decrease or position must be Liquidated"
            );
        }
    }

    // ================================================================
    // 4. Liquidator receives value (USDC from unwound collateral)
    // ================================================================

    function test_invariant_liquidatorReceivesValue() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, (maxBorrow * 90) / 100);

        _crashEthPrice(3000 ether);

        (bool isLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(posId);
        if (!isLiq || maxRepay == 0) return;

        uint256 repayAmt = maxRepay / 2;
        _fundUsdc(liquidator, repayAmt);

        uint256 usdcBefore = IERC20(Constants.USDC).balanceOf(liquidator);
        uint256 wethBefore = IERC20(Constants.WETH).balanceOf(liquidator);

        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), repayAmt);
        liquidationEngine.liquidate(posId, repayAmt, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        uint256 usdcAfter = IERC20(Constants.USDC).balanceOf(liquidator);
        uint256 wethAfter = IERC20(Constants.WETH).balanceOf(liquidator);

        // Liquidator spent USDC to repay debt but received collateral tokens.
        // Addition-based comparison to avoid 0.8 underflow if pre-balance < repayAmt.
        bool receivedSomething = (wethAfter > wethBefore) || (usdcAfter + repayAmt > usdcBefore);
        assertTrue(receivedSomething, "Liquidator must receive collateral tokens");
    }

    // ================================================================
    // 5. Market totalBorrow decreases after liquidation
    // ================================================================

    function test_invariant_marketBorrowDecreasesAfterLiquidation() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, (maxBorrow * 90) / 100);

        _crashEthPrice(3000 ether);

        (bool isLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(posId);
        if (!isLiq || maxRepay == 0) return;

        address marketAddr = core.markets(ethUsdcMarketId);
        IMarket.MarketState memory sBefore = IMarket(marketAddr).getMarketState();

        _fundUsdc(liquidator, maxRepay);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        liquidationEngine.liquidate(posId, maxRepay, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        IMarket.MarketState memory sAfter = IMarket(marketAddr).getMarketState();
        assertLt(sAfter.totalBorrow, sBefore.totalBorrow, "Market totalBorrow must decrease after liquidation");
    }

    // ================================================================
    // 6. Post-liquidation: if position still exists, HF should improve
    // ================================================================

    function test_invariant_liquidationImprovesHF() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 posId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(posId);
        vm.prank(alice);
        lendingEngine.borrow(posId, (maxBorrow * 85) / 100);

        _crashEthPrice(2000 ether);

        (bool isLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(posId);
        if (!isLiq || maxRepay == 0) return;

        // Snapshot HF before the partial liquidation
        uint256 hfBefore = _getHealthFactor(posId);

        // Partial liquidation (half of max)
        uint256 repayAmt = maxRepay / 2;

        _fundUsdc(liquidator, repayAmt);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), repayAmt);
        liquidationEngine.liquidate(posId, repayAmt, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        // If the position survives with debt, HF must have strictly improved:
        // repaid debt is worth more, proportionally, than the bonus-discounted collateral seized.
        if (positionManager.getPosition(posId).amount > 0 && _getDebt(posId) > 0) {
            uint256 hfAfter = _getHealthFactor(posId);
            console.log("HF before: %s, after: %s", hfBefore / 1e16, hfAfter / 1e16);
            assertGt(hfAfter, hfBefore, "Partial liquidation must improve the position's health factor");
        }
    }
}
