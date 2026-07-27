// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {InterestRateModel} from "./InterestRateModel.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";
import {FeeCollector} from "../core/FeeCollector.sol";

/// @title Market
/// @notice Isolated lending market — single source of truth for interest accrual
/// @dev UUPS upgradeable. Uses ProtocolCore for ownership (DAO controls admin ops).
///      LendingEngine address is updatable so Market isn't bricked if LE is redeployed.
contract Market is IMarket, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for OZIERC20;

    MarketConfig public config;
    MarketState public state;
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
    ///      Inline `= 30` removed (misleading for proxies — proxy storage defaults to 0).
    uint256 public protocolFeeBps;

    uint256 internal constant RAY = 1e27;

    uint256 public constant DEAD_SHARES = 1_000_000;
    address internal constant DEAD_ADDRESS = address(0xdead);

    /// @notice Maximum liquidation bonus in bps (15% — aligned with Aave V3 upper bound)
    uint256 public constant MAX_LIQUIDATION_BONUS = 1500;

    event InterestRateModelUpdated(address oldModel, address newModel);
    event MarketConfigUpdated(string field, uint256 oldValue, uint256 newValue);
    event InterestAccrued(uint256 interestAmount, uint256 protocolShare, uint256 newBorrowIndex, uint256 timestamp);
    /// @dev ProtocolFeeUpdated removed — protocolFeeBps is deprecated, use ReserveFactorUpdated
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

    function initialize(MarketConfig memory _config, address _interestRateModel, address _core) external initializer {
        require(_core != address(0), "ZERO_CORE");
        require(_interestRateModel != address(0), "ZERO_IRM");
        require(_config.maxLtv <= 9500, "LTV_TOO_HIGH");
        require(_config.liquidationThreshold <= 9800, "THRESHOLD_TOO_HIGH");
        require(_config.maxLtv < _config.liquidationThreshold, "LTV_MUST_BE_BELOW_LIQ_THRESHOLD");
        require(_config.liquidationBonus <= MAX_LIQUIDATION_BONUS, "BONUS_TOO_HIGH");
        config = _config;
        interestRateModel = InterestRateModel(_interestRateModel);
        core = ProtocolCore(_core);
        state.lastAccrualTimestamp = block.timestamp;
        borrowIndex = RAY;
        // protocolFeeBps is deprecated — kept in storage for UUPS layout.
        // Use setReserveFactor() to configure the protocol's interest share.
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
    ///      At high utilization, reserves may exceed cash (tokens lent out).
    ///      In that case, only available cash is distributed. Remaining reserves
    ///      stay tracked and can be distributed after repayments bring cash back.
    /// @dev Reserve distribution reduces totalPoolAssets, causing a utilization increase
    ///      and higher borrow rates until new reserves accrue. This is inherent to
    ///      utilization-based rate models (same in Aave/Compound).
    function distributeReserves() external nonReentrant {
        accrueInterest(); // Ensure reserves are up-to-date
        uint256 amount = protocolReserves;
        require(amount > 0, "NO_RESERVES");
        require(address(feeCollector) != address(0), "NO_FEE_COLLECTOR");

        // Cap at available cash (reserves may exceed balance at high utilization).
        // If no cash available, silently return — reserves stay tracked for later.
        uint256 balanceBefore = IERC20(config.borrowAsset).balanceOf(address(this));
        if (amount > balanceBefore) amount = balanceBefore;
        if (amount == 0) return; // No cash to distribute — try again after repayments

        // Approve FeeCollector to pull, then call depositReserves
        OZIERC20(config.borrowAsset).forceApprove(address(feeCollector), amount);
        feeCollector.depositReserves(config.borrowAsset, amount);

        // Use balance delta to track actual amount sent (fee-on-transfer safe)
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

    function updateConfig(
        uint256 _maxLtv,
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus,
        uint256 _borrowCap
    )
        external
        onlyRiskAdmin
    {
        require(_maxLtv <= 9500, "LTV_TOO_HIGH");
        require(_liquidationThreshold <= 9800, "THRESHOLD_TOO_HIGH");
        require(_maxLtv < _liquidationThreshold, "LTV_MUST_BE_BELOW_LIQ_THRESHOLD");
        require(_liquidationBonus <= MAX_LIQUIDATION_BONUS, "BONUS_TOO_HIGH");

        if (_maxLtv != config.maxLtv) emit MarketConfigUpdated("maxLtv", config.maxLtv, _maxLtv);
        if (_liquidationThreshold != config.liquidationThreshold) {
            emit MarketConfigUpdated("liquidationThreshold", config.liquidationThreshold, _liquidationThreshold);
        }
        if (_liquidationBonus != config.liquidationBonus) {
            emit MarketConfigUpdated("liquidationBonus", config.liquidationBonus, _liquidationBonus);
        }
        if (_borrowCap != config.borrowCap) emit MarketConfigUpdated("borrowCap", config.borrowCap, _borrowCap);

        config.maxLtv = _maxLtv;
        config.liquidationThreshold = _liquidationThreshold;
        config.liquidationBonus = _liquidationBonus;
        config.borrowCap = _borrowCap;
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

        // If no pool assets, use max utilization (10000 bps) — interest still accrues
        // and goes entirely to protocol reserves. Prevents free borrowing when totalSupply = 0.
        uint256 currentUtilization;
        if (totalPoolAssets == 0) {
            currentUtilization = 10_000;
        } else {
            uint256 rawUtil = (state.totalBorrow * 10_000) / totalPoolAssets;
            currentUtilization = rawUtil > 10_000 ? 10_000 : rawUtil;
        }
        uint256 borrowRatePerSecond = interestRateModel.getBorrowRate(currentUtilization);

        uint256 interestAccrued = (state.totalBorrow * borrowRatePerSecond * elapsed) / 1e18;

        // Split interest: protocol keeps reserveFactorBps%, lenders get the rest
        uint256 protocolShare;
        uint256 lenderShare;
        if (state.totalSupply == 0) {
            // No lenders — all interest goes to protocol reserves
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

        // borrowRatePerSecond is 1e18 scale, borrowIndex is RAY (1e27) scale
        uint256 interestFactor = RAY + ((borrowRatePerSecond * elapsed * RAY) / 1e18);
        borrowIndex = (borrowIndex * interestFactor) / RAY;

        _updateRates();

        emit InterestAccrued(interestAccrued, protocolShare, borrowIndex, block.timestamp);
    }

    // --- Lender Operations ---

    /// @inheritdoc IMarket
    function supply(uint256 amount) external whenNotPaused nonReentrant returns (uint256 sharesToMint) {
        require(amount > 0, "ZERO_AMOUNT");
        accrueInterest();

        // Balance delta for fee-on-transfer safety
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
            sharesToMint = (received * totalShares) / state.totalSupply;
            require(sharesToMint > 0, "DEPOSIT_TOO_SMALL");
        }

        shares[msg.sender] += sharesToMint;
        totalShares += sharesToMint;
        state.totalSupply += received;

        emit Supply(msg.sender, received, sharesToMint);
    }

    /// @inheritdoc IMarket
    function withdraw(uint256 sharesToBurn) external whenNotPaused nonReentrant returns (uint256 amount) {
        require(sharesToBurn > 0, "ZERO_SHARES");
        accrueInterest();

        require(shares[msg.sender] >= sharesToBurn, "INSUFFICIENT_SHARES");

        amount = (sharesToBurn * state.totalSupply) / totalShares;

        // Available = actual token balance (protocol reserves are accounting claims,
        // not locked cash — lenders have priority over reserves)
        uint256 availableLiquidity = IERC20(config.borrowAsset).balanceOf(address(this));
        require(amount <= availableLiquidity, "INSUFFICIENT_LIQUIDITY");

        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        state.totalSupply -= amount;

        OZIERC20(config.borrowAsset).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, sharesToBurn);
    }

    // --- LendingEngine Operations ---

    function transferOut(address to, uint256 amount) external onlyLendingEngine nonReentrant {
        require(to != address(0), "ZERO_RECIPIENT");
        require(state.totalSupply > 0, "NO_SUPPLY");
        // Available = actual balance (reserves are accounting claims, not locked)
        uint256 available = IERC20(config.borrowAsset).balanceOf(address(this));
        require(amount <= available, "INSUFFICIENT_LIQUIDITY");

        // Enforce borrow cap (MKT-6)
        if (config.borrowCap > 0) {
            require(state.totalBorrow + amount <= config.borrowCap, "BORROW_CAP_EXCEEDED");
        }

        state.totalBorrow += amount;
        _updateRates();

        OZIERC20(config.borrowAsset).safeTransfer(to, amount);
    }

    function transferIn(address from, uint256 amount) external onlyLendingEngine nonReentrant {
        require(from != address(0), "ZERO_SENDER");
        require(amount <= state.totalBorrow, "REPAY_EXCEEDS_BORROW");

        // Balance delta for fee-on-transfer safety
        uint256 balBefore = IERC20(config.borrowAsset).balanceOf(address(this));
        OZIERC20(config.borrowAsset).safeTransferFrom(from, address(this), amount);
        uint256 received = IERC20(config.borrowAsset).balanceOf(address(this)) - balBefore;
        require(received > 0 && received <= amount, "INVALID_TRANSFER_AMOUNT");

        state.totalBorrow -= received;
        _updateRates();
    }

    // --- View ---

    /// @inheritdoc IMarket
    function getMarketState() external view returns (MarketState memory) {
        return state;
    }

    /// @inheritdoc IMarket
    function getConfig() external view returns (MarketConfig memory) {
        return config;
    }

    // --- Internal ---

    function _updateRates() internal {
        // Total pool assets = lender share + protocol reserves
        uint256 totalPoolAssets = state.totalSupply + protocolReserves;
        if (totalPoolAssets == 0) {
            state.utilization = 0;
        } else {
            uint256 rawUtil = (state.totalBorrow * 10_000) / totalPoolAssets;
            state.utilization = rawUtil > 10_000 ? 10_000 : rawUtil;
        }
        state.borrowRate = interestRateModel.getBorrowRate(state.utilization);
        // Supply rate reflects actual protocol cut from interest
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
    event DeficitRecorded(uint256 amount, uint256 totalDeficit);
    event DeficitEliminated(uint256 covered, uint256 remaining);

    // --- Bad Debt Management ---

    /// @notice Record bad debt from underwater liquidation (called by LendingEngine)
    /// @dev Burns uncollectable debt from totalBorrow and tracks as deficit
    function recordDeficit(uint256 amount) external onlyLendingEngine {
        require(amount > 0, "ZERO_AMOUNT");
        // Clamp to totalBorrow (can't burn more debt than exists)
        uint256 burn = amount > state.totalBorrow ? state.totalBorrow : amount;
        require(burn > 0, "NO_BORROW_TO_BURN");
        state.totalBorrow -= burn;
        deficit += burn;
        _updateRates();
        emit DeficitRecorded(burn, deficit);
    }

    /// @notice Cover deficit using protocol reserves (callable by RiskAdmin)
    /// @dev Partial coverage OK — covers min(deficit, protocolReserves)
    function eliminateDeficit() external onlyRiskAdmin {
        require(deficit > 0, "NO_DEFICIT");
        uint256 coverage = deficit > protocolReserves ? protocolReserves : deficit;
        protocolReserves -= coverage;
        deficit -= coverage;
        // Note: totalSupply is NOT reduced — reserves were protocol's, not lenders'
        _updateRates();
        emit DeficitEliminated(coverage, deficit);
    }

    // --- Storage Gap ---
    // Reduced from 50 to 46 after adding 4 new state vars.
    uint256[46] private __gap;
}
