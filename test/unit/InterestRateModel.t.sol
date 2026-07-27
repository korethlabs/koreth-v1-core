// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";

contract InterestRateModelTest is Test {
    InterestRateModel public model;

    // Volatile market params: 2% base, 6% slope1, 100% slope2, 80% kink
    function setUp() public {
        model = new InterestRateModel(200, 600, 10_000, 8000);
    }

    function test_zeroUtilization() public view {
        uint256 apr = model.getBorrowRateAPR(0);
        // At 0% utilization: just base rate = 2%
        assertApproxEqAbs(apr, 200, 5); // ~2% APR (±0.05% tolerance)
    }

    function test_kinkUtilization() public view {
        uint256 apr = model.getBorrowRateAPR(8000);
        // At 80% (kink): base + slope1 = 2% + 6% = 8%
        assertApproxEqAbs(apr, 800, 5);
    }

    function test_halfUtilization() public view {
        uint256 apr = model.getBorrowRateAPR(4000);
        // At 40%: base + slope1 * (40/80) = 2% + 3% = 5%
        assertApproxEqAbs(apr, 500, 5);
    }

    function test_fullUtilization() public view {
        uint256 apr = model.getBorrowRateAPR(10_000);
        // At 100%: base + slope1 + slope2 = 2% + 6% + 100% = 108%
        assertApproxEqAbs(apr, 10_800, 10);
    }

    function test_supplyRateLowerThanBorrow() public view {
        uint256 borrowRate = model.getBorrowRate(5000);
        uint256 supplyRate = model.getSupplyRate(5000, 30); // 0.3% protocol fee
        assertLt(supplyRate, borrowRate);
    }

    function test_rateIncreasesWithUtilization() public view {
        uint256 rate20 = model.getBorrowRate(2000);
        uint256 rate50 = model.getBorrowRate(5000);
        uint256 rate80 = model.getBorrowRate(8000);
        uint256 rate90 = model.getBorrowRate(9000);

        assertLt(rate20, rate50);
        assertLt(rate50, rate80);
        assertLt(rate80, rate90);
    }

    function test_steepSlopeAboveKink() public view {
        // Rate increase from 70% → 80% (below kink) should be small
        uint256 rate70 = model.getBorrowRate(7000);
        uint256 rate80 = model.getBorrowRate(8000);
        uint256 belowKinkIncrease = rate80 - rate70;

        // Rate increase from 80% → 90% (above kink) should be much larger
        uint256 rate90 = model.getBorrowRate(9000);
        uint256 aboveKinkIncrease = rate90 - rate80;

        assertGt(aboveKinkIncrease, belowKinkIncrease * 5);
    }

    function testFuzz_rateAlwaysPositive(uint256 utilization) public view {
        utilization = bound(utilization, 0, 10_000);
        uint256 rate = model.getBorrowRate(utilization);
        assertGt(rate, 0);
    }
}
