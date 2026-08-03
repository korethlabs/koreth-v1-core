// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ILPOracleHub} from "../interfaces/ILPOracleHub.sol";
import {ILendingEngine} from "../interfaces/ILendingEngine.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolCore} from "./ProtocolCore.sol";
import {ACLManager} from "./ACLManager.sol";
import {PriceFeedRegistry} from "../oracle/PriceFeedRegistry.sol";
import {RiskManager} from "../security/RiskManager.sol";
import {CircuitBreaker} from "../security/CircuitBreaker.sol";
import {FeeCollector} from "./FeeCollector.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

/// @title PositionManager
/// @notice Manages LP position deposits, withdrawals, and position state tracking
/// @dev UUPS upgradeable + reentrancy protected (external calls to adapters/oracles)
///      Uses ACLManager for role-based access control (Aave V3 pattern).
contract PositionManager is IPositionManager, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for OZIERC20;

    ProtocolCore public core;
    ILPOracleHub public oracleHub;
    ILendingEngine public lendingEngine;

    mapping(uint256 => Position) internal _positions;
    mapping(address => uint256[]) internal _ownerPositions;
    uint256 public nextPositionId;
    mapping(uint256 => uint256) public positionDebt;

    /// @dev Max total fee (protocol + caller reward) that compoundFees may take from a
    ///      position's collected fees. Bounds KEEPER griefing on arbitrary positions.
    uint256 public constant MAX_COMPOUND_FEE_BPS = 500; // 5%
    /// @dev Deprecated — was `authorized` mapping. Kept for UUPS storage layout compatibility.
    mapping(address => bool) private __deprecated_authorized;

    /// @dev Set during transform() — the position being transformed. Zero when not in transform.
    ///      Used as both reentrancy guard and authorization context for transformer callbacks.
    uint256 public transformedPositionId;

    /// @dev The specific transformer contract authorized during transform(). Zero when not in transform.
    ///      Only THIS address can act on the position — prevents other transformers from piggy-backing.
    address public activeTransformer;

    /// @dev Params struct to avoid stack-too-deep in compoundFees → _distributeFees
    struct CompoundParams {
        address token0;
        address token1;
        address lpToken;
        uint256 tokenId;
        address adapterAddr;
        uint256 fees0;
        uint256 fees1;
        address protocolFeeRecipient;
        uint256 protocolFeeBps;
        address callerRewardRecipient;
        uint256 callerRewardBps;
        address dustRefundTo;
        uint256 maxSlippageBps;
    }

    // --- Events ---
    event CollateralAdded(uint256 indexed positionId, uint256 addedLiquidity, uint256 used0, uint256 used1);
    event CollateralRemoved(uint256 indexed positionId, uint128 liquidityRemoved, uint256 amount0, uint256 amount1);
    event PositionAmountReduced(uint256 indexed positionId, uint256 amountRemoved, uint256 newAmount);
    event LendingEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event CircuitBreakerUpdated(address indexed oldBreaker, address indexed newBreaker);
    event PositionTransformed(uint256 indexed positionId, address indexed transformer);

    // --- ACL Helpers ---
    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    /// @dev Returns true if caller is the position owner OR the specific active transformer.
    ///      Only the exact transformer contract passed to transform() is authorized, and only
    ///      for the exact position being transformed. Prevents other transformers from piggy-backing.
    function _isOwnerOrActiveTransformer(uint256 positionId, address caller) internal view returns (bool) {
        if (_positions[positionId].owner == caller) return true;
        return transformedPositionId == positionId && caller == activeTransformer;
    }

    // --- Modifiers ---
    modifier onlyPoolAdmin() {
        require(_acl().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    modifier onlyLendingEngine() {
        require(_acl().isLendingEngine(msg.sender), "NOT_LENDING_ENGINE");
        _;
    }

    modifier onlyLiquidationEngine() {
        require(_acl().isLiquidationEngine(msg.sender), "NOT_LIQUIDATION_ENGINE");
        _;
    }

    modifier onlyLendingOrLiquidation() {
        ACLManager acl = _acl();
        require(acl.isLendingEngine(msg.sender) || acl.isLiquidationEngine(msg.sender), "NOT_AUTHORIZED");
        _;
    }

    modifier whenNotPaused() {
        require(!core.paused(), "PAUSED");
        _;
    }

    modifier positionExists(uint256 positionId) {
        require(positionId < nextPositionId, "POSITION_NOT_FOUND");
        require(_positions[positionId].owner != address(0), "POSITION_NOT_FOUND");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _core, address _oracleHub) external initializer {
        require(_core != address(0) && _oracleHub != address(0), "ZERO_ADDRESS");
        core = ProtocolCore(_core);
        oracleHub = ILPOracleHub(_oracleHub);
        nextPositionId = 1; // Reserve 0 as sentinel for transformedPositionId (pre-production — no migration needed)
    }

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

    /// @notice Set the LendingEngine reference (needed for accurate health factor)
    function setLendingEngine(address _lendingEngine) external onlyPoolAdmin {
        require(_lendingEngine != address(0), "ZERO_ADDRESS");
        require(_lendingEngine.code.length > 0, "NOT_CONTRACT");
        emit LendingEngineUpdated(address(lendingEngine), _lendingEngine);
        lendingEngine = ILendingEngine(_lendingEngine);
    }

    /// @notice Set CircuitBreaker for pool-level pause enforcement
    /// @dev Cannot be unset. Every freeze check reads it, so clearing it would not disable one
    ///      lever — it would silently disable the whole circuit breaker across deposits, borrows
    ///      and collateral changes, leaving a paused pool or a frozen collateral type accepting new
    ///      risk with nothing but an event to say so.
    function setCircuitBreaker(address _circuitBreaker) external onlyPoolAdmin {
        require(_circuitBreaker != address(0), "ZERO_ADDRESS");
        require(_circuitBreaker.code.length > 0, "NOT_CONTRACT");
        emit CircuitBreakerUpdated(address(circuitBreaker), _circuitBreaker);
        circuitBreaker = CircuitBreaker(_circuitBreaker);
    }

    /// @notice Resolve the circuit breaker (reverts if it was never configured).
    /// @dev Mirrors ProtocolCore.getPriceFeedRegistry(). Now that the breaker is mandatory, the
    ///      only way to meet an unset one is a deployment that is still being wired — and that
    ///      should say which wire is missing rather than revert as a call into an empty address.
    function getCircuitBreaker() public view returns (CircuitBreaker) {
        CircuitBreaker breaker = circuitBreaker;
        require(address(breaker) != address(0), "CIRCUIT_BREAKER_UNSET");
        return breaker;
    }

    // --- Core Logic ---

    /// @inheritdoc IPositionManager
    function deposit(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        address borrowAsset
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 positionId)
    {
        require(lpToken != address(0), "ZERO_LP_TOKEN");
        require(amount > 0 || tokenId > 0, "ZERO_AMOUNT");
        require(core.pools(borrowAsset) != address(0), "INVALID_POOL");

        // Auto-detect LP type by querying each registered adapter
        ILPAdapter.LPType lpType = _detectLPType(lpToken);

        // Validate this collateral type is enabled in the shared-pool risk registry.
        // RiskManager is mandatory here: it is the source of truth for collateral risk, and the
        // health-factor / liquidation-bonus paths hard-require it. Accepting a deposit without it
        // would create a position that cannot later be valued or liquidated correctly.
        require(_collateralConfig(lpType).enabled, "COLLATERAL_NOT_ENABLED");

        // Validate oracle is healthy before accepting deposit
        require(oracleHub.isOracleHealthy(lpType), "ORACLE_UNHEALTHY");

        address adapterAddr = core.adapters(lpType);
        require(adapterAddr != address(0), "NO_ADAPTER");

        ILPAdapter adapter = ILPAdapter(adapterAddr);

        // Validate and lock the LP position
        ILPAdapter.LPInfo memory info = adapter.validateAndLock(lpToken, tokenId, amount, msg.sender);

        // Verify pool is whitelisted and not circuit-broken
        require(core.isPoolSupported(info.pool), "POOL_NOT_SUPPORTED");
        CircuitBreaker breaker = getCircuitBreaker();
        require(!breaker.poolPaused(info.pool), "POOL_CIRCUIT_BREAKER");
        require(!breaker.collateralFrozen(lpType), "COLLATERAL_FROZEN");

        // Get oracle price to validate position has value
        ILPOracleHub.PriceResult memory price = oracleHub.getPrice(lpToken, tokenId, amount, lpType);
        // Under principal-only valuation, totalValue == principalValue, so this also rejects
        // liquidity-less (fee-only) V3 positions as collateral.
        require(price.totalValue > 0, "ZERO_VALUE");

        // RiskManager: validate deposit caps
        {
            address rmAddr = core.riskManagerAddr();
            if (rmAddr != address(0)) {
                RiskManager rm = RiskManager(rmAddr);
                (bool valid, string memory reason) =
                    rm.validateDeposit(price.totalValue, borrowAsset, activePositionCount[msg.sender]);
                require(valid, reason);
                rm.recordDeposit(price.totalValue, borrowAsset);
            }
        }

        // Create position
        positionId = nextPositionId++;
        _positions[positionId] = Position({
            id: positionId,
            owner: msg.sender,
            lpToken: lpToken,
            tokenId: tokenId,
            amount: amount,
            lpType: lpType,
            pool: info.pool,
            token0: info.token0,
            token1: info.token1,
            borrowAsset: borrowAsset,
            status: PositionStatus.Active,
            depositTimestamp: block.timestamp,
            depositBlock: block.number
        });

        _ownerPositions[msg.sender].push(positionId);
        activePositionCount[msg.sender]++;

        emit PositionCreated(positionId, msg.sender, borrowAsset, lpToken, tokenId, lpType, price.totalValue);
    }

    /// @inheritdoc IPositionManager
    function withdraw(uint256 positionId) external whenNotPaused nonReentrant positionExists(positionId) {
        Position storage pos = _positions[positionId];
        require(_isOwnerOrActiveTransformer(positionId, msg.sender), "NOT_POSITION_OWNER");
        require(positionDebt[positionId] == 0, "HAS_DEBT");
        require(pos.status == PositionStatus.Active, "NOT_ACTIVE");

        // Defense-in-depth: also check live debt from LendingEngine
        if (address(lendingEngine) != address(0)) {
            require(lendingEngine.getDebt(positionId) == 0, "HAS_LIVE_DEBT");
        }

        address adapterAddr = core.adapters(pos.lpType);
        require(adapterAddr != address(0), "ADAPTER_NOT_FOUND");

        // RiskManager: track withdrawal for supply cap
        {
            address rmAddr = core.riskManagerAddr();
            if (rmAddr != address(0)) {
                uint256 posValue = getPositionValue(positionId);
                RiskManager(rmAddr).recordWithdraw(posValue, pos.borrowAsset);
            }
        }

        // CEI: update state BEFORE external call
        // Use pos.owner for accounting — msg.sender may be a transformer during transform()
        address owner = pos.owner;
        pos.status = PositionStatus.Closed;
        if (activePositionCount[owner] > 0) activePositionCount[owner]--;
        emit PositionClosed(positionId, owner);

        // Unlock LP via adapter — always send to position owner, not msg.sender
        ILPAdapter(adapterAddr).unlock(pos.lpToken, pos.tokenId, pos.amount, owner);
    }

    /// @inheritdoc IPositionManager
    /// @dev Pulls token0/token1 from user, forwards to adapter which adds liquidity.
    ///      For V2: new LP tokens are minted → pos.amount increases.
    ///      For V3: NFT liquidity increases in same tick range → pos.amount unchanged (liquidity in NFT).
    ///      Unused tokens (dust from price ratio mismatch) are refunded to the user.
    function addCollateral(
        uint256 positionId,
        uint256 amount0,
        uint256 amount1,
        uint256 minAmount0Used,
        uint256 minAmount1Used
    )
        external
        whenNotPaused
        nonReentrant
        positionExists(positionId)
    {
        Position storage pos = _positions[positionId];
        require(_isOwnerOrActiveTransformer(positionId, msg.sender), "NOT_POSITION_OWNER");
        require(pos.status == PositionStatus.Active || pos.status == PositionStatus.Borrowed, "POSITION_NOT_BORROWABLE");
        require(amount0 > 0 || amount1 > 0, "ZERO_AMOUNTS");

        // Frozen collateral types block new collateral (risk-taking)
        require(!getCircuitBreaker().collateralFrozen(pos.lpType), "COLLATERAL_FROZEN");

        address adapterAddr = core.adapters(pos.lpType);
        require(adapterAddr != address(0), "ADAPTER_NOT_FOUND");

        // Snapshot pre-change value for RiskManager delta tracking
        uint256 valueBefore = getPositionValue(positionId);

        // Pull tokens from user to adapter (balance-delta to measure actual received)
        uint256 adapterBal0Before = IERC20(pos.token0).balanceOf(adapterAddr);
        uint256 adapterBal1Before = IERC20(pos.token1).balanceOf(adapterAddr);

        if (amount0 > 0) {
            OZIERC20(pos.token0).safeTransferFrom(msg.sender, adapterAddr, amount0);
        }
        if (amount1 > 0) {
            OZIERC20(pos.token1).safeTransferFrom(msg.sender, adapterAddr, amount1);
        }

        uint256 received0 = IERC20(pos.token0).balanceOf(adapterAddr) - adapterBal0Before;
        uint256 received1 = IERC20(pos.token1).balanceOf(adapterAddr) - adapterBal1Before;

        // Adapter adds liquidity to the position (unused tokens refunded to user)
        (uint256 addedLiquidity, uint256 used0, uint256 used1) = ILPAdapter(adapterAddr)
            .addLiquidity(pos.lpToken, pos.tokenId, pos.token0, pos.token1, received0, received1, msg.sender);

        require(addedLiquidity > 0, "ZERO_LIQUIDITY_ADDED");
        require(used0 >= minAmount0Used, "SLIPPAGE_AMOUNT0");
        require(used1 >= minAmount1Used, "SLIPPAGE_AMOUNT1");

        // For V2: LP tokens were minted → increase stored amount
        if (pos.lpType == ILPAdapter.LPType.UniswapV2 || pos.lpType == ILPAdapter.LPType.PancakeSwapV2) {
            pos.amount += addedLiquidity;
            require(pos.amount <= type(uint128).max, "AMOUNT_OVERFLOW");
        }
        // For V3: liquidity is inside the NFT — oracle reads it directly, no amount update

        // RiskManager: enforce position value cap and track supply delta
        // Note: skip maxPositionsPerUser check (not creating a new position)
        {
            address rmAddr = core.riskManagerAddr();
            if (rmAddr != address(0)) {
                RiskManager rm = RiskManager(rmAddr);
                uint256 valueAfter = getPositionValue(positionId);
                require(valueAfter <= rm.maxPositionValue(), "POSITION_TOO_LARGE");
                uint256 delta = valueAfter > valueBefore ? valueAfter - valueBefore : 0;
                if (delta > 0) {
                    rm.recordDeposit(delta, pos.borrowAsset);
                }
            }
        }

        emit CollateralAdded(positionId, addedLiquidity, used0, used1);
    }

    /// @notice Remove partial collateral from an LP position
    /// @dev Decreases liquidity and sends underlying tokens to msg.sender.
    ///      Auth: position owner or active transformer (during transform() call).
    ///      Post-check: if position has debt, health factor must remain >= 1.0.
    ///      For V2: pos.amount is reduced. For V3: liquidity lives in the NFT.
    /// @param positionId The position to remove collateral from
    /// @param liquidity Amount of liquidity units to remove
    /// @param minAmount0 Minimum token0 to receive (slippage protection)
    /// @param minAmount1 Minimum token1 to receive (slippage protection)
    /// @return amount0 Actual token0 received
    /// @return amount1 Actual token1 received
    function removeCollateral(
        uint256 positionId,
        uint128 liquidity,
        uint256 minAmount0,
        uint256 minAmount1
    )
        external
        whenNotPaused
        nonReentrant
        positionExists(positionId)
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage pos = _positions[positionId];
        require(_isOwnerOrActiveTransformer(positionId, msg.sender), "NOT_POSITION_OWNER");
        require(pos.status == PositionStatus.Active || pos.status == PositionStatus.Borrowed, "POSITION_NOT_ACTIVE");
        require(liquidity > 0, "ZERO_LIQUIDITY");

        address adapterAddr = core.adapters(pos.lpType);
        require(adapterAddr != address(0), "ADAPTER_NOT_FOUND");

        // Circuit breaker: block collateral removal on frozen collateral types (oracle may be manipulated)
        require(!getCircuitBreaker().collateralFrozen(pos.lpType), "COLLATERAL_FROZEN");

        // Validate liquidity bounds before calling adapter
        if (pos.lpType == ILPAdapter.LPType.UniswapV2 || pos.lpType == ILPAdapter.LPType.PancakeSwapV2) {
            require(uint256(liquidity) <= pos.amount, "EXCEEDS_POSITION_AMOUNT");
        } else {
            uint128 currentLiquidity = ILPAdapter(adapterAddr).getLiquidity(pos.lpToken, pos.tokenId, pos.amount);
            require(liquidity <= currentLiquidity, "EXCEEDS_AVAILABLE_LIQUIDITY");
        }

        // Snapshot pre-change value for RiskManager delta tracking
        uint256 valueBefore;
        address rmAddr = core.riskManagerAddr();
        if (rmAddr != address(0)) {
            valueBefore = getPositionValue(positionId);
        }

        // Remove liquidity — tokens sent to msg.sender (owner or transformer)
        (amount0, amount1) = ILPAdapter(adapterAddr).removeLiquidity(pos.lpToken, pos.tokenId, liquidity, msg.sender);

        require(amount0 >= minAmount0, "SLIPPAGE_AMOUNT0");
        require(amount1 >= minAmount1, "SLIPPAGE_AMOUNT1");

        // For V2: reduce stored LP amount
        if (pos.lpType == ILPAdapter.LPType.UniswapV2 || pos.lpType == ILPAdapter.LPType.PancakeSwapV2) {
            pos.amount -= uint256(liquidity);
        }

        // RiskManager: track withdrawal for supply cap accounting
        if (rmAddr != address(0)) {
            uint256 valueAfter = getPositionValue(positionId);
            uint256 delta = valueBefore > valueAfter ? valueBefore - valueAfter : 0;
            if (delta > 0) {
                RiskManager(rmAddr).recordWithdraw(delta, pos.borrowAsset);
            }
        }

        // Health check: if position has debt, must remain solvent
        if (pos.status == PositionStatus.Borrowed) {
            require(address(lendingEngine) != address(0), "LENDING_ENGINE_NOT_SET");
            uint256 hf = this.getHealthFactor(positionId);
            require(hf >= 1e18, "UNHEALTHY_AFTER_REMOVAL");
        }

        emit CollateralRemoved(positionId, liquidity, amount0, amount1);
    }

    // --- Transform (periphery contract delegation) ---

    /// @notice Execute a transformation on a position via a whitelisted transformer contract.
    /// @dev Gateway for periphery contracts (LeverageTransformer, CompoundSwapRouter) to act
    ///      on user positions. The transformer is temporarily authorized to call addCollateral/removeCollateral/withdraw
    ///      on the specified position during this call — authorization is revoked after.
    ///
    ///      Security model (Revert Lend pattern):
    ///        1. Transformer must be admin-whitelisted (TRANSFORMER role in ACLManager)
    ///        2. Caller must be the position owner
    ///        3. Authorization is transient — only active during this call
    ///        4. Health check after transformation — ensures position is still solvent
    ///        5. Reentrancy blocked — transformedPositionId must be 0 on entry
    ///
    /// @param positionId The position to transform
    /// @param transformer The whitelisted transformer contract to call
    /// @param data Calldata to forward to the transformer
    function transform(
        uint256 positionId,
        address transformer,
        bytes calldata data
    )
        external
        whenNotPaused
        positionExists(positionId)
    {
        Position storage pos = _positions[positionId];
        require(pos.owner == msg.sender, "NOT_POSITION_OWNER");
        require(_acl().isTransformer(transformer), "NOT_TRANSFORMER");
        require(transformedPositionId == 0, "TRANSFORM_IN_PROGRESS");

        // Set transient authorization — only THIS transformer, only THIS position
        transformedPositionId = positionId;
        activeTransformer = transformer;

        // Call the transformer
        (bool success, bytes memory result) = transformer.call(data);
        if (!success) {
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert("TRANSFORM_FAILED");
        }

        // Revoke authorization
        transformedPositionId = 0;
        activeTransformer = address(0);

        // Defense-in-depth: verify position is still healthy after transformation
        // (skip if position was closed during transform — e.g., full deleverage)
        if (pos.status == PositionStatus.Borrowed && address(lendingEngine) != address(0)) {
            uint256 hf = this.getHealthFactor(positionId);
            require(hf >= 1e18, "UNHEALTHY_AFTER_TRANSFORM");
        }

        emit PositionTransformed(positionId, transformer);
    }

    // --- State Updates (role-based access) ---

    /// @notice Update position debt (called by LendingEngine)
    function updateDebt(
        uint256 positionId,
        uint256 newDebt
    )
        external
        onlyLendingEngine
        nonReentrant
        positionExists(positionId)
    {
        Position storage pos = _positions[positionId];
        require(pos.status == PositionStatus.Active || pos.status == PositionStatus.Borrowed, "POSITION_NOT_BORROWABLE");

        positionDebt[positionId] = newDebt;
        if (newDebt > 0 && pos.status == PositionStatus.Active) {
            pos.status = PositionStatus.Borrowed;
        } else if (newDebt == 0 && pos.status == PositionStatus.Borrowed) {
            // Debt cleared → transition to Active. Final status (Closed/Liquidated)
            // is set by withdraw() or markLiquidated(), not here.
            pos.status = PositionStatus.Active;
        }
    }

    /// @notice Reduce position amount after partial liquidation (called by LiquidationEngine)
    function reducePositionAmount(
        uint256 positionId,
        uint256 amountRemoved
    )
        external
        onlyLiquidationEngine
        nonReentrant
        positionExists(positionId)
    {
        Position storage pos = _positions[positionId];
        require(amountRemoved > 0, "ZERO_AMOUNT");
        require(amountRemoved <= pos.amount, "EXCEEDS_POSITION_AMOUNT");
        pos.amount -= amountRemoved;
        emit PositionAmountReduced(positionId, amountRemoved, pos.amount);
    }

    /// @notice Mark position as liquidated (called by LiquidationEngine)
    function markLiquidated(
        uint256 positionId,
        address liquidator,
        uint256 debtRepaid
    )
        external
        onlyLiquidationEngine
        nonReentrant
        positionExists(positionId)
    {
        require(liquidator != address(0), "ZERO_LIQUIDATOR");
        Position storage pos = _positions[positionId];
        require(pos.status == PositionStatus.Borrowed || pos.status == PositionStatus.Active, "NOT_LIQUIDATABLE_STATUS");
        pos.status = PositionStatus.Liquidated;
        positionDebt[positionId] = 0;
        if (activePositionCount[pos.owner] > 0) activePositionCount[pos.owner]--;
        emit PositionLiquidated(positionId, liquidator, debtRepaid);
    }

    /// @inheritdoc IPositionManager
    function recordCollateralSeized(
        uint256 positionId,
        uint256 valueUsd
    )
        external
        onlyLiquidationEngine
        positionExists(positionId)
    {
        if (valueUsd == 0) return;
        address rmAddr = core.riskManagerAddr();
        if (rmAddr != address(0)) {
            RiskManager(rmAddr).recordWithdraw(valueUsd, _positions[positionId].borrowAsset);
        }
    }

    // --- View Functions ---

    /// @inheritdoc IPositionManager
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return _positions[positionId];
    }

    /// @inheritdoc IPositionManager
    /// @dev Returns ALL position IDs including closed/liquidated ones.
    ///      Use getActivePositionsByOwner() for only active/borrowed positions.
    ///      We don't remove IDs on close/liquidate to avoid O(n) array shifts on every withdrawal.
    function getPositionsByOwner(address posOwner) external view returns (uint256[] memory) {
        return _ownerPositions[posOwner];
    }

    /// @notice Get only active/borrowed position IDs for an owner
    /// @dev Filters _ownerPositions — gas cost scales with total positions ever created.
    ///      Use for off-chain queries. On-chain callers should use activePositionCount for count.
    function getActivePositionsByOwner(address posOwner) external view returns (uint256[] memory) {
        uint256[] storage all = _ownerPositions[posOwner];
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            PositionStatus s = _positions[all[i]].status;
            if (s == PositionStatus.Active || s == PositionStatus.Borrowed) count++;
        }
        uint256[] memory result = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < all.length; i++) {
            PositionStatus s = _positions[all[i]].status;
            if (s == PositionStatus.Active || s == PositionStatus.Borrowed) {
                result[idx++] = all[i];
            }
        }
        return result;
    }

    /// @inheritdoc IPositionManager
    function getPositionValue(uint256 positionId) public view returns (uint256) {
        Position memory pos = _positions[positionId];
        if (pos.owner == address(0)) return 0;
        ILPOracleHub.PriceResult memory price = oracleHub.getPrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType);
        return price.totalValue;
    }

    /// @inheritdoc IPositionManager
    function getHealthFactor(uint256 positionId) external view returns (uint256) {
        require(positionId < nextPositionId && _positions[positionId].owner != address(0), "POSITION_NOT_FOUND");
        require(address(lendingEngine) != address(0), "LENDING_ENGINE_NOT_SET");
        uint256 debt = lendingEngine.getDebt(positionId);
        if (debt == 0) return type(uint256).max;

        uint256 collateralValue = getPositionValue(positionId);
        if (collateralValue == 0) return 0;

        Position memory pos = _positions[positionId];
        address borrowAsset = pos.borrowAsset;

        // Read collateral risk params (liquidationThreshold + haircut) from RiskManager by lpType.
        RiskManager.CollateralConfig memory cc = _collateralConfig(pos.lpType);

        // Apply haircut to collateral value (discount applied in bps; 0 = none)
        if (cc.haircut > 0) {
            collateralValue = Math.mulDiv(collateralValue, 10_000 - cc.haircut, 10_000);
            if (collateralValue == 0) return 0;
        }

        // Convert debt from borrow asset decimals to 18-dec USD value (Aave-style)
        // Always through the registry — see LendingEngine._toUsd. A guessed debt value here is a
        // guessed health factor, which is the number liquidation is gated on.
        uint8 borrowDecimals = TokenUtils.safeDecimals(borrowAsset);
        uint256 debtUsd = PriceFeedRegistry(core.getPriceFeedRegistry()).getUsdValue(borrowAsset, debt, borrowDecimals);

        if (debtUsd == 0) return type(uint256).max;
        uint256 numerator = Math.mulDiv(collateralValue, cc.liquidationThreshold, 10_000);
        return Math.mulDiv(numerator, 1e18, debtUsd);
    }

    /// @notice Get the block number at which a position was deposited (used for borrow cooldown)
    /// @param positionId The position to query
    /// @return The block number of the deposit
    function getDepositBlock(uint256 positionId) external view returns (uint256) {
        return _positions[positionId].depositBlock;
    }

    event FeesCompoundedInternal(uint256 indexed positionId, uint256 fees0, uint256 fees1, uint256 addedLiquidity);

    /// @notice Collect fees and reinvest as liquidity (called by LPCompounder)
    /// @dev Permissionless via LPCompounder. PositionManager mediates adapter access.
    /// @param params CompoundFeesParams struct with positionId, fee recipients, bps, threshold, etc.
    /// @return fees0 Total fees collected in token0
    /// @return fees1 Total fees collected in token1
    /// @return addedLiquidity Liquidity added back to position
    function compoundFees(IPositionManager.CompoundFeesParams calldata params)
        external
        whenNotPaused
        nonReentrant
        positionExists(params.positionId)
        returns (uint256 fees0, uint256 fees1, uint256 addedLiquidity)
    {
        // Access: only keeper or pool admin (LPCompounder has KEEPER role)
        require(_acl().isKeeper(msg.sender) || _acl().isPoolAdmin(msg.sender), "NOT_AUTHORIZED");

        // Validate inputs. Total fee is bounded to 5% to limit how much a KEEPER can
        // redirect from an arbitrary position's collected fees (griefing/theft bound).
        // Legitimate callers (LPCompounder, CompoundSwapRouter) use 2.5% total.
        require(params.protocolFeeBps + params.callerRewardBps <= MAX_COMPOUND_FEE_BPS, "FEES_TOO_HIGH");
        require(params.protocolFeeBps == 0 || params.protocolFeeRecipient != address(0), "ZERO_FEE_RECIPIENT");
        require(params.dustRefundTo != address(0), "ZERO_REFUND_ADDRESS");

        Position storage pos = _positions[params.positionId];
        require(pos.status == PositionStatus.Active || pos.status == PositionStatus.Borrowed, "POSITION_NOT_ACTIVE");

        address adapterAddr = core.adapters(pos.lpType);
        require(adapterAddr != address(0), "NO_ADAPTER");
        ILPAdapter adapter = ILPAdapter(adapterAddr);

        // Snapshot value before compounding so we can record the reinvested principal delta.
        uint256 valueBefore = getPositionValue(params.positionId);

        // Step 1: Collect fees from NFT → tokens to this contract
        (fees0, fees1) = adapter.collectFees(pos.lpToken, pos.tokenId);
        if (fees0 == 0 && fees1 == 0) return (0, 0, 0);

        // Step 1b: Threshold check — revert so fee collection is rolled back when not worth compounding
        require(fees0 >= params.minFeeThreshold || fees1 >= params.minFeeThreshold, "BELOW_MIN_FEE_THRESHOLD");

        // Distribute fees and reinvest
        CompoundParams memory cp = CompoundParams({
            token0: pos.token0,
            token1: pos.token1,
            lpToken: pos.lpToken,
            tokenId: pos.tokenId,
            adapterAddr: adapterAddr,
            fees0: fees0,
            fees1: fees1,
            protocolFeeRecipient: params.protocolFeeRecipient,
            protocolFeeBps: params.protocolFeeBps,
            callerRewardRecipient: params.callerRewardRecipient,
            callerRewardBps: params.callerRewardBps,
            dustRefundTo: params.dustRefundTo,
            maxSlippageBps: params.maxSlippageBps
        });
        addedLiquidity = _distributeFees(adapter, cp);

        // Compounding reinvests the position's own fees into principal, growing the market's
        // tracked collateral. Record the delta so RiskManager.marketCurrentSupply stays accurate
        // (track-only — not cap-enforced; see RiskManager.recordCompoundReinvest).
        {
            address rmAddr = core.riskManagerAddr();
            if (rmAddr != address(0)) {
                uint256 valueAfter = getPositionValue(params.positionId);
                uint256 delta = valueAfter > valueBefore ? valueAfter - valueBefore : 0;
                if (delta > 0) RiskManager(rmAddr).recordCompoundReinvest(delta, pos.borrowAsset);
            }
        }

        emit FeesCompoundedInternal(params.positionId, fees0, fees1, addedLiquidity);
    }

    /// @dev Internal: distribute protocol fee + caller reward, reinvest remainder.
    ///      Uses CompoundParams struct to avoid stack-too-deep.
    function _distributeFees(ILPAdapter adapter, CompoundParams memory cp) internal returns (uint256 addedLiquidity) {
        uint256 totalDeducted0;
        uint256 totalDeducted1;

        // Protocol fee → FeeCollector (via collectFee so accumulatedFees is tracked)
        if (cp.protocolFeeBps > 0 && cp.protocolFeeRecipient != address(0)) {
            uint256 pFee0 = Math.mulDiv(cp.fees0, cp.protocolFeeBps, 10_000);
            uint256 pFee1 = Math.mulDiv(cp.fees1, cp.protocolFeeBps, 10_000);
            if (pFee0 > 0) {
                OZIERC20(cp.token0).forceApprove(cp.protocolFeeRecipient, pFee0);
                FeeCollector(cp.protocolFeeRecipient).collectFee(cp.token0, pFee0, address(this), "compound");
            }
            if (pFee1 > 0) {
                OZIERC20(cp.token1).forceApprove(cp.protocolFeeRecipient, pFee1);
                FeeCollector(cp.protocolFeeRecipient).collectFee(cp.token1, pFee1, address(this), "compound");
            }
            totalDeducted0 += pFee0;
            totalDeducted1 += pFee1;
        }

        // Caller reward → whoever triggered the compound
        if (cp.callerRewardBps > 0 && cp.callerRewardRecipient != address(0)) {
            uint256 cReward0 = Math.mulDiv(cp.fees0, cp.callerRewardBps, 10_000);
            uint256 cReward1 = Math.mulDiv(cp.fees1, cp.callerRewardBps, 10_000);
            if (cReward0 > 0) OZIERC20(cp.token0).safeTransfer(cp.callerRewardRecipient, cReward0);
            if (cReward1 > 0) OZIERC20(cp.token1).safeTransfer(cp.callerRewardRecipient, cReward1);
            totalDeducted0 += cReward0;
            totalDeducted1 += cReward1;
        }

        // Reinvest remainder as liquidity
        uint256 reinvest0 = cp.fees0 - totalDeducted0;
        uint256 reinvest1 = cp.fees1 - totalDeducted1;

        if (reinvest0 > 0) OZIERC20(cp.token0).safeTransfer(cp.adapterAddr, reinvest0);
        if (reinvest1 > 0) OZIERC20(cp.token1).safeTransfer(cp.adapterAddr, reinvest1);

        uint256 used0;
        uint256 used1;
        (addedLiquidity, used0, used1) =
            adapter.addLiquidity(cp.lpToken, cp.tokenId, cp.token0, cp.token1, reinvest0, reinvest1, cp.dustRefundTo);

        // Slippage protection on reinvestment — revert if too much value lost to sandwich.
        // Check each side independently (V3 positions may only use one token at range edges).
        if (cp.maxSlippageBps > 0) {
            require(cp.maxSlippageBps <= 10_000, "SLIPPAGE_BPS_OVERFLOW");
            if (reinvest0 > 0) {
                require(used0 >= (reinvest0 * (10_000 - cp.maxSlippageBps)) / 10_000, "COMPOUND_SLIPPAGE_0");
            }
            if (reinvest1 > 0) {
                require(used1 >= (reinvest1 * (10_000 - cp.maxSlippageBps)) / 10_000, "COMPOUND_SLIPPAGE_1");
            }
        }
    }

    // --- New state vars (appended for UUPS upgrade safety) ---
    /// @dev Deprecated — priceFeedRegistry moved to ProtocolCore. Kept for UUPS storage layout.
    address private __deprecated_priceFeedRegistry;
    /// @dev Deprecated — riskManager moved to ProtocolCore. Kept for UUPS storage layout.
    address private __deprecated_riskManager;
    mapping(address => uint256) public activePositionCount;
    CircuitBreaker public circuitBreaker;

    // --- Storage Gap ---
    // 14 declared slots (0-13, incl. preserved __deprecated_* slots) + 44 gap slots = 58 total.
    // When appending a state var, decrement __gap by the slots it consumes so the total stays
    // 58 (UUPS storage-collision safety). Verified via `forge inspect ... storage-layout`.
    uint256[44] private __gap;

    // --- Internal ---

    /// @dev Read the collateral-risk config for an LP type from RiskManager (source of truth).
    function _collateralConfig(ILPAdapter.LPType lpType) internal view returns (RiskManager.CollateralConfig memory) {
        address rmAddr = core.riskManagerAddr();
        require(rmAddr != address(0), "RISK_MANAGER_NOT_SET");
        return RiskManager(rmAddr).getCollateralConfig(lpType);
    }

    function _detectLPType(address lpToken) internal view returns (ILPAdapter.LPType) {
        uint8 maxType = core.maxRegisteredLPType();
        for (uint8 i = 0; i <= maxType; i++) {
            ILPAdapter.LPType lt = ILPAdapter.LPType(i);
            address adapterAddr = core.adapters(lt);
            if (adapterAddr != address(0) && ILPAdapter(adapterAddr).isSupported(lpToken)) {
                return lt;
            }
        }
        revert("UNSUPPORTED_LP");
    }
}
