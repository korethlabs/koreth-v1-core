// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {TokenUtils} from "../../src/libraries/TokenUtils.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title TokenUtilsTest
/// @notice Tests for TokenUtils.safeDecimals library
contract TokenUtilsTest is Test {
    function test_safeDecimals_normalToken() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);
        assertEq(TokenUtils.safeDecimals(address(token)), 6);
    }

    function test_safeDecimals_18decimals() public {
        MockERC20 token = new MockERC20("WETH", "WETH", 18);
        assertEq(TokenUtils.safeDecimals(address(token)), 18);
    }

    function test_safeDecimals_revertsOnNoDecimals() public {
        address noDecimalsToken = address(new NoDecimalsToken());
        SafeDecimalsWrapper wrapper = new SafeDecimalsWrapper();
        vm.expectRevert("DECIMALS_NOT_SUPPORTED");
        wrapper.callSafeDecimals(noDecimalsToken);
    }
}

/// @notice Wrapper to make TokenUtils.safeDecimals callable externally (for vm.expectRevert)
contract SafeDecimalsWrapper {
    function callSafeDecimals(address token) external view returns (uint8) {
        return TokenUtils.safeDecimals(token);
    }
}

/// @notice Token without decimals() for testing
contract NoDecimalsToken {
    string public name = "NoDecimals";

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}
