// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title RiskManager
/// @notice Enforces risk limits: position caps, borrow caps, supply caps
/// @dev Pure risk limits only — no LTV, no cooldown (those live in LendingEngine).
///      All amounts passed in 18-dec USD. Callers convert before calling.
///      Uses ACLManager: LENDING_ENGINE calls record*, RISK_ADMIN adjusts caps.
contract RiskManager {
    ProtocolCore public immutable core;

    // --- Position Limits ---
    uint256 public maxPositionsPerUser = 20;
    uint256 public maxPositionValue = 10_000_000e18; // $10M max single position

    // --- Borrow Caps (all in 18-dec USD) ---
    uint256 public globalBorrowCap = 100_000_000e18; // $100M total borrows
    uint256 public currentGlobalBorrows;
    mapping(ILPAdapter.LPType => uint256) public lpTypeCurrentBorrows;

    // --- Collateral registry (per LP type) ---
    // Single source of truth for collateral-risk params in the shared-pool model. All bps except
    // haircut (bps applied to collateral value) and borrowCap (18-dec USD). enabled gates deposits.
    struct CollateralConfig {
        uint256 maxLtv; // Max LTV in basis points (e.g. 6500 = 65%)
        uint256 liquidationThreshold; // Liquidation trigger in bps
        uint256 liquidationBonus; // Liquidator bonus in bps
        uint256 haircut; // Discount applied to collateral value in bps (0 = none)
        uint256 borrowCap; // Max USD borrowable against this collateral type (0 = uncapped)
        bool enabled; // Whether this collateral type may back new positions
    }

    mapping(ILPAdapter.LPType => CollateralConfig) public collateralConfig;

    // --- Supply Caps (per-market collateral cap, 18-dec USD) ---
    mapping(uint256 => uint256) public marketSupplyCap; // marketId → max collateral value
    mapping(uint256 => uint256) public marketCurrentSupply; // marketId → current collateral value

    // --- Events ---
    event GlobalBorrowCapUpdated(uint256 oldValue, uint256 newValue);
    event LPTypeBorrowCapUpdated(ILPAdapter.LPType indexed lpType, uint256 cap);
    event CollateralConfigSet(ILPAdapter.LPType indexed lpType);
    event MaxPositionValueUpdated(uint256 oldValue, uint256 newValue);
    event MaxPositionsPerUserUpdated(uint256 oldValue, uint256 newValue);
    event MarketSupplyCapUpdated(uint256 indexed marketId, uint256 oldValue, uint256 newValue);
    event BorrowTrackingDrift(uint256 tracked, uint256 repaid, bool isGlobal);
    event BorrowRecorded(uint256 amountUsd, uint256 newGlobalBorrows);
    event RepayRecorded(uint256 amountUsd, uint256 newGlobalBorrows);
    event DepositRecorded(uint256 valueUsd, uint256 indexed marketId, uint256 newMarketSupply);
    event WithdrawRecorded(uint256 valueUsd, uint256 indexed marketId, uint256 newMarketSupply);

    // --- ACL ---
    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyRiskAdmin() {
        ACLManager acl = _acl();
        require(acl.isRiskAdmin(msg.sender) || acl.isPoolAdmin(msg.sender), "NOT_RISK_ADMIN");
        _;
    }

    modifier onlyLendingEngine() {
        require(_acl().isLendingEngine(msg.sender), "NOT_LENDING_ENGINE");
        _;
    }

    modifier onlyPositionManager() {
        require(_acl().isPositionManager(msg.sender), "NOT_POSITION_MANAGER");
        _;
    }

    constructor(address _core) {
        require(_core != address(0), "ZERO_ADDRESS");
        core = ProtocolCore(_core);
    }

    // --- Borrow Validation (called by LendingEngine) ---

    /// @notice Validate a borrow request against risk caps
    /// @param borrowAmountUsd Borrow amount in 18-dec USD
    /// @notice Validate borrow caps AND atomically record the borrow.
    ///         Prevents TOCTOU: two borrows in the same block cannot both pass
    ///         validation before either records, since validation + recording is atomic.
    /// @param borrowAmountUsd Borrow amount in 18-dec USD
    /// @param positionValue Position value in 18-dec USD
    /// @param lpType LP type for per-type cap check
    function validateAndRecordBorrow(
        uint256 borrowAmountUsd,
        uint256 positionValue,
        ILPAdapter.LPType lpType
    )
        external
        onlyLendingEngine
        returns (bool valid, string memory reason)
    {
        // Check 1: Position value cap
        if (positionValue > maxPositionValue) {
            return (false, "POSITION_TOO_LARGE");
        }

        // Check 2: Global borrow cap
        if (currentGlobalBorrows + borrowAmountUsd > globalBorrowCap) {
            return (false, "GLOBAL_CAP_REACHED");
        }

        // Check 3: LP type borrow cap
        uint256 typeCap = collateralConfig[lpType].borrowCap;
        if (typeCap > 0 && lpTypeCurrentBorrows[lpType] + borrowAmountUsd > typeCap) {
            return (false, "LP_TYPE_CAP_REACHED");
        }

        // Atomically record the borrow (no gap between validate and record)
        currentGlobalBorrows += borrowAmountUsd;
        lpTypeCurrentBorrows[lpType] += borrowAmountUsd;
        emit BorrowRecorded(borrowAmountUsd, currentGlobalBorrows);

        return (true, "");
    }

    /// @notice Record a repayment for cap tracking (18-dec USD)
    /// @dev Clamped to prevent underflow when repay includes accrued interest.
    ///      ACCEPTED DRIFT: validateAndRecordBorrow records borrow PRINCIPAL, but repay/writeoff
    ///      subtract PRINCIPAL + accrued interest. So the borrow counters drift DOWNWARD over time
    ///      (caps only ever loosen, never trap a borrower). This is a soft risk limit — never a
    ///      funds-safety check — so we accept the drift rather than thread the principal/interest
    ///      split out of LendingEngine (same tradeoff as the supply-side drift in recordWithdraw).
    function recordRepay(uint256 amountUsd, ILPAdapter.LPType lpType) external onlyLendingEngine {
        if (amountUsd > currentGlobalBorrows) {
            emit BorrowTrackingDrift(currentGlobalBorrows, amountUsd, true);
            currentGlobalBorrows = 0;
        } else {
            currentGlobalBorrows -= amountUsd;
        }
        if (amountUsd > lpTypeCurrentBorrows[lpType]) {
            emit BorrowTrackingDrift(lpTypeCurrentBorrows[lpType], amountUsd, false);
            lpTypeCurrentBorrows[lpType] = 0;
        } else {
            lpTypeCurrentBorrows[lpType] -= amountUsd;
        }
        emit RepayRecorded(amountUsd, currentGlobalBorrows);
    }

    // --- Deposit Validation (called by PositionManager) ---

    /// @notice Validate a deposit against risk limits
    /// @param positionValue Position value in 18-dec USD
    /// @param marketId Market ID for supply cap
    /// @param userPositionCount Current number of positions the user has
    function validateDeposit(
        uint256 positionValue,
        uint256 marketId,
        uint256 userPositionCount
    )
        external
        view
        returns (bool valid, string memory reason)
    {
        // Check 1: Max positions per user
        if (userPositionCount >= maxPositionsPerUser) {
            return (false, "MAX_POSITIONS_REACHED");
        }

        // Check 2: Position value cap
        if (positionValue > maxPositionValue) {
            return (false, "POSITION_TOO_LARGE");
        }

        // Check 3: Market supply cap
        uint256 cap = marketSupplyCap[marketId];
        if (cap > 0 && marketCurrentSupply[marketId] + positionValue > cap) {
            return (false, "SUPPLY_CAP_REACHED");
        }

        return (true, "");
    }

    /// @notice Record a deposit for supply cap tracking (18-dec USD)
    /// @dev Enforces the market supply cap at the single choke point so EVERY value-in path
    ///      (deposit + addCollateral) is capped by construction — a caller cannot record a
    ///      supply increase that breaches the cap. cap == 0 means uncapped (Aave-style default).
    ///
    ///      DESIGN DECISION: addCollateral is INTENTIONALLY subject to this cap (it flows through
    ///      recordDeposit). This matches Aave V3, where supply() — the collateral-add path — is
    ///      blocked at the supply cap with no top-up exemption. Rationale: an at-cap market is at
    ///      its liquidatable-exposure budget; letting a single position grow past it via
    ///      addCollateral would reintroduce unbounded exposure. A borrower needing to restore
    ///      health in an at-cap market can always repay() (never blocked), so this is not a trap.
    function recordDeposit(uint256 valueUsd, uint256 marketId) external onlyPositionManager {
        uint256 cap = marketSupplyCap[marketId];
        uint256 newSupply = marketCurrentSupply[marketId] + valueUsd;
        require(cap == 0 || newSupply <= cap, "SUPPLY_CAP_REACHED");
        marketCurrentSupply[marketId] = newSupply;
        emit DepositRecorded(valueUsd, marketId, newSupply);
    }

    /// @notice Track supply added by compounding a position's own fees into principal (18-dec USD).
    /// @dev Unlike recordDeposit this does NOT enforce the market supply cap. Compounding reinvests
    ///      a position's OWN uncollected fees (permissionless, keeper-driven) — it is organic growth
    ///      of existing exposure, not new external capital, so it is tracked for accounting accuracy
    ///      but never blocked at the cap (blocking would strand fees and let anyone grief keepers by
    ///      pinning a market at its cap). Analogous to interest accrual pushing borrows past borrowCap.
    function recordCompoundReinvest(uint256 valueUsd, uint256 marketId) external onlyPositionManager {
        marketCurrentSupply[marketId] += valueUsd;
        emit DepositRecorded(valueUsd, marketId, marketCurrentSupply[marketId]);
    }

    event SupplyTrackingDrift(uint256 tracked, uint256 withdrawn, uint256 indexed marketId);

    /// @notice Record a withdrawal for supply cap tracking (18-dec USD)
    /// @dev ACCEPTED TRADEOFF (drift): deposits/withdrawals are recorded at the LIVE oracle USD
    ///      value at the time of each action. If collateral appreciates between deposit and
    ///      withdraw, the withdraw value exceeds the recorded deposit value and the counter is
    ///      clamped to 0 (drift surfaced via SupplyTrackingDrift). This only affects a SOFT risk
    ///      cap — never user funds — and self-corrects as positions fully close. A drift-free
    ///      design would require per-position recorded-value bookkeeping (deferred; not worth the
    ///      added storage/complexity for a soft limit).
    function recordWithdraw(uint256 valueUsd, uint256 marketId) external onlyPositionManager {
        if (valueUsd > marketCurrentSupply[marketId]) {
            emit SupplyTrackingDrift(marketCurrentSupply[marketId], valueUsd, marketId);
            marketCurrentSupply[marketId] = 0;
        } else {
            marketCurrentSupply[marketId] -= valueUsd;
        }
        emit WithdrawRecorded(valueUsd, marketId, marketCurrentSupply[marketId]);
    }

    // --- Admin (RISK_ADMIN) ---

    function setGlobalBorrowCap(uint256 cap) external onlyRiskAdmin {
        require(cap > 0, "ZERO_CAP");
        emit GlobalBorrowCapUpdated(globalBorrowCap, cap);
        globalBorrowCap = cap;
    }

    function setLPTypeBorrowCap(ILPAdapter.LPType lpType, uint256 cap) external onlyRiskAdmin {
        emit LPTypeBorrowCapUpdated(lpType, cap);
        collateralConfig[lpType].borrowCap = cap;
    }

    /// @notice Back-compat view — the per-LP-type borrow cap now lives in collateralConfig.
    function lpTypeBorrowCap(ILPAdapter.LPType lpType) external view returns (uint256) {
        return collateralConfig[lpType].borrowCap;
    }

    /// @notice Set the full collateral-risk config for an LP type (source of truth in the shared pool).
    function setCollateralConfig(ILPAdapter.LPType lpType, CollateralConfig calldata cfg) external onlyRiskAdmin {
        require(cfg.maxLtv <= cfg.liquidationThreshold, "LTV_GT_THRESHOLD");
        require(cfg.liquidationThreshold <= 10_000, "THRESHOLD_GT_100");
        require(cfg.haircut <= 10_000, "HAIRCUT_GT_100");
        collateralConfig[lpType] = cfg;
        emit CollateralConfigSet(lpType);
        emit LPTypeBorrowCapUpdated(lpType, cfg.borrowCap);
    }

    /// @notice Read the collateral-risk config for an LP type.
    function getCollateralConfig(ILPAdapter.LPType lpType) external view returns (CollateralConfig memory) {
        return collateralConfig[lpType];
    }

    function setMaxPositionValue(uint256 maxValue) external onlyRiskAdmin {
        require(maxValue > 0, "ZERO_VALUE");
        emit MaxPositionValueUpdated(maxPositionValue, maxValue);
        maxPositionValue = maxValue;
    }

    function setMaxPositionsPerUser(uint256 max) external onlyRiskAdmin {
        require(max >= 1, "AT_LEAST_ONE");
        emit MaxPositionsPerUserUpdated(maxPositionsPerUser, max);
        maxPositionsPerUser = max;
    }

    function setMarketSupplyCap(uint256 marketId, uint256 cap) external onlyRiskAdmin {
        emit MarketSupplyCapUpdated(marketId, marketSupplyCap[marketId], cap);
        marketSupplyCap[marketId] = cap;
    }
}
