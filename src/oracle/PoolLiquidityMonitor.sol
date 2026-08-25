// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";
import {CircuitBreaker} from "../security/CircuitBreaker.sol";
import {PriceFeedRegistry} from "./PriceFeedRegistry.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {IUniswapV2Pair} from "../interfaces/external/IUniswapV2.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

/// @notice Both Uniswap V2 pairs and V3 pools expose their token pair this way.
interface IPoolTokens {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @title PoolLiquidityMonitor
/// @notice Watches whether a whitelisted collateral pool still holds enough liquidity to be worth
///         accepting as backing, and trips the circuit breaker when it does not.
/// @dev Replaces PriceValidator, which took every number it checked from its caller. That made its
///      deviation check unfalsifiable — a keeper passing two consistent figures always passed — so
///      it was equivalent to the keeper calling circuitBreaker.pausePool() directly, wrapped in
///      something shaped like verification. Note it could never mis-price anything: valuation runs
///      only through PriceFeedRegistry, so the failure mode was a freeze that never happened.
///
///      The price-deviation check is gone rather than fixed, because there is no longer a
///      pool-reported price to check against. UniswapV3Oracle derives a range position's
///      composition from an implied price computed off Chainlink feeds, never from the pool's tick,
///      so there is no TWAP to reconcile with Chainlink (a reverting deviation guard on this path
///      would freeze liquidations during a crash). UniswapV2Oracle needs no equivalent
///      either: fair value per LP token is 2*sqrt(k)*sqrt(p0*p1)/totalSupply, where the pool
///      contributes only k and totalSupply, neither of which a swap can move. Neither oracle trusts
///      a pool-reported price, so there is nothing left to cross-validate.
///
///      What remains is the part nothing else covers, and it is now derived rather than reported:
///      how much of each token the pool actually holds, priced through the registry. A keeper can
///      decide when to look, which needs no trust, since the worst it can do is not look — and it
///      cannot choose what the look returns, which is the whole difference from what came before.
contract PoolLiquidityMonitor {
    ProtocolCore public immutable core;
    CircuitBreaker public immutable circuitBreaker;

    // --- Configurable Threshold ---
    uint256 public minPoolTvl = 1_000_000e18; // $1M floor, 18-dec USD

    // --- Absolute Bound ---
    uint256 public constant MIN_TVL_FLOOR = 100_000e18;

    event PoolLiquidityChecked(address indexed pool, uint256 tvlUsd, bool healthy);
    event ParameterUpdated(string name, uint256 oldValue, uint256 newValue);

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyRiskAdmin() {
        ACLManager acl = _acl();
        require(acl.isRiskAdmin(msg.sender) || acl.isPoolAdmin(msg.sender), "NOT_RISK_ADMIN");
        _;
    }

    modifier onlyKeeper() {
        ACLManager acl = _acl();
        require(acl.isKeeper(msg.sender) || acl.isPoolAdmin(msg.sender), "NOT_KEEPER");
        _;
    }

    constructor(address _core, address _circuitBreaker) {
        require(_core != address(0) && _circuitBreaker != address(0), "ZERO_ADDRESS");
        require(_core.code.length > 0 && _circuitBreaker.code.length > 0, "NOT_CONTRACT");
        core = ProtocolCore(_core);
        circuitBreaker = CircuitBreaker(_circuitBreaker);
        require(address(circuitBreaker.core()) == _core, "CORE_MISMATCH");
    }

    // --- Admin Setters ---

    function setMinPoolTvl(uint256 _minTvl) external onlyRiskAdmin {
        require(_minTvl >= MIN_TVL_FLOOR, "BELOW_ABSOLUTE_MIN");
        emit ParameterUpdated("minPoolTvl", minPoolTvl, _minTvl);
        minPoolTvl = _minTvl;
    }

    // --- Views ---

    /// @notice The pool's liquidity in 18-dec USD, read from the chain.
    /// @dev Reverts rather than degrading whenever it cannot arrive at a number it trusts: no price
    ///      feed (NO_PRICE_FEED), a stale or out-of-bounds answer, a token whose decimals() cannot
    ///      be read, an unset registry, or a pool whose AMM this contract has no measure for. That
    ///      is deliberate and applies to all of them equally — a pool the protocol cannot value is
    ///      not one it can judge, and every one of these cases would otherwise have to be answered
    ///      with a guess. checkPool propagates the revert, so a pool in this state is neither paused
    ///      nor pronounced healthy; it goes unjudged until the missing piece is fixed.
    function poolTvlUsd(address pool) public view returns (uint256) {
        address token0 = IPoolTokens(pool).token0();
        address token1 = IPoolTokens(pool).token1();
        (uint256 held0, uint256 held1) = _heldAmounts(pool, token0, token1);
        PriceFeedRegistry registry = PriceFeedRegistry(core.getPriceFeedRegistry());

        uint256 value0 = registry.getUsdValue(token0, held0, TokenUtils.safeDecimals(token0));
        uint256 value1 = registry.getUsdValue(token1, held1, TokenUtils.safeDecimals(token1));

        return value0 + value1;
    }

    /// @notice How much of each token a pool holds, for the purpose of judging whether it is deep
    ///         enough to back collateral.
    /// @dev The naive measure is balanceOf, and for a V3 pool it is the right one: liquidity sits as
    ///      balances spread across ticks and there is no reserve figure to compare against.
    ///
    ///      On a V2 pair it is not, because balanceOf is writable by anyone for the price of a
    ///      transfer and the write is refundable. A pair tracks reserves separately from balances
    ///      and hands the difference to whoever asks: transfer tokens in, and skim() takes them
    ///      back out. So a pool below minPoolTvl can be carried over it by sandwiching the keeper's
    ///      checkPool — donate, let the check read the inflated balance, skim afterwards — at a cost
    ///      of two transactions and no capital. Reserves are not writable that way: only mint, burn
    ///      and swap move them, and each leaves the pool actually holding what it claims.
    ///
    ///      Hence min(balance, reserve) per token, which is neither figure alone. Reserves alone
    ///      would reintroduce what balanceOf was chosen to see past: a pair drained directly holds
    ///      stale reserves above what it has, and would keep clearing the floor while empty. The
    ///      minimum takes the pessimistic side of each divergence — a donation cannot lift the
    ///      figure above reserves, a drain cannot hide behind them — and the two agree on a pair
    ///      nobody is manipulating, which is the normal case and is unaffected.
    ///
    ///      Capped per token rather than on the total, so that donating one side cannot offset a
    ///      shortfall on the other.
    ///
    ///      An AMM with no case here reverts. That is the fail-closed default and the point of
    ///      routing through the declared type instead of probing: whoever integrates the next AMM
    ///      has to state how its depth is measured, rather than inheriting whichever branch its
    ///      interface happens to fall into. Two sit there today. Curve, which already did — it
    ///      exposes neither token0() nor token1(), so poolTvlUsd never reached this far for one. And
    ///      Aerodrome, whose getReserves() returns uint256 where a Uniswap V2 pair returns uint112:
    ///      a different ABI, not a different label, so adding it to the branch below would be
    ///      decoding one pool's numbers with another pool's layout. Neither is deployed.
    function _heldAmounts(
        address pool,
        address token0,
        address token1
    )
        internal
        view
        returns (uint256 held0, uint256 held1)
    {
        ILPAdapter.LPType lpType = core.getLpPoolType(pool);

        held0 = IERC20(token0).balanceOf(pool);
        held1 = IERC20(token1).balanceOf(pool);

        if (lpType == ILPAdapter.LPType.UniswapV2 || lpType == ILPAdapter.LPType.PancakeSwapV2) {
            (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pool).getReserves();
            return (_min(held0, reserve0), _min(held1, reserve1));
        }

        if (lpType == ILPAdapter.LPType.UniswapV3 || lpType == ILPAdapter.LPType.PancakeSwapV3) {
            return (held0, held1);
        }

        revert("LP_TYPE_NOT_MEASURABLE");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // --- Core Logic ---

    /// @notice Measure a pool's liquidity and trip the breaker if it has fallen through the floor.
    /// @dev Keeper-triggered, but not keeper-informed: the figure compared here is read on-chain.
    ///
    ///      An absolute floor, and nothing more. An earlier design also paused on a sharp *drop* vs a
    ///      recent observation, but that comparison stored the previous reading as its baseline and
    ///      overwrote it every call, so a drain in sub-threshold steps reset the baseline each time
    ///      and never tripped. It was dropped rather than repaired with a
    ///      windowed high-water-mark, because the drop check protected nothing the rest of the system
    ///      does not already cover: collateral is valued off Chainlink, never the pool's own price
    ///      (see UniswapV3Oracle / UniswapV2Oracle), so a drained pool cannot inflate a position's
    ///      value; and liquidation seizes the LP's underlying tokens and hands them over WITHOUT
    ///      swapping through the pool (LiquidationEngine, "NO SWAP"), so pool depth does not gate
    ///      whether collateral can be realised. Slow-drain throttling that the drop check aimed at is
    ///      handled where the protocol actually controls the flow — RiskManager's borrow caps and
    ///      daily borrow-increase limit — not by polling an external pool it cannot intercept.
    /// @return healthy Whether the liquidity this call measured cleared the floor — and only that.
    ///         A pool paused earlier for an unrelated reason still reads healthy while its liquidity
    ///         holds up. Callers who want the breaker's state should read the breaker, which is the
    ///         one place that knows why a pool is paused.
    function checkPool(address pool) external onlyKeeper returns (bool healthy) {
        require(pool != address(0), "ZERO_POOL");

        uint256 tvl = poolTvlUsd(pool);
        healthy = tvl >= minPoolTvl;

        // Don't pause a pool already paused (for any reason) a second time; still report on liquidity.
        if (!healthy && !circuitBreaker.poolPaused(pool)) {
            circuitBreaker.pausePool(pool, "TVL_TOO_LOW");
        }

        emit PoolLiquidityChecked(pool, tvl, healthy);
        return healthy;
    }
}
