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
    // haircut (bps applied to collateral value) and borrowCap (18-dec USD). enabled gates deposits
    // and new borrows.
    struct CollateralConfig {
        uint256 maxLtv; // Max LTV in basis points (e.g. 6500 = 65%)
        uint256 liquidationThreshold; // Liquidation trigger in bps
        uint256 liquidationBonus; // Liquidator bonus in bps
        uint256 haircut; // Discount applied to collateral value in bps (0 = none)
        uint256 borrowCap; // Max USD borrowable against this collateral type — see NO_BORROW_CAP
        bool enabled; // Whether this collateral type may back new positions/borrows
    }

    /// @notice Upper bounds on collateral params. Ceilings (not 10_000) so a misconfigured type
    ///         cannot be made instantly liquidatable or hand liquidators an unbounded bonus.
    uint256 public constant MAX_LTV_BPS = 9500;
    uint256 public constant MAX_LIQUIDATION_THRESHOLD_BPS = 9800;
    uint256 public constant MAX_LIQUIDATION_BONUS_BPS = 1500;
    /// @notice A haircut this large would zero collateral value and mark every position of the
    ///         type liquidatable at once, so it is bounded well below 100%.
    uint256 public constant MAX_HAIRCUT_BPS = 5000;

    /// @notice Sentinel for "no borrow cap" on a collateral type.
    /// @dev borrowCap is deliberately restrictive-by-default: 0 blocks ALL borrowing against the
    ///      type. The per-collateral cap is the blast-radius control for the shared pool (ADR-001),
    ///      so a forgotten or default-constructed config must fail closed, not silently uncapped.
    ///      Set borrowCap to this value to opt out explicitly.
    uint256 public constant NO_BORROW_CAP = type(uint256).max;

    mapping(ILPAdapter.LPType => CollateralConfig) public collateralConfig;

    // --- Supply Caps (per-pool collateral cap, 18-dec USD) ---
    // Keyed by the shared pool's borrow-asset address in the unified-pool model.
    mapping(address => uint256) public poolSupplyCap; // borrowAsset → max collateral value
    mapping(address => uint256) public poolCurrentSupply; // borrowAsset → current collateral value

    // --- Events ---
    event GlobalBorrowCapUpdated(uint256 oldValue, uint256 newValue);
    event LPTypeBorrowCapUpdated(ILPAdapter.LPType indexed lpType, uint256 cap);
    event CollateralConfigSet(ILPAdapter.LPType indexed lpType);
    event MaxPositionValueUpdated(uint256 oldValue, uint256 newValue);
    event MaxPositionsPerUserUpdated(uint256 oldValue, uint256 newValue);
    event PoolSupplyCapUpdated(address indexed pool, uint256 oldValue, uint256 newValue);
    event BorrowTrackingDrift(uint256 tracked, uint256 repaid, bool isGlobal);
    // All three carry lpType: per-collateral exposure is the unit of risk in the shared-pool model,
    // so an indexer must be able to reconstruct lpTypeCurrentBorrows from the event stream alone.
    event BorrowRecorded(uint256 amountUsd, ILPAdapter.LPType indexed lpType, uint256 newGlobalBorrows);
    event AccrualRecorded(uint256 amountUsd, ILPAdapter.LPType indexed lpType, uint256 newGlobalBorrows);
    event RepayRecorded(uint256 amountUsd, ILPAdapter.LPType indexed lpType, uint256 newGlobalBorrows);
    event DepositRecorded(uint256 valueUsd, address indexed pool, uint256 newPoolSupply);
    event WithdrawRecorded(uint256 valueUsd, address indexed pool, uint256 newPoolSupply);

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

        // Check 3: collateral type must still be enabled. Offboarding a type via enabled=false
        // has to stop its existing positions drawing fresh liquidity from the SHARED pool,
        // otherwise the offboarding does nothing for the lenders backing every other type.
        CollateralConfig memory cfg = collateralConfig[lpType];
        if (!cfg.enabled) {
            return (false, "COLLATERAL_DISABLED");
        }

        // Check 4: LP type borrow cap (no zero-escape — 0 means blocked, see NO_BORROW_CAP)
        if (borrowAmountUsd > cfg.borrowCap || lpTypeCurrentBorrows[lpType] > cfg.borrowCap - borrowAmountUsd) {
            return (false, "LP_TYPE_CAP_REACHED");
        }

        // Atomically record the borrow (no gap between validate and record)
        currentGlobalBorrows += borrowAmountUsd;
        lpTypeCurrentBorrows[lpType] += borrowAmountUsd;
        emit BorrowRecorded(borrowAmountUsd, lpType, currentGlobalBorrows);

        return (true, "");
    }

    /// @notice Record interest accrued on an existing position since it was last touched (18-dec USD)
    /// @dev Keeps the borrow counters symmetric. Borrows record principal only, while repay and
    ///      write-off subtract principal + accrued interest; without this the counters would
    ///      ratchet DOWNWARD, letting a long-lived borrower repay interest repeatedly until the
    ///      tracked exposure hit zero and then re-borrow the full cap. LendingEngine calls this
    ///      before each borrow/repay so both sides move by the same, interest-inclusive quantity.
    ///
    ///      Deliberately NOT cap-checked: accrual is not new borrowing, and reverting here would
    ///      make repaying an over-cap position impossible. Counters may therefore exceed a cap,
    ///      which correctly blocks further borrowing until the position is paid down.
    function recordAccrual(uint256 amountUsd, ILPAdapter.LPType lpType) external onlyLendingEngine {
        if (amountUsd == 0) return;
        currentGlobalBorrows += amountUsd;
        lpTypeCurrentBorrows[lpType] += amountUsd;
        emit AccrualRecorded(amountUsd, lpType, currentGlobalBorrows);
    }

    /// @notice Record a repayment for cap tracking (18-dec USD)
    /// @dev Subtracts principal + accrued interest, matching the interest-inclusive increments
    ///      made by validateAndRecordBorrow + recordAccrual. The clamps below are defence in
    ///      depth: they should not trigger now that both sides are symmetric, so a
    ///      BorrowTrackingDrift event indicates an accounting bug worth investigating.
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
        emit RepayRecorded(amountUsd, lpType, currentGlobalBorrows);
    }

    // --- Deposit Validation (called by PositionManager) ---

    /// @notice Validate a deposit against risk limits
    /// @param positionValue Position value in 18-dec USD
    /// @param pool The shared pool (borrow-asset address) for supply cap
    /// @param userPositionCount Current number of positions the user has
    function validateDeposit(
        uint256 positionValue,
        address pool,
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

        // Check 3: Pool supply cap
        uint256 cap = poolSupplyCap[pool];
        if (cap > 0 && poolCurrentSupply[pool] + positionValue > cap) {
            return (false, "SUPPLY_CAP_REACHED");
        }

        return (true, "");
    }

    /// @notice Record a deposit for supply cap tracking (18-dec USD)
    /// @dev Enforces the pool supply cap at the single choke point so EVERY value-in path
    ///      (deposit + addCollateral) is capped by construction — a caller cannot record a
    ///      supply increase that breaches the cap. cap == 0 means uncapped (Aave-style default).
    ///
    ///      DESIGN DECISION: addCollateral is INTENTIONALLY subject to this cap (it flows through
    ///      recordDeposit). This matches Aave V3, where supply() — the collateral-add path — is
    ///      blocked at the supply cap with no top-up exemption. Rationale: an at-cap pool is at
    ///      its liquidatable-exposure budget; letting a single position grow past it via
    ///      addCollateral would reintroduce unbounded exposure. A borrower needing to restore
    ///      health in an at-cap pool can always repay() (never blocked), so this is not a trap.
    function recordDeposit(uint256 valueUsd, address pool) external onlyPositionManager {
        uint256 cap = poolSupplyCap[pool];
        uint256 newSupply = poolCurrentSupply[pool] + valueUsd;
        require(cap == 0 || newSupply <= cap, "SUPPLY_CAP_REACHED");
        poolCurrentSupply[pool] = newSupply;
        emit DepositRecorded(valueUsd, pool, newSupply);
    }

    /// @notice Track supply added by compounding a position's own fees into principal (18-dec USD).
    /// @dev Unlike recordDeposit this does NOT enforce the pool supply cap. Compounding reinvests
    ///      a position's OWN uncollected fees (permissionless, keeper-driven) — it is organic growth
    ///      of existing exposure, not new external capital, so it is tracked for accounting accuracy
    ///      but never blocked at the cap (blocking would strand fees and let anyone grief keepers by
    ///      pinning a pool at its cap). Analogous to interest accrual pushing borrows past borrowCap.
    function recordCompoundReinvest(uint256 valueUsd, address pool) external onlyPositionManager {
        poolCurrentSupply[pool] += valueUsd;
        emit DepositRecorded(valueUsd, pool, poolCurrentSupply[pool]);
    }

    event SupplyTrackingDrift(uint256 tracked, uint256 withdrawn, address indexed pool);

    /// @notice Record a withdrawal for supply cap tracking (18-dec USD)
    /// @dev PositionManager calls this with the value the position RECORDED on the way in
    ///      (stored per-position as Position.recordedValue), not a fresh oracle re-price — so a
    ///      clean deposit→withdraw nets the counter back to its baseline regardless of price moves,
    ///      and a debt-free exit never depends on oracle liveness. The clamp below is a
    ///      defense-in-depth backstop: any residual over-release (e.g. an oracle-priced liquidation
    ///      seize exceeding the recorded value) saturates the counter at 0 and surfaces
    ///      SupplyTrackingDrift rather than under-flowing. This only affects a SOFT risk cap —
    ///      never user funds.
    function recordWithdraw(uint256 valueUsd, address pool) external onlyPositionManager {
        if (valueUsd > poolCurrentSupply[pool]) {
            emit SupplyTrackingDrift(poolCurrentSupply[pool], valueUsd, pool);
            poolCurrentSupply[pool] = 0;
        } else {
            poolCurrentSupply[pool] -= valueUsd;
        }
        emit WithdrawRecorded(valueUsd, pool, poolCurrentSupply[pool]);
    }

    // --- Admin (RISK_ADMIN) ---

    function setGlobalBorrowCap(uint256 cap) external onlyRiskAdmin {
        require(cap > 0, "ZERO_CAP");
        emit GlobalBorrowCapUpdated(globalBorrowCap, cap);
        globalBorrowCap = cap;
    }

    /// @notice Adjust only the borrow cap of an already-configured collateral type.
    /// @dev Operational lever for retuning a cap without restating the whole config. Setting
    ///      cap to 0 halts new borrowing against the type (repay and liquidation stay open);
    ///      use NO_BORROW_CAP to remove the limit.
    function setLPTypeBorrowCap(ILPAdapter.LPType lpType, uint256 cap) external onlyRiskAdmin {
        emit LPTypeBorrowCapUpdated(lpType, cap);
        collateralConfig[lpType].borrowCap = cap;
    }

    /// @notice Back-compat view — the per-LP-type borrow cap now lives in collateralConfig.
    function lpTypeBorrowCap(ILPAdapter.LPType lpType) external view returns (uint256) {
        return collateralConfig[lpType].borrowCap;
    }

    /// @notice Set the full collateral-risk config for an LP type (source of truth in the shared pool).
    /// @dev The bounds below are always enforced, including for `enabled: false` configs. That is
    ///      deliberate: these params keep being read for EXISTING positions after a type is
    ///      offboarded (`enabled` only gates new deposits/borrows), so writing an all-zero config
    ///      to "disable" a type would set liquidationThreshold to 0 and instantly mark every live
    ///      position of that type liquidatable — at a zero bonus, so no liquidator would take it.
    ///      To offboard a type, flip `enabled` while keeping its risk params intact.
    function setCollateralConfig(ILPAdapter.LPType lpType, CollateralConfig calldata cfg) external onlyRiskAdmin {
        // Strict: at maxLtv == liquidationThreshold a position is liquidatable the instant it
        // borrows its maximum, leaving no room to react to a price move.
        require(cfg.maxLtv < cfg.liquidationThreshold, "LTV_GE_THRESHOLD");
        require(cfg.maxLtv <= MAX_LTV_BPS, "LTV_TOO_HIGH");
        require(cfg.liquidationThreshold <= MAX_LIQUIDATION_THRESHOLD_BPS, "THRESHOLD_TOO_HIGH");
        require(cfg.liquidationBonus <= MAX_LIQUIDATION_BONUS_BPS, "BONUS_TOO_HIGH");
        require(cfg.haircut <= MAX_HAIRCUT_BPS, "HAIRCUT_TOO_HIGH");
        if (cfg.enabled) {
            require(cfg.maxLtv > 0, "ZERO_LTV");
            // A live type with no bonus is unliquidatable in practice — liquidators have no
            // incentive, so underwater positions would just accrue bad debt.
            require(cfg.liquidationBonus > 0, "ZERO_BONUS");
            require(cfg.borrowCap > 0, "ZERO_BORROW_CAP");
        }
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

    function setPoolSupplyCap(address pool, uint256 cap) external onlyRiskAdmin {
        require(pool != address(0), "ZERO_POOL");
        emit PoolSupplyCapUpdated(pool, poolSupplyCap[pool], cap);
        poolSupplyCap[pool] = cap;
    }
}
