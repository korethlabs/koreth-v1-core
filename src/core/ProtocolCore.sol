// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {ACLManager} from "./ACLManager.sol";

/// @notice Satellite contracts bind to one ProtocolCore at construction and expose it. Pointing
///         this core at a satellite wired to a *different* core produces a half-connected protocol
///         that still answers calls, so the setters below check the link points back.
interface ICoreBound {
    function core() external view returns (address);
}

/// @notice The calls ProtocolCore needs from the price registry. Declared here rather than imported
///         because PriceFeedRegistry already imports ProtocolCore, and this is the whole of the
///         dependency in this direction.
interface IPriceSource is ICoreBound {
    function isPriceable(address token) external view returns (bool);
}

/// @title ProtocolCore
/// @notice Central registry and access control for the Koreth protocol
/// @dev All core contracts reference this for shared state and permissions.
///      Not proxied — this IS the root of trust. owner = DAO multisig.
///      Uses ACLManager (Aave V3 pattern) for role-based access control.
contract ProtocolCore {
    // --- Roles (via ACLManager) ---
    ACLManager public aclManager;
    address public owner;
    address public pendingOwner;

    // --- Registry ---
    mapping(ILPAdapter.LPType => address) public adapters;
    mapping(ILPAdapter.LPType => address) public oracles;
    /// @notice One shared lending pool per borrow asset (the pool key IS the borrow-asset address).
    mapping(address => address) public pools;
    mapping(address => bool) public registeredPools;
    address public poolFactory;

    /// @notice Highest LP type index with a registered adapter
    /// @dev Only increases — sparse enum slots with no adapter are handled downstream.
    uint8 public maxRegisteredLPType;

    // --- Protocol State ---
    bool public paused;
    mapping(address => bool) public supportedPools;
    mapping(address => uint256) public poolAddedAt;

    // --- Shared Registry Addresses ---
    address public priceFeedRegistryAddr;
    address public riskManagerAddr;

    // --- Events ---
    event PriceFeedRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event RiskManagerUpdated(address indexed oldManager, address indexed newManager);
    // Carry the previous address: re-registering silently replaces a live adapter/oracle, and an
    // event that only reports the new one makes a swap indistinguishable from a first-time setup.
    event AdapterRegistered(ILPAdapter.LPType indexed lpType, address indexed oldAdapter, address indexed adapter);
    event OracleRegistered(ILPAdapter.LPType indexed lpType, address indexed oldOracle, address indexed oracle);
    event PoolRegistered(address indexed borrowAsset, address indexed pool);
    event PoolFactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event PoolWhitelisted(address indexed pool);
    event PoolRemoved(address indexed pool);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferCancelled(address indexed currentOwner, address indexed cancelledPendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ACLManagerUpdated(address indexed oldManager, address indexed newManager);

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyPoolAdmin() {
        require(address(aclManager) != address(0) && aclManager.isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    modifier onlyEmergencyAdmin() {
        require(
            address(aclManager) != address(0)
                && (aclManager.isEmergencyAdmin(msg.sender) || aclManager.isPoolAdmin(msg.sender)),
            "NOT_EMERGENCY_ADMIN"
        );
        _;
    }

    constructor(address _owner, address _aclManager) {
        require(_owner != address(0), "ZERO_OWNER");
        require(_aclManager != address(0), "ZERO_ACL");
        require(_aclManager.code.length > 0, "NOT_CONTRACT");
        owner = _owner;
        aclManager = ACLManager(_aclManager);
    }

    // --- ACLManager ---

    function setACLManager(address _aclManager) external onlyOwner {
        require(_aclManager != address(0), "ZERO_ADDRESS");
        require(_aclManager.code.length > 0, "NOT_CONTRACT");
        emit ACLManagerUpdated(address(aclManager), _aclManager);
        aclManager = ACLManager(_aclManager);
    }

    // --- Registry Management ---

    function registerAdapter(ILPAdapter.LPType lpType, address adapter) external onlyPoolAdmin {
        require(adapter != address(0), "ZERO_ADDRESS");
        require(adapter.code.length > 0, "NOT_CONTRACT");
        emit AdapterRegistered(lpType, adapters[lpType], adapter);
        adapters[lpType] = adapter;
        if (uint8(lpType) > maxRegisteredLPType) {
            maxRegisteredLPType = uint8(lpType);
        }
    }

    function registerOracle(ILPAdapter.LPType lpType, address oracle) external onlyPoolAdmin {
        require(oracle != address(0), "ZERO_ADDRESS");
        require(oracle.code.length > 0, "NOT_CONTRACT");
        emit OracleRegistered(lpType, oracles[lpType], oracle);
        oracles[lpType] = oracle;
    }

    function setPoolFactory(address _factory) external onlyPoolAdmin {
        require(_factory != address(0), "ZERO_ADDRESS");
        require(_factory.code.length > 0, "NOT_CONTRACT");
        emit PoolFactoryUpdated(poolFactory, _factory);
        poolFactory = _factory;
    }

    /// @notice Register a shared lending pool, keyed by its borrow asset.
    /// @dev One pool per borrow asset. The pool key IS the borrow-asset address.
    function registerPool(address borrowAsset, address pool) external {
        require(
            (address(aclManager) != address(0) && aclManager.isPoolAdmin(msg.sender)) || msg.sender == poolFactory,
            "NOT_AUTHORIZED"
        );
        require(borrowAsset != address(0), "ZERO_BORROW_ASSET");
        // PoolFactory already screens the borrow asset, but a PoolAdmin can register a pool
        // directly, and this is the chokepoint both paths share. An EOA key would satisfy the
        // borrowAsset() match below and only fail much later, on the first transfer.
        require(borrowAsset.code.length > 0, "BORROW_ASSET_NOT_CONTRACT");
        require(pool != address(0), "ZERO_ADDRESS");
        require(pool.code.length > 0, "NOT_CONTRACT");
        require(pools[borrowAsset] == address(0), "POOL_ALREADY_REGISTERED");
        require(!registeredPools[pool], "POOL_ALREADY_REGISTERED");
        // The key must match the pool's own borrow asset, otherwise every downstream
        // `pools[asset]` lookup would resolve to a pool that lends a different token.
        require(ILendingPool(pool).borrowAsset() == borrowAsset, "BORROW_ASSET_MISMATCH");
        // Listing is atomic with pricing: a market whose borrow asset has no price source can be
        // borrowed against but not valued, so its debt would never register against the health
        // factor. Checked for existence rather than health — a feed that is merely stale must not
        // block listing, and getPrice() rejects it at the point money actually moves.
        address registry = priceFeedRegistryAddr;
        require(registry != address(0), "PRICE_REGISTRY_UNSET");
        require(IPriceSource(registry).isPriceable(borrowAsset), "BORROW_ASSET_NOT_PRICEABLE");
        registeredPools[pool] = true;
        pools[borrowAsset] = pool;
        emit PoolRegistered(borrowAsset, pool);
    }

    /// @notice Resolve the shared pool for a borrow asset (reverts if none registered).
    function getPool(address borrowAsset) external view returns (address) {
        address pool = pools[borrowAsset];
        require(pool != address(0), "POOL_NOT_FOUND");
        return pool;
    }

    // --- Pool Management ---

    /// @notice Curate an AMM pool as acceptable collateral backing.
    /// @dev Distinct from registerPool, which lists a *lending* market. This is the curation layer
    ///      over the adapters' authenticity check: they already refuse an LP token whose pool does
    ///      not come from the configured factory, so this decides which authentic pools we want.
    function whitelistPool(address pool) external onlyPoolAdmin {
        require(pool != address(0), "ZERO_ADDRESS");
        require(pool.code.length > 0, "NOT_CONTRACT");
        require(!supportedPools[pool], "ALREADY_WHITELISTED");
        supportedPools[pool] = true;
        poolAddedAt[pool] = block.timestamp;
        emit PoolWhitelisted(pool);
    }

    /// @notice Remove a pool from the whitelist — blocks new deposits only.
    /// @dev Existing positions in this pool can still be withdrawn, repaid, and liquidated.
    ///      Oracles intentionally do NOT check whitelist so pricing continues for delisted pools.
    ///      Admin should verify no active borrowed positions remain before removing,
    ///      or accept that existing positions will run until closed/liquidated naturally.
    function removePool(address pool) external onlyPoolAdmin {
        require(supportedPools[pool], "NOT_WHITELISTED");
        supportedPools[pool] = false;
        delete poolAddedAt[pool];
        emit PoolRemoved(pool);
    }

    // --- Emergency ---

    function pause() external onlyEmergencyAdmin {
        require(!paused, "ALREADY_PAUSED");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyPoolAdmin {
        require(paused, "NOT_PAUSED");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // --- Ownership (two-step transfer) ---

    /// @notice Step 1: Propose new owner (two-step transfer)
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_ADDRESS");
        if (pendingOwner != address(0)) {
            emit OwnershipTransferCancelled(owner, pendingOwner);
        }
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        require(pendingOwner != address(0), "NO_PENDING_TRANSFER");
        emit OwnershipTransferCancelled(owner, pendingOwner);
        pendingOwner = address(0);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "NOT_PENDING_OWNER");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // --- Shared Registry Management ---

    /// @dev Cannot be unset, for the same reason RiskManager cannot: every borrow-side consumer
    ///      reads prices through here, so clearing it would leave them with no source for the debt
    ///      side of the health factor. It used to be clearable, and the consumers answered by
    ///      assuming $1 — which silently over-issues against any asset that is not worth a dollar
    ///      and hides a depeg on the ones that are. Pricing now fails closed, so this must hold.
    function setPriceFeedRegistry(address _registry) external onlyPoolAdmin {
        require(_registry != address(0), "ZERO_ADDRESS");
        require(_registry.code.length > 0, "NOT_CONTRACT");
        // A registry bound to a different core would price against foreign admin roles and cannot
        // be walked back by unsetting, so refuse the link rather than discover it at the next borrow.
        require(IPriceSource(_registry).core() == address(this), "WRONG_CORE");
        emit PriceFeedRegistryUpdated(priceFeedRegistryAddr, _registry);
        priceFeedRegistryAddr = _registry;
    }

    /// @dev Cannot be unset. RiskManager is the collateral registry: clearing it would zero the
    ///      liquidation threshold for every live position (health factor 0 across the board) and
    ///      wipe the per-type borrow-cap accounting for debt that is still outstanding.
    function setRiskManager(address _riskManager) external onlyPoolAdmin {
        require(_riskManager != address(0), "ZERO_ADDRESS");
        require(_riskManager.code.length > 0, "NOT_CONTRACT");
        require(ICoreBound(_riskManager).core() == address(this), "WRONG_CORE");
        emit RiskManagerUpdated(riskManagerAddr, _riskManager);
        riskManagerAddr = _riskManager;
    }

    // --- View ---

    function getAdapter(ILPAdapter.LPType lpType) external view returns (address) {
        address adapter = adapters[lpType];
        require(adapter != address(0), "ADAPTER_NOT_FOUND");
        return adapter;
    }

    function getOracle(ILPAdapter.LPType lpType) external view returns (address) {
        address oracle = oracles[lpType];
        require(oracle != address(0), "ORACLE_NOT_FOUND");
        return oracle;
    }

    /// @notice Resolve the price registry (reverts if it was never configured).
    /// @dev The borrow-side consumers read it through here rather than off the raw storage slot, so
    ///      a deployment that reaches them before wiring fails by name instead of as a call into an
    ///      empty address. Same shape as getPool/getAdapter/getOracle above.
    function getPriceFeedRegistry() external view returns (address) {
        address registry = priceFeedRegistryAddr;
        require(registry != address(0), "PRICE_REGISTRY_UNSET");
        return registry;
    }

    function isPoolSupported(address pool) external view returns (bool) {
        return supportedPools[pool];
    }

    /// @notice Get pool age in seconds (returns 0 if pool is not currently supported)
    function getPoolAge(address pool) external view returns (uint256) {
        if (!supportedPools[pool]) return 0;
        uint256 addedAt = poolAddedAt[pool];
        if (addedAt == 0) return 0;
        return block.timestamp - addedAt;
    }
}
