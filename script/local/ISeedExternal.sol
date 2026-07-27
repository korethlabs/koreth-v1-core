// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal WETH interface (wrap ETH) — not in production interfaces.
interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice Router swap surface (production IUniswapV2Router only exposes add/removeLiquidity).
interface IUniswapV2SwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        returns (uint256[] memory amounts);
}
