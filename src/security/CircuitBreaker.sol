// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title CircuitBreaker
/// @notice Granular halt mechanism for individual markets and pools.
/// @dev EmergencyAdmin/Keeper can freeze/pause. Only PoolAdmin can unfreeze/unpause.
///      Per-market halts use `marketFrozen` (Aave-style: blocks new risk, always allows
///      withdraw/repay/liquidate so users can exit). Per-pool halts use `poolPaused`.
///      A full protocol stop is `ProtocolCore.pause()`. There is deliberately NO per-market
///      "block-everything" switch: halting user exits (withdraw/repay) would trap funds.
contract CircuitBreaker {
    ProtocolCore public immutable core;

    // Per-pool pause state
    mapping(address => bool) public poolPaused;

    // Frozen state (Aave V3 pattern): blocks deposits/borrows/supply, allows withdraw/repay/liquidate
    mapping(uint256 => bool) public marketFrozen;

    // --- Events ---
    event MarketFrozen(uint256 indexed marketId, string reason);
    event MarketUnfrozen(uint256 indexed marketId);
    event PoolPaused(address indexed pool, string reason);
    event PoolUnpaused(address indexed pool);

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyGuardianOrKeeper() {
        ACLManager acl = _acl();
        require(
            acl.isEmergencyAdmin(msg.sender) || acl.isPoolAdmin(msg.sender) || acl.isKeeper(msg.sender),
            "NOT_AUTHORIZED"
        );
        _;
    }

    modifier onlyPoolAdmin() {
        require(_acl().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    constructor(address _core) {
        require(_core != address(0), "ZERO_CORE");
        core = ProtocolCore(_core);
    }

    /// @notice Pause all operations for a specific pool
    function pausePool(address pool, string calldata reason) external onlyGuardianOrKeeper {
        poolPaused[pool] = true;
        emit PoolPaused(pool, reason);
    }

    /// @notice Unpause a pool (guardian/owner only, after investigation)
    function unpausePool(address pool) external onlyPoolAdmin {
        poolPaused[pool] = false;
        emit PoolUnpaused(pool);
    }

    /// @notice Freeze a market — blocks new risk (deposit/borrow/addCollateral) but allows withdraw/repay/liquidate/supply
    /// @dev Use for token depegs, oracle issues, or exploit response (Aave V3 frozen reserve pattern)
    function freezeMarket(uint256 marketId, string calldata reason) external onlyGuardianOrKeeper {
        marketFrozen[marketId] = true;
        emit MarketFrozen(marketId, reason);
    }

    /// @notice Unfreeze a market (PoolAdmin only — requires timelock)
    function unfreezeMarket(uint256 marketId) external onlyPoolAdmin {
        marketFrozen[marketId] = false;
        emit MarketUnfrozen(marketId);
    }

    /// @notice Check if a pool's positions can be managed (global pause + pool pause)
    function isPoolOperationAllowed(address pool) external view returns (bool) {
        if (core.paused()) return false;
        if (poolPaused[pool]) return false;
        return true;
    }
}
