// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";
import {CircuitBreaker} from "../security/CircuitBreaker.sol";
import {LPMath} from "../libraries/LPMath.sol";

/// @title PriceValidator
/// @notice Cross-validates oracle prices and triggers circuit breakers
/// @dev Implements defense layers against oracle manipulation.
///      Triggers CircuitBreaker.pausePool() — unified pause system with PositionManager.
///      All thresholds are configurable by RISK_ADMIN.
///
///      ENFORCEMENT MODEL — this is a KEEPER-DRIVEN tool, NOT a per-transaction gate:
///        - validatePrice() is `onlyKeeper` and is called off-chain by monitoring bots (same trust
///          model as Aave's Chaos Labs risk bots), not inside the deposit/borrow/liquidation path.
///        - Its ENFORCED effect is `circuitBreaker.pausePool()` (deviation / low-TVL / TVL-drop),
///          which IS consumed on-chain — a paused pool blocks deposits & borrows in PositionManager.
///        - The returned `adjustedRiskBps` (volatility/staleness risk premiums) is ADVISORY: it is
///          surfaced for off-chain keeper decision-making and is NOT applied as an on-chain haircut.
///          On-chain collateral safety comes from the static LTV / liquidation-threshold gap plus
///          the per-call staleness/sequencer/deviation checks in PriceFeedRegistry & the LP oracles.
contract PriceValidator {
    ProtocolCore public immutable core;
    CircuitBreaker public immutable circuitBreaker;

    mapping(address => uint256) public lastKnownTvl;
    mapping(address => uint256) public lastPriceTimestamp;

    // --- Configurable Thresholds ---
    uint256 public maxPriceDeviationBps = 300; // 3% TWAP vs Chainlink
    uint256 public maxVolatilityBps = 1000; // 10% in 5 minutes
    uint256 public minPoolTvl = 1_000_000e18; // $1M minimum
    uint256 public stalePriceThreshold = 3600; // 1 hour
    uint256 public tvlDropThresholdBps = 3000; // 30% TVL drop triggers pause
    uint256 public tvlDropWindow = 3600; // 1 hour window for TVL drop detection

    // --- Absolute Bounds ---
    uint256 public constant MIN_DEVIATION_BPS = 100;
    uint256 public constant MAX_DEVIATION_BPS_CAP = 1000;
    uint256 public constant MIN_VOLATILITY_BPS = 300;
    uint256 public constant MAX_VOLATILITY_BPS_CAP = 3000;
    uint256 public constant MIN_TVL_FLOOR = 100_000e18;
    uint256 public constant MIN_STALE_THRESHOLD = 600;
    uint256 public constant MAX_STALE_THRESHOLD = 86_400;
    uint256 public constant MIN_TVL_DROP_BPS = 1000;
    uint256 public constant MAX_TVL_DROP_BPS = 8000;
    uint256 public constant MIN_TVL_DROP_WINDOW = 900; // 15 minutes
    uint256 public constant MAX_TVL_DROP_WINDOW = 86_400; // 24 hours

    // Volatility tracking
    struct PriceSnapshot {
        uint256 price;
        uint256 timestamp;
    }

    mapping(address => PriceSnapshot[]) public priceHistory;
    mapping(address => uint256) public priceHistoryIndex; // ring buffer write index

    // --- Events ---
    event PriceValidated(address indexed pool, uint256 price, uint256 confidence);
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

    function setMaxPriceDeviation(uint256 _bps) external onlyRiskAdmin {
        require(_bps >= MIN_DEVIATION_BPS && _bps <= MAX_DEVIATION_BPS_CAP, "OUT_OF_BOUNDS");
        emit ParameterUpdated("maxPriceDeviationBps", maxPriceDeviationBps, _bps);
        maxPriceDeviationBps = _bps;
    }

    function setMaxVolatility(uint256 _bps) external onlyRiskAdmin {
        require(_bps >= MIN_VOLATILITY_BPS && _bps <= MAX_VOLATILITY_BPS_CAP, "OUT_OF_BOUNDS");
        emit ParameterUpdated("maxVolatilityBps", maxVolatilityBps, _bps);
        maxVolatilityBps = _bps;
    }

    function setMinPoolTvl(uint256 _minTvl) external onlyRiskAdmin {
        require(_minTvl >= MIN_TVL_FLOOR, "BELOW_ABSOLUTE_MIN");
        emit ParameterUpdated("minPoolTvl", minPoolTvl, _minTvl);
        minPoolTvl = _minTvl;
    }

    function setStalePriceThreshold(uint256 _seconds) external onlyRiskAdmin {
        require(_seconds >= MIN_STALE_THRESHOLD && _seconds <= MAX_STALE_THRESHOLD, "OUT_OF_BOUNDS");
        emit ParameterUpdated("stalePriceThreshold", stalePriceThreshold, _seconds);
        stalePriceThreshold = _seconds;
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

    // --- Core Logic ---

    /// @notice Validate price and trigger circuit breaker if needed
    /// @dev Called by keeper only. Writes to CircuitBreaker (unified pause system).
    function validatePrice(
        address pool,
        uint256 twapPrice,
        uint256 chainlinkPrice,
        uint256 poolTvl
    )
        external
        onlyKeeper
        returns (bool valid, uint256 adjustedRiskBps)
    {
        require(pool != address(0), "ZERO_POOL");

        // Allow validation while paused — still record telemetry for monitoring,
        // but skip pause triggers (pool is already paused)
        bool alreadyPaused = circuitBreaker.poolPaused(pool);

        adjustedRiskBps = 0;

        // Check 1: TWAP vs Chainlink deviation (symmetric — anchored to min)
        uint256 deviation = LPMath.deviationBps(twapPrice, chainlinkPrice);
        if (deviation > maxPriceDeviationBps) {
            if (!alreadyPaused) circuitBreaker.pausePool(pool, "ORACLE_DEVIATION");
            return (false, 0);
        }

        // Check 2: Pool TVL minimum
        if (poolTvl < minPoolTvl) {
            if (!alreadyPaused) circuitBreaker.pausePool(pool, "TVL_TOO_LOW");
            return (false, 0);
        }

        // Check 3: TVL drop detection
        if (lastKnownTvl[pool] > 0 && lastPriceTimestamp[pool] > 0) {
            uint256 elapsed = block.timestamp - lastPriceTimestamp[pool];
            if (elapsed <= tvlDropWindow && poolTvl < lastKnownTvl[pool]) {
                uint256 tvlDropBps = ((lastKnownTvl[pool] - poolTvl) * 10_000) / lastKnownTvl[pool];
                if (tvlDropBps >= tvlDropThresholdBps) {
                    if (!alreadyPaused) circuitBreaker.pausePool(pool, "TVL_DROP");
                    return (false, 0);
                }
            }
        }

        // Check 4: Volatility check
        uint256 volatility = _checkVolatility(pool, twapPrice);
        if (volatility > maxVolatilityBps) {
            adjustedRiskBps = 500; // +5% risk premium during high volatility
        }

        // Check 5: Staleness check
        if (lastPriceTimestamp[pool] > 0) {
            uint256 elapsed = block.timestamp - lastPriceTimestamp[pool];
            if (elapsed > stalePriceThreshold) {
                adjustedRiskBps += 200; // +2% risk premium for stale prices
            }
        }

        // Record price snapshot and TVL
        lastKnownTvl[pool] = poolTvl;
        lastPriceTimestamp[pool] = block.timestamp;

        // Ring buffer: index always advances, overwrites oldest once full (cap 100)
        uint256 idx = priceHistoryIndex[pool];
        if (priceHistory[pool].length < 100) {
            priceHistory[pool].push(PriceSnapshot(twapPrice, block.timestamp));
        } else {
            priceHistory[pool][idx % 100] = PriceSnapshot(twapPrice, block.timestamp);
        }
        priceHistoryIndex[pool] = (idx + 1) % 100;

        if (adjustedRiskBps > 10_000) adjustedRiskBps = 10_000;
        emit PriceValidated(pool, twapPrice, 10_000 - adjustedRiskBps);
        return (true, adjustedRiskBps);
    }

    // --- Internal ---

    function _checkVolatility(address pool, uint256 currentPrice) internal view returns (uint256) {
        PriceSnapshot[] storage history = priceHistory[pool];
        if (history.length == 0) return 0;

        // Find entry closest to 5 minutes ago (ring buffer — entries may not be chronological)
        if (block.timestamp < 300) return 0;
        uint256 targetTimestamp = block.timestamp - 300;
        uint256 bestPrice = 0;
        uint256 bestDelta = type(uint256).max;
        for (uint256 i = 0; i < history.length; i++) {
            if (history[i].timestamp <= targetTimestamp) {
                uint256 delta = targetTimestamp - history[i].timestamp;
                if (delta < bestDelta) {
                    bestDelta = delta;
                    bestPrice = history[i].price;
                }
            }
        }
        if (bestPrice == 0) return 0;
        return LPMath.deviationBps(currentPrice, bestPrice);
    }
}
