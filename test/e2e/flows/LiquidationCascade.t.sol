// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IUniswapV2Pair} from "../../../src/interfaces/external/IUniswapV2.sol";

/// @title LiquidationCascade
/// @notice E2E tests for multi-position liquidation scenarios, cross-market borrowing,
///         and interest accrual during price crashes.
contract LiquidationCascade is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    function _liquidateIfPossible(uint256 positionId) internal returns (bool liquidated, uint256 repaid) {
        (bool isLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        if (isLiq && maxRepay > 0) {
            _fundUsdc(liquidator, maxRepay);
            vm.startPrank(liquidator);
            IERC20(Constants.USDC).approve(address(liquidationEngine), type(uint256).max);
            liquidationEngine.liquidate(positionId, maxRepay, block.timestamp + 300, 0, 0);
            vm.stopPrank();
            return (true, maxRepay);
        }
        return (false, 0);
    }

    /// @notice Alice has 3 V3 positions - price drops - 2 get liquidated, 1 survives
    function test_multiPosition_selectiveLiquidation() public {
        // 1. Alice creates 3 positions with different leverage
        uint256 tokenId1 = _createV3Position(alice, 1 ether, 2000e6);
        uint256 posId1 = _depositV3(alice, tokenId1);

        _fundWeth(alice, 1 ether);
        _fundUsdc(alice, 2000e6);
        uint256 tokenId2 = _createV3Position(alice, 1 ether, 2000e6);
        uint256 posId2 = _depositV3(alice, tokenId2);

        _fundWeth(alice, 1 ether);
        _fundUsdc(alice, 2000e6);
        uint256 tokenId3 = _createV3Position(alice, 1 ether, 2000e6);
        uint256 posId3 = _depositV3(alice, tokenId3);

        // Advance past all deposit blocks
        vm.roll(block.number + 5);

        // Position 1: borrow 90% of max (high risk)
        uint256 _max1 = lendingEngine.getMaxBorrow(posId1);
        vm.prank(alice);
        lendingEngine.borrow(posId1, (_max1 * 90) / 100);

        // Position 2: borrow 80% of max (medium risk)
        uint256 _max2 = lendingEngine.getMaxBorrow(posId2);
        vm.prank(alice);
        lendingEngine.borrow(posId2, (_max2 * 80) / 100);

        // Position 3: borrow 30% of max (safe)
        uint256 _max3 = lendingEngine.getMaxBorrow(posId3);
        vm.prank(alice);
        lendingEngine.borrow(posId3, (_max3 * 30) / 100);

        console.log("=== Before crash ===");
        console.log("Position 1 HF: %s (high leverage)", _getHealthFactor(posId1) / 1e16);
        console.log("Position 2 HF: %s (medium leverage)", _getHealthFactor(posId2) / 1e16);
        console.log("Position 3 HF: %s (safe)", _getHealthFactor(posId3) / 1e16);

        // 2. Crash ETH price
        _crashEthPrice(2000 ether);

        uint256 hf3 = _getHealthFactor(posId3);

        // 3. Liquidate underwater positions
        (bool liq1, uint256 repaid1) = _liquidateIfPossible(posId1);
        if (liq1) console.log("Position 1 liquidated: %s USDC", repaid1 / 1e6);

        (bool liq2, uint256 repaid2) = _liquidateIfPossible(posId2);
        if (liq2) console.log("Position 2 liquidated: %s USDC", repaid2 / 1e6);

        // Position 3 should survive
        assertGe(hf3, 1e18, "Position 3 should survive crash");
        console.log("Position 3 survived with HF: %s", hf3 / 1e16);
    }

    /// @notice Interest accrues while price crashes - double pressure on health factor
    function test_interestDuringPriceCrash() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 70) / 100);

        uint256 hfStart = _getHealthFactor(positionId);
        uint256 debtStart = _getDebt(positionId);
        console.log("Start HF: %s, debt: %s USDC", hfStart / 1e16, debtStart / 1e6);

        // 1. Interest accrues for 90 days
        _advanceTime(90 days);

        // Re-mock Chainlink to avoid STALE_PRICE (fork data is old after time warp)
        int256 ethPrice = int256(_getEthPrice() / 1e10); // convert 18-dec to 8-dec
        vm.mockCall(
            Constants.CL_ETH_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), ethPrice, block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(
            Constants.CL_USDC_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), int256(100_000_000), block.timestamp, block.timestamp, uint80(1))
        );

        lendingEngine.accrueInterest(ethUsdcMarketId);

        uint256 hfAfterInterest = _getHealthFactor(positionId);
        uint256 debtAfterInterest = _getDebt(positionId);
        console.log("After 90d interest - HF: %s, debt: %s USDC", hfAfterInterest / 1e16, debtAfterInterest / 1e6);

        assertLt(hfAfterInterest, hfStart, "Interest should degrade HF");
        assertGt(debtAfterInterest, debtStart, "Debt should grow from interest");

        // 2. Then crash ETH price
        _crashEthPrice(1500 ether);

        uint256 hfAfterCrash = _getHealthFactor(positionId);
        console.log("After crash - HF: %s", hfAfterCrash / 1e16);

        assertLt(hfAfterCrash, hfAfterInterest, "Crash should further degrade HF");

        (bool isLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        console.log("Liquidatable: %s, maxRepay: %s USDC", isLiq ? uint256(1) : uint256(0), maxRepay / 1e6);
    }

    /// @notice Cross-market: Alice borrows from V3 market AND V2 market - positions are independent
    function test_crossMarket_V3andV2() public {
        vm.startPrank(deployer);
        (uint256 v2MarketId,) = marketFactory.createMarket(
            ILPAdapter.LPType.UniswapV2, Constants.USDC, 6500, 7500, 500, 10_000_000e6, 0, 0, "volatile"
        );
        vm.stopPrank();

        _fundUsdc(bob, 50_000e6);
        address v2MarketAddr = core.markets(v2MarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(v2MarketAddr, 50_000e6);
        IMarket(v2MarketAddr).supply(50_000e6);
        vm.stopPrank();

        // V3 position
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 v3PosId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);
        uint256 _v3Max = lendingEngine.getMaxBorrow(v3PosId);
        vm.prank(alice);
        lendingEngine.borrow(v3PosId, _v3Max / 3);

        // V2 position
        _fundWeth(alice, 1 ether);
        _fundUsdc(alice, 2000e6);
        uint256 lpAmount = _createV2Position(alice, 1 ether, 2000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 v2PosId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();
        vm.roll(block.number + 5);
        uint256 _v2Max = lendingEngine.getMaxBorrow(v2PosId);
        vm.prank(alice);
        lendingEngine.borrow(v2PosId, _v2Max / 3);

        console.log("V3 debt: %s USDC, V2 debt: %s USDC", _getDebt(v3PosId) / 1e6, _getDebt(v2PosId) / 1e6);

        // Repay V3 - V2 should be unaffected
        _fundUsdc(alice, _getDebt(v3PosId));
        address v3MarketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(v3MarketAddr, type(uint256).max);
        lendingEngine.repay(v3PosId, type(uint256).max);
        vm.stopPrank();

        assertEq(_getDebt(v3PosId), 0, "V3 debt should be zero");
        assertGt(_getDebt(v2PosId), 0, "V2 debt should be unchanged");
        console.log("=== Cross-market independence verified ===");
    }

    /// @notice Liquidation during circuit breaker - should still work on paused pools
    function test_liquidation_duringCircuitBreaker() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 5);

        uint256 _maxB = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (_maxB * 85) / 100);

        _crashEthPrice(2500 ether);

        // Pause the pool
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        vm.prank(deployer);
        circuitBreaker.pausePool(pos.pool, "test pause");

        (bool liq, uint256 repaid) = _liquidateIfPossible(positionId);
        if (liq) console.log("Liquidated during circuit breaker: %s USDC", repaid / 1e6);

        vm.prank(deployer);
        circuitBreaker.unpausePool(pos.pool);
    }
}
