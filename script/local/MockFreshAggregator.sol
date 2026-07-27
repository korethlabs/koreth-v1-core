// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MockFreshAggregator
/// @notice Chainlink AggregatorV3 mock that always reports a FIXED answer with a LIVE-fresh
///         timestamp. Used ONLY on the local anvil fork: the forked real feeds are frozen in time,
///         so as anvil's block.timestamp drifts forward (real wall-clock) they eventually trip the
///         oracle's staleness check. This mock's updatedAt == block.timestamp, so it never goes
///         stale. The fixed answer is captured at deploy from the real feed, so on a static fork it
///         stays within the LP oracles' cross-validation band against the pool price.
contract MockFreshAggregator {
    uint8 public immutable decimals;
    int256 public immutable answer;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 ans, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }

    function latestAnswer() external view returns (int256) {
        return answer;
    }
}
