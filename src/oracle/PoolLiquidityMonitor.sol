// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";
import {CircuitBreaker} from "../security/CircuitBreaker.sol";
import {PriceFeedRegistry} from "./PriceFeedRegistry.sol";
import {IERC20} from "../interfaces/IERC20.sol";
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
///      so there is no TWAP to reconcile with Chainlink (audit finding H-1: a reverting deviation
///      guard on this path froze liquidations during a crash). UniswapV2Oracle needs no equivalent
///      either: fair value per LP token is 2*sqrt(k)*sqrt(p0*p1)/totalSupply, where the pool
///      contributes only k and totalSupply, neither of which a swap can move. Neither oracle trusts
///      a pool-reported price, so there is nothing left to cross-validate.
///
///      What remains is the part nothing else covers, and it is now derived rather than reported:
///      the pool's own token balances, priced through the registry. A keeper can decide when to
///      look, which needs no trust, since the worst it can do is not look.
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
    /// @dev Token balances rather than V2 reserves or V3 liquidity, because that is the one measure
    ///      both pool types answer identically: a V3 pool holds its liquidity as balances across
    ///      ticks, and a V2 pair's balances match its reserves except for donations, which only
    ///      overstate — and overstating cannot trip a floor that is meant to catch a pool draining.
    ///
    ///      Reverts rather than degrading whenever it cannot arrive at a number it trusts: no price
    ///      feed (NO_PRICE_FEED), a stale or out-of-bounds answer, a token whose decimals() cannot
    ///      be read, or an unset registry. That is deliberate and applies to all of them equally —
    ///      a pool the protocol cannot value is not one it can judge, and every one of these cases
    ///      would otherwise have to be answered with a guess. checkPool propagates the revert, so a
    ///      pool in this state is neither paused nor pronounced healthy; it goes unjudged until the
    ///      missing piece is fixed.
    function poolTvlUsd(address pool) public view returns (uint256) {
        address token0 = IPoolTokens(pool).token0();
        address token1 = IPoolTokens(pool).token1();
        PriceFeedRegistry registry = PriceFeedRegistry(core.getPriceFeedRegistry());

        uint256 value0 = registry.getUsdValue(token0, IERC20(token0).balanceOf(pool), TokenUtils.safeDecimals(token0));
        uint256 value1 = registry.getUsdValue(token1, IERC20(token1).balanceOf(pool), TokenUtils.safeDecimals(token1));

        return value0 + value1;
    }

    // --- Core Logic ---

    /// @notice Measure a pool's liquidity and trip the breaker if it has fallen through the floor.
    /// @dev Keeper-triggered, but not keeper-informed: the figure compared here is read on-chain.
    ///
    ///      An absolute floor, and nothing more. An earlier design also paused on a sharp *drop* vs a
    ///      recent observation, but that comparison stored the previous reading as its baseline and
    ///      overwrote it every call, so a drain in sub-threshold steps reset the baseline each time
    ///      and never tripped (audit finding Oracle M-1). It was dropped rather than repaired with a
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
