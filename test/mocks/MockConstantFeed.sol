// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MockConstantFeed
/// @notice A Chainlink-shaped feed that always reports the same price, freshly.
/// @dev Reports 18 decimals, so the answer is the 18-dec USD price the registry works in.
///
///      `updatedAt` is `block.timestamp` at read time rather than a value fixed at construction:
///      suites routinely warp days ahead to accrue interest, and a frozen timestamp would trip
///      STALE_PRICE and fail them for a reason unrelated to what they test.
///
///      Deliberately a feed and not a shortcut inside the registry. A test asset is priced through
///      the same path production uses — sequencer check, staleness, sanity bounds and decimal
///      normalisation all still apply — instead of past it.
contract MockConstantFeed {
    uint8 public constant decimals = 18;
    int256 public answer;

    constructor(int256 _answer) {
        require(_answer > 0, "NON_POSITIVE_ANSWER");
        answer = _answer;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}
