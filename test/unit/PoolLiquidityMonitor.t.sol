// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";
import {PoolLiquidityMonitor} from "../../src/oracle/PoolLiquidityMonitor.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {CurveAdapter} from "../../src/adapters/CurveAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TestPricing} from "../helpers/TestPricing.sol";

/// @notice Minimal stand-in for a Uniswap V3 pool: it holds its liquidity as plain token balances
///         spread across ticks, with no reserve figure, so the monitor only needs the token pair.
contract MockPool {
    address public token0;
    address public token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }
}

/// @notice A Uniswap V2 pair, reduced to the part that matters here: reserves tracked separately
///         from balances, and the two functions that move between them.
/// @dev Faithful to the real pair on the point the tests turn on. sync() and skim() are both
///      permissionless there and are here; skim() sends away balance - reserve, which UniswapV2Pair
///      computes with SafeMath and this computes in checked 0.8 arithmetic, so both revert on a pair
///      holding less than it claims. Reserves move only when this contract is told to move them,
///      which is what makes them the harder number to write.
contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function sync() external {
        reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
    }

    function skim(address to) external {
        IERC20(token0).transfer(to, IERC20(token0).balanceOf(address(this)) - reserve0);
        IERC20(token1).transfer(to, IERC20(token1).balanceOf(address(this)) - reserve1);
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
    MockV2Pair public pair;

    address public owner = makeAddr("owner");
    address public keeper = makeAddr("keeper");
    address public stranger = makeAddr("stranger");
    address public attacker = makeAddr("attacker");

    function setUp() public {
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));
        circuitBreaker = new CircuitBreaker(address(core));

        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        pool = new MockPool(address(weth), address(usdc));
        pair = new MockV2Pair(address(weth), address(usdc));

        vm.startPrank(owner);
        priceRegistry = TestPricing.wire(core, address(weth), 2000e18); // $2,000
        TestPricing.priceAsset(priceRegistry, address(usdc), 1e18); // $1
        monitor = new PoolLiquidityMonitor(address(core), address(circuitBreaker));
        aclManager.addKeeper(address(monitor));
        aclManager.addKeeper(keeper);

        // The real adapters, not mocks: the measure under test lives in them, and a mock would only
        // re-state the expected answer. Their factory and router addresses are never reached — the
        // holdings measure reads the pool itself — so any non-zero address satisfies the constructors.
        core.registerAdapter(
            ILPAdapter.LPType.UniswapV2,
            address(new UniswapV2Adapter(makeAddr("v2Factory"), makeAddr("v2Router"), address(core)))
        );
        core.registerAdapter(
            ILPAdapter.LPType.UniswapV3,
            address(new UniswapV3Adapter(makeAddr("nftManager"), makeAddr("v3Factory"), address(core)))
        );

        // The monitor measures a pool by what its AMM makes measurable, so it needs the pool listed
        // with the AMM it belongs to before it can judge one.
        core.whitelistLpPool(address(pool), ILPAdapter.LPType.UniswapV3);
        core.whitelistLpPool(address(pair), ILPAdapter.LPType.UniswapV2);
        vm.stopPrank();

        // $2M: 500 WETH at $2,000 plus 1,000,000 USDC at $1.
        weth.mint(address(pool), 500e18);
        usdc.mint(address(pool), 1_000_000e6);

        // The same $2M in the V2 pair, with reserves recorded to match — an untampered pair.
        weth.mint(address(pair), 500e18);
        usdc.mint(address(pair), 1_000_000e6);
        pair.sync();
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
        vm.prank(owner);
        core.whitelistLpPool(address(odd), ILPAdapter.LPType.UniswapV3);

        vm.expectRevert("NO_PRICE_FEED");
        monitor.poolTvlUsd(address(odd));
    }

    // ========== The floor ==========

    function test_checkPool_passesWhileLiquidityIsAmpleAndDoesNotPause() public {
        vm.prank(keeper);
        assertTrue(monitor.checkPool(address(pool)));

        assertFalse(circuitBreaker.poolPaused(address(pool)));
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

    // ========== No drop check ==========

    /// @dev The monitor is a floor, not a drop detector. A pool that lost 40% of its liquidity but
    ///      is still above the floor passes — deliberately. The removed drop-% check stored a single
    ///      previous reading as its baseline and overwrote it every call, so a drain in sub-threshold
    ///      steps reset the baseline each time and never tripped. It protected nothing
    ///      the rest of the system does not already cover: collateral is valued off Chainlink not the
    ///      pool's own price, and liquidation seizes underlying tokens without swapping through the
    ///      pool, so pool depth gates neither a position's value nor whether it can be realised.
    function test_checkPool_doesNotPauseOnASharpDropThatStaysAboveTheFloor() public {
        vm.prank(keeper);
        monitor.checkPool(address(pool)); // $2M

        // Down to $1.2M — a 40% drop, but still above the $1M floor.
        vm.prank(address(pool));
        usdc.transfer(stranger, 800_000e6);

        vm.warp(block.timestamp + 10 minutes);
        vm.prank(keeper);
        assertTrue(monitor.checkPool(address(pool)));

        assertFalse(circuitBreaker.poolPaused(address(pool)));
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

    // ========== What a V2 pair holds, vs what it says it holds ==========

    /// @dev A donation to a V2 pair raises its balances without raising its reserves, and the pair
    ///      hands the difference back to whoever asks for it. Counting it would let anyone move this
    ///      number for the price of a transfer they get refunded.
    function test_poolTvlUsd_ignoresADonationToAV2Pair() public {
        uint256 before = monitor.poolTvlUsd(address(pair));

        usdc.mint(attacker, 5_000_000e6);
        vm.prank(attacker);
        usdc.transfer(address(pair), 5_000_000e6);

        assertEq(monitor.poolTvlUsd(address(pair)), before, "a donation is not liquidity the pair owes anyone");
    }

    /// @dev The reason the cap is there. The floor is checked in the keeper's transaction, and an
    ///      attacker can put a transaction on either side of it: donate first, let checkPool read the
    ///      inflated balance, skim the donation back after. Two transactions, no capital at risk, and
    ///      a pair holding a fifth of the floor keeps taking deposits. Capping at reserves makes the
    ///      first transaction do nothing, so the sandwich has nothing to sandwich.
    function test_checkPool_cannotBeCarriedOverTheFloorByADonation() public {
        // The pair drains to $200k and its reserves are honest about it.
        vm.startPrank(address(pair));
        usdc.transfer(stranger, 900_000e6);
        weth.transfer(stranger, 450e18);
        vm.stopPrank();
        pair.sync();
        assertEq(monitor.poolTvlUsd(address(pair)), 200_000e18);

        // Front-run: donate enough to clear the $1M floor twice over.
        usdc.mint(attacker, 2_000_000e6);
        vm.prank(attacker);
        usdc.transfer(address(pair), 2_000_000e6);

        vm.prank(keeper);
        assertFalse(monitor.checkPool(address(pair)), "the donation is not the pair's liquidity");
        assertTrue(circuitBreaker.poolPaused(address(pair)));

        // Back-run: and the attacker takes it all back, which is why it was never a cost.
        vm.prank(attacker);
        pair.skim(attacker);
        assertEq(usdc.balanceOf(attacker), 2_000_000e6);
    }

    /// @dev The other direction, and the reason the cap is a minimum rather than a switch to
    ///      getReserves(). A pair that lost its tokens without anyone calling sync() still reports
    ///      the reserves it had before. Reading reserves alone would leave an empty pair clearing the
    ///      floor; the minimum takes the pessimistic side of each divergence, so the drain shows.
    function test_poolTvlUsd_seesADrainThatStaleReservesStillHide() public {
        vm.startPrank(address(pair));
        usdc.transfer(stranger, 900_000e6);
        weth.transfer(stranger, 450e18);
        vm.stopPrank();
        // No sync(): reserves still claim the full $2M.
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        assertEq(uint256(reserve0), 500e18);
        assertEq(uint256(reserve1), 1_000_000e6);

        assertEq(monitor.poolTvlUsd(address(pair)), 200_000e18, "the pair is judged on what it holds");

        vm.prank(keeper);
        assertFalse(monitor.checkPool(address(pair)));
    }

    /// @dev Syncing away the stale reserves does not restore the pair's ability to hide the drain —
    ///      it only makes both numbers agree on the emptied figure.
    function test_poolTvlUsd_unchangedByASyncAfterADrain() public {
        vm.startPrank(address(pair));
        usdc.transfer(stranger, 900_000e6);
        weth.transfer(stranger, 450e18);
        vm.stopPrank();

        uint256 beforeSync = monitor.poolTvlUsd(address(pair));
        pair.sync();

        assertEq(monitor.poolTvlUsd(address(pair)), beforeSync);
    }

    // ========== Measuring the right thing per AMM ==========

    /// @dev V3 has no reserves to cap against — liquidity sits as balances across ticks — so balances
    ///      remain the measure there, and a V3 pool is not skimmable the way a pair is.
    function test_poolTvlUsd_measuresV3PoolsByBalance() public {
        usdc.mint(address(pool), 500_000e6);
        assertEq(monitor.poolTvlUsd(address(pool)), 2_500_000e18);
    }

    /// @dev A pool whose adapter has not defined a measure for its AMM is not judged at all. The
    ///      alternative is falling back to balances, which is the reading this change exists to stop
    ///      relying on — an AMM nobody has looked at is the last place to assume it is safe. Curve's
    ///      adapter is a stub whose every method reverts, and the measure reverts with it rather than
    ///      being the one method a stub answers.
    function test_poolTvlUsd_revertsForAnAmmWhoseAdapterHasNoMeasure() public {
        MockPool curvePool = new MockPool(address(weth), address(usdc));
        vm.startPrank(owner);
        core.registerAdapter(
            ILPAdapter.LPType.Curve, address(new CurveAdapter(makeAddr("curveRegistry"), address(core)))
        );
        core.whitelistLpPool(address(curvePool), ILPAdapter.LPType.Curve);
        vm.stopPrank();

        vm.expectRevert("NOT_IMPLEMENTED");
        monitor.poolTvlUsd(address(curvePool));
    }

    /// @dev The AMM is declared by a pool admin at listing and nothing cross-checks it, so a
    ///      mislabelled pool has to fail closed rather than be measured by the wrong rules. A V3 pool
    ///      listed as V2 reaches UniswapV2Adapter, which asks it for reserves it does not keep, and
    ///      the read reverts instead of quietly measuring a pool by a figure that is not there.
    function test_poolTvlUsd_revertsForAPoolListedUnderTheWrongAmm() public {
        MockPool mislabelled = new MockPool(address(weth), address(usdc));
        weth.mint(address(mislabelled), 500e18);
        vm.prank(owner);
        core.whitelistLpPool(address(mislabelled), ILPAdapter.LPType.UniswapV2);

        vm.expectRevert();
        monitor.poolTvlUsd(address(mislabelled));
    }

    /// @dev And an AMM with no adapter at all fails at the lookup, before any pool is touched. Both
    ///      routes end the same way: nothing is measured, so nothing is pronounced healthy.
    function test_poolTvlUsd_revertsForAnAmmWithNoAdapterRegistered() public {
        MockPool aeroPool = new MockPool(address(weth), address(usdc));
        vm.prank(owner);
        core.whitelistLpPool(address(aeroPool), ILPAdapter.LPType.Aerodrome);

        vm.expectRevert("ADAPTER_NOT_FOUND");
        monitor.poolTvlUsd(address(aeroPool));
    }

    /// @dev And a pool nobody listed is not judged either, rather than being read as the zero enum
    ///      member and measured as a V2 pair.
    function test_poolTvlUsd_revertsForAnUnlistedPool() public {
        MockPool unlisted = new MockPool(address(weth), address(usdc));

        vm.expectRevert("LP_TYPE_UNKNOWN");
        monitor.poolTvlUsd(address(unlisted));
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
