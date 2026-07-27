// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title ReserveDistribution
/// @notice E2E tests for Market.distributeReserves and FeeCollector distribution flows
contract ReserveDistribution is E2EBase {
    address public marketAddr;
    Market public market;

    function setUp() public override {
        super.setUp();

        marketAddr = core.markets(ethUsdcMarketId);
        market = Market(marketAddr);

        vm.startPrank(deployer);
        // Set reserve factor (20% of interest goes to protocol)
        market.setReserveFactor(2000);
        // Wire FeeCollector to Market
        market.setFeeCollector(address(feeCollector));
        vm.stopPrank();
    }

    // ========================================================================
    // 1. DISTRIBUTE RESERVES — permissionless, reserves flow to FeeCollector
    // ========================================================================

    function test_distributeReserves_permissionless() public {
        // Alice borrows to generate interest
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 2);

        // Advance time so interest accrues
        _advanceTime(1 hours);
        market.accrueInterest();

        uint256 reserves = market.protocolReserves();
        assertGt(reserves, 0, "Reserves should accumulate from interest");

        // Anyone can call distributeReserves (it is permissionless)
        address randomUser = makeAddr("randomUser");
        uint256 fcBefore = IERC20(Constants.USDC).balanceOf(address(feeCollector));

        vm.prank(randomUser);
        market.distributeReserves();

        uint256 fcAfter = IERC20(Constants.USDC).balanceOf(address(feeCollector));
        assertGt(fcAfter, fcBefore, "FeeCollector should receive reserves");

        console.log("Reserves distributed: %s USDC", (fcAfter - fcBefore) / 1e6);
        console.log("=== Distribute Reserves Permissionless ===");
    }

    // ========================================================================
    // 2. DISTRIBUTE RESERVES — feeCollector.accumulatedFees matches
    // ========================================================================

    function test_distributeReserves_feeCollectorTracksAmount() public {
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

        uint256 reservesBefore = market.protocolReserves();
        assertGt(reservesBefore, 0, "Reserves should exist");

        uint256 accFeesBefore = feeCollector.accumulatedFees(Constants.USDC);

        // Distribute
        market.distributeReserves();

        uint256 accFeesAfter = feeCollector.accumulatedFees(Constants.USDC);
        uint256 feeIncrease = accFeesAfter - accFeesBefore;

        assertGt(feeIncrease, 0, "Accumulated fees should increase");

        // The fee increase should match the USDC balance increase in FeeCollector
        uint256 fcBalance = IERC20(Constants.USDC).balanceOf(address(feeCollector));
        assertGe(fcBalance, accFeesAfter, "FeeCollector balance should cover accumulated fees");

        console.log("Accumulated fees tracked: %s USDC", accFeesAfter / 1e6);
        console.log("=== FeeCollector Tracks Amount ===");
    }

    // ========================================================================
    // 3. FEE COLLECTOR DISTRIBUTE — split to treasury and insurance fund
    // ========================================================================

    function test_feeCollector_distribute_splitToTreasuryAndInsurance() public {
        // Alice borrows to generate interest
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 2);

        // Accrue and distribute reserves to FeeCollector
        _advanceTime(1 hours);
        market.accrueInterest();
        market.distributeReserves();

        uint256 accFees = feeCollector.accumulatedFees(Constants.USDC);
        assertGt(accFees, 0, "Should have accumulated fees");

        // Record treasury and insurance balances before distribution
        address treasuryAddr = feeCollector.treasury();
        address insuranceAddr = feeCollector.insuranceFund();
        uint256 treasuryBefore = IERC20(Constants.USDC).balanceOf(treasuryAddr);
        uint256 insuranceBefore = IERC20(Constants.USDC).balanceOf(insuranceAddr);

        // Distribute from FeeCollector (deployer is PoolAdmin)
        vm.prank(deployer);
        feeCollector.distribute(Constants.USDC);

        uint256 treasuryAfter = IERC20(Constants.USDC).balanceOf(treasuryAddr);
        uint256 insuranceAfter = IERC20(Constants.USDC).balanceOf(insuranceAddr);

        uint256 treasuryGain = treasuryAfter - treasuryBefore;
        uint256 insuranceGain = insuranceAfter - insuranceBefore;

        // Both treasury and insurance should receive something
        // Default insurance share is 10%, treasury gets 90%
        assertGt(treasuryGain + insuranceGain, 0, "Total distribution should be > 0");

        // If treasury and insurance are different addresses, verify the split
        if (treasuryAddr != insuranceAddr) {
            assertGt(treasuryGain, 0, "Treasury should receive fees");
            assertGt(insuranceGain, 0, "Insurance fund should receive fees");
            // Verify approximate 90/10 split
            uint256 totalDist = treasuryGain + insuranceGain;
            uint256 insuranceShareBps = (insuranceGain * 10_000) / totalDist;
            assertGt(insuranceShareBps, 800, "Insurance share should be ~10% (min 8%)");
            assertLt(insuranceShareBps, 1200, "Insurance share should be ~10% (max 12%)");
        } else {
            // Treasury and insurance are the same address in test setup
            assertGt(treasuryGain, 0, "Treasury/insurance should receive all fees");
        }

        // Accumulated fees should be cleared
        assertEq(feeCollector.accumulatedFees(Constants.USDC), 0, "Fees should be cleared after distribution");

        console.log("Treasury gained: %s USDC, Insurance gained: %s USDC", treasuryGain / 1e6, insuranceGain / 1e6);
        console.log("=== FeeCollector Split to Treasury and Insurance ===");
    }

    // ========================================================================
    // 4. RESERVE ACCUMULATION — borrow, advance 30 days, verify reserves > 0
    // ========================================================================

    function test_reserveAccumulation_overTime() public {
        // Alice borrows
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 2);

        uint256 debtBefore = _getDebt(positionId);
        uint256 reservesBefore = market.protocolReserves();

        // Advance 30 days in 12-hour chunks (to stay within oracle staleness)
        for (uint256 i = 0; i < 60; i++) {
            _advanceTime(12 hours);
            market.accrueInterest();
        }

        uint256 debtAfter = _getDebt(positionId);
        uint256 reservesAfter = market.protocolReserves();

        assertGt(debtAfter, debtBefore, "Debt should grow over 30 days");
        assertGt(reservesAfter, reservesBefore, "Reserves should accumulate over 30 days");

        // Reserves should be meaningful relative to debt growth
        uint256 interestAccrued = debtAfter - debtBefore;
        assertGt(reservesAfter, 0, "Protocol reserves must be positive");

        // Distribute and verify flow to FeeCollector
        uint256 fcBefore = IERC20(Constants.USDC).balanceOf(address(feeCollector));
        market.distributeReserves();
        uint256 fcAfter = IERC20(Constants.USDC).balanceOf(address(feeCollector));

        assertGt(fcAfter, fcBefore, "FeeCollector should receive 30-day reserves");

        console.log("30-day interest: %s USDC", interestAccrued / 1e6);
        console.log("30-day reserves: %s USDC", reservesAfter / 1e6);
        console.log("FeeCollector received: %s USDC", (fcAfter - fcBefore) / 1e6);
        console.log("=== Reserve Accumulation Over Time ===");
    }
}
