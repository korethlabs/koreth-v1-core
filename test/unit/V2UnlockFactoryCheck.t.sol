// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TestAdapters} from "../helpers/TestAdapters.sol";

/// @notice ERC20 that also answers factory() — models a Uniswap V2 pair for the authenticity check.
contract MockV2Pair is MockERC20 {
    address public factory;

    constructor(address _factory) MockERC20("LP", "LP", 18) {
        factory = _factory;
    }
}

/// @title V2UnlockFactoryCheck
/// @notice unlock() must re-validate the pair against our factory before moving tokens, matching the
///         authenticity guard its sibling liquidity functions already perform. Without it a caller
///         passing an unvalidated token would have the adapter transfer out an arbitrary asset.
contract V2UnlockFactoryCheckTest is Test {
    ACLManager internal acl;
    ProtocolCore internal core;
    UniswapV2Adapter internal adapter;

    address internal ourFactory = makeAddr("ourFactory");
    address internal router = makeAddr("router");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        acl = new ACLManager(address(this));
        core = new ProtocolCore(address(this), address(acl));
        // Let this test contract pass the adapter's onlyProtocol gate as a position manager.
        acl.addPositionManager(address(this));
        adapter = TestAdapters.uniswapV2(ourFactory, router, address(core));
    }

    /// @dev A pair reporting a factory other than ours must be refused before any transfer.
    function test_unlock_revertsForForeignFactory() public {
        MockV2Pair foreign = new MockV2Pair(makeAddr("otherFactory"));
        foreign.mint(address(adapter), 1e18);

        vm.expectRevert("NOT_OUR_FACTORY");
        adapter.unlock(address(foreign), 0, 1e18, recipient);
    }

    /// @dev An EOA-like lpToken (no code) must be refused as NOT_CONTRACT before the factory read.
    function test_unlock_revertsForNonContract() public {
        vm.expectRevert("NOT_CONTRACT");
        adapter.unlock(makeAddr("notAContract"), 0, 1e18, recipient);
    }

    /// @dev Positive control: a genuine pair from our factory still unlocks and pays the recipient.
    function test_unlock_succeedsForOurFactory() public {
        MockV2Pair ours = new MockV2Pair(ourFactory);
        ours.mint(address(adapter), 1e18);

        adapter.unlock(address(ours), 0, 1e18, recipient);

        assertEq(ours.balanceOf(recipient), 1e18, "recipient received the LP");
        assertEq(ours.balanceOf(address(adapter)), 0, "adapter emptied");
    }
}
