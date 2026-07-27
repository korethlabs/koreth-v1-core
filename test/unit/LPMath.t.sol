// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LPMath} from "../../src/libraries/LPMath.sol";

/// @dev Wrapper to make internal LPMath functions callable externally (for vm.expectRevert)
contract LPMathWrapper {
    function fairLPValueV2(
        uint256 r0,
        uint256 r1,
        uint256 ts,
        uint256 p0,
        uint256 p1,
        uint256 amt
    )
        external
        pure
        returns (uint256)
    {
        return LPMath.fairLPValueV2(r0, r1, ts, p0, p1, amt);
    }
}

contract LPMathTest is Test {
    using LPMath for uint256;

    LPMathWrapper public wrapper;

    function setUp() public {
        wrapper = new LPMathWrapper();
    }

    function test_sqrt_usesOZ() public pure {
        // LPMath uses OZ Math.sqrt internally — verify consistency
        assertEq(Math.sqrt(0), 0);
        assertEq(Math.sqrt(1), 1);
        assertEq(Math.sqrt(4), 2);
        assertEq(Math.sqrt(9), 3);
        assertEq(Math.sqrt(100), 10);
        assertEq(Math.sqrt(1e18), 1e9);
        assertEq(Math.sqrt(2), 1);
        assertEq(Math.sqrt(8), 2);
    }

    function test_deviationBps() public pure {
        // Same values → 0 deviation
        assertEq(LPMath.deviationBps(100, 100), 0);

        // Symmetric: anchored to min(a, b)
        // deviationBps(100, 95) = 5 * 10000 / 95 = 526
        assertEq(LPMath.deviationBps(100, 95), 526);
        // Symmetric: deviationBps(95, 100) == deviationBps(100, 95)
        assertEq(LPMath.deviationBps(95, 100), 526);

        // 10% deviation: 10 * 10000 / 90 = 1111
        assertEq(LPMath.deviationBps(100, 90), 1111);
    }

    function test_fairLPValueV2() public pure {
        // Pool: 100 ETH / 200,000 USDC
        // ETH price: $2,000, USDC price: $1
        // LP supply: 1000 tokens
        // Pricing 10 tokens
        uint256 value = LPMath.fairLPValueV2(
            100e18, // reserve0 (ETH)
            200_000e18, // reserve1 (USDC)
            1000e18, // totalSupply
            2000e18, // price0 (ETH = $2000)
            1e18, // price1 (USDC = $1)
            10e18 // amount (10 LP tokens)
        );

        // Each LP token should be worth ~$400 (200K + 200K = 400K / 1000)
        // 10 LP tokens = ~$4000
        // With sqrt method the value should be close
        assertGt(value, 3500e18);
        assertLt(value, 4500e18);
    }

    function test_fairLPValueV2_revertsZeroTotalSupply() public {
        vm.expectRevert("ZERO_TOTAL_SUPPLY");
        wrapper.fairLPValueV2(1000e18, 1000e6, 0, 2000e18, 1e18, 100e18);
    }
}
