// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "./ILPAdapter.sol";

/// @title IPositionManager
/// @notice Manages LP position deposits, withdrawals, and position state
interface IPositionManager {
    enum PositionStatus {
        Active, // LP deposited, no debt
        Borrowed, // LP deposited, has outstanding debt
        Closed, // User withdrew LP (debt fully repaid)
        Liquidated // Position was seized by liquidator
    }

    struct Position {
        uint256 id;
        address owner;
        address lpToken;
        uint256 tokenId; // 0 for ERC-20 LP tokens
        uint256 amount; // 0 for NFT positions
        ILPAdapter.LPType lpType;
        address pool;
        address token0;
        address token1;
        uint256 marketId;
        PositionStatus status;
        uint256 depositTimestamp;
        uint256 depositBlock; // Block number at deposit (for borrow cooldown)
    }

    event PositionCreated(
        uint256 indexed positionId,
        address indexed owner,
        address lpToken,
        uint256 tokenId,
        ILPAdapter.LPType lpType,
        uint256 value
    );

    event PositionClosed(uint256 indexed positionId, address indexed owner);

    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 debtRepaid);

    function deposit(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        uint256 marketId
    )
        external
        returns (uint256 positionId);

    function withdraw(uint256 positionId) external;

    /// @notice Add collateral to an existing position by providing underlying tokens
    /// @param positionId The position to add collateral to
    /// @param amount0 Amount of token0 to add
    /// @param amount1 Amount of token1 to add
    /// @param minAmount0Used Minimum token0 that must be used (slippage protection)
    /// @param minAmount1Used Minimum token1 that must be used (slippage protection)
    function addCollateral(
        uint256 positionId,
        uint256 amount0,
        uint256 amount1,
        uint256 minAmount0Used,
        uint256 minAmount1Used
    )
        external;

    function getPosition(uint256 positionId) external view returns (Position memory);

    function getPositionsByOwner(address owner) external view returns (uint256[] memory);

    function getPositionValue(uint256 positionId) external view returns (uint256);

    function getHealthFactor(uint256 positionId) external view returns (uint256);

    /// @notice Update position debt (called by LendingEngine)
    function updateDebt(uint256 positionId, uint256 newDebt) external;

    /// @notice Reduce position amount after partial liquidation (called by LiquidationEngine)
    function reducePositionAmount(uint256 positionId, uint256 amountRemoved) external;

    /// @notice Mark position as liquidated (called by LiquidationEngine)
    function markLiquidated(uint256 positionId, address liquidator, uint256 debtRepaid) external;

    /// @notice Record collateral value (18-dec USD) leaving the market on liquidation, for supply-cap tracking
    /// @dev Called by LiquidationEngine; forwards to RiskManager.recordWithdraw so marketCurrentSupply
    ///      does not drift upward as liquidations remove collateral.
    function recordCollateralSeized(uint256 positionId, uint256 valueUsd) external;

    /// @notice Parameters for fee compounding
    struct CompoundFeesParams {
        uint256 positionId;
        address protocolFeeRecipient;
        uint256 protocolFeeBps;
        address callerRewardRecipient;
        uint256 callerRewardBps;
        uint256 minFeeThreshold;
        address dustRefundTo;
        uint256 maxSlippageBps;
    }

    /// @notice Collect fees and reinvest as liquidity (called by LPCompounder)
    function compoundFees(CompoundFeesParams calldata params) external returns (uint256, uint256, uint256);

    /// @notice Get the block number at which a position was deposited
    function getDepositBlock(uint256 positionId) external view returns (uint256);

    /// @notice Set the LendingEngine reference
    function setLendingEngine(address _lendingEngine) external;

    /// @notice Set CircuitBreaker for pool-level pause enforcement
    function setCircuitBreaker(address _circuitBreaker) external;

    /// @notice Get position debt
    function positionDebt(uint256 positionId) external view returns (uint256);

    /// @notice Get active position count for an owner
    function activePositionCount(address owner) external view returns (uint256);

    /// @notice Get the next position ID
    function nextPositionId() external view returns (uint256);

    // Note: circuitBreaker() getter is on the concrete PositionManager contract
    // (returns CircuitBreaker type, not address).
}
