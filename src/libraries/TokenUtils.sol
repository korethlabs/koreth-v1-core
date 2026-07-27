// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";

/// @title TokenUtils
/// @notice Safe helpers for ERC20 token interactions
library TokenUtils {
    /// @notice Get token decimals safely — reverts if token doesn't support decimals()
    /// @dev Some tokens (old USDT proxy, non-standard ERC20s) may not implement decimals()
    function safeDecimals(address token) internal view returns (uint8) {
        try IERC20(token).decimals() returns (uint8 dec) {
            require(dec <= 36, "INVALID_DECIMALS");
            return dec;
        } catch {
            revert("DECIMALS_NOT_SUPPORTED");
        }
    }
}
