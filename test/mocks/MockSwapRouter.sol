// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @notice Mock swap router with configurable exchange rates per token
contract MockSwapRouter is ISwapRouter {
    address public outputToken;
    bool public shouldRevert;

    // tokenIn → exchange rate (how many outputToken per 1e18 tokenIn)
    // e.g., WETH → 2000e18 means 1 WETH = 2000 USDC
    mapping(address => uint256) public exchangeRate;
    uint256 public defaultRate = 1e18; // 1:1 default

    constructor(address _outputToken) {
        outputToken = _outputToken;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /// @notice Set exchange rate for a token (outputToken per 1e18 of tokenIn)
    function setExchangeRate(address tokenIn, uint256 rate) external {
        exchangeRate[tokenIn] = rate;
    }

    function swap(
        address tokenIn,
        address, /* tokenOut */
        uint256 amountIn,
        uint256 amountOutMin
    )
        external
        override
        returns (uint256 amountOut)
    {
        require(!shouldRevert, "SWAP_FAILED");

        // Pull tokenIn from caller
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Apply exchange rate
        uint256 rate = exchangeRate[tokenIn];
        if (rate == 0) rate = defaultRate;
        amountOut = (amountIn * rate) / 1e18;

        require(amountOut >= amountOutMin, "SLIPPAGE");
        IERC20(outputToken).transfer(msg.sender, amountOut);
    }

    function exactInput(ExactInputParams calldata params) external payable override returns (uint256 amountOut) {
        require(!shouldRevert, "SWAP_FAILED");

        // Decode first token from path (first 20 bytes of packed encoding)
        require(params.path.length >= 20, "INVALID_PATH");
        address tokenIn = address(bytes20(params.path[:20]));

        // Pull tokenIn from caller
        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Apply exchange rate
        uint256 rate = exchangeRate[tokenIn];
        if (rate == 0) rate = defaultRate;
        amountOut = (params.amountIn * rate) / 1e18;

        require(amountOut >= params.amountOutMinimum, "SLIPPAGE");
        IERC20(outputToken).transfer(params.recipient, amountOut);
    }
}
