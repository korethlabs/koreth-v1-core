// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Mock PriceFeedRegistry for unit tests
/// @dev Returns configurable USD prices per token (18 decimals).
///      Uses Math.mulDiv to match production overflow safety.
contract MockPriceFeedRegistry {
    mapping(address => uint256) public prices; // token → USD price (18 dec)

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view returns (uint256) {
        uint256 price = prices[token];
        require(price > 0, "NO_PRICE_FEED");
        return price;
    }

    function getUsdValue(address token, uint256 amount, uint8 tokenDecimals) external view returns (uint256) {
        require(tokenDecimals <= 36, "INVALID_DECIMALS");
        uint256 price = prices[token];
        require(price > 0, "NO_PRICE_FEED");
        return Math.mulDiv(amount, price, 10 ** tokenDecimals);
    }
}
