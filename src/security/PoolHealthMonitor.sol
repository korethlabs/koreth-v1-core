// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ProtocolCore} from "../core/ProtocolCore.sol";
import {CircuitBreaker} from "./CircuitBreaker.sol";

/// @title PoolHealthMonitor
/// @notice Monitors underlying DEX pool health and triggers circuit breakers
contract PoolHealthMonitor {
    ProtocolCore public immutable core;
    CircuitBreaker public immutable circuitBreaker;

    struct PoolSnapshot {
        uint256 tvl;
        uint256 timestamp;
    }

    mapping(address => PoolSnapshot) public lastSnapshot;
    mapping(address => uint256) public minRequiredTvl;

    // --- Configurable Thresholds ---
    uint256 public tvlDropThresholdBps = 3000; // 30% drop triggers alert
    uint256 public criticalTvlDropBps = 5000; // 50% drop triggers circuit breaker

    // --- Absolute Bounds ---
    uint256 public constant MIN_DROP_THRESHOLD = 500; // 5%
    uint256 public constant MAX_DROP_THRESHOLD = 9000; // 90%

    // --- Events ---
    event PoolHealthAlert(address indexed pool, uint256 currentTvl, uint256 previousTvl, string severity);
    event ParameterUpdated(string name, uint256 oldValue, uint256 newValue);
    event MinTvlUpdated(address indexed pool, uint256 minTvl);

    modifier onlyKeeper() {
        require(core.aclManager().isKeeper(msg.sender) || core.aclManager().isPoolAdmin(msg.sender), "NOT_KEEPER");
        _;
    }

    modifier onlyPoolAdmin() {
        require(core.aclManager().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
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

    function setTvlDropThreshold(uint256 _bps) external onlyPoolAdmin {
        require(_bps >= MIN_DROP_THRESHOLD && _bps <= MAX_DROP_THRESHOLD, "OUT_OF_BOUNDS");
        require(_bps < criticalTvlDropBps, "MUST_BE_BELOW_CRITICAL");
        emit ParameterUpdated("tvlDropThresholdBps", tvlDropThresholdBps, _bps);
        tvlDropThresholdBps = _bps;
    }

    function setCriticalTvlDrop(uint256 _bps) external onlyPoolAdmin {
        require(_bps >= MIN_DROP_THRESHOLD && _bps <= MAX_DROP_THRESHOLD, "OUT_OF_BOUNDS");
        require(_bps > tvlDropThresholdBps, "MUST_BE_ABOVE_WARNING");
        emit ParameterUpdated("criticalTvlDropBps", criticalTvlDropBps, _bps);
        criticalTvlDropBps = _bps;
    }

    function setMinTvl(address pool, uint256 minTvl) external onlyPoolAdmin {
        minRequiredTvl[pool] = minTvl;
        emit MinTvlUpdated(pool, minTvl);
    }

    // --- Core Logic ---

    /// @notice Check pool health and trigger circuit breaker if needed
    /// @dev currentTvl is provided by the keeper bot (off-chain data).
    ///      The keeper is a permissioned role (KEEPER in ACLManager) — same trust model
    ///      as Aave's Chaos Labs risk bots that feed on-chain actions from off-chain monitoring.
    ///      On-chain TVL reads (pool.getReserves) are not used here because they are
    ///      manipulable within a transaction. The keeper reads TVL from a subgraph or
    ///      multi-block RPC sampling, which is manipulation-resistant.
    function checkPoolHealth(address pool, uint256 currentTvl) external onlyKeeper {
        PoolSnapshot memory prev = lastSnapshot[pool];

        // Relative-drop check needs a prior snapshot to compare against.
        if (prev.tvl > 0 && prev.timestamp > 0 && currentTvl < prev.tvl) {
            uint256 dropBps = ((prev.tvl - currentTvl) * 10_000) / prev.tvl;
            uint256 elapsed = block.timestamp - prev.timestamp;

            if (dropBps >= criticalTvlDropBps && elapsed <= 1 hours) {
                circuitBreaker.pausePool(pool, "CRITICAL_TVL_DROP");
                emit PoolHealthAlert(pool, currentTvl, prev.tvl, "CRITICAL");
            } else if (dropBps >= tvlDropThresholdBps && elapsed <= 1 hours) {
                emit PoolHealthAlert(pool, currentTvl, prev.tvl, "WARNING");
            }
        }

        // Absolute floor is standalone — enforce on EVERY call, including the first snapshot.
        uint256 minTvl = minRequiredTvl[pool];
        if (minTvl > 0 && currentTvl < minTvl) {
            circuitBreaker.pausePool(pool, "BELOW_MIN_TVL");
            emit PoolHealthAlert(pool, currentTvl, prev.tvl, "BELOW_MIN_TVL");
        }

        lastSnapshot[pool] = PoolSnapshot(currentTvl, block.timestamp);
    }
}
