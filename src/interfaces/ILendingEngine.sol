// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ILendingEngine
/// @notice Handles borrowing, repayment, and interest accrual
interface ILendingEngine {
    event Borrowed(uint256 indexed positionId, address indexed borrower, uint256 amount, uint256 totalDebt);

    event Repaid(uint256 indexed positionId, address indexed repayer, uint256 amount, uint256 remainingDebt);

    // Note: InterestAccrued is emitted by Market.accrueInterest(), not LendingEngine.
    // LendingEngine delegates accrual entirely to Market as the single source of truth.

    /// @notice Borrow assets against a deposited LP position
    /// @param positionId The position to borrow against
    /// @param amount Amount of borrow asset to borrow
    function borrow(uint256 positionId, uint256 amount) external;

    /// @notice Repay borrowed assets
    /// @param positionId The position to repay debt for
    /// @param amount Amount to repay (type(uint256).max for full repay)
    function repay(uint256 positionId, uint256 amount) external;

    /// @notice Get current debt including accrued interest
    /// @param positionId The position to check
    /// @return debt Current total debt
    function getDebt(uint256 positionId) external view returns (uint256 debt);

    /// @notice Get maximum borrowable amount for a position
    /// @param positionId The position to check
    /// @return maxBorrow Maximum borrow amount in borrow asset
    function getMaxBorrow(uint256 positionId) external view returns (uint256 maxBorrow);

    /// @notice Accrue interest for a market
    /// @param marketId The market to accrue interest for
    function accrueInterest(uint256 marketId) external;

    /// @notice Repay debt on behalf of a borrower (used by LiquidationEngine)
    function repayOnBehalf(uint256 positionId, uint256 repayAmount) external;

    /// @notice Write off bad debt from an underwater position (called by LiquidationEngine)
    function writeOffDebt(uint256 positionId) external;

    /// @notice Set borrow cooldown (blocks after deposit before borrowing allowed)
    function setBorrowCooldown(uint256 _blocks) external;
}
