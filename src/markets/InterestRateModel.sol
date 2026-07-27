// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title InterestRateModel
/// @notice Kinked interest rate model — gentle slope below kink, steep above
/// @dev Incentivizes utilization near the kink point (target utilization).
///      All rates are per-second, scaled by 1e18.
///      Rounding: floor (truncation) — standard DeFi behavior.
contract InterestRateModel {
    uint256 public immutable baseRatePerSecond;
    uint256 public immutable slope1PerSecond;
    uint256 public immutable slope2PerSecond;
    uint256 public immutable kink; // Target utilization (bps, e.g., 8000 = 80%)

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365.25 days;
    /// @dev Safety cap: ~500% APR. Prevents absurd accrual from governance misconfiguration.
    uint256 public constant MAX_RATE_PER_SECOND = 158_548_959_919;

    constructor(uint256 baseRateAnnualBps, uint256 slope1AnnualBps, uint256 slope2AnnualBps, uint256 _kink) {
        require(_kink > 0 && _kink < BPS, "INVALID_KINK");
        require(slope2AnnualBps >= slope1AnnualBps, "SLOPE2_MUST_BE_GTE_SLOPE1");
        baseRatePerSecond = (baseRateAnnualBps * 1e18) / (BPS * SECONDS_PER_YEAR);
        slope1PerSecond = (slope1AnnualBps * 1e18) / (BPS * SECONDS_PER_YEAR);
        slope2PerSecond = (slope2AnnualBps * 1e18) / (BPS * SECONDS_PER_YEAR);
        kink = _kink;
    }

    /// @notice Calculate borrow rate based on utilization
    /// @param utilization Current utilization in basis points (0-10000)
    /// @return ratePerSecond The borrow rate per second (1e18 scale)
    function getBorrowRate(uint256 utilization) public view returns (uint256 ratePerSecond) {
        if (utilization <= kink) {
            ratePerSecond = baseRatePerSecond + (slope1PerSecond * utilization) / kink;
        } else {
            uint256 rateAtKink = baseRatePerSecond + slope1PerSecond;
            uint256 excessUtilization = utilization - kink;
            uint256 excessRange = BPS - kink;
            ratePerSecond = rateAtKink + (slope2PerSecond * excessUtilization) / excessRange;
        }
        if (ratePerSecond > MAX_RATE_PER_SECOND) ratePerSecond = MAX_RATE_PER_SECOND;
    }

    /// @notice Calculate supply rate (what lenders earn)
    /// @param utilization Current utilization in bps (0-10000)
    /// @param protocolFeeBps Protocol's cut of interest in bps (0-10000)
    /// @return ratePerSecond The supply rate per second (1e18 scale)
    function getSupplyRate(uint256 utilization, uint256 protocolFeeBps) external view returns (uint256 ratePerSecond) {
        uint256 borrowRate = getBorrowRate(utilization);
        uint256 protocolCut = (borrowRate * protocolFeeBps) / BPS;
        ratePerSecond = ((borrowRate - protocolCut) * utilization) / BPS;
    }

    /// @notice Get annual percentage rate for display
    function getBorrowRateAPR(uint256 utilization) external view returns (uint256 aprBps) {
        uint256 ratePerSecond = getBorrowRate(utilization);
        aprBps = (ratePerSecond * SECONDS_PER_YEAR * BPS) / 1e18;
    }
}
