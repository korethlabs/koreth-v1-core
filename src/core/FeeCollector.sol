// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "./ProtocolCore.sol";
import {ACLManager} from "./ACLManager.sol";

/// @title FeeCollector
/// @notice Collects and distributes protocol fees using Aave-style reserve factor model
/// @dev Revenue sources:
///   1. Reserve factor: % of borrow interest kept by protocol (per LP type)
///   2. Liquidation fee: % of liquidation penalty goes to protocol
///   3. Management fee: small annual fee on deposited LP collateral
///
/// Fee flow:
///   LendingEngine/LiquidationEngine -> collectFee() -> pulls tokens into FeeCollector
///   Keeper/DAO -> distribute() -> splits to treasury + insurance fund
///
/// Safety:
///   - Uses OZ ReentrancyGuard (not manual bool — avoids permanent stuck state)
///   - collectFee measures actual received amount (fee-on-transfer token safe)
///   - distribute verifies balance before sending
contract FeeCollector is ReentrancyGuard {
    using SafeERC20 for OZIERC20;

    ProtocolCore public immutable core;

    // --- Reserve Factor (Aave-style, per LP type) ---
    mapping(ILPAdapter.LPType => uint256) public reserveFactorBps;
    uint256 public defaultReserveFactorBps = 2000; // 20%

    // --- Other Fee Rates ---
    /// @notice Protocol's share of the liquidation bonus (bps).
    ///         e.g., 7000 = protocol takes 70% of bonus, liquidator keeps 30%.
    ///         With 5% liquidation bonus on $20K debt: bonus = $1K,
    ///         protocol gets $700, liquidator gets $300.
    uint256 public liquidationFeeBps = 7000; // 70% of bonus → protocol
    /// @dev Deprecated — management fee not implemented. Kept for storage layout.
    uint256 private __deprecated_managementFeeBps;

    // --- Absolute Bounds ---
    uint256 public constant MIN_RESERVE_FACTOR = 500; // 5%
    uint256 public constant MAX_RESERVE_FACTOR = 5000; // 50%
    uint256 public constant MIN_PROTOCOL_BONUS_SHARE = 50; // 0.5% of bonus
    uint256 public constant MAX_PROTOCOL_BONUS_SHARE = 9000; // 90% of bonus
    /// @dev Deprecated — management fee not implemented
    uint256 private constant __DEPRECATED_MAX_MANAGEMENT_FEE = 100;
    uint256 public constant MAX_INSURANCE_SHARE = 5000; // 50%

    // --- Fee Recipients ---
    address public treasury;
    address public insuranceFund;
    uint256 public insuranceFundShareBps = 1000; // 10%

    // --- Accumulated Fees ---
    mapping(address => uint256) public accumulatedFees; // token -> amount

    // --- Events ---
    event FeesCollected(address indexed token, uint256 amount, address indexed from, string feeType);
    event FeesDistributed(address indexed token, uint256 toTreasury, uint256 toInsurance);
    event ReserveFactorUpdated(ILPAdapter.LPType indexed lpType, uint256 oldValue, uint256 newValue);
    event DefaultReserveFactorUpdated(uint256 oldValue, uint256 newValue);
    event LiquidationFeeUpdated(uint256 oldValue, uint256 newValue);
    event InsuranceFundShareUpdated(uint256 oldValue, uint256 newValue);
    event TreasuryUpdated(address indexed oldAddr, address indexed newAddr);
    event InsuranceFundUpdated(address indexed oldAddr, address indexed newAddr);
    event ExcessSwept(address indexed token, address indexed to, uint256 amount);

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

    /// @dev Authorized = LendingEngine, LiquidationEngine, PositionManager, Keeper, or PoolAdmin
    modifier onlyAuthorized() {
        ACLManager acl = _acl();
        require(
            acl.isLiquidationEngine(msg.sender) || acl.isLendingEngine(msg.sender) || acl.isPositionManager(msg.sender)
                || acl.isKeeper(msg.sender) || acl.isPoolAdmin(msg.sender),
            "NOT_AUTHORIZED"
        );
        _;
    }

    modifier whenNotPaused() {
        require(!core.paused(), "PAUSED");
        _;
    }

    constructor(address _core, address _treasury, address _insuranceFund) {
        require(_core != address(0), "ZERO_CORE");
        require(_treasury != address(0), "ZERO_TREASURY");
        require(_insuranceFund != address(0), "ZERO_INSURANCE");
        core = ProtocolCore(_core);
        treasury = _treasury;
        insuranceFund = _insuranceFund;

        reserveFactorBps[ILPAdapter.LPType.Curve] = 1000;
        reserveFactorBps[ILPAdapter.LPType.UniswapV2] = 2000;
        reserveFactorBps[ILPAdapter.LPType.UniswapV3] = 2000;
        reserveFactorBps[ILPAdapter.LPType.Aerodrome] = 2500;
        reserveFactorBps[ILPAdapter.LPType.PancakeSwapV2] = 2000;
        reserveFactorBps[ILPAdapter.LPType.PancakeSwapV3] = 2500;
    }

    // --- Fee Collection ---

    /// @notice Pull fee tokens from a source into FeeCollector and record actual received amount
    /// @dev Measures balance before/after transfer to handle fee-on-transfer tokens correctly.
    function collectFee(
        address token,
        uint256 amount,
        address from,
        string calldata feeType
    )
        external
        onlyAuthorized
        whenNotPaused
        nonReentrant
    {
        require(amount > 0, "ZERO_AMOUNT");
        require(token != address(0), "ZERO_TOKEN");
        require(from != address(0), "ZERO_FROM");

        // Measure actual received (fee-on-transfer safe)
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        OZIERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 actualReceived = IERC20(token).balanceOf(address(this)) - balanceBefore;
        require(actualReceived > 0, "ZERO_RECEIVED");

        accumulatedFees[token] += actualReceived;
        emit FeesCollected(token, actualReceived, from, feeType);
    }

    /// @notice Distribute accumulated fees to treasury and insurance fund
    /// @dev Uses OZ ReentrancyGuard — cannot get permanently stuck on revert
    function distribute(address token) external onlyAuthorized whenNotPaused nonReentrant {
        require(token != address(0), "ZERO_TOKEN");
        require(treasury != address(0), "TREASURY_NOT_SET");
        require(insuranceFund != address(0), "INSURANCE_NOT_SET");

        uint256 total = accumulatedFees[token];
        require(total > 0, "NO_FEES");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= total, "INSUFFICIENT_BALANCE");

        // Clear before transfers (CEI pattern)
        accumulatedFees[token] = 0;

        uint256 toInsurance = (total * insuranceFundShareBps) / 10_000;
        uint256 toTreasury = total - toInsurance;

        if (toTreasury > 0) {
            OZIERC20(token).safeTransfer(treasury, toTreasury);
        }
        if (toInsurance > 0) {
            OZIERC20(token).safeTransfer(insuranceFund, toInsurance);
        }

        emit FeesDistributed(token, toTreasury, toInsurance);
    }

    /// @notice Accept reserve transfers from registered Market contracts only
    /// @dev Called by Market.distributeReserves() which approves this contract first.
    ///      Pulls tokens via safeTransferFrom and tracks via balance delta.
    function depositReserves(address token, uint256 expectedAmount) external whenNotPaused nonReentrant {
        require(core.registeredMarkets(msg.sender), "NOT_REGISTERED_MARKET");
        require(token != address(0), "ZERO_TOKEN");
        require(expectedAmount > 0, "ZERO_AMOUNT");

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        OZIERC20(token).safeTransferFrom(msg.sender, address(this), expectedAmount);
        uint256 actualReceived = IERC20(token).balanceOf(address(this)) - balanceBefore;
        require(actualReceived > 0, "ZERO_RECEIVED");

        accumulatedFees[token] += actualReceived;
        emit FeesCollected(token, actualReceived, msg.sender, "reserve");
    }

    /// @notice Sweep tokens that were sent directly to this contract (not via collectFee)
    /// @dev Recovers balance - accumulatedFees[token] excess. Only callable by POOL_ADMIN.
    function sweepExcess(address token, address to) external onlyPoolAdmin nonReentrant {
        require(token != address(0) && to != address(0), "ZERO_ADDRESS");
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 tracked = accumulatedFees[token];
        require(balance > tracked, "NO_EXCESS");
        uint256 excess = balance - tracked;
        OZIERC20(token).safeTransfer(to, excess);
        emit ExcessSwept(token, to, excess);
    }

    // --- View ---

    function getReserveFactor(ILPAdapter.LPType lpType) external view returns (uint256) {
        uint256 rf = reserveFactorBps[lpType];
        return rf > 0 ? rf : defaultReserveFactorBps;
    }

    function calculateInterestSplit(
        uint256 totalInterest,
        ILPAdapter.LPType lpType
    )
        external
        view
        returns (uint256 protocolShare, uint256 lenderShare)
    {
        uint256 rf = reserveFactorBps[lpType];
        if (rf == 0) rf = defaultReserveFactorBps;
        protocolShare = (totalInterest * rf) / 10_000;
        lenderShare = totalInterest - protocolShare;
    }

    function calculateLiquidationFee(uint256 liquidatorProfit)
        external
        view
        returns (uint256 protocolFee, uint256 liquidatorNet)
    {
        protocolFee = (liquidatorProfit * liquidationFeeBps) / 10_000;
        liquidatorNet = liquidatorProfit - protocolFee;
    }

    // --- Admin (DAO controlled) ---

    function setReserveFactor(ILPAdapter.LPType lpType, uint256 _bps) external onlyRiskAdmin {
        require(_bps >= MIN_RESERVE_FACTOR && _bps <= MAX_RESERVE_FACTOR, "OUT_OF_BOUNDS");
        emit ReserveFactorUpdated(lpType, reserveFactorBps[lpType], _bps);
        reserveFactorBps[lpType] = _bps;
    }

    function setDefaultReserveFactor(uint256 _bps) external onlyRiskAdmin {
        require(_bps >= MIN_RESERVE_FACTOR && _bps <= MAX_RESERVE_FACTOR, "OUT_OF_BOUNDS");
        emit DefaultReserveFactorUpdated(defaultReserveFactorBps, _bps);
        defaultReserveFactorBps = _bps;
    }

    function setLiquidationFee(uint256 _bps) external onlyRiskAdmin {
        require(_bps >= MIN_PROTOCOL_BONUS_SHARE && _bps <= MAX_PROTOCOL_BONUS_SHARE, "OUT_OF_BOUNDS");
        emit LiquidationFeeUpdated(liquidationFeeBps, _bps);
        liquidationFeeBps = _bps;
    }

    /// @dev Deprecated — management fee not implemented
    function setManagementFee(uint256) external pure {
        revert("DEPRECATED");
    }

    function setInsuranceFundShare(uint256 _bps) external onlyRiskAdmin {
        require(_bps <= MAX_INSURANCE_SHARE, "TOO_HIGH");
        emit InsuranceFundShareUpdated(insuranceFundShareBps, _bps);
        insuranceFundShareBps = _bps;
    }

    function setTreasury(address _treasury) external onlyPoolAdmin {
        require(_treasury != address(0), "ZERO_ADDRESS");
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setInsuranceFund(address _insuranceFund) external onlyPoolAdmin {
        require(_insuranceFund != address(0), "ZERO_ADDRESS");
        emit InsuranceFundUpdated(insuranceFund, _insuranceFund);
        insuranceFund = _insuranceFund;
    }
}
