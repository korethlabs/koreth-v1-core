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
    /// @notice ACLManager proposed by owner, awaiting acceptance by the incumbent role authority.
    address public pendingACLManager;
    address public owner;
    address public pendingOwner;

    // --- Registry ---
    mapping(ILPAdapter.LPType => address) public adapters;
    mapping(ILPAdapter.LPType => address) public oracles;
    /// @notice The lending market for a borrow asset — one per asset, keyed by the asset itself.
    /// @dev Not the same thing as supportedLpPools below, and the distinction is the reason both
    ///      were renamed. A lending pool is somewhere you borrow *from*; an LP pool is AMM
    ///      liquidity accepted as collateral. They share no addresses and no lifecycle. Reading the
    ///      old names, which called both of them "pool", a reviewer proposed requiring that every
    ///      whitelisted collateral pool also be a registered lending market — a change that would
    ///      have blocked every deposit in the protocol.
    mapping(address => address) public lendingPool;
    mapping(address => bool) public isLendingPool;
    address public poolFactory;

    /// @notice Highest LP type index with a registered adapter
    /// @dev Only increases — sparse enum slots with no adapter are handled downstream.
    uint8 public maxRegisteredLPType;

    // --- Protocol State ---
    bool public paused;

    /// @notice AMM pools curated as acceptable collateral backing. See lendingPool above for why
    ///         the names carry "Lp": these are the venues behind deposited LP positions, not
    ///         markets anyone borrows from.
    mapping(address => bool) public supportedLpPools;

    /// @notice Which AMM a curated collateral pool belongs to, stored as uint8(lpType) + 1.
    /// @dev Offset by one because LPType.UniswapV2 is 0, so an unoffset mapping would answer
    ///      "UniswapV2" for an address never registered exactly as it does for a V2 pair that was.
    ///      The offset makes "never registered" a distinguishable state, which getLpPoolType below
    ///      rejects rather than guesses at. Private so the raw offset cannot be misread as an LPType.
    ///
    ///      Consumers need this because a pool address does not say what it is, and there is no
    ///      common interface to probe: measuring a V2 pair's liquidity means reading getReserves(),
    ///      a V3 pool's means reading token balances. Recording the answer when a pool admin lists
    ///      the pool costs one slot; the alternative is every consumer inferring it from which call
    ///      happens to revert, which is a guess that gets less reliable with each AMM integrated.
    ///
    ///      What a consumer does with the answer is look up adapters[lpType] and ask that adapter,
    ///      which is where AMM-specific behaviour already lives. So this maps a pool to the contract
    ///      that knows how to read it, not to a branch every caller has to carry.
    mapping(address => uint8) private lpPoolType;

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
    event LendingPoolRegistered(address indexed borrowAsset, address indexed pool);
    event PoolFactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event LpPoolWhitelisted(address indexed pool, ILPAdapter.LPType indexed lpType);
    event LpPoolRemoved(address indexed pool);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferCancelled(address indexed currentOwner, address indexed cancelledPendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ACLManagerTransferStarted(address indexed currentManager, address indexed pendingManager);
    event ACLManagerTransferCancelled(address indexed currentManager, address indexed cancelledPendingManager);
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

    // --- ACLManager (two-step replacement) ---

    /// @notice Step 1: owner proposes a replacement ACLManager. Takes effect only once acceptACLManager
    ///         is called by a holder of DEFAULT_ADMIN_ROLE on the *current* manager.
    /// @dev The ACLManager is the source of truth for every operational role, and it is core-agnostic
    ///      (no core() back-link to verify against, unlike the price registry / risk manager). A
    ///      single-step onlyOwner setter therefore let whoever held owner repoint the whole protocol
    ///      at a self-serving ACLManager in one call — a takeover if owner and DEFAULT_ADMIN_ROLE ever
    ///      diverge (e.g. mid governance handover). Splitting the swap so the incumbent role authority
    ///      must co-sign binds the two together: neither key alone can move it.
    function setPendingACLManager(address _aclManager) external onlyOwner {
        require(_aclManager != address(0), "ZERO_ADDRESS");
        require(_aclManager.code.length > 0, "NOT_CONTRACT");
        if (pendingACLManager != address(0)) {
            emit ACLManagerTransferCancelled(address(aclManager), pendingACLManager);
        }
        pendingACLManager = _aclManager;
        emit ACLManagerTransferStarted(address(aclManager), _aclManager);
    }

    /// @notice Owner withdraws a pending ACLManager proposal before it is accepted.
    function cancelACLManagerTransfer() external onlyOwner {
        require(pendingACLManager != address(0), "NO_PENDING_TRANSFER");
        emit ACLManagerTransferCancelled(address(aclManager), pendingACLManager);
        pendingACLManager = address(0);
    }

    /// @notice Step 2: a DEFAULT_ADMIN_ROLE holder on the current ACLManager activates the proposal.
    /// @dev Co-sign by the incumbent role authority is what makes the swap require both owner (who
    ///      proposed) and DEFAULT_ADMIN_ROLE (who accepts). The check reads the current manager, so a
    ///      hostile owner cannot self-approve through the replacement it is trying to install.
    function acceptACLManager() external {
        address newManager = pendingACLManager;
        require(newManager != address(0), "NO_PENDING_TRANSFER");
        // Re-check code at acceptance, not only at proposal: an address that was a contract when
        // proposed can be codeless by now (e.g. SELFDESTRUCT, or a not-yet-deployed CREATE2 target).
        // Pointing aclManager at a codeless address would brick every onlyPoolAdmin/onlyEmergencyAdmin
        // path, which reads roles through it.
        require(newManager.code.length > 0, "NOT_CONTRACT");
        require(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), msg.sender), "NOT_ACL_ADMIN");
        emit ACLManagerUpdated(address(aclManager), newManager);
        aclManager = ACLManager(newManager);
        pendingACLManager = address(0);
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
    function registerLendingPool(address borrowAsset, address pool) external {
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
        require(lendingPool[borrowAsset] == address(0), "LENDING_POOL_ALREADY_REGISTERED");
        require(!isLendingPool[pool], "LENDING_POOL_ALREADY_REGISTERED");
        // The key must match the pool's own borrow asset, otherwise every downstream
        // `lendingPool[asset]` lookup would resolve to a pool that lends a different token.
        require(ILendingPool(pool).borrowAsset() == borrowAsset, "BORROW_ASSET_MISMATCH");
        // Listing is atomic with pricing: a market whose borrow asset has no price source can be
        // borrowed against but not valued, so its debt would never register against the health
        // factor. Checked for existence rather than health — a feed that is merely stale must not
        // block listing, and getPrice() rejects it at the point money actually moves.
        address registry = priceFeedRegistryAddr;
        require(registry != address(0), "PRICE_REGISTRY_UNSET");
        require(IPriceSource(registry).isPriceable(borrowAsset), "BORROW_ASSET_NOT_PRICEABLE");
        isLendingPool[pool] = true;
        lendingPool[borrowAsset] = pool;
        emit LendingPoolRegistered(borrowAsset, pool);
    }

    /// @notice Resolve the shared *lending* market for a borrow asset (reverts if none registered).
    function getLendingPool(address borrowAsset) external view returns (address) {
        address pool = lendingPool[borrowAsset];
        require(pool != address(0), "LENDING_POOL_NOT_FOUND");
        return pool;
    }

    // --- Pool Management ---

    /// @notice Curate an AMM pool as acceptable collateral backing, and record which AMM it is.
    /// @dev Distinct from registerLendingPool, which lists a *lending* market. This is the curation layer
    ///      over the adapters' authenticity check: they already refuse an LP token whose pool does
    ///      not come from the configured factory, so this decides which authentic pools we want.
    ///
    ///      lpType is declared by the pool admin, not derived, and is not cross-checked against the
    ///      pool: there is no call every AMM answers that would confirm it. Declaring the wrong one
    ///      is a listing error with the same reach as listing the wrong address, which this role can
    ///      already do. The adapter a consumer reaches through the type should fail closed when the
    ///      pool does not behave as declared — see PoolLiquidityMonitor, where a V3 pool listed as
    ///      V2 sends the liquidity read to UniswapV2Adapter, whose getReserves() call the pool has
    ///      no answer for, so the read reverts rather than falling back to a weaker measure.
    /// @param pool The AMM pool address
    /// @param lpType The AMM the pool belongs to — permanent for this address once set
    function whitelistLpPool(address pool, ILPAdapter.LPType lpType) external onlyPoolAdmin {
        require(pool != address(0), "ZERO_ADDRESS");
        require(pool.code.length > 0, "NOT_CONTRACT");
        require(!supportedLpPools[pool], "ALREADY_WHITELISTED");

        // What AMM an address belongs to is a fact about the address, so a re-listing may not
        // contradict the first one. Without this a delist/re-list cycle could silently re-label a
        // pool, and every consumer branching on the type would change behaviour with no event
        // saying the type moved — the LpPoolWhitelisted below would look like an ordinary re-listing.
        uint8 stored = lpPoolType[pool];
        require(stored == 0 || stored == uint8(lpType) + 1, "LP_TYPE_MISMATCH");

        supportedLpPools[pool] = true;
        lpPoolType[pool] = uint8(lpType) + 1;
        emit LpPoolWhitelisted(pool, lpType);
    }

    /// @notice Delist an AMM pool as collateral backing — blocks new deposits only.
    /// @dev Nothing about the lending markets changes here. Existing positions backed by this pool
    ///      can still be withdrawn, repaid, and liquidated.
    ///      Oracles intentionally do NOT check whitelist so pricing continues for delisted pools.
    ///      Admin should verify no active borrowed positions remain before removing,
    ///      or accept that existing positions will run until closed/liquidated naturally.
    ///
    ///      lpPoolType is deliberately NOT cleared. The whitelist is a permission and this revokes
    ///      it; the type is what the pool *is*, which delisting does not change. Keeping it is also
    ///      what lets the liquidity monitor keep measuring a delisted pool, which still backs every
    ///      position opened before the delisting — the same reason the oracles ignore the whitelist.
    function removeLpPool(address pool) external onlyPoolAdmin {
        require(supportedLpPools[pool], "NOT_WHITELISTED");
        supportedLpPools[pool] = false;
        emit LpPoolRemoved(pool);
    }

    // --- Emergency ---

    function pause() external onlyEmergencyAdmin {
        require(!paused, "ALREADY_PAUSED");
        paused = true;
        emit Paused(msg.sender);
    }

    /// @dev Symmetric with pause(): whoever can freeze the protocol in an emergency can also restore
    ///      service. The onlyEmergencyAdmin modifier admits emergency admins AND pool admins (see its
    ///      definition above), so pool admins keep the unpause authority they already had and
    ///      emergency admins gain it. This mirrors Aave V3, where setPoolPause is gated by a single
    ///      emergency-or-pool admin check in both directions, and prioritizes speed of recovery — an
    ///      emergency pauser is not left waiting on a pool admin to bring the protocol back.
    function unpause() external onlyEmergencyAdmin {
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
    ///      empty address. Same shape as getLendingPool/getAdapter/getOracle above.
    function getPriceFeedRegistry() external view returns (address) {
        address registry = priceFeedRegistryAddr;
        require(registry != address(0), "PRICE_REGISTRY_UNSET");
        return registry;
    }

    function isLpPoolSupported(address pool) external view returns (bool) {
        return supportedLpPools[pool];
    }

    /// @notice The AMM a curated collateral pool belongs to.
    /// @dev Reverts for an address never passed to whitelistLpPool, rather than returning the zero
    ///      enum member. A caller asking this is about to branch on the answer, and the branch for
    ///      an unknown pool is not "treat it as UniswapV2" — it is "do not act". Answers for
    ///      delisted pools too: see removeLpPool for why the type outlives the permission.
    function getLpPoolType(address pool) external view returns (ILPAdapter.LPType) {
        uint8 stored = lpPoolType[pool];
        require(stored != 0, "LP_TYPE_UNKNOWN");
        return ILPAdapter.LPType(stored - 1);
    }
}
