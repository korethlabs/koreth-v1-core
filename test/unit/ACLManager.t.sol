// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";

/// @title ACLManagerTest
/// @notice Tests for ACLManager add/remove functions and zero-address guards
contract ACLManagerTest is Test {
    ACLManager public acl;
    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");

    function setUp() public {
        acl = new ACLManager(admin);
    }

    // ========== Contract Role Management ==========

    function test_addLendingEngine_success() public {
        vm.prank(admin);
        acl.addLendingEngine(alice);
        assertTrue(acl.isLendingEngine(alice));
    }

    function test_addLendingEngine_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("ZERO_ADDRESS");
        acl.addLendingEngine(address(0));
    }

    function test_addLendingEngine_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        acl.addLendingEngine(alice);
    }

    function test_removeLendingEngine_success() public {
        vm.prank(admin);
        acl.addLendingEngine(alice);
        assertTrue(acl.isLendingEngine(alice));

        vm.prank(admin);
        acl.removeLendingEngine(alice);
        assertFalse(acl.isLendingEngine(alice));
    }

    function test_removeLendingEngine_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("ZERO_ADDRESS");
        acl.removeLendingEngine(address(0));
    }

    function test_addLiquidationEngine_success() public {
        vm.prank(admin);
        acl.addLiquidationEngine(alice);
        assertTrue(acl.isLiquidationEngine(alice));
    }

    function test_removeLiquidationEngine_success() public {
        vm.prank(admin);
        acl.addLiquidationEngine(alice);
        vm.prank(admin);
        acl.removeLiquidationEngine(alice);
        assertFalse(acl.isLiquidationEngine(alice));
    }

    function test_addPositionManager_success() public {
        vm.prank(admin);
        acl.addPositionManager(alice);
        assertTrue(acl.isPositionManager(alice));
    }

    function test_removePositionManager_success() public {
        vm.prank(admin);
        acl.addPositionManager(alice);
        vm.prank(admin);
        acl.removePositionManager(alice);
        assertFalse(acl.isPositionManager(alice));
    }

    function test_addKeeper_success() public {
        vm.prank(admin);
        acl.addKeeper(alice);
        assertTrue(acl.isKeeper(alice));
    }

    function test_removeKeeper_success() public {
        vm.prank(admin);
        acl.addKeeper(alice);
        vm.prank(admin);
        acl.removeKeeper(alice);
        assertFalse(acl.isKeeper(alice));
    }

    // ========== Admin Role Zero-Address Guards ==========

    function test_removePoolAdmin_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("ZERO_ADDRESS");
        acl.removePoolAdmin(address(0));
    }

    function test_removeEmergencyAdmin_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("ZERO_ADDRESS");
        acl.removeEmergencyAdmin(address(0));
    }

    function test_removeRiskAdmin_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("ZERO_ADDRESS");
        acl.removeRiskAdmin(address(0));
    }

    // ========== Anti-Bricking ==========

    function test_cannotRemoveLastAdmin() public {
        bytes32 adminRole = acl.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        vm.expectRevert("CANNOT_REMOVE_LAST_ADMIN");
        acl.revokeRole(adminRole, admin);
        vm.stopPrank();
    }

    function test_cannotRenounceAdmin() public {
        bytes32 adminRole = acl.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        vm.expectRevert("CANNOT_RENOUNCE_ADMIN");
        acl.renounceRole(adminRole, admin);
        vm.stopPrank();
    }
}
