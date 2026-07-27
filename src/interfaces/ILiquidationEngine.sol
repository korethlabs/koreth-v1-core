// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ILiquidationEngine
/// @notice Handles atomic liquidation of unhealthy positions
/// @dev Liquidators send borrow asset (repay debt) and receive the raw underlying tokens
///      from the LP unwind (e.g., ETH + USDC). No swap inside the protocol.
interface ILiquidationEngine {
    /// @param positionId The liquidated position
    /// @param liquidator The address that called liquidate
    /// @param repayAmount Borrow asset amount sent by liquidator (fully applied to debt)
    /// @param collateralSeized USD value (18 decimals) of collateral removed from position
    /// @param liquidatorProfit Always 0 — profit is implicit in the underlying tokens received
    event LiquidationExecuted(
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 repayAmount,
        uint256 collateralSeized,
        uint256 liquidatorProfit
    );

    /// @notice Liquidate an unhealthy position
    /// @dev Atomically: pull repayment → repay debt → unwind LP → send underlying tokens to liquidator
    /// @param positionId The position to liquidate
    /// @param repayAmount Amount of debt to repay
    /// @param deadline Transaction deadline
    /// @param minAmount0 Minimum token0 amount the liquidator must receive (net of protocol fees)
    /// @param minAmount1 Minimum token1 amount the liquidator must receive (net of protocol fees)
    /// @return profit Always 0 — profit is implicit in the underlying tokens received
    function liquidate(
        uint256 positionId,
        uint256 repayAmount,
        uint256 deadline,
        uint256 minAmount0,
        uint256 minAmount1
    )
        external
        returns (uint256 profit);

    /// @notice Check if a position is liquidatable
    /// @param positionId The position to check
    /// @return liquidatable Whether the position can be liquidated
    /// @return maxRepay Maximum repayable amount
    function isLiquidatable(uint256 positionId) external view returns (bool liquidatable, uint256 maxRepay);

    /// @notice Get the liquidation bonus for a position's LP type
    /// @param positionId The position to check
    /// @return bonus Liquidation bonus in basis points
    function getLiquidationBonus(uint256 positionId) external view returns (uint256 bonus);

    /// @notice Set the maximum liquidation portion
    function setMaxLiquidationPortion(uint256 _maxLiquidationPortion) external;

    /// @notice Set the FeeCollector address
    function setFeeCollector(address _feeCollector) external;

    /// @notice Rescue tokens stuck in this contract
    function rescueTokens(address token, address to, uint256 amount) external;
}
