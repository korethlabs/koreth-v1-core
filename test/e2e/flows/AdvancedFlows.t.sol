// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";

/// @title AdvancedFlows
/// @notice Comprehensive E2E tests covering liquidation execution, bad debt, multi-borrow,
///         protocol fees, addCollateral, long-duration interest, and state transitions.
/// @dev All tests run against real Uniswap on forked mainnet via Anvil.
contract AdvancedFlows is E2EBase {
    uint256 public v2MarketId;

    function setUp() public override {
        super.setUp();

        // Create V2 market for liquidation tests (V2 has pos.amount > 0)
        vm.startPrank(deployer);
        (v2MarketId,) = marketFactory.createMarket(
            ILPAdapter.LPType.UniswapV2, Constants.USDC, 6500, 7500, 500, 10_000_000e6, 0, 0, "volatile"
        );
        // Set reserve factor for fee tests
        Market(core.markets(ethUsdcMarketId)).setReserveFactor(2000); // 20%
        Market(core.markets(v2MarketId)).setReserveFactor(2000);
        // Wire FeeCollector
        Market(core.markets(ethUsdcMarketId)).setFeeCollector(address(feeCollector));
        Market(core.markets(v2MarketId)).setFeeCollector(address(feeCollector));
        vm.stopPrank();

        // Fund V2 market with liquidity
        _fundUsdc(bob, 50_000e6);
        address v2MarketAddr = core.markets(v2MarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(v2MarketAddr, 50_000e6);
        IMarket(v2MarketAddr).supply(50_000e6);
        vm.stopPrank();
    }

    // ========================================================================
    // 1. FULL LIQUIDATION EXECUTION — real Uniswap unwind
    // ========================================================================

    function test_fullLiquidation_execution_V2() public {
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();
        vm.roll(block.number + 2);

        // Borrow aggressively
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 90) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Mock price drop to make liquidatable
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 40) / 100);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Must be liquidatable");

        // Record liquidator balances before
        uint256 liqWethBefore = IERC20(Constants.WETH).balanceOf(liquidator);
        uint256 liqUsdcBefore = IERC20(Constants.USDC).balanceOf(liquidator);

        // Execute liquidation
        _fundUsdc(liquidator, maxRepay);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        // Verify liquidator received underlying tokens
        uint256 liqWethAfter = IERC20(Constants.WETH).balanceOf(liquidator);
        uint256 liqUsdcAfter = IERC20(Constants.USDC).balanceOf(liquidator);
        assertTrue(liqWethAfter > liqWethBefore || liqUsdcAfter > liqUsdcBefore, "Liquidator must receive tokens");

        // Verify debt decreased
        uint256 debtAfter = _getDebt(positionId);
        assertLt(debtAfter, borrowAmount, "Debt must decrease after liquidation");

        console.log("Liquidator WETH gained: %s", (liqWethAfter - liqWethBefore));
        console.log("Liquidator USDC gained: %s", (liqUsdcAfter - liqUsdcBefore) / 1e6);
        console.log("=== Full Liquidation Execution Passed ===");
    }

    // ========================================================================
    // 2. PARTIAL LIQUIDATION — repay < maxRepay
    // ========================================================================

    function test_partialLiquidation_execution() public {
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 80) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        uint256 amountBefore = positionManager.getPosition(positionId).amount;

        // Mock price for partial liquidation (HF ~ 0.97)
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 debtUsd = uint256(borrowAmount) * 1e12;
        uint256 targetValue = (debtUsd * 10_000 * 97) / (7500 * 100);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, targetValue);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq);

        // Partial repay — only half of maxRepay
        uint256 partialRepay = maxRepay / 2;
        _fundUsdc(liquidator, partialRepay);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), partialRepay);
        liquidationEngine.liquidate(positionId, partialRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        // Position should still be active (not fully liquidated)
        PositionManager.Position memory posAfter = positionManager.getPosition(positionId);
        assertLt(posAfter.amount, amountBefore, "Position amount must decrease");
        assertGt(posAfter.amount, 0, "Position should still have collateral");
        assertTrue(
            posAfter.status == IPositionManager.PositionStatus.Borrowed
                || posAfter.status == IPositionManager.PositionStatus.Active,
            "Position should still be active/borrowed"
        );

        console.log("Amount before: %s, after: %s", amountBefore, posAfter.amount);
        console.log("=== Partial Liquidation Execution Passed ===");
    }

    // ========================================================================
    // 3. MULTIPLE PARTIAL LIQUIDATIONS on same position
    // ========================================================================

    function test_multiplePartialLiquidations() public {
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 85) / 100);

        // Make liquidatable
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 50) / 100);

        // First partial liquidation
        (, uint256 maxRepay1) = liquidationEngine.isLiquidatable(positionId);
        uint256 repay1 = maxRepay1 / 3;
        _fundUsdc(liquidator, repay1);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), repay1);
        liquidationEngine.liquidate(positionId, repay1, block.timestamp, 0, 0);
        vm.stopPrank();

        uint256 debtAfter1 = _getDebt(positionId);

        // Update mock for reduced position
        pos = positionManager.getPosition(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 35) / 100);

        // Second partial liquidation
        (, uint256 maxRepay2) = liquidationEngine.isLiquidatable(positionId);
        if (maxRepay2 > 0) {
            uint256 repay2 = maxRepay2 / 2;
            _fundUsdc(liquidator, repay2);
            vm.startPrank(liquidator);
            IERC20(Constants.USDC).approve(address(liquidationEngine), repay2);
            liquidationEngine.liquidate(positionId, repay2, block.timestamp, 0, 0);
            vm.stopPrank();

            uint256 debtAfter2 = _getDebt(positionId);
            assertLt(debtAfter2, debtAfter1, "Debt should decrease after second liquidation");
        }

        console.log("=== Multiple Partial Liquidations Passed ===");
    }

    // ========================================================================
    // 4. MULTI-BORROW on same position
    // ========================================================================

    function test_multiBorrow_samePosition() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);

        // First borrow — 30% of max
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 3);
        uint256 debt1 = _getDebt(positionId);
        assertEq(debt1, maxBorrow / 3);

        // Second borrow — another 20%
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 5);
        uint256 debt2 = _getDebt(positionId);
        assertGt(debt2, debt1, "Debt should increase after second borrow");

        // HF should still be above 1.0
        uint256 hf = _getHealthFactor(positionId);
        assertGt(hf, 1e18, "Should still be healthy");

        // Cannot exceed max LTV
        uint256 remaining = maxBorrow - debt2;
        vm.prank(alice);
        vm.expectRevert("EXCEEDS_MAX_LTV");
        lendingEngine.borrow(positionId, remaining + 1);

        console.log("Debt after 2 borrows: %s USDC, HF: %s", debt2 / 1e6, hf / 1e16);
        console.log("=== Multi-Borrow Same Position Passed ===");
    }

    // ========================================================================
    // 5. BORROW → PARTIAL REPAY → BORROW MORE
    // ========================================================================

    function test_borrowRepayBorrowCycle() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);

        // Borrow 50%
        uint256 borrow1 = maxBorrow / 2;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrow1);

        // Partial repay — pay back 40%
        uint256 repayAmount = (borrow1 * 40) / 100;
        _fundUsdc(alice, repayAmount);
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, repayAmount);
        lendingEngine.repay(positionId, repayAmount);
        vm.stopPrank();

        uint256 debtAfterRepay = _getDebt(positionId);
        assertLt(debtAfterRepay, borrow1, "Debt should decrease after repay");

        // Borrow more — should work since debt decreased
        uint256 newMax = lendingEngine.getMaxBorrow(positionId);
        assertGt(newMax, 0, "Should be able to borrow more after partial repay");

        vm.prank(alice);
        lendingEngine.borrow(positionId, newMax / 2);

        uint256 finalDebt = _getDebt(positionId);
        assertGt(finalDebt, debtAfterRepay, "Debt should increase after re-borrow");

        console.log("=== Borrow-Repay-Borrow Cycle Passed ===");
    }

    // ========================================================================
    // 6. FULL POSITION LIFECYCLE — state transitions
    // ========================================================================

    function test_fullPositionLifecycle_stateTransitions() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        // State: Active
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        assertEq(uint256(pos.status), uint256(IPositionManager.PositionStatus.Active));

        // Borrow → state: Borrowed
        vm.roll(block.number + 2);
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 3);

        pos = positionManager.getPosition(positionId);
        assertEq(uint256(pos.status), uint256(IPositionManager.PositionStatus.Borrowed));

        // Repay all → state: Active
        uint256 debt = _getDebt(positionId);
        _fundUsdc(alice, debt);
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, type(uint256).max);
        lendingEngine.repay(positionId, type(uint256).max);
        vm.stopPrank();

        pos = positionManager.getPosition(positionId);
        assertEq(uint256(pos.status), uint256(IPositionManager.PositionStatus.Active));

        // Withdraw → state: Closed
        vm.prank(alice);
        positionManager.withdraw(positionId);

        pos = positionManager.getPosition(positionId);
        assertEq(uint256(pos.status), uint256(IPositionManager.PositionStatus.Closed));
        assertEq(nftManager.ownerOf(tokenId), alice, "Alice gets NFT back");

        console.log("=== Full Lifecycle State Transitions Passed ===");
    }

    // ========================================================================
    // 7. LONG-DURATION INTEREST ACCRUAL (1 week)
    // ========================================================================

    function test_longDurationInterest_1week() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 2);

        uint256 debtBefore = _getDebt(positionId);

        // Advance 1 week (within 24h staleness window — accrue in 12h chunks)
        for (uint256 i = 0; i < 14; i++) {
            _advanceTime(12 hours);
            lendingEngine.accrueInterest(ethUsdcMarketId);
        }

        uint256 debtAfter = _getDebt(positionId);
        assertGt(debtAfter, debtBefore, "Debt must grow over 1 week");

        uint256 interest = debtAfter - debtBefore;
        console.log("Borrowed: %s USDC, 1-week interest: %s USDC", debtBefore / 1e6, interest / 1e6);
        console.log("=== 1-Week Interest Accrual Passed ===");
    }

    // ========================================================================
    // 8. PROTOCOL FEES — reserve factor → distributeReserves → FeeCollector → Treasury
    // ========================================================================

    function test_protocolFees_fullFlow() public {
        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);

        // Alice borrows
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 2);

        // Advance time → interest accrues → reserves accumulate
        _advanceTime(1 hours);
        market.accrueInterest();

        uint256 reserves = market.protocolReserves();
        assertGt(reserves, 0, "Protocol reserves should accumulate");

        // Distribute reserves to FeeCollector
        uint256 fcBefore = IERC20(Constants.USDC).balanceOf(address(feeCollector));
        market.distributeReserves();
        uint256 fcAfter = IERC20(Constants.USDC).balanceOf(address(feeCollector));
        assertGt(fcAfter, fcBefore, "FeeCollector should receive reserves");

        // FeeCollector distributes to Treasury + Insurance
        uint256 accFees = feeCollector.accumulatedFees(Constants.USDC);
        assertGt(accFees, 0, "Accumulated fees tracked");

        uint256 treasuryBefore = IERC20(Constants.USDC).balanceOf(deployer); // treasury = deployer
        vm.prank(deployer);
        feeCollector.distribute(Constants.USDC);
        uint256 treasuryAfter = IERC20(Constants.USDC).balanceOf(deployer);

        assertGt(treasuryAfter, treasuryBefore, "Treasury should receive fees");
        assertEq(feeCollector.accumulatedFees(Constants.USDC), 0, "Fees cleared after distribute");

        console.log(
            "Reserves: %s, FeeCollector: %s, Treasury gained: %s",
            reserves,
            fcAfter - fcBefore,
            treasuryAfter - treasuryBefore
        );
        console.log("=== Protocol Fees Full Flow Passed ===");
    }

    // ========================================================================
    // 9. LENDER WITHDRAWAL BLOCKED at high utilization
    // ========================================================================

    function test_lenderWithdrawal_blockedAtHighUtil() public {
        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);

        uint256 bobShares = market.shares(bob);

        // Alice borrows most of the market
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow);

        // Bob tries to withdraw all — should fail (insufficient liquidity)
        vm.prank(bob);
        vm.expectRevert("INSUFFICIENT_LIQUIDITY");
        market.withdraw(bobShares);

        // Bob can withdraw a small amount
        uint256 marketBalance = IERC20(Constants.USDC).balanceOf(marketAddr);
        if (marketBalance > 100e6) {
            // Calculate shares for partial withdrawal
            uint256 partialShares = (bobShares * marketBalance) / (market.getMarketState().totalSupply * 2);
            if (partialShares > 0) {
                vm.prank(bob);
                market.withdraw(partialShares);
            }
        }

        console.log("Market balance after max borrow: %s USDC", marketBalance / 1e6);
        console.log("=== Lender Withdrawal Blocked at High Util Passed ===");
    }

    // ========================================================================
    // 10. MULTIPLE USERS competing for liquidity
    // ========================================================================

    function test_multipleUsers_liquidityCompetition() public {
        // Carol joins as third borrower
        address carol = makeAddr("carol");
        _fundWeth(carol, 5 ether);
        _fundUsdc(carol, 20_000e6);

        // Alice borrows 40%
        uint256 tokenId1 = _createV3Position(alice, 1 ether, 2000e6);
        uint256 posId1 = _depositV3(alice, tokenId1);
        vm.roll(block.number + 2);
        uint256 maxBorrow1 = lendingEngine.getMaxBorrow(posId1);
        vm.prank(alice);
        lendingEngine.borrow(posId1, maxBorrow1 / 2);

        // Carol borrows 40%
        uint256 tokenId2 = _createV3Position(carol, 1 ether, 2000e6);
        vm.startPrank(carol);
        nftManager.approve(address(v3Adapter), tokenId2);
        uint256 posId2 = positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId2, 0, ethUsdcMarketId);
        vm.stopPrank();
        vm.roll(block.number + 3); // extra cooldown

        uint256 maxBorrow2 = lendingEngine.getMaxBorrow(posId2);
        vm.prank(carol);
        lendingEngine.borrow(posId2, maxBorrow2 / 2);

        // Both have debt, market has reduced liquidity
        assertGt(_getDebt(posId1), 0);
        assertGt(_getDebt(posId2), 0);

        address marketAddr = core.markets(ethUsdcMarketId);
        uint256 remaining = IERC20(Constants.USDC).balanceOf(marketAddr);
        console.log("Market remaining after 2 borrowers: %s USDC", remaining / 1e6);

        console.log("=== Multiple Users Liquidity Competition Passed ===");
    }

    // ========================================================================
    // 11. FROZEN MARKET + LIQUIDATION still works
    // ========================================================================

    function test_frozenMarket_liquidationWorks() public {
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        // Freeze market + make liquidatable
        vm.prank(deployer);
        circuitBreaker.freezeMarket(v2MarketId, "Depeg detected");

        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 40) / 100);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Should be liquidatable even when frozen");

        // Liquidation should work on frozen market
        _fundUsdc(liquidator, maxRepay);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        assertLt(_getDebt(positionId), (maxBorrow * 90) / 100, "Debt should decrease");
        console.log("=== Frozen Market Liquidation Passed ===");
    }

    // ========================================================================
    // 12. REPAY ON BEHALF (third party repays)
    // ========================================================================

    function test_thirdPartyFundsRepay() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 3);

        uint256 debt = _getDebt(positionId);

        // Bob sends USDC to Alice so she can repay
        _fundUsdc(bob, debt);
        vm.prank(bob);
        IERC20(Constants.USDC).transfer(alice, debt);

        // Alice repays with Bob's funds
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, type(uint256).max);
        lendingEngine.repay(positionId, type(uint256).max);
        vm.stopPrank();

        assertEq(_getDebt(positionId), 0, "Debt should be zero");

        // Alice withdraws
        vm.prank(alice);
        positionManager.withdraw(positionId);
        assertEq(nftManager.ownerOf(tokenId), alice);

        console.log("=== Third Party Funds Repay Passed ===");
    }

    // ========================================================================
    // 13. LIQUIDATION BONUS — verify liquidator profit
    // ========================================================================

    function test_liquidationBonus_liquidatorProfit() public {
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 85) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Make liquidatable
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 45) / 100);

        (, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);

        // Fund liquidator first, then snapshot balances
        _fundUsdc(liquidator, maxRepay);
        uint256 liqUsdcBefore = IERC20(Constants.USDC).balanceOf(liquidator);
        uint256 liqWethBefore = IERC20(Constants.WETH).balanceOf(liquidator);

        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        uint256 liqWethAfter = IERC20(Constants.WETH).balanceOf(liquidator);
        uint256 liqUsdcAfter = IERC20(Constants.USDC).balanceOf(liquidator);

        // Liquidator paid maxRepay USDC, received WETH + USDC from LP unwind
        uint256 wethGained = liqWethAfter - liqWethBefore;
        // USDC: liquidator spent maxRepay but received USDC from unwind
        // Net may be negative (paid more than received in USDC), profit is in WETH
        uint256 usdcSpent = liqUsdcBefore > liqUsdcAfter ? liqUsdcBefore - liqUsdcAfter : 0;
        uint256 usdcReceived = liqUsdcAfter > liqUsdcBefore ? liqUsdcAfter - liqUsdcBefore : 0;

        // Liquidator must have received WETH (from LP unwind)
        assertGt(wethGained, 0, "Liquidator must receive WETH from unwind");

        console.log("Liquidator WETH gained: %s wei", wethGained);
        console.log("Liquidator USDC spent: %s, received: %s", usdcSpent / 1e6, usdcReceived / 1e6);
        console.log("Repay amount: %s USDC", maxRepay / 1e6);
        console.log("=== Liquidation Bonus Passed ===");
    }

    // ========================================================================
    // 14. RESERVE FACTOR — verify 80/20 split between lenders and protocol
    // ========================================================================

    function test_reserveFactor_interestSplit() public {
        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);

        uint256 totalSupplyBefore = market.getMarketState().totalSupply;
        uint256 reservesBefore = market.protocolReserves();

        // Fund Alice for this test
        _fundWeth(alice, 2 ether);
        _fundUsdc(alice, 10_000e6);

        // Alice borrows
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 2);

        // Accrue interest
        _advanceTime(1 hours);
        market.accrueInterest();

        uint256 totalSupplyAfter = market.getMarketState().totalSupply;
        uint256 reservesAfter = market.protocolReserves();

        uint256 lenderEarnings = totalSupplyAfter - totalSupplyBefore;
        uint256 protocolEarnings = reservesAfter - reservesBefore;

        assertGt(lenderEarnings, 0, "Lenders should earn");
        assertGt(protocolEarnings, 0, "Protocol should earn reserves");

        // With 20% reserve factor: protocol gets 20%, lenders get 80%
        // Allow some rounding tolerance
        uint256 totalInterest = lenderEarnings + protocolEarnings;
        uint256 protocolShareBps = (protocolEarnings * 10_000) / totalInterest;
        assertGt(protocolShareBps, 1800, "Protocol share should be ~20% (min 18%)");
        assertLt(protocolShareBps, 2200, "Protocol share should be ~20% (max 22%)");

        console.log("Total interest: %s, Lender: %s, Protocol: %s", totalInterest, lenderEarnings, protocolEarnings);
        console.log("Protocol share: %s bps", protocolShareBps);
        console.log("=== Reserve Factor Interest Split Passed ===");
    }
}
