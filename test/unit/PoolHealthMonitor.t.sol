// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";
import {PoolHealthMonitor} from "../../src/security/PoolHealthMonitor.sol";

/// @title PoolHealthMonitorTest
/// @notice Unit tests focused on the absolute min-TVL floor (A6)
contract PoolHealthMonitorTest is Test {
    ACLManager public aclManager;
    ProtocolCore public core;
    CircuitBreaker public cb;
    PoolHealthMonitor public monitor;

    address public owner = makeAddr("owner");
    address public pool = makeAddr("pool");

    function setUp() public {
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));
        cb = new CircuitBreaker(address(core));
        monitor = new PoolHealthMonitor(address(core), address(cb));

        // The monitor must be able to trip the breaker.
        vm.prank(owner);
        aclManager.addKeeper(address(monitor));
    }

    /// @notice A6: the absolute floor is enforced on the FIRST snapshot (no prior needed).
    function test_firstSnapshot_belowMinTvl_pauses() public {
        vm.prank(owner);
        monitor.setMinTvl(pool, 1000e18);

        // Very first call for this pool, already below the floor → must pause.
        vm.prank(owner);
        monitor.checkPoolHealth(pool, 500e18);

        assertTrue(cb.poolPaused(pool), "pool should be paused on first below-floor snapshot");
    }

    function test_firstSnapshot_aboveMinTvl_noPause() public {
        vm.prank(owner);
        monitor.setMinTvl(pool, 1000e18);

        vm.prank(owner);
        monitor.checkPoolHealth(pool, 2000e18);

        assertFalse(cb.poolPaused(pool), "healthy first snapshot should not pause");
    }

    function test_noMinTvl_firstSnapshot_noPause() public {
        // No floor configured → never pauses on the floor rule.
        vm.prank(owner);
        monitor.checkPoolHealth(pool, 1);

        assertFalse(cb.poolPaused(pool));
    }
}
