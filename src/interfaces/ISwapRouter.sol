// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISwapRouter
/// @notice Interface for swapping tokens during liquidation
/// @dev Can be implemented as a wrapper around any DEX router (Uniswap, 1inch, etc.)
interface ISwapRouter {
    /// @notice Swap exact input amount of tokenIn for tokenOut
    /// @param tokenIn Token to sell
    /// @param tokenOut Token to buy
    /// @param amountIn Exact amount of tokenIn to sell
    /// @param amountOutMin Minimum acceptable amount of tokenOut
    /// @return amountOut Actual amount of tokenOut received
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    )
        external
        returns (uint256 amountOut);

    /// @notice Swap exact input along a multi-hop path
    /// @dev Matches Uniswap V3 SwapRouter.exactInput signature
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
