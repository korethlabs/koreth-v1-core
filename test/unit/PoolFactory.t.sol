// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolFactory} from "../../src/markets/PoolFactory.sol";

/// @title PoolFactoryConstructor
/// @notice Verifies the PoolFactory constructor rejects zero addresses, so a factory can never be
///         deployed pointing at a null core or a null pool implementation.
contract PoolFactoryConstructor is Test {
    address internal constant CORE = address(0xC0FFEE);
    address internal constant IMPL = address(0xBEEF);

    function test_constructor_revertsOnZeroCore() public {
        vm.expectRevert("ZERO_ADDRESS");
        new PoolFactory(address(0), IMPL);
    }

    function test_constructor_revertsOnZeroImplementation() public {
        vm.expectRevert("ZERO_ADDRESS");
        new PoolFactory(CORE, address(0));
    }

    function test_constructor_storesAddresses() public {
        PoolFactory factory = new PoolFactory(CORE, IMPL);
        assertEq(address(factory.core()), CORE, "core stored");
        assertEq(factory.poolImplementation(), IMPL, "implementation stored");
    }
}
