// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {InterestRateModel} from "./InterestRateModel.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";
import {FeeCollector} from "../core/FeeCollector.sol";

/// @title LendingPool
/// @notice Shared lending pool for a single borrow asset — single source of truth for interest accrual.
/// @dev Formerly Market. One pool per borrow asset; ALL collateral types borrow from it. Collateral
///      risk params live in RiskManager per LPType; this contract is liquidity-only (no borrow cap here).
///      UUPS upgradeable. Uses ProtocolCore for ownership (DAO controls admin ops).
contract LendingPool is ILendingPool, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for OZIERC20;

    PoolConfig public config;
    PoolState public state;
    InterestRateModel public interestRateModel;

    mapping(address => uint256) public shares;
    uint256 public totalShares;

    /// @notice Reference to ProtocolCore for ownership/admin checks
    ProtocolCore public core;

    /// @dev Deprecated — was `lendingEngine` address. Kept for UUPS storage layout compatibility.
    /// LendingEngine auth now checked via ACLManager.isLendingEngine().
    address private __deprecated_lendingEngine;

    /// @notice Cumulative borrow interest index (RAY = 1e27 precision)
    uint256 public borrowIndex;

    /// @dev Deprecated — supply rate now uses reserveFactorBps. Kept for UUPS storage layout.
    uint256 public protocolFeeBps;

    uint256 internal constant RAY = 1e27;

    uint256 public constant DEAD_SHARES = 1_000_000;
    address internal constant DEAD_ADDRESS = address(0xdead);

    event InterestRateModelUpdated(address oldModel, address newModel);
    event InterestAccrued(uint256 interestAmount, uint256 protocolShare, uint256 newBorrowIndex, uint256 timestamp);
    event ReserveFactorUpdated(uint256 oldValue, uint256 newValue);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event ReservesDistributed(uint256 amount, address indexed feeCollector);

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyPoolAdmin() {
        require(_acl().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
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

    modifier whenNotPaused() {
        require(!core.paused(), "PAUSED");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(PoolConfig memory _config, address _interestRateModel, address _core) external initializer {
        require(_core != address(0), "ZERO_CORE");
        require(_interestRateModel != address(0), "ZERO_IRM");
        require(_config.borrowAsset != address(0), "ZERO_BORROW_ASSET");
        config = _config;
        interestRateModel = InterestRateModel(_interestRateModel);
        core = ProtocolCore(_core);
        state.lastAccrualTimestamp = block.timestamp;
        borrowIndex = RAY;
    }

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

    // --- Admin ---

    /// @dev Deprecated — use setReserveFactor() instead. Kept for UUPS storage compatibility.
    function setProtocolFee(uint256) external pure {
        revert("DEPRECATED_USE_RESERVE_FACTOR");
    }

    function setReserveFactor(uint256 _bps) external onlyRiskAdmin {
        require(_bps <= 5000, "RESERVE_TOO_HIGH"); // Max 50%
        accrueInterest();
        emit ReserveFactorUpdated(reserveFactorBps, _bps);
        reserveFactorBps = _bps;
        _updateRates();
    }

    function setFeeCollector(address _feeCollector) external onlyPoolAdmin {
        require(_feeCollector != address(0), "ZERO_ADDRESS");
        require(_feeCollector.code.length > 0, "NOT_CONTRACT");
        require(address(FeeCollector(_feeCollector).core()) == address(core), "CORE_MISMATCH");
        emit FeeCollectorUpdated(address(feeCollector), _feeCollector);
        feeCollector = FeeCollector(_feeCollector);
    }

    /// @notice Distribute accumulated protocol reserves to FeeCollector
    /// @dev Permissionless — anyone can trigger (keeper, user, DAO).
    ///      At high utilization reserves may exceed cash on hand (the tokens are lent out). In that
    ///      case only the available cash is sent; the remainder stays tracked in protocolReserves
    ///      and can be distributed once repayments bring cash back — hence the early `return` on
    ///      zero cash rather than a revert.
    ///      Distribution reduces totalPoolAssets, so utilization (and borrow rates) tick up until
    ///      new reserves accrue. That is inherent to utilization-based rate models (same in
    ///      Aave/Compound) and is an accepted tradeoff.
    function distributeReserves() external nonReentrant {
        accrueInterest(); // Ensure reserves are up-to-date
        uint256 amount = protocolReserves;
        require(amount > 0, "NO_RESERVES");
        require(address(feeCollector) != address(0), "NO_FEE_COLLECTOR");

        uint256 balanceBefore = IERC20(config.borrowAsset).balanceOf(address(this));
        if (amount > balanceBefore) amount = balanceBefore;
        if (amount == 0) return; // No cash to distribute — try again after repayments

        OZIERC20(config.borrowAsset).forceApprove(address(feeCollector), amount);
        feeCollector.depositReserves(config.borrowAsset, amount);

        uint256 balanceAfter = IERC20(config.borrowAsset).balanceOf(address(this));
        uint256 actualSent = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (actualSent > protocolReserves) actualSent = protocolReserves;
        protocolReserves -= actualSent;

        _updateRates();

        emit ReservesDistributed(actualSent, address(feeCollector));
    }

    function setInterestRateModel(address _newModel) external onlyPoolAdmin {
        require(_newModel != address(0), "ZERO_ADDRESS");
        accrueInterest();
        emit InterestRateModelUpdated(address(interestRateModel), _newModel);
        interestRateModel = InterestRateModel(_newModel);
    }

    // --- Interest Accrual (single source of truth) ---

    function accrueInterest() public {
        if (block.timestamp <= state.lastAccrualTimestamp) return;
        if (state.totalBorrow == 0) {
            state.lastAccrualTimestamp = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - state.lastAccrualTimestamp;
        uint256 totalPoolAssets = state.totalSupply + protocolReserves;

        uint256 currentUtilization;
        if (totalPoolAssets == 0) {
            // No pool assets — use max utilization (10000 bps). Interest still accrues and goes
            // entirely to protocol reserves, which prevents free borrowing when totalSupply == 0.
            currentUtilization = 10_000;
        } else {
            uint256 rawUtil = (state.totalBorrow * 10_000) / totalPoolAssets;
            currentUtilization = rawUtil > 10_000 ? 10_000 : rawUtil;
        }
        uint256 borrowRatePerSecond = interestRateModel.getBorrowRate(currentUtilization);

        // Floors to a whole base unit, while the borrowIndex below keeps RAY precision. Position debt
        // derives from the index, so debt gains just under one base unit on totalBorrow per accrual
        // and the sum of position debts can sit above totalBorrow. transferIn and recordDeficit are
        // written for that: neither treats debt above totalBorrow as an error.
        uint256 interestAccrued = (state.totalBorrow * borrowRatePerSecond * elapsed) / 1e18;

        // Split interest: protocol keeps reserveFactorBps%, lenders get the rest.
        uint256 protocolShare;
        uint256 lenderShare;
        if (state.totalSupply == 0) {
            // No lenders — all interest goes to protocol reserves.
            protocolShare = interestAccrued;
            lenderShare = 0;
        } else {
            protocolShare = (interestAccrued * reserveFactorBps) / 10_000;
            lenderShare = interestAccrued - protocolShare;
        }

        state.totalBorrow += interestAccrued; // Borrowers owe full interest
        state.totalSupply += lenderShare; // Lenders earn less than 100%
        protocolReserves += protocolShare; // Protocol's cut stored separately
        state.lastAccrualTimestamp = block.timestamp;

        // borrowRatePerSecond is 1e18 scale, borrowIndex is RAY (1e27) scale.
        uint256 interestFactor = RAY + ((borrowRatePerSecond * elapsed * RAY) / 1e18);
        borrowIndex = (borrowIndex * interestFactor) / RAY;

        _updateRates();

        emit InterestAccrued(interestAccrued, protocolShare, borrowIndex, block.timestamp);
    }

    // --- Lender Operations ---

    /// @inheritdoc ILendingPool
    function supply(uint256 amount) external whenNotPaused nonReentrant returns (uint256 sharesToMint) {
        require(amount > 0, "ZERO_AMOUNT");
        accrueInterest();

        uint256 balBefore = IERC20(config.borrowAsset).balanceOf(address(this));
        OZIERC20(config.borrowAsset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(config.borrowAsset).balanceOf(address(this)) - balBefore;
        require(received > 0, "ZERO_RECEIVED");

        if (totalShares == 0) {
            require(received > DEAD_SHARES, "BELOW_MINIMUM_DEPOSIT");
            sharesToMint = received - DEAD_SHARES;

            shares[DEAD_ADDRESS] += DEAD_SHARES;
            totalShares += DEAD_SHARES;
        } else {
            // A full-pool default can socialize losses all the way down to totalSupply == 0 while
            // shares are still outstanding (they now redeem to nothing). Refuse new deposits in that
            // insolvent state: minting against a zero share price would both divide-by-zero and, worse,
            // hand the fresh deposit straight to the holders of the now-worthless legacy shares. The
            // market recovers only when eliminateDeficit() credits reserves back into totalSupply.
            require(state.totalSupply > 0, "MARKET_INSOLVENT");
            sharesToMint = (received * totalShares) / state.totalSupply;
            require(sharesToMint > 0, "DEPOSIT_TOO_SMALL");
        }

        shares[msg.sender] += sharesToMint;
        totalShares += sharesToMint;
        state.totalSupply += received;

        emit Supply(msg.sender, received, sharesToMint);
    }

    /// @inheritdoc ILendingPool
    function withdraw(uint256 sharesToBurn) external whenNotPaused nonReentrant returns (uint256 amount) {
        require(sharesToBurn > 0, "ZERO_SHARES");
        accrueInterest();

        require(shares[msg.sender] >= sharesToBurn, "INSUFFICIENT_SHARES");

        amount = (sharesToBurn * state.totalSupply) / totalShares;
        // Two ways this lands on zero: an insolvent market (recordDeficit socialized totalSupply down
        // to 0 while shares stayed outstanding) and dust rounding down in a healthy one. Reverting is
        // the policy rather than a guard — the caller would receive no tokens either way, and failing
        // closed keeps their shares alive so a later eliminateDeficit() still refunds them. Burning
        // them for nothing would irreversibly hand that recovery to the holders who did not exit.
        require(amount > 0, "ZERO_REDEEM_VALUE");

        uint256 availableLiquidity = IERC20(config.borrowAsset).balanceOf(address(this));
        require(amount <= availableLiquidity, "INSUFFICIENT_LIQUIDITY");

        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        state.totalSupply -= amount;

        OZIERC20(config.borrowAsset).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, sharesToBurn);
    }

    // --- LendingEngine Operations ---

    /// @dev Borrow cap is enforced in RiskManager per LPType (not here). This pool draws liquidity
    ///      for ANY collateral type — the shared-pool model.
    ///      `available` is the actual token balance, NOT totalSupply: protocolReserves are an
    ///      accounting claim rather than locked cash, so borrowers can draw against them. Lenders
    ///      keep priority — reserves are only paid out by distributeReserves once cash allows.
    function transferOut(address to, uint256 amount) external onlyLendingEngine nonReentrant {
        require(to != address(0), "ZERO_RECIPIENT");
        require(state.totalSupply > 0, "NO_SUPPLY");
        uint256 available = IERC20(config.borrowAsset).balanceOf(address(this));
        require(amount <= available, "INSUFFICIENT_LIQUIDITY");

        state.totalBorrow += amount;
        _updateRates();

        OZIERC20(config.borrowAsset).safeTransfer(to, amount);
    }

    /// @dev `amount` may exceed totalBorrow: it is position debt, which derives from borrowIndex and
    ///      carries the interest accrueInterest() floored off totalBorrow. Whoever repays last holds
    ///      that gap, so bounding `amount` by totalBorrow would make the last borrower unable to repay
    ///      and unable to be liquidated. As in Morpho Blue, which floors totalBorrowAssets at zero in
    ///      repay() and liquidate() (UtilsLib.zeroFloorSub), totalBorrow saturates at zero here.
    ///      Morpho leaves the difference unaccounted in the contract. Here it is booked to
    ///      protocolReserves, because `balance + totalBorrow == totalSupply + protocolReserves` has to
    ///      keep holding and these tokens are interest no one was credited with. Reserves rather than
    ///      totalSupply so a repayment can never move the share price.
    ///      `amount` is bounded by the caller, which refuses to repay more than the position owes.
    function transferIn(address from, uint256 amount) external onlyLendingEngine nonReentrant {
        require(from != address(0), "ZERO_SENDER");

        uint256 balBefore = IERC20(config.borrowAsset).balanceOf(address(this));
        OZIERC20(config.borrowAsset).safeTransferFrom(from, address(this), amount);
        uint256 balAfter = IERC20(config.borrowAsset).balanceOf(address(this));
        // Exact equality, not a bound. This is the refusal of fee-on-transfer (and rebasing) borrow
        // assets, not a redundant sanity check: the caller writes the borrower's debt down by the
        // requested `amount` before calling here, so a short delivery forgives the shortfall at the
        // lenders' expense, and an over-delivery understates totalBorrow. The `>=` leg keeps a
        // balance that went *down* across the transfer failing under this name too, instead of as an
        // arithmetic panic. LiquidationEngine's repayment path refuses the same thing the same way.
        require(balAfter >= balBefore && balAfter - balBefore == amount, "FEE_ON_TRANSFER_UNSUPPORTED");

        // The delivery is now proven exact, so settle the value the caller's own accounting used.
        uint256 borrowed = state.totalBorrow;
        if (amount > borrowed) {
            protocolReserves += amount - borrowed;
            state.totalBorrow = 0;
        } else {
            state.totalBorrow = borrowed - amount;
        }
        _updateRates();
    }

    // --- View ---

    /// @inheritdoc ILendingPool
    function getPoolState() external view returns (PoolState memory) {
        return state;
    }

    /// @inheritdoc ILendingPool
    function getConfig() external view returns (PoolConfig memory) {
        return config;
    }

    /// @inheritdoc ILendingPool
    function borrowAsset() external view returns (address) {
        return config.borrowAsset;
    }

    // --- Internal ---

    function _updateRates() internal {
        uint256 totalPoolAssets = state.totalSupply + protocolReserves;
        if (totalPoolAssets == 0) {
            state.utilization = 0;
        } else {
            uint256 rawUtil = (state.totalBorrow * 10_000) / totalPoolAssets;
            state.utilization = rawUtil > 10_000 ? 10_000 : rawUtil;
        }
        state.borrowRate = interestRateModel.getBorrowRate(state.utilization);
        state.supplyRate = interestRateModel.getSupplyRate(state.utilization, reserveFactorBps);
    }

    // --- New state vars (appended for UUPS upgrade safety) ---
    /// @notice Reserve factor: % of interest kept by protocol (bps). Set via setReserveFactor().
    uint256 public reserveFactorBps;
    /// @notice Accumulated protocol reserves (in borrow asset decimals)
    uint256 public protocolReserves;
    /// @notice FeeCollector address for reserve distribution
    FeeCollector public feeCollector;
    /// @notice Bad debt accumulated from underwater liquidations (borrow asset decimals)
    uint256 public deficit;

    // --- Events ---
    /// @param burned         Debt removed from totalBorrow (uncollectable principal + interest)
    /// @param reservesUsed   Portion of `burned` absorbed by protocolReserves (no lender impact)
    /// @param supplierLoss   Portion socialized onto suppliers by reducing totalSupply
    /// @param totalDeficit   Running total of socialized loss still owed back to suppliers
    event DeficitRecorded(uint256 burned, uint256 reservesUsed, uint256 supplierLoss, uint256 totalDeficit);
    /// @param covered              Deficit reduced this call
    /// @param refundedToSuppliers  Amount credited back to totalSupply (restores share price)
    /// @param remaining            Deficit still outstanding after this call
    event DeficitEliminated(uint256 covered, uint256 refundedToSuppliers, uint256 remaining);

    // --- Bad Debt Management ---

    /// @notice Record bad debt from underwater liquidation (called by LendingEngine)
    /// @dev Burns uncollectable debt from totalBorrow, then absorbs it — reserves first, suppliers
    ///      second — so the loss is socialized immediately at write-off time. This is the crux of the
    ///      Morpho-style model: reducing totalSupply the instant bad debt is recorded drops the share
    ///      price for everyone pro-rata in the same transaction, so no lender can front-run the
    ///      write-off by withdrawing at the stale (too-high) price and pushing the loss onto whoever
    ///      exits last. Absorption order:
    ///        1. `reservesUsed = min(burn, protocolReserves)` — spend the protocol's own cut first,
    ///           shielding lenders to the extent reserves allow (no totalSupply impact).
    ///        2. `supplierLoss = min(burn - reservesUsed, totalSupply)` — socialize the remainder by
    ///           reducing totalSupply. The min() is defensive saturation: the solvency identity
    ///           `balance + totalBorrow == totalSupply + protocolReserves` with balance >= 0 already
    ///           guarantees the uncovered remainder can never exceed totalSupply, but we clamp anyway
    ///           so a hypothetical accounting bug can never underflow here and brick every liquidation.
    ///      Only `supplierLoss` is tracked in `deficit`: it is the lender principal owed back and thus
    ///      the only part eliminateDeficit() can later refund. The reserves-funded portion is already
    ///      final — lenders never lost it, so there is nothing to refund.
    ///      The burn is clamped to totalBorrow — more debt can never be written off than the pool
    ///      believes exists. That makes a burn of zero a valid outcome rather than an error: the
    ///      part of the debt above totalBorrow was never credited to anyone (see transferIn), so the
    ///      clamp discards nothing the pool holds, and this call runs inside liquidate(), which must
    ///      not revert over it.
    ///      Morpho Blue takes the same `min` in liquidate() and carries on when it comes to zero.
    function recordDeficit(uint256 amount) external onlyLendingEngine {
        require(amount > 0, "ZERO_AMOUNT");
        uint256 burn = amount > state.totalBorrow ? state.totalBorrow : amount;
        state.totalBorrow -= burn;

        uint256 reservesUsed = burn > protocolReserves ? protocolReserves : burn;
        protocolReserves -= reservesUsed;

        uint256 uncovered = burn - reservesUsed;
        uint256 supplierLoss = uncovered > state.totalSupply ? state.totalSupply : uncovered;
        state.totalSupply -= supplierLoss;
        deficit += supplierLoss;

        _updateRates();
        emit DeficitRecorded(burn, reservesUsed, supplierLoss, deficit);
    }

    /// @notice Cover deficit using protocol reserves (callable by RiskAdmin)
    /// @dev Partial coverage is fine — covers min(deficit, protocolReserves) and leaves the rest
    ///      outstanding. `deficit` only ever holds the socialized supplier loss (see recordDeficit),
    ///      so covering it means crediting that amount back into totalSupply: the share price rises
    ///      pro-rata and suppliers are made whole. This is the symmetric inverse of the socialization
    ///      in recordDeficit — reserves that later become available flow back to the lenders who ate
    ///      the loss, not to new depositors.
    function eliminateDeficit() external onlyRiskAdmin {
        require(deficit > 0, "NO_DEFICIT");
        uint256 coverage = deficit > protocolReserves ? protocolReserves : deficit;
        protocolReserves -= coverage;
        deficit -= coverage;
        state.totalSupply += coverage;
        _updateRates();
        emit DeficitEliminated(coverage, coverage, deficit);
    }

    // --- Storage Gap ---
    uint256[46] private __gap;
}
