// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LPMath
/// @notice Math utilities for LP position valuation
/// @dev Uses OpenZeppelin Math for sqrt and mulDiv (audited, battle-tested).
///      Prefer importing tested libraries over custom implementations.
///      Only protocol-specific formulas (fairLPValueV2, deviationBps) are custom.
///      All prices are 18-decimal USD. Reserves are in native token decimals.
library LPMath {
    /// @notice Calculate fair value of V2 LP token using sqrt(k) method
    /// @dev Formula: value = 2 * sqrt(reserve0 * reserve1) * sqrt(price0 * price1) * amount / (totalSupply * 1e18)
    ///      Uses mulDiv to prevent overflow on reserve0 * reserve1 and price0 * price1.
    /// @param reserve0 Reserve of token0 (18 decimals, caller must normalize)
    /// @param reserve1 Reserve of token1 (18 decimals, caller must normalize)
    /// @param totalSupply Total LP token supply
    /// @param price0 Chainlink price of token0 (18 decimals USD)
    /// @param price1 Chainlink price of token1 (18 decimals USD)
    /// @param amount Amount of LP tokens to price
    /// @return value Fair value in USD (18 decimals)
    function fairLPValueV2(
        uint256 reserve0,
        uint256 reserve1,
        uint256 totalSupply,
        uint256 price0,
        uint256 price1,
        uint256 amount
    )
        internal
        pure
        returns (uint256 value)
    {
        require(totalSupply > 0, "ZERO_TOTAL_SUPPLY");
        if (amount == 0) return 0;

        // sqrt(k) = sqrt(reserve0 * reserve1) — mulDiv for overflow-safe product
        uint256 sqrtK = Math.sqrt(Math.mulDiv(reserve0, reserve1, 1));

        // sqrt(price0 * price1) — mulDiv for overflow-safe product
        uint256 sqrtP = Math.sqrt(Math.mulDiv(price0, price1, 1));

        // value = 2 * sqrtK * sqrtP * amount / (totalSupply * 1e18)
        // Chain mulDiv to maximize precision while preventing overflow:
        // Step 1: sqrtK * sqrtP * amount / totalSupply (keep precision by multiplying first)
        uint256 scaled = Math.mulDiv(Math.mulDiv(sqrtK, sqrtP, 1), amount, totalSupply);
        // Step 2: scaled * 2 / 1e18
        value = Math.mulDiv(scaled, 2, 1e18);
    }

    /// @notice Calculate absolute deviation between two values in basis points
    /// @dev Anchored to the minimum of (a, b): deviation = |a - b| / min(a, b) * 10000
    ///      Symmetric: deviationBps(a, b) == deviationBps(b, a).
    ///      Using min as anchor catches manipulation in both directions — an inflated TWAP
    ///      produces the same deviation as a deflated TWAP for the same absolute difference.
    ///      Returns 10_000 (100%) if either value is 0.
    function deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 10_000;
        uint256 diff = a > b ? a - b : b - a;
        uint256 anchor = a < b ? a : b;
        return Math.mulDiv(diff, 10_000, anchor);
    }
}
