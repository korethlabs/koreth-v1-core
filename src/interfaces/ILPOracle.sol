// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPOracleHub} from "./ILPOracleHub.sol";

/// @title ILPOracle
/// @notice Interface that each type-specific oracle must implement
/// @dev UniswapV3Oracle, UniswapV2Oracle, CurveOracle, etc. all implement this
interface ILPOracle {
    /// @notice Get the price of an LP position
    /// @param lpToken LP token or NFT manager address
    /// @param tokenId NFT token ID (0 for ERC-20)
    /// @param amount LP token amount (0 for NFT)
    /// @return result Full price result
    function getPrice(
        address lpToken,
        uint256 tokenId,
        uint256 amount
    )
        external
        view
        returns (ILPOracleHub.PriceResult memory result);

    /// @notice Get raw price
    function getRawPrice(address lpToken, uint256 tokenId, uint256 amount) external view returns (uint256 value);

    /// @notice Check if the oracle is returning fresh, valid data
    function isHealthy() external view returns (bool);
}
