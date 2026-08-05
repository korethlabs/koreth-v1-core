// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title ACLManager
/// @notice Role-based access control for the Koreth protocol (Aave V3 pattern)
/// @dev Extends OZ AccessControlEnumerable for role member counting.
///      Single source of truth for all permissions.
///      DEFAULT_ADMIN_ROLE holder (owner multisig, later timelock) can grant/revoke all roles.
contract ACLManager is AccessControlEnumerable {
    // --- Admin Roles (humans / multisigs / governance) ---

    /// @notice Full protocol management — deploy contracts, register markets/oracles/adapters,
    ///         upgrade UUPS proxies, configure fee collector. Also the only role that can reverse
    ///         an emergency action (CircuitBreaker.unpausePool/unfreezeCollateral) and the one that
    ///         tunes oracle plumbing (PriceFeedRegistry.setMaxStaleness/setSequencerUptimeFeed,
    ///         UniswapV3Oracle/CurveOracle deviation and TWAP settings). Held by deployer, later DAO
    ///         timelock.
    bytes32 public constant POOL_ADMIN = keccak256("POOL_ADMIN");

    /// @notice Emergency pause only — can pause the entire protocol or individual markets.
    ///         Cannot change parameters or upgrade contracts. Held by security multisig.
    bytes32 public constant EMERGENCY_ADMIN = keccak256("EMERGENCY_ADMIN");

    /// @notice Risk parameter tuning — LTV, liquidation threshold, borrow caps, interest rate
    ///         models, oracle thresholds. Cannot deploy or upgrade contracts.
    bytes32 public constant RISK_ADMIN = keccak256("RISK_ADMIN");

    // --- Contract Roles (protocol contracts + automation bots) ---

    /// @notice Core lending contract — can call transferOut/transferIn on markets,
    ///         update position debt, accrue interest. Exactly one instance.
    bytes32 public constant LENDING_ENGINE = keccak256("LENDING_ENGINE");

    /// @notice Core liquidation contract — can call markLiquidated, reducePositionAmount
    ///         on PositionManager. Exactly one instance.
    bytes32 public constant LIQUIDATION_ENGINE = keccak256("LIQUIDATION_ENGINE");

    /// @notice Core position contract — can record fees in FeeCollector.
    ///         Exactly one instance.
    bytes32 public constant POSITION_MANAGER = keccak256("POSITION_MANAGER");

    /// @notice Automation bots — can call compoundFees and PoolLiquidityMonitor.checkPool.
    ///         Multiple instances (bot fleet).
    /// @dev Grant this deliberately: CircuitBreaker.onlyGuardianOrKeeper accepts it, so a keeper can
    ///      pause any pool and freeze any collateral type directly, without going through a check.
    ///      It cannot unpause — only POOL_ADMIN can (CircuitBreaker.onlyPoolAdmin) — so a rogue
    ///      keeper's reach is denial of service that a human reverses, not loss.
    ///
    ///      Nothing a keeper calls takes its numbers from the keeper. PoolLiquidityMonitor.checkPool
    ///      reads balances and Chainlink prices itself, so the role decides when a check runs, never
    ///      what it concludes.
    bytes32 public constant KEEPER = keccak256("KEEPER");

    /// @notice Periphery contracts that act on user positions via PositionManager.transform().
    ///         Admin-whitelisted, user-invoked. Examples: LeverageTransformer, CompoundSwapRouter.
    ///         Authorization is transient — only active during the transform() call.
    bytes32 public constant TRANSFORMER = keccak256("TRANSFORMER");

    constructor(address admin) {
        require(admin != address(0), "ZERO_ADMIN");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POOL_ADMIN, admin);
    }

    // --- Pool Admin ---
    function addPoolAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "ZERO_ADDRESS");
        grantRole(POOL_ADMIN, admin);
    }

    function removePoolAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "ZERO_ADDRESS");
        revokeRole(POOL_ADMIN, admin);
    }

    function isPoolAdmin(address admin) external view returns (bool) {
        return hasRole(POOL_ADMIN, admin);
    }

    // --- Emergency Admin ---
    function addEmergencyAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "ZERO_ADDRESS");
        grantRole(EMERGENCY_ADMIN, admin);
    }

    function removeEmergencyAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "ZERO_ADDRESS");
        revokeRole(EMERGENCY_ADMIN, admin);
    }

    function isEmergencyAdmin(address admin) external view returns (bool) {
        return hasRole(EMERGENCY_ADMIN, admin);
    }

    // --- Risk Admin ---
    function addRiskAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "ZERO_ADDRESS");
        grantRole(RISK_ADMIN, admin);
    }

    function removeRiskAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "ZERO_ADDRESS");
        revokeRole(RISK_ADMIN, admin);
    }

    function isRiskAdmin(address admin) external view returns (bool) {
        return hasRole(RISK_ADMIN, admin);
    }

    // --- Contract Roles (Lending Engine) ---
    function addLendingEngine(address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(addr != address(0), "ZERO_ADDRESS");
        grantRole(LENDING_ENGINE, addr);
    }

    function removeLendingEngine(address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(addr != address(0), "ZERO_ADDRESS");
        revokeRole(LENDING_ENGINE, addr);
    }

    function isLendingEngine(address addr) external view returns (bool) {
        return hasRole(LENDING_ENGINE, addr);
    }

    // --- Contract Roles (Liquidation Engine) ---
    function addLiquidationEngine(address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(addr != address(0), "ZERO_ADDRESS");
        grantRole(LIQUIDATION_ENGINE, addr);
    }

    function removeLiquidationEngine(address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(addr != address(0), "ZERO_ADDRESS");
        revokeRole(LIQUIDATION_ENGINE, addr);
    }

    function isLiquidationEngine(address addr) external view returns (bool) {
        return hasRole(LIQUIDATION_ENGINE, addr);
    }

    // --- Contract Roles (Position Manager) ---
    function addPositionManager(address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(addr != address(0), "ZERO_ADDRESS");
        grantRole(POSITION_MANAGER, addr);
    }

    function removePositionManager(address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(addr != address(0), "ZERO_ADDRESS");
        revokeRole(POSITION_MANAGER, addr);
    }

    function isPositionManager(address addr) external view returns (bool) {
        return hasRole(POSITION_MANAGER, addr);
    }

    // --- Contract Roles (Transformer — periphery contracts that act on positions) ---
    function addTransformer(address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(addr != address(0), "ZERO_ADDRESS");
        grantRole(TRANSFORMER, addr);
    }

    function removeTransformer(address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(addr != address(0), "ZERO_ADDRESS");
        revokeRole(TRANSFORMER, addr);
    }

    function isTransformer(address addr) external view returns (bool) {
        return hasRole(TRANSFORMER, addr);
    }

    // --- Contract Roles (Keeper) ---
    function addKeeper(address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(addr != address(0), "ZERO_ADDRESS");
        grantRole(KEEPER, addr);
    }

    function removeKeeper(address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(addr != address(0), "ZERO_ADDRESS");
        revokeRole(KEEPER, addr);
    }

    function isKeeper(address addr) external view returns (bool) {
        return hasRole(KEEPER, addr);
    }

    // --- Anti-bricking: protect last DEFAULT_ADMIN_ROLE ---

    /// @notice Cannot renounce DEFAULT_ADMIN_ROLE (prevents bricking)
    function renounceRole(bytes32 role, address callerConfirmation) public override(AccessControl, IAccessControl) {
        require(role != DEFAULT_ADMIN_ROLE, "CANNOT_RENOUNCE_ADMIN");
        super.renounceRole(role, callerConfirmation);
    }

    /// @notice Cannot revoke last DEFAULT_ADMIN_ROLE holder (prevents bricking)
    function revokeRole(
        bytes32 role,
        address account
    )
        public
        override(AccessControl, IAccessControl)
        onlyRole(getRoleAdmin(role))
    {
        if (role == DEFAULT_ADMIN_ROLE && hasRole(DEFAULT_ADMIN_ROLE, account)) {
            require(getRoleMemberCount(DEFAULT_ADMIN_ROLE) > 1, "CANNOT_REMOVE_LAST_ADMIN");
        }
        super.revokeRole(role, account);
    }
}
