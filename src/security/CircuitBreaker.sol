// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";

/// @title CircuitBreaker
/// @notice Granular halt mechanism for individual collateral types and pools.
/// @dev EmergencyAdmin/Keeper can freeze/pause. Only PoolAdmin can unfreeze/unpause.
///      Per-collateral-type halts use `collateralFrozen` (Aave-style: blocks new risk, always allows
///      withdraw/repay/liquidate so users can exit). Per-pool halts use `poolPaused`.
///      A full protocol stop is `ProtocolCore.pause()`. There is deliberately NO per-collateral
///      "block-everything" switch: halting user exits (withdraw/repay) would trap funds.
contract CircuitBreaker {
    ProtocolCore public immutable core;

    // Per-pool pause state
    mapping(address => bool) public poolPaused;

    // Frozen state (Aave V3 pattern): blocks deposits/borrows against this collateral, allows
    // withdraw/repay/liquidate. Keyed by LP collateral type in the unified-pool model, so it does
    // not reach lender-side LendingPool.supply(), which no breaker gates: poolPaused is keyed by
    // the AMM pool backing the collateral and is read only on deposit and borrow.
    mapping(ILPAdapter.LPType => bool) public collateralFrozen;

    // --- Events ---
    event CollateralFrozen(ILPAdapter.LPType indexed lpType, string reason);
    event CollateralUnfrozen(ILPAdapter.LPType indexed lpType);
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

    /// @notice Unpause a pool (PoolAdmin only, after investigation)
    function unpausePool(address pool) external onlyPoolAdmin {
        poolPaused[pool] = false;
        emit PoolUnpaused(pool);
    }

    /// @notice Freeze a collateral type — blocks new risk (deposit/borrow/addCollateral) but allows
    ///         withdraw/repay/liquidate/supply
    /// @dev Use for token depegs, oracle issues, or exploit response (Aave V3 frozen reserve pattern)
    function freezeCollateral(ILPAdapter.LPType lpType, string calldata reason) external onlyGuardianOrKeeper {
        collateralFrozen[lpType] = true;
        emit CollateralFrozen(lpType, reason);
    }

    /// @notice Unfreeze a collateral type (PoolAdmin only)
    function unfreezeCollateral(ILPAdapter.LPType lpType) external onlyPoolAdmin {
        collateralFrozen[lpType] = false;
        emit CollateralUnfrozen(lpType);
    }

    /// @notice Check if a pool's positions can be managed (global pause + pool pause)
    function isPoolOperationAllowed(address pool) external view returns (bool) {
        if (core.paused()) return false;
        if (poolPaused[pool]) return false;
        return true;
    }
}
