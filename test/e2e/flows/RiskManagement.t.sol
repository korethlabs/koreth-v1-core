// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";

/// @title RiskManagement
/// @notice E2E tests for RiskManager caps and CircuitBreaker freeze/pause flows
contract RiskManagement is E2EBase {
    function setUp() public override {
        super.setUp();

        // Set reserve factor + fee collector for the market (needed for liquidation test)
        vm.startPrank(deployer);
        address marketAddr = core.markets(ethUsdcMarketId);
        Market(marketAddr).setReserveFactor(2000);
        Market(marketAddr).setFeeCollector(address(feeCollector));
        vm.stopPrank();
    }

    // ========================================================================
    // 1. GLOBAL BORROW CAP — set to $1K, borrow up to cap, second borrow reverts
    // ========================================================================

    function test_globalBorrowCap_enforced() public {
        // Set global borrow cap to $1K (18-dec USD) — low value guarantees trigger
        vm.prank(deployer);
        riskManager.setGlobalBorrowCap(1000e18); // $1K cap (very low to guarantee trigger)

        // Alice deposits a large position
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // First borrow $500 — should succeed (within $1K cap)
        uint256 smallBorrow = 500e6;
        vm.prank(alice);
        lendingEngine.borrow(positionId, smallBorrow);
        assertGt(_getDebt(positionId), 0, "Should have debt");

        // Second borrow $600 — should exceed $1K cap and revert
        vm.prank(alice);
        vm.expectRevert("GLOBAL_CAP_REACHED");
        lendingEngine.borrow(positionId, 600e6);

        console.log("=== Global Borrow Cap Enforced ===");
    }

    // ========================================================================
    // 2. MAX POSITION VALUE — set to $5K, deposit a large position reverts
    // ========================================================================

    function test_maxPositionValue_enforced() public {
        // Set max position value to $5K (18-dec USD)
        vm.prank(deployer);
        riskManager.setMaxPositionValue(5000e18);

        // Alice creates a position worth much more than $5K (1 ETH + 2000 USDC ~ $4K+)
        // Use a larger position to ensure it exceeds $5K
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);

        // Deposit should revert because position value > $5K
        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        vm.expectRevert("POSITION_TOO_LARGE");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);
        vm.stopPrank();

        console.log("=== Max Position Value Enforced ===");
    }

    // ========================================================================
    // 3. MAX POSITIONS PER USER — set to 2, third deposit reverts
    // ========================================================================

    function test_maxPositionsPerUser_enforced() public {
        // Set max positions per user to 2
        vm.prank(deployer);
        riskManager.setMaxPositionsPerUser(2);

        // First deposit
        uint256 tokenId1 = _createV3Position(alice, 0.5 ether, 1000e6);
        _depositV3(alice, tokenId1);

        // Second deposit
        _fundWeth(alice, 0.5 ether);
        _fundUsdc(alice, 1000e6);
        uint256 tokenId2 = _createV3Position(alice, 0.5 ether, 1000e6);
        _depositV3(alice, tokenId2);

        // Third deposit — should revert
        _fundWeth(alice, 0.5 ether);
        _fundUsdc(alice, 1000e6);
        uint256 tokenId3 = _createV3Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId3);
        vm.expectRevert("MAX_POSITIONS_REACHED");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId3, 0, ethUsdcMarketId);
        vm.stopPrank();

        console.log("=== Max Positions Per User Enforced ===");
    }

    // ========================================================================
    // 4. CIRCUIT BREAKER — keeper pauses pool, new deposit reverts, unpause works
    // ========================================================================

    function test_circuitBreaker_keeperPausesPool_blocksDeposit() public {
        address keeper = makeAddr("keeper");

        // Grant keeper role
        vm.prank(deployer);
        aclManager.addKeeper(keeper);

        // Keeper pauses the V3 pool
        vm.prank(keeper);
        circuitBreaker.pausePool(Constants.UNI_V3_WETH_USDC_3000, "TVL anomaly");

        assertTrue(circuitBreaker.poolPaused(Constants.UNI_V3_WETH_USDC_3000), "Pool should be paused");

        // New deposit should revert
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        vm.expectRevert("POOL_CIRCUIT_BREAKER");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);
        vm.stopPrank();

        // PoolAdmin unpauses
        vm.prank(deployer);
        circuitBreaker.unpausePool(Constants.UNI_V3_WETH_USDC_3000);

        assertFalse(circuitBreaker.poolPaused(Constants.UNI_V3_WETH_USDC_3000), "Pool should be unpaused");

        // Now deposit works
        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        uint256 positionId = positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);
        vm.stopPrank();

        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        assertEq(pos.owner, alice, "Position should belong to alice");
        console.log("=== Keeper Pauses Pool / Blocks Deposit / Unpause Works ===");
    }

    // ========================================================================
    // 5. CIRCUIT BREAKER — freeze market, deposit/borrow blocked, liquidation works
    // ========================================================================

    function test_circuitBreaker_freezeMarket_allowsLiquidation() public {
        // Create a V2 market for liquidation (V2 uses amount-based positions)
        vm.startPrank(deployer);
        (uint256 v2MarketId,) = marketFactory.createMarket(
            ILPAdapter.LPType.UniswapV2, Constants.USDC, 6500, 7500, 500, 10_000_000e6, 0, 0, "volatile"
        );
        Market(core.markets(v2MarketId)).setReserveFactor(2000);
        Market(core.markets(v2MarketId)).setFeeCollector(address(feeCollector));
        vm.stopPrank();

        // Fund V2 market with liquidity
        _fundUsdc(bob, 50_000e6);
        address v2MarketAddr = core.markets(v2MarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(v2MarketAddr, 50_000e6);
        IMarket(v2MarketAddr).supply(50_000e6);
        vm.stopPrank();

        // Alice creates position and borrows aggressively
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        // Mock price drop to make position liquidatable
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 40) / 100);

        // Freeze the market
        vm.prank(deployer);
        circuitBreaker.freezeMarket(v2MarketId, "Depeg detected");

        assertTrue(circuitBreaker.marketFrozen(v2MarketId), "Market should be frozen");

        // New deposit should be blocked on frozen market
        _fundWeth(alice, 0.5 ether);
        _fundUsdc(alice, 1000e6);
        uint256 lpAmount2 = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount2);
        vm.expectRevert("MARKET_FROZEN");
        positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount2, v2MarketId);
        vm.stopPrank();

        // Borrow should be blocked on frozen market
        vm.prank(alice);
        vm.expectRevert("MARKET_FROZEN");
        lendingEngine.borrow(positionId, 100e6);

        // Liquidation should still work on frozen market
        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Should be liquidatable");

        _fundUsdc(liquidator, maxRepay);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        uint256 debtAfter = _getDebt(positionId);
        assertLt(debtAfter, (maxBorrow * 90) / 100, "Debt should decrease after liquidation");

        console.log("=== Freeze Market Allows Liquidation ===");
    }
}
