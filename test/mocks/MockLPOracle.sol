// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {ILPOracleHub} from "../../src/interfaces/ILPOracleHub.sol";

/// @notice Mock oracle for testing — returns configurable prices
contract MockLPOracle is ILPOracle {
    uint256 public mockPrice = 50_000e18; // Default $50,000
    bool public healthy = true;
    bool public shouldRevert; // Simulate a fail-closed oracle (e.g. stale Chainlink feed)

    function setPrice(uint256 _price) external {
        mockPrice = _price;
    }

    function setHealthy(bool _healthy) external {
        healthy = _healthy;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function getPrice(address, uint256, uint256) external view override returns (ILPOracleHub.PriceResult memory) {
        require(!shouldRevert, "ORACLE_FAIL_CLOSED");
        return ILPOracleHub.PriceResult({
            totalValue: mockPrice,
            principalValue: mockPrice,
            feeValue: 0,
            confidence: 10_000,
            timestamp: block.timestamp
        });
    }

    function getRawPrice(address, uint256, uint256) external view override returns (uint256) {
        return mockPrice;
    }

    function isHealthy() external view override returns (bool) {
        return healthy;
    }
}
