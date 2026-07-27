// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {PoolHealthMonitor} from "../../../src/security/PoolHealthMonitor.sol";

/// @title PoolHealthMonitorE2E
/// @notice E2E tests for PoolHealthMonitor auto-pause on TVL drops.
contract PoolHealthMonitorE2E is E2EBase {
    PoolHealthMonitor public monitor;
    address public keeper;

    function setUp() public override {
        super.setUp();

        keeper = makeAddr("keeper");

        // Deploy PoolHealthMonitor
        monitor = new PoolHealthMonitor(address(core), address(circuitBreaker));

        // Grant keeper role to both the keeper address AND the monitor
        // (monitor needs guardian/keeper to call circuitBreaker.pausePool)
        vm.startPrank(deployer);
        aclManager.addKeeper(keeper);
        aclManager.addKeeper(address(monitor));
        vm.stopPrank();
    }

    /// @notice Critical TVL drop (>50%) triggers pool pause
    function test_criticalTvlDrop_pausesPool() public {
        address pool = Constants.UNI_V3_WETH_USDC_3000;

        // First snapshot: 100M TVL
        vm.prank(keeper);
        monitor.checkPoolHealth(pool, 100_000_000e18);

        // 30 minutes later: TVL dropped to 40M (60% drop)
        _advanceTime(30 minutes);
        vm.prank(keeper);
        monitor.checkPoolHealth(pool, 40_000_000e18);

        // Pool should be paused
        assertTrue(circuitBreaker.poolPaused(pool), "Pool must be paused after critical TVL drop");
    }

    /// @notice Warning TVL drop (30-50%) emits alert but does NOT pause
    function test_warningTvlDrop_noPause() public {
        address pool = Constants.UNI_V3_WETH_USDC_3000;

        vm.prank(keeper);
        monitor.checkPoolHealth(pool, 100_000_000e18);

        // 30 minutes later: TVL dropped to 65M (35% drop — warning level)
        _advanceTime(30 minutes);
        vm.prank(keeper);
        monitor.checkPoolHealth(pool, 65_000_000e18);

        // Pool should NOT be paused (only warning)
        assertFalse(circuitBreaker.poolPaused(pool), "Pool must not be paused for warning-level drop");
    }

    /// @notice Slow TVL drop over >1 hour does NOT trigger pause
    function test_slowDrop_noPause() public {
        address pool = Constants.UNI_V3_WETH_USDC_3000;

        vm.prank(keeper);
        monitor.checkPoolHealth(pool, 100_000_000e18);

        // 2 hours later: 60% drop but slow — should not trigger
        _advanceTime(2 hours);
        vm.prank(keeper);
        monitor.checkPoolHealth(pool, 40_000_000e18);

        assertFalse(circuitBreaker.poolPaused(pool), "Slow drop must not trigger pause");
    }

    /// @notice Below minimum TVL triggers pause regardless of drop speed
    function test_belowMinTvl_pausesPool() public {
        address pool = Constants.UNI_V3_WETH_USDC_3000;

        // Set minimum TVL requirement
        vm.prank(deployer);
        monitor.setMinTvl(pool, 50_000_000e18);

        // First snapshot at healthy TVL
        vm.prank(keeper);
        monitor.checkPoolHealth(pool, 100_000_000e18);

        // Later: TVL below minimum
        _advanceTime(10 hours);
        vm.prank(keeper);
        monitor.checkPoolHealth(pool, 30_000_000e18);

        assertTrue(circuitBreaker.poolPaused(pool), "Pool must be paused when below min TVL");
    }

    /// @notice Pool pause blocks new deposits
    function test_poolPause_blocksDeposits() public {
        address pool = Constants.UNI_V3_WETH_USDC_3000;

        // Trigger critical TVL drop
        vm.prank(keeper);
        monitor.checkPoolHealth(pool, 100_000_000e18);
        _advanceTime(30 minutes);
        vm.prank(keeper);
        monitor.checkPoolHealth(pool, 40_000_000e18);

        // Pool is paused — try to deposit a new V3 position
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        vm.expectRevert("POOL_CIRCUIT_BREAKER");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);
        vm.stopPrank();
    }

    /// @notice Non-keeper cannot call checkPoolHealth
    function test_revert_nonKeeper() public {
        vm.prank(alice);
        vm.expectRevert("NOT_KEEPER");
        monitor.checkPoolHealth(Constants.UNI_V3_WETH_USDC_3000, 100_000_000e18);
    }
}
