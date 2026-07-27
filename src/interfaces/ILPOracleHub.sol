// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "./ILPAdapter.sol";

/// @title ILPOracleHub
/// @notice Central oracle router that prices any supported LP position
interface ILPOracleHub {
    struct PriceResult {
        uint256 totalValue; // USD value (18 decimals)
        uint256 principalValue; // Value of underlying tokens
        uint256 feeValue; // Value of unclaimed fees
        uint256 confidence; // Oracle confidence (0-10000 bps)
        uint256 timestamp; // Price timestamp
    }

    /// @notice Get the price of an LP position
    /// @param lpToken Address of LP token or NFT manager
    /// @param tokenId NFT token ID (0 for ERC-20)
    /// @param amount Amount of LP tokens (0 for NFT)
    /// @param lpType Type of LP position
    /// @return result Full price result
    function getPrice(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        ILPAdapter.LPType lpType
    )
        external
        view
        returns (PriceResult memory result);

    /// @notice Get raw price (for display only)
    function getRawPrice(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        ILPAdapter.LPType lpType
    )
        external
        view
        returns (uint256 value);

    /// @notice Register a new oracle for an LP type
    function registerOracle(ILPAdapter.LPType lpType, address oracle) external;

    /// @notice Check if oracle is healthy (prices within bounds)
    function isOracleHealthy(ILPAdapter.LPType lpType) external view returns (bool);
}
