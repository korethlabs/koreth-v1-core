// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "./ILPAdapter.sol";

/// @title IMarket
/// @notice Isolated lending market for a specific LP type
interface IMarket {
    struct MarketConfig {
        ILPAdapter.LPType lpType;
        address borrowAsset; // USDC, USDT, etc.
        uint256 maxLtv; // Maximum LTV in basis points (e.g., 6500 = 65%)
        uint256 liquidationThreshold; // Liquidation trigger in bps
        uint256 liquidationBonus; // Bonus for liquidators in bps
        uint256 borrowCap; // Max total borrows
        // ADVISORY listing metadata — NOT enforced on-chain (on-chain pool TVL is flash-manipulable
        // and V3 exposes no cheap creation-time). The manipulation-resistant TVL floor is enforced
        // OFF-CHAIN by the keeper-driven PriceValidator (which pauses the pool via CircuitBreaker);
        // a minimum age is implicitly required by the oracle's 30-min TWAP history requirement.
        uint256 minPoolTvl; // Min underlying pool TVL (advisory — see note above)
        uint256 minPoolAge; // Min pool age in seconds (advisory — see note above)
    }

    struct MarketState {
        uint256 totalSupply; // Total lender deposits
        uint256 totalBorrow; // Total outstanding borrows
        uint256 supplyRate; // Current supply APY (ray)
        uint256 borrowRate; // Current borrow APY (ray)
        uint256 utilization; // Current utilization (bps)
        uint256 lastAccrualTimestamp;
    }

    event Supply(address indexed supplier, uint256 amount, uint256 shares);
    event Withdraw(address indexed supplier, uint256 amount, uint256 shares);

    /// @notice Supply lending assets to the market
    /// @param amount Amount of borrow asset to supply
    /// @return shares Share tokens received
    function supply(uint256 amount) external returns (uint256 shares);

    /// @notice Withdraw lending assets from the market
    /// @param shares Amount of share tokens to redeem
    /// @return amount Borrow asset received
    function withdraw(uint256 shares) external returns (uint256 amount);

    /// @notice Get current market state
    function getMarketState() external view returns (MarketState memory);

    /// @notice Get market configuration
    function getConfig() external view returns (MarketConfig memory);

    /// @notice Accrue interest on the market
    function accrueInterest() external;

    /// @notice Transfer borrow asset out (called by LendingEngine)
    function transferOut(address to, uint256 amount) external;

    /// @notice Transfer borrow asset in (called by LendingEngine)
    function transferIn(address from, uint256 amount) external;

    /// @notice Cumulative borrow interest index (RAY = 1e27 precision)
    function borrowIndex() external view returns (uint256);

    /// @notice Record bad debt from underwater liquidation (called by LendingEngine)
    function recordDeficit(uint256 amount) external;

    /// @notice Cover deficit using protocol reserves (callable by RiskAdmin)
    function eliminateDeficit() external;

    /// @notice Distribute accumulated protocol reserves to FeeCollector
    function distributeReserves() external;

    /// @notice Update market risk parameters
    function updateConfig(
        uint256 _maxLtv,
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus,
        uint256 _borrowCap
    )
        external;

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
