// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title ReserveDistribution
/// @notice E2E tests for Market.distributeReserves and FeeCollector distribution flows
contract ReserveDistribution is E2EBase {
    address public poolAddr;
    LendingPool public market;

    function setUp() public override {
        super.setUp();

        poolAddr = address(usdcPool);
        market = LendingPool(poolAddr);

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

        // The split is the whole subject of this test, so the two recipients have to be distinct
        // accounts. ForkTestBase wires both to `deployer`, under which every balance below is the
        // same balance read twice and the ratio is arithmetically forced to 50/50 whatever the
        // contract does.
        vm.startPrank(deployer);
        feeCollector.setTreasury(makeAddr("treasury"));
        feeCollector.setInsuranceFund(makeAddr("insurance"));
        vm.stopPrank();

        // Record treasury and insurance balances before distribution
        address treasuryAddr = feeCollector.treasury();
        address insuranceAddr = feeCollector.insuranceFund();
        assertTrue(treasuryAddr != insuranceAddr, "Recipients must differ or the split is untestable");
        uint256 treasuryBefore = IERC20(Constants.USDC).balanceOf(treasuryAddr);
        uint256 insuranceBefore = IERC20(Constants.USDC).balanceOf(insuranceAddr);

        // Distribute from FeeCollector (deployer is PoolAdmin)
        vm.prank(deployer);
        feeCollector.distribute(Constants.USDC);

        uint256 treasuryAfter = IERC20(Constants.USDC).balanceOf(treasuryAddr);
        uint256 insuranceAfter = IERC20(Constants.USDC).balanceOf(insuranceAddr);

        uint256 treasuryGain = treasuryAfter - treasuryBefore;
        uint256 insuranceGain = insuranceAfter - insuranceBefore;

        // Each leg separately: a sum is satisfied by either one alone, which is exactly the case
        // where the split is broken and one recipient is paid nothing.
        assertGt(treasuryGain, 0, "Treasury should receive fees");
        assertGt(insuranceGain, 0, "Insurance fund should receive fees");

        // The whole distribution is accounted for by the two recipients — nothing is stranded.
        assertEq(treasuryGain + insuranceGain, accFees, "Distribution must pay out the accumulated fees exactly");

        // Default insurance share is 10%, treasury 90%. Pinned against the configured parameter
        // rather than a hardcoded 1000, so the assertion follows the setting instead of drifting
        // from it, and holds for the boundary values the setter admits.
        uint256 expectedShareBps = feeCollector.insuranceFundShareBps();
        assertEq(insuranceGain, (accFees * expectedShareBps) / 10_000, "Insurance leg must equal the configured share");
        assertEq(treasuryGain, accFees - insuranceGain, "Treasury leg must be the remainder");

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
