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
///      The price-deviation check is gone rather than fixed, because on-chain it is either already
///      done or unnecessary. UniswapV3Oracle compares its own TWAP tick against Chainlink inside
///      getPrice() and reverts — per call, no keeper. UniswapV2Oracle needs no equivalent: fair
///      value there is 2*sqrt(k)*sqrt(p0*p1), where the pool contributes only k, which no swap can
///      move. V3 must trust the pool's tick to know a range position's composition, V2 must not
///      trust the pool's price at all, and each behaves accordingly.
///
///      What remains is the part nothing else covers, and it is now derived rather than reported:
///      the pool's own token balances, priced through the registry. A keeper can decide when to
///      look, which needs no trust, since the worst it can do is not look.
contract PoolLiquidityMonitor {
    ProtocolCore public immutable core;
    CircuitBreaker public immutable circuitBreaker;

    /// @notice Last observed USD liquidity per pool, and when it was observed.
    mapping(address => uint256) public lastKnownTvl;
    mapping(address => uint256) public lastCheckedAt;

    // --- Configurable Thresholds ---
    uint256 public minPoolTvl = 1_000_000e18; // $1M floor, 18-dec USD
    uint256 public tvlDropThresholdBps = 3000; // 30% drop within the window trips the breaker
    uint256 public tvlDropWindow = 3600; // only compare against an observation this recent

    // --- Absolute Bounds ---
    uint256 public constant MIN_TVL_FLOOR = 100_000e18;
    uint256 public constant MIN_TVL_DROP_BPS = 1000;
    uint256 public constant MAX_TVL_DROP_BPS = 8000;
    uint256 public constant MIN_TVL_DROP_WINDOW = 900; // 15 minutes
    uint256 public constant MAX_TVL_DROP_WINDOW = 86_400; // 24 hours

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

    function setTvlDropThreshold(uint256 _bps) external onlyRiskAdmin {
        require(_bps >= MIN_TVL_DROP_BPS && _bps <= MAX_TVL_DROP_BPS, "OUT_OF_BOUNDS");
        emit ParameterUpdated("tvlDropThresholdBps", tvlDropThresholdBps, _bps);
        tvlDropThresholdBps = _bps;
    }

    function setTvlDropWindow(uint256 _seconds) external onlyRiskAdmin {
        require(_seconds >= MIN_TVL_DROP_WINDOW && _seconds <= MAX_TVL_DROP_WINDOW, "OUT_OF_BOUNDS");
        emit ParameterUpdated("tvlDropWindow", tvlDropWindow, _seconds);
        tvlDropWindow = _seconds;
    }

    // --- Views ---

    /// @notice The pool's liquidity in 18-dec USD, read from the chain.
    /// @dev Token balances rather than V2 reserves or V3 liquidity, because that is the one measure
    ///      both pool types answer identically: a V3 pool holds its liquidity as balances across
    ///      ticks, and a V2 pair's balances match its reserves except for donations, which only
    ///      overstate — and overstating cannot trip a floor that is meant to catch a pool draining.
    ///
    ///      Reverts if either token has no price source. That is deliberate: a pool the protocol
    ///      cannot value is not one it can judge, and reporting "healthy" would be a guess.
    function poolTvlUsd(address pool) public view returns (uint256) {
        address token0 = IPoolTokens(pool).token0();
        address token1 = IPoolTokens(pool).token1();
        PriceFeedRegistry registry = PriceFeedRegistry(core.getPriceFeedRegistry());

        uint256 value0 = registry.getUsdValue(token0, IERC20(token0).balanceOf(pool), TokenUtils.safeDecimals(token0));
        uint256 value1 = registry.getUsdValue(token1, IERC20(token1).balanceOf(pool), TokenUtils.safeDecimals(token1));

        return value0 + value1;
    }

    // --- Core Logic ---

    /// @notice Measure a pool's liquidity and trip the breaker if it has fallen too far.
    /// @dev Keeper-triggered, but not keeper-informed: every figure compared here is read on-chain.
    /// @return healthy False when this call paused the pool, or found it already paused.
    function checkPool(address pool) external onlyKeeper returns (bool healthy) {
        require(pool != address(0), "ZERO_POOL");

        uint256 tvl = poolTvlUsd(pool);

        // A pool already paused still gets measured — the record is what tells you afterwards
        // whether it kept draining — but it is not paused twice.
        bool alreadyPaused = circuitBreaker.poolPaused(pool);

        healthy = true;

        if (tvl < minPoolTvl) {
            if (!alreadyPaused) circuitBreaker.pausePool(pool, "TVL_TOO_LOW");
            healthy = false;
        } else if (lastKnownTvl[pool] > 0 && lastCheckedAt[pool] > 0) {
            // Only against a recent observation: comparing today's liquidity to last month's would
            // read ordinary drift as an emergency.
            uint256 elapsed = block.timestamp - lastCheckedAt[pool];
            if (elapsed <= tvlDropWindow && tvl < lastKnownTvl[pool]) {
                uint256 dropBps = ((lastKnownTvl[pool] - tvl) * 10_000) / lastKnownTvl[pool];
                if (dropBps >= tvlDropThresholdBps) {
                    if (!alreadyPaused) circuitBreaker.pausePool(pool, "TVL_DROP");
                    healthy = false;
                }
            }
        }

        lastKnownTvl[pool] = tvl;
        lastCheckedAt[pool] = block.timestamp;

        emit PoolLiquidityChecked(pool, tvl, healthy);
        return healthy;
    }
}
