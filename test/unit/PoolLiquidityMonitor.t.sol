// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";
import {PoolLiquidityMonitor} from "../../src/oracle/PoolLiquidityMonitor.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TestPricing} from "../helpers/TestPricing.sol";

/// @notice Minimal stand-in for a Uniswap pair or pool: the monitor only needs the token pair, and
///         reads the liquidity from the tokens themselves.
contract MockPool {
    address public token0;
    address public token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }
}

/// @title PoolLiquidityMonitorTest
/// @notice The monitor that replaced PriceValidator.
/// @dev The point of the replacement is that the numbers are read, not reported. These tests never
///      hand the monitor a figure — they move real balances and let it find out — because the old
///      contract's whole problem was that its caller could tell it whatever kept it quiet.
contract PoolLiquidityMonitorTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    CircuitBreaker public circuitBreaker;
    PoolLiquidityMonitor public monitor;
    PriceFeedRegistry public priceRegistry;

    MockERC20 public weth;
    MockERC20 public usdc;
    MockPool public pool;

    address public owner = makeAddr("owner");
    address public keeper = makeAddr("keeper");
    address public stranger = makeAddr("stranger");

    function setUp() public {
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));
        circuitBreaker = new CircuitBreaker(address(core));

        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        pool = new MockPool(address(weth), address(usdc));

        vm.startPrank(owner);
        priceRegistry = TestPricing.wire(core, address(weth), 2000e18); // $2,000
        TestPricing.priceAsset(priceRegistry, address(usdc), 1e18); // $1
        monitor = new PoolLiquidityMonitor(address(core), address(circuitBreaker));
        aclManager.addKeeper(address(monitor));
        aclManager.addKeeper(keeper);
        vm.stopPrank();

        // $2M: 500 WETH at $2,000 plus 1,000,000 USDC at $1.
        weth.mint(address(pool), 500e18);
        usdc.mint(address(pool), 1_000_000e6);
    }

    // ========== Reading, not being told ==========

    function test_poolTvlUsd_isReadFromBalancesAndFeeds() public view {
        assertEq(monitor.poolTvlUsd(address(pool)), 2_000_000e18);
    }

    /// @dev Decimals are taken from each token, so a 6-dec side does not have to be pre-normalised
    ///      by whoever calls — which is exactly the kind of thing a caller used to get wrong.
    function test_poolTvlUsd_handlesMixedDecimals() public {
        usdc.mint(address(pool), 500_000e6);
        assertEq(monitor.poolTvlUsd(address(pool)), 2_500_000e18);
    }

    function test_poolTvlUsd_followsThePrice() public {
        vm.prank(owner);
        TestPricing.feedFor(priceRegistry, address(weth)).setAnswer(1000e18); // WETH halves

        assertEq(monitor.poolTvlUsd(address(pool)), 1_500_000e18);
    }

    /// @dev A pool the protocol cannot value is not one it can judge. Reporting it healthy would be
    ///      a guess, and guessing is what this whole line of work removes.
    function test_poolTvlUsd_revertsWhenATokenHasNoPrice() public {
        MockERC20 unpriced = new MockERC20("XYZ", "XYZ", 18);
        MockPool odd = new MockPool(address(weth), address(unpriced));

        vm.expectRevert("NO_PRICE_FEED");
        monitor.poolTvlUsd(address(odd));
    }

    // ========== The floor ==========

    function test_checkPool_passesWhileLiquidityIsAmpleAndDoesNotPause() public {
        vm.prank(keeper);
        assertTrue(monitor.checkPool(address(pool)));

        assertFalse(circuitBreaker.poolPaused(address(pool)));
        assertEq(monitor.lastKnownTvl(address(pool)), 2_000_000e18);
    }

    function test_checkPool_pausesWhenLiquidityFallsThroughTheFloor() public {
        // Drain to $200k, below the $1M floor.
        vm.prank(address(pool));
        usdc.transfer(stranger, 900_000e6);
        vm.prank(address(pool));
        weth.transfer(stranger, 450e18);

        vm.prank(keeper);
        assertFalse(monitor.checkPool(address(pool)));

        assertTrue(circuitBreaker.poolPaused(address(pool)), "a pool this thin must stop taking deposits");
    }

    // ========== The drop ==========

    /// @dev The case the floor alone misses: a pool still far above the minimum that lost a third
    ///      of its liquidity in an hour is behaving nothing like the one that was whitelisted.
    function test_checkPool_pausesOnASharpDropEvenWellAboveTheFloor() public {
        vm.prank(keeper);
        monitor.checkPool(address(pool)); // records $2M

        // Down to $1.2M — a 40% drop, but still above the $1M floor.
        vm.prank(address(pool));
        usdc.transfer(stranger, 800_000e6);

        vm.warp(block.timestamp + 10 minutes);
        vm.prank(keeper);
        assertFalse(monitor.checkPool(address(pool)));

        assertTrue(circuitBreaker.poolPaused(address(pool)));
    }

    /// @dev Comparing today's liquidity against a stale observation would read ordinary drift as an
    ///      emergency, so an old reading is not a baseline.
    function test_checkPool_ignoresADropMeasuredAgainstAnOldObservation() public {
        vm.prank(keeper);
        monitor.checkPool(address(pool));

        vm.prank(address(pool));
        usdc.transfer(stranger, 800_000e6);

        vm.warp(block.timestamp + 3 hours); // past the 1h window
        vm.prank(keeper);
        assertTrue(monitor.checkPool(address(pool)));

        assertFalse(circuitBreaker.poolPaused(address(pool)));
    }

    function test_checkPool_leavesAGentleDeclineAlone() public {
        vm.prank(keeper);
        monitor.checkPool(address(pool));

        vm.prank(address(pool));
        usdc.transfer(stranger, 200_000e6); // 10%, under the 30% threshold

        vm.warp(block.timestamp + 10 minutes);
        vm.prank(keeper);
        assertTrue(monitor.checkPool(address(pool)));

        assertFalse(circuitBreaker.poolPaused(address(pool)));
    }

    /// @dev An already-paused pool is still measured: the record is what tells you afterwards
    ///      whether it kept draining while paused.
    function test_checkPool_keepsRecordingWhileAlreadyPaused() public {
        vm.prank(owner);
        circuitBreaker.pausePool(address(pool), "manual");

        vm.prank(address(pool));
        usdc.transfer(stranger, 900_000e6);

        vm.prank(keeper);
        monitor.checkPool(address(pool));

        assertEq(monitor.lastKnownTvl(address(pool)), 1_100_000e18);
    }

    /// @dev The return value answers one question — did the liquidity pass — and not "is this pool
    ///      usable". A pool paused by hand still holds whatever it holds, and conflating the two
    ///      would make this answer depend on why someone else pressed a button.
    function test_checkPool_reportsOnLiquidityAloneNotOnThePauseState() public {
        vm.prank(owner);
        circuitBreaker.pausePool(address(pool), "manual");

        vm.prank(keeper);
        assertTrue(monitor.checkPool(address(pool)), "liquidity is untouched, so the check passes");
    }

    // ========== Access ==========

    function test_checkPool_onlyKeeper() public {
        vm.prank(stranger);
        vm.expectRevert("NOT_KEEPER");
        monitor.checkPool(address(pool));
    }

    function test_setMinPoolTvl_onlyRiskAdmin() public {
        vm.prank(stranger);
        vm.expectRevert("NOT_RISK_ADMIN");
        monitor.setMinPoolTvl(500_000e18);
    }

    function test_setMinPoolTvl_rejectsBelowTheAbsoluteFloor() public {
        vm.prank(owner);
        vm.expectRevert("BELOW_ABSOLUTE_MIN");
        monitor.setMinPoolTvl(1e18);
    }

    function test_constructor_rejectsABreakerFromAnotherCore() public {
        ProtocolCore otherCore = new ProtocolCore(owner, address(aclManager));
        CircuitBreaker foreign = new CircuitBreaker(address(otherCore));

        vm.expectRevert("CORE_MISMATCH");
        new PoolLiquidityMonitor(address(core), address(foreign));
    }
}
