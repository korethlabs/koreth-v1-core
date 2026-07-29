// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ILendingEngine} from "../interfaces/ILendingEngine.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolCore} from "./ProtocolCore.sol";
import {ACLManager} from "./ACLManager.sol";
import {PriceFeedRegistry} from "../oracle/PriceFeedRegistry.sol";
import {PositionManager} from "./PositionManager.sol";
import {RiskManager} from "../security/RiskManager.sol";
import {CircuitBreaker} from "../security/CircuitBreaker.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

/// @title LendingEngine
/// @notice Handles borrowing against LP positions and repayment with interest
/// @dev UUPS upgradeable + reentrancy protected.
///      Interest accrual is delegated to Market (single source of truth).
///      LendingEngine reads Market.borrowIndex() for per-position debt calculation.
///
///      Important for integrators:
///      - getDebt() returns debt as of the last on-chain accrual, NOT real-time.
///        Call accrueInterest(marketId) first for up-to-date values.
///      - repay() is permissionless — anyone can repay any position's debt (payer = msg.sender).
///        This is intentional (same as Aave/Compound — generous repayment).
///      - repayOnBehalf() is restricted to LIQUIDATION_ENGINE role.
///      - borrowCooldownBlocks is chain-dependent: 50 blocks = ~10min on ETH, ~100s on L2s.
contract LendingEngine is ILendingEngine, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    ProtocolCore public core;
    PositionManager public positionManager;

    struct DebtInfo {
        uint256 principal;
        uint256 borrowIndex;
    }

    mapping(uint256 => DebtInfo) public debtInfo;

    uint256 public borrowCooldownBlocks = 1;
    uint256 public constant MIN_COOLDOWN = 1;
    uint256 public constant MAX_COOLDOWN = 50;

    /// @dev Deprecated — riskManager moved to ProtocolCore. Kept for UUPS storage layout.
    address private __deprecated_riskManager;

    event BorrowCooldownUpdated(uint256 oldValue, uint256 newValue);

    /// @notice Emitted when an underwater position's remaining debt is written off as bad debt.
    /// @param positionId The position whose debt was written off
    /// @param borrowAsset The shared pool (borrow asset) that absorbed the deficit
    /// @param amount The debt amount written off (borrow-asset decimals)
    /// @param caller The liquidation engine that triggered the write-off
    event DebtWrittenOff(uint256 indexed positionId, address indexed borrowAsset, uint256 amount, address caller);

    // --- ACL Helpers ---
    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier whenNotPaused() {
        require(!core.paused(), "PAUSED");
        _;
    }

    modifier onlyPoolAdmin() {
        require(_acl().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    modifier onlyLiquidationEngine() {
        require(_acl().isLiquidationEngine(msg.sender), "NOT_LIQUIDATION_ENGINE");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _core, address _positionManager) external initializer {
        require(_core != address(0) && _positionManager != address(0), "ZERO_ADDRESS");
        core = ProtocolCore(_core);
        positionManager = PositionManager(_positionManager);
        borrowCooldownBlocks = 1;
    }

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

    /// @notice Set borrow cooldown (blocks after deposit before borrowing allowed)
    function setBorrowCooldown(uint256 _blocks) external onlyPoolAdmin {
        require(_blocks >= MIN_COOLDOWN && _blocks <= MAX_COOLDOWN, "OUT_OF_BOUNDS");
        emit BorrowCooldownUpdated(borrowCooldownBlocks, _blocks);
        borrowCooldownBlocks = _blocks;
    }

    // --- Core Logic ---

    /// @inheritdoc ILendingEngine
    function borrow(uint256 positionId, uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "ZERO_AMOUNT");

        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        // Allow owner or the specific active transformer (during PositionManager.transform() call)
        require(
            pos.owner == msg.sender
                || (positionManager.transformedPositionId() == positionId
                    && msg.sender == positionManager.activeTransformer()),
            "NOT_POSITION_OWNER"
        );
        require(
            pos.status != IPositionManager.PositionStatus.Liquidated
                && pos.status != IPositionManager.PositionStatus.Closed,
            "POSITION_NOT_ACTIVE"
        );

        // Circuit breaker: no new borrows against paused pools or frozen collateral types
        CircuitBreaker cb = positionManager.circuitBreaker();
        if (address(cb) != address(0)) {
            require(!cb.poolPaused(pos.pool), "POOL_CIRCUIT_BREAKER");
            require(!cb.collateralFrozen(pos.lpType), "COLLATERAL_FROZEN");
        }

        require(block.number > pos.depositBlock + borrowCooldownBlocks, "BORROW_COOLDOWN");

        address poolAddr = _getPoolAddr(pos.borrowAsset);
        ILendingPool pool = ILendingPool(poolAddr);
        pool.accrueInterest();

        uint256 currentDebt = _getCurrentDebt(positionId, pool);
        uint256 newTotalDebt = currentDebt + amount;
        uint256 maxBorrow = _getMaxBorrow(positionId, pos.borrowAsset, pos.lpType);
        require(newTotalDebt <= maxBorrow, "EXCEEDS_MAX_LTV");

        // RiskManager: validate caps (all in 18-dec USD)
        {
            address rmAddr = core.riskManagerAddr();
            if (rmAddr != address(0)) {
                uint256 positionValue = positionManager.getPositionValue(positionId);
                uint256 amountUsd = _toUsd(amount, pos.borrowAsset);
                (bool valid, string memory reason) =
                    RiskManager(rmAddr).validateAndRecordBorrow(amountUsd, positionValue, pos.lpType);
                require(valid, reason);
            }
        }

        uint256 currentBorrowIndex = pool.borrowIndex();
        require(currentBorrowIndex > 0, "POOL_NOT_INITIALIZED");
        debtInfo[positionId] = DebtInfo({principal: newTotalDebt, borrowIndex: currentBorrowIndex});

        positionManager.updateDebt(positionId, newTotalDebt);

        pool.transferOut(msg.sender, amount);

        emit Borrowed(positionId, msg.sender, amount, newTotalDebt);
    }

    /// @inheritdoc ILendingEngine
    function repay(uint256 positionId, uint256 amount) external whenNotPaused nonReentrant {
        _repayInternal(positionId, amount, msg.sender);
    }

    /// @notice Repay debt on behalf of a borrower (used by LiquidationEngine)
    function repayOnBehalf(
        uint256 positionId,
        uint256 repayAmount
    )
        external
        whenNotPaused
        onlyLiquidationEngine
        nonReentrant
    {
        _repayInternal(positionId, repayAmount, msg.sender);
    }

    // --- View ---

    /// @inheritdoc ILendingEngine
    function getDebt(uint256 positionId) external view returns (uint256) {
        if (debtInfo[positionId].principal == 0) return 0;
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        address poolAddr = _getPoolAddr(pos.borrowAsset);
        return _getCurrentDebt(positionId, ILendingPool(poolAddr));
    }

    /// @inheritdoc ILendingEngine
    function getMaxBorrow(uint256 positionId) external view returns (uint256) {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        return _getMaxBorrow(positionId, pos.borrowAsset, pos.lpType);
    }

    /// @inheritdoc ILendingEngine
    function accrueInterest(address borrowAsset) public {
        address poolAddr = _getPoolAddr(borrowAsset);
        ILendingPool(poolAddr).accrueInterest();
    }

    // --- Internal ---

    function _repayInternal(uint256 positionId, uint256 amount, address payer) internal {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);

        address poolAddr = _getPoolAddr(pos.borrowAsset);
        ILendingPool pool = ILendingPool(poolAddr);
        pool.accrueInterest();

        uint256 currentDebt = _getCurrentDebt(positionId, pool);
        require(currentDebt > 0, "NO_DEBT");

        uint256 repayAmount = amount == type(uint256).max ? currentDebt : amount;
        require(repayAmount > 0, "ZERO_AMOUNT");
        require(repayAmount <= currentDebt, "REPAY_EXCEEDS_DEBT");

        uint256 remainingDebt = currentDebt - repayAmount;

        debtInfo[positionId] = DebtInfo({principal: remainingDebt, borrowIndex: pool.borrowIndex()});

        positionManager.updateDebt(positionId, remainingDebt);

        pool.transferIn(payer, repayAmount);

        // RiskManager: track repayment (18-dec USD)
        {
            address rmAddr = core.riskManagerAddr();
            if (rmAddr != address(0)) {
                uint256 repayUsd = _toUsd(repayAmount, pos.borrowAsset);
                RiskManager(rmAddr).recordRepay(repayUsd, pos.lpType);
            }
        }

        emit Repaid(positionId, payer, repayAmount, remainingDebt);
    }

    function _getCurrentDebt(uint256 positionId, ILendingPool pool) internal view returns (uint256) {
        DebtInfo memory info = debtInfo[positionId];
        if (info.principal == 0) return 0;

        uint256 currentIndex = pool.borrowIndex();
        require(currentIndex > 0 && info.borrowIndex > 0, "INDEX_ZERO");

        return Math.mulDiv(info.principal, currentIndex, info.borrowIndex);
    }

    /// @notice Calculate max borrow in borrow asset decimals
    /// @dev maxLtv + haircut sourced from RiskManager per lpType (shared-pool model).
    function _getMaxBorrow(
        uint256 positionId,
        address borrowAsset,
        ILPAdapter.LPType lpType
    )
        internal
        view
        returns (uint256)
    {
        uint256 collateralValue = positionManager.getPositionValue(positionId);

        uint256 maxLtv;
        uint256 haircut;
        {
            address rmAddr = core.riskManagerAddr();
            if (rmAddr != address(0)) {
                RiskManager.CollateralConfig memory cc = RiskManager(rmAddr).getCollateralConfig(lpType);
                maxLtv = cc.maxLtv;
                haircut = cc.haircut;
            }
        }

        // Apply haircut to collateral value (discount in bps; 0 = none)
        if (haircut > 0) {
            collateralValue = Math.mulDiv(collateralValue, 10_000 - haircut, 10_000);
        }
        uint256 maxBorrowUsd = (collateralValue * maxLtv) / 10_000;

        uint8 borrowDecimals = TokenUtils.safeDecimals(borrowAsset);

        PriceFeedRegistry registry = PriceFeedRegistry(core.priceFeedRegistryAddr());
        if (address(registry) != address(0)) {
            uint256 borrowAssetPrice = registry.getPrice(borrowAsset);
            require(borrowAssetPrice > 0, "ZERO_PRICE");
            return Math.mulDiv(maxBorrowUsd, 10 ** borrowDecimals, borrowAssetPrice);
        }
        if (borrowDecimals < 18) {
            return maxBorrowUsd / (10 ** (18 - borrowDecimals));
        } else if (borrowDecimals > 18) {
            return Math.mulDiv(maxBorrowUsd, 10 ** (borrowDecimals - 18), 1);
        }
        return maxBorrowUsd;
    }

    /// @notice Convert borrow asset amount to 18-dec USD
    /// @dev DEPLOY INVARIANT: when core.priceFeedRegistryAddr() is unset, every market's
    ///      borrowAsset MUST be a USD-pegged stablecoin (the decimal-only fallback prices it at
    ///      $1). To use a non-pegged borrow asset (e.g. WETH), a PriceFeedRegistry with a feed for
    ///      that asset MUST be configured first, otherwise debt/LTV/health-factor are mispriced.
    function _toUsd(uint256 amount, address borrowAsset) internal view returns (uint256) {
        uint8 dec = TokenUtils.safeDecimals(borrowAsset);
        PriceFeedRegistry registry = PriceFeedRegistry(core.priceFeedRegistryAddr());
        if (address(registry) != address(0)) {
            return registry.getUsdValue(borrowAsset, amount, dec);
        }
        // Fallback: normalize to 18 dec (assumes USD-pegged — see DEPLOY INVARIANT above)
        if (dec < 18) return Math.mulDiv(amount, 10 ** (18 - dec), 1);
        if (dec > 18) return amount / (10 ** (dec - 18));
        return amount;
    }

    function _getPoolAddr(address borrowAsset) internal view returns (address) {
        address poolAddr = core.pools(borrowAsset);
        require(poolAddr != address(0), "POOL_NOT_FOUND");
        return poolAddr;
    }

    /// @notice Write off bad debt from an underwater position (called by LiquidationEngine)
    /// @dev Zeros out the position's debt and records deficit on the shared pool
    function writeOffDebt(uint256 positionId) external whenNotPaused onlyLiquidationEngine nonReentrant {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        address poolAddr = _getPoolAddr(pos.borrowAsset);
        ILendingPool pool = ILendingPool(poolAddr);

        // Accrue interest to ensure borrowIndex is current before reading debt
        pool.accrueInterest();

        uint256 currentDebt = _getCurrentDebt(positionId, pool);
        require(currentDebt > 0, "NO_DEBT");

        // Zero out the position's debt tracking
        debtInfo[positionId] = DebtInfo({principal: 0, borrowIndex: pool.borrowIndex()});
        positionManager.updateDebt(positionId, 0);

        // Record deficit on the shared pool (burns from totalBorrow, tracks as deficit)
        pool.recordDeficit(currentDebt);

        // Update RiskManager to prevent ghost debt from blocking new borrows
        {
            address rmAddr = core.riskManagerAddr();
            if (rmAddr != address(0)) {
                uint256 debtUsd = _toUsd(currentDebt, pos.borrowAsset);
                RiskManager(rmAddr).recordRepay(debtUsd, pos.lpType);
            }
        }

        emit DebtWrittenOff(positionId, pos.borrowAsset, currentDebt, msg.sender);
    }

    // --- Storage Gap ---
    // 49 slots: layout unchanged (deprecated riskManager slot preserved for UUPS compatibility).
    uint256[49] private __gap;
}
