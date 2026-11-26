// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ILendingPool
/// @notice Shared lending pool for a single borrow asset. ALL collateral types borrow from it.
/// @dev Formerly IMarket. Collateral-risk params (LTV/liqThreshold/liqBonus/haircut/borrowCap) now
///      live in RiskManager per LPType; this interface is liquidity-only.
interface ILendingPool {
    /// @notice Pool config — liquidity concern only. Risk params live in RiskManager per LPType.
    struct PoolConfig {
        address borrowAsset; // USDC, USDT, etc.
    }

    struct PoolState {
        uint256 totalSupply; // Total lender deposits
        uint256 totalBorrow; // Total outstanding borrows
        uint256 supplyRate; // Current supply APY (ray)
        uint256 borrowRate; // Current borrow APY (ray)
        uint256 utilization; // Current utilization (bps)
        uint256 lastAccrualTimestamp;
    }

    event Supply(address indexed supplier, uint256 amount, uint256 shares);
    event Withdraw(address indexed supplier, uint256 amount, uint256 shares);

    /// @notice Supply lending assets to the pool
    /// @param amount Amount of borrow asset to supply
    /// @return shares Share tokens received
    function supply(uint256 amount) external returns (uint256 shares);

    /// @notice Withdraw lending assets from the pool
    /// @param shares Amount of share tokens to redeem
    /// @return amount Borrow asset received
    function withdraw(uint256 shares) external returns (uint256 amount);

    /// @notice Get current pool state
    function getPoolState() external view returns (PoolState memory);

    /// @notice Get pool configuration
    function getConfig() external view returns (PoolConfig memory);

    /// @notice The borrow asset backing this pool
    function borrowAsset() external view returns (address);

    /// @notice Accrue interest on the pool
    function accrueInterest() external;

    /// @notice Transfer borrow asset out (called by LendingEngine)
    function transferOut(address to, uint256 amount) external;

    /// @notice Transfer borrow asset in (called by LendingEngine)
    /// @dev `amount` may exceed totalBorrow, which then floors at zero with the excess going to reserves.
    function transferIn(address from, uint256 amount) external;

    /// @notice Cumulative borrow interest index (RAY = 1e27 precision)
    function borrowIndex() external view returns (uint256);

    /// @notice Record bad debt from underwater liquidation (called by LendingEngine)
    /// @dev The burn is clamped to totalBorrow and may be zero; that is not an error.
    function recordDeficit(uint256 amount) external;

    /// @notice Cover deficit using protocol reserves (callable by RiskAdmin)
    function eliminateDeficit() external;

    /// @notice Distribute accumulated protocol reserves to FeeCollector
    function distributeReserves() external;

    /// @notice Set reserve factor (% of interest kept by protocol)
    function setReserveFactor(uint256 _bps) external;

    /// @notice Set the FeeCollector address
    function setFeeCollector(address _feeCollector) external;

    /// @notice Set the interest rate model
    function setInterestRateModel(address _newModel) external;

    /// @notice Accumulated protocol reserves (in borrow asset decimals)
    function protocolReserves() external view returns (uint256);

    /// @notice Reserve factor in basis points
    function reserveFactorBps() external view returns (uint256);
}
