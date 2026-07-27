// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title SecurityE2E
/// @notice Fork-based security tests — real Uniswap V2/V3, real Chainlink (vm.mockCall for attack simulation).
/// @dev Covers all Tier 2 attack vectors from docs/security/attack-vectors.md
contract SecurityE2E is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    // ========== 1. Chainlink Returns Stale/Zero ==========

    function test_security_chainlinkStale_oracleReverts() public {
        // Create real V3 position
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        // Mock Chainlink ETH/USD to return stale data (>24h old)
        vm.mockCall(
            Constants.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(2500e8), block.timestamp - 90_000, block.timestamp - 90_000, uint80(1))
        );

        // Oracle should revert on stale data — getPositionValue fails
        vm.expectRevert("STALE_PRICE");
        positionManager.getPositionValue(positionId);
    }

    function test_security_chainlinkZero_oracleReverts() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        // Mock Chainlink ETH/USD to return 0
        vm.mockCall(
            Constants.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(0), block.timestamp, block.timestamp, uint80(1))
        );

        vm.expectRevert("INVALID_PRICE");
        positionManager.getPositionValue(positionId);
    }

    // ========== 2. Token Depeg ==========

    function test_security_usdcDepeg_healthFactorDrops() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 80) / 100);

        uint256 hfBefore = _getHealthFactor(positionId);
        assertGt(hfBefore, 1e18, "Should be healthy");

        // Simulate depeg: collateral value drops 15% (LP contains USDC)
        // Mock at oracleHub level to avoid TWAP/Chainlink deviation check
        uint256 originalValue = _getPositionValue(positionId);
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 85) / 100);

        uint256 hfAfter = _getHealthFactor(positionId);
        assertLt(hfAfter, hfBefore, "HF should drop after depeg");
        console.log("HF before depeg: %s, after: %s", hfBefore / 1e16, hfAfter / 1e16);
    }

    // ========== 3. Token Crash — Liquidation + Bad Debt Path ==========

    function test_security_tokenCrash_positionLiquidatable() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        // Token crashes — mock collateral to near zero
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, 100e18); // $100 left

        uint256 hf = _getHealthFactor(positionId);
        assertLt(hf, 1e18, "Must be liquidatable after crash");

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable");
        assertGt(maxRepay, 0);

        console.log("=== Token Crash: HF=%s, maxRepay=%s USDC ===", hf / 1e16, maxRepay / 1e6);
    }

    // ========== 4. Flash Loan — Borrow Cooldown ==========

    function test_security_flashLoan_cooldownBlocks() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        // Same block — borrow blocked
        vm.prank(alice);
        vm.expectRevert("BORROW_COOLDOWN");
        lendingEngine.borrow(positionId, 100e6);

        // After cooldown — borrow works
        vm.roll(block.number + 2);
        vm.prank(alice);
        lendingEngine.borrow(positionId, 100e6);
        assertGt(_getDebt(positionId), 0, "Borrow should succeed after cooldown");

        console.log("=== Flash Loan Cooldown Test Passed ===");
    }

    // ========== 5. Double Deposit V3 NFT ==========

    function test_security_doubleDepositNFT_secondFails() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);

        // First deposit — NFT transferred to adapter
        _depositV3(alice, tokenId);

        // Second deposit — alice no longer owns the NFT
        vm.startPrank(alice);
        vm.expectRevert(); // transferFrom fails — alice doesn't own tokenId
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);
        vm.stopPrank();

        console.log("=== Double Deposit NFT Blocked ===");
    }

    // ========== 6. 100% Utilization ==========

    function test_security_highUtilization_liquidityDrained() public {
        // Bob supplied 100K in setUp. Alice borrows near max.
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow);

        // Market should have very low liquidity now
        address marketAddr = core.markets(ethUsdcMarketId);
        uint256 marketBalance = IERC20(Constants.USDC).balanceOf(marketAddr);
        console.log("Market balance after max borrow: %s USDC", marketBalance / 1e6);

        // Verify market is nearly drained
        assertLt(marketBalance, BOB_USDC, "Market should have less than initial supply");

        console.log("=== Full Utilization Test Passed ===");
    }

    // ========== 7. Self-Liquidation ==========

    function test_security_selfLiquidation_allowed() public {
        // Use V2 for liquidation test — V2 has pos.amount > 0 (required for ZERO_LIQUIDITY check)
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);

        // Create V2 market
        vm.startPrank(deployer);
        (uint256 v2MarketId,) = marketFactory.createMarket(
            ILPAdapter.LPType.UniswapV2, Constants.USDC, 6500, 7500, 500, 10_000_000e6, 0, 0, "volatile"
        );
        vm.stopPrank();

        // Fund and supply to V2 market
        _fundUsdc(bob, 50_000e6);
        address v2MarketAddr = core.markets(v2MarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(v2MarketAddr, 50_000e6);
        IMarket(v2MarketAddr).supply(50_000e6);
        vm.stopPrank();

        // Deposit V2 LP
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 90) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Mock price drop to make liquidatable
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 40) / 100);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Should be liquidatable");

        // Alice self-liquidates — should work (by design, like Aave)
        _fundUsdc(alice, maxRepay);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        IERC20(Constants.USDC).approve(v2MarketAddr, maxRepay);
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        uint256 debtAfter = _getDebt(positionId);
        assertLt(debtAfter, borrowAmount, "Debt should decrease");
        console.log("=== Self-Liquidation Allowed (by design) ===");
    }

    // ========== 8. Frozen Market ==========

    function test_security_frozenMarket_depositsBlocked() public {
        // Freeze market
        vm.prank(deployer);
        circuitBreaker.freezeMarket(ethUsdcMarketId, "USDC depeg");

        // New deposit should fail
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        vm.expectRevert("MARKET_FROZEN");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);
        vm.stopPrank();

        console.log("=== Frozen Market Blocks Deposits ===");
    }

    function test_security_frozenMarket_borrowsBlocked() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Freeze
        vm.prank(deployer);
        circuitBreaker.freezeMarket(ethUsdcMarketId, "Oracle anomaly");

        vm.prank(alice);
        vm.expectRevert("MARKET_FROZEN");
        lendingEngine.borrow(positionId, 100e6);

        console.log("=== Frozen Market Blocks Borrows ===");
    }

    function test_security_frozenMarket_withdrawAndRepayWork() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Borrow first
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 4);

        // Freeze
        vm.prank(deployer);
        circuitBreaker.freezeMarket(ethUsdcMarketId, "Emergency");

        // Repay should work (risk-reducing)
        _fundUsdc(alice, maxBorrow);
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, type(uint256).max);
        lendingEngine.repay(positionId, type(uint256).max);
        vm.stopPrank();
        assertEq(_getDebt(positionId), 0, "Debt should be zero");

        // Withdraw should work (risk-reducing)
        vm.prank(alice);
        positionManager.withdraw(positionId);
        assertEq(nftManager.ownerOf(tokenId), alice, "Alice gets NFT back");

        console.log("=== Frozen Market Allows Withdraw + Repay ===");
    }

    function test_security_frozenMarket_unfreezeRequiresPoolAdmin() public {
        vm.prank(deployer);
        circuitBreaker.freezeMarket(ethUsdcMarketId, "Test");

        // Guardian cannot unfreeze
        vm.prank(guardian);
        vm.expectRevert("NOT_POOL_ADMIN");
        circuitBreaker.unfreezeMarket(ethUsdcMarketId);

        // PoolAdmin (deployer) can unfreeze
        vm.prank(deployer);
        circuitBreaker.unfreezeMarket(ethUsdcMarketId);
        assertFalse(circuitBreaker.marketFrozen(ethUsdcMarketId));

        console.log("=== Unfreeze Requires PoolAdmin ===");
    }

    // ========== 9. Interest Rate Cap ==========

    function test_security_interestRateCapped() public {
        // Deploy IRM with extreme slopes
        InterestRateModel extremeIrm = new InterestRateModel(0, 0, 100_000, 5000);

        // At 100% utilization, rate should be capped
        uint256 rate = extremeIrm.getBorrowRate(10_000);
        assertLe(rate, extremeIrm.MAX_RATE_PER_SECOND(), "Rate must be capped at ~500% APR");

        // Normal IRM should NOT be capped
        uint256 normalRate = volatileModel.getBorrowRate(5000);
        assertLt(normalRate, volatileModel.MAX_RATE_PER_SECOND(), "Normal rate below cap");

        console.log("=== Interest Rate Cap Test Passed ===");
    }

    // ========== 10. Interest Accrual Long Duration ==========

    function test_security_interestAccrual_1hour() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 2);

        uint256 debtBefore = _getDebt(positionId);

        // Advance 1 hour (within Chainlink staleness window)
        _advanceTime(1 hours);
        lendingEngine.accrueInterest(ethUsdcMarketId);

        uint256 debtAfter = _getDebt(positionId);
        assertGe(debtAfter, debtBefore, "Debt should not decrease");

        console.log("Debt before: %s, after: %s USDC", debtBefore / 1e6, debtAfter / 1e6);
        console.log("=== Interest Accrual Test Passed ===");
    }
}
