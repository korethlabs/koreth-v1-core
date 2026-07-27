// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {LPMath} from "../../src/libraries/LPMath.sol";

/// @title LendingInvariantTest
/// @notice Invariant tests for core lending math
/// @dev These run without fork — pure math invariants
contract LendingInvariantTest is Test {
    InterestRateModel public model;

    function setUp() public {
        model = new InterestRateModel(200, 600, 10_000, 8000);
    }

    /// @notice Borrow rate must always be > 0 and monotonically increasing
    function testFuzz_borrowRateMonotonic(uint256 u1, uint256 u2) public view {
        u1 = bound(u1, 0, 10_000);
        u2 = bound(u2, u1, 10_000);

        uint256 rate1 = model.getBorrowRate(u1);
        uint256 rate2 = model.getBorrowRate(u2);

        assertGe(rate2, rate1, "Borrow rate must be monotonically increasing");
        assertGt(rate1, 0, "Borrow rate must always be positive");
    }

    /// @notice Supply rate must always be <= borrow rate
    function testFuzz_supplyRateLessThanBorrow(uint256 utilization) public view {
        utilization = bound(utilization, 0, 10_000);

        uint256 borrowRate = model.getBorrowRate(utilization);
        uint256 supplyRate = model.getSupplyRate(utilization, 30); // 0.3% fee

        assertLe(supplyRate, borrowRate, "Supply rate must be <= borrow rate");
    }

    /// @notice Deviation of equal values must be 0
    function testFuzz_deviationZeroForEqual(uint256 a) public pure {
        a = bound(a, 1, type(uint128).max);
        uint256 deviation = LPMath.deviationBps(a, a);
        assertEq(deviation, 0, "Deviation of equal values must be 0");
    }

    /// @notice Deviation must be > 0 when values differ by >1%
    function testFuzz_deviationPositiveForDifferent(uint256 a, uint256 multiplier) public pure {
        a = bound(a, 100, type(uint64).max);
        multiplier = bound(multiplier, 10_100, 20_000); // 1.01x to 2x
        uint256 b = (a * multiplier) / 10_000;
        vm.assume(b != a);
        uint256 deviation = LPMath.deviationBps(a, b);
        assertGt(deviation, 0, "Deviation of meaningfully different values must be > 0");
    }

    /// @notice sqrt(x)^2 should approximate x (uses OZ Math.sqrt)
    function testFuzz_sqrtApprox(uint256 x) public pure {
        x = bound(x, 0, type(uint128).max);
        uint256 root = Math.sqrt(x);

        // root^2 <= x < (root+1)^2
        assertLe(root * root, x, "sqrt(x)^2 must be <= x");
        if (root < type(uint128).max) {
            assertLt(x, (root + 1) * (root + 1), "x must be < (sqrt(x)+1)^2");
        }
    }

    /// @notice Fair LP value V2 must be proportional to amount
    function testFuzz_v2ValueProportional(uint256 amount1, uint256 amount2) public pure {
        amount1 = bound(amount1, 1e18, 1_000_000e18);
        amount2 = bound(amount2, 1e18, 1_000_000e18);

        uint256 r0 = 1000e18;
        uint256 r1 = 2_000_000e18;
        uint256 supply = 10_000e18;
        uint256 p0 = 2000e18;
        uint256 p1 = 1e18;

        uint256 v1 = LPMath.fairLPValueV2(r0, r1, supply, p0, p1, amount1);
        uint256 v2 = LPMath.fairLPValueV2(r0, r1, supply, p0, p1, amount2);

        // Value should scale linearly with amount
        // v1/amount1 ≈ v2/amount2
        if (v1 > 0 && v2 > 0) {
            uint256 ratio1 = (v1 * 1e18) / amount1;
            uint256 ratio2 = (v2 * 1e18) / amount2;
            uint256 deviation = LPMath.deviationBps(ratio1, ratio2);
            assertLe(deviation, 10, "Value must scale linearly with amount");
        }
    }
}
