// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMarket} from "../../src/interfaces/IMarket.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";

/// @notice Mock market for testing — simulates Market.sol with borrowIndex
contract MockMarket is IMarket {
    MarketConfig public _config;
    MarketState public _state;
    InterestRateModel public interestRateModel;

    /// @notice Cumulative borrow index (same as real Market)
    uint256 public borrowIndex;
    uint256 internal constant RAY = 1e27;

    constructor(address _borrowAsset, address _irm) {
        interestRateModel = InterestRateModel(_irm);
        borrowIndex = RAY; // Initialize to 1.0
        _config = MarketConfig({
            lpType: ILPAdapter.LPType.UniswapV3,
            borrowAsset: _borrowAsset,
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            borrowCap: 10_000_000e18,
            minPoolTvl: 5_000_000e18,
            minPoolAge: 0
        });
    }

    function setLpType(ILPAdapter.LPType _lpType) external {
        _config.lpType = _lpType;
    }

    /// @notice Accrue interest (simplified for testing — just updates index based on elapsed time)
    function accrueInterest() public {
        // In tests, we manually advance time with vm.warp
        // For simplicity, we update index only when explicitly called via setBorrowIndex
        // Real Market computes from rate model, but tests control this directly
    }

    /// @notice Test helper — manually set the borrow index to simulate interest accrual
    function setBorrowIndex(uint256 _index) external {
        borrowIndex = _index;
    }

    function transferOut(address to, uint256 amount) external {
        _state.totalBorrow += amount;
        require(IERC20(_config.borrowAsset).transfer(to, amount), "TRANSFER_OUT_FAILED");
    }

    function transferIn(address from, uint256 amount) external {
        if (amount <= _state.totalBorrow) {
            _state.totalBorrow -= amount;
        }
        require(IERC20(_config.borrowAsset).transferFrom(from, address(this), amount), "TRANSFER_IN_FAILED");
    }

    function supply(uint256) external pure returns (uint256) {
        return 0;
    }

    function withdraw(uint256) external pure returns (uint256) {
        return 0;
    }

    function getMarketState() external view returns (MarketState memory) {
        return _state;
    }

    function getConfig() external view returns (MarketConfig memory) {
        return _config;
    }

    function recordDeficit(uint256 amount) external {
        uint256 burn = amount > _state.totalBorrow ? _state.totalBorrow : amount;
        _state.totalBorrow -= burn;
    }

    function eliminateDeficit() external {}

    function distributeReserves() external {}

    function updateConfig(
        uint256 _maxLtv,
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus,
        uint256 _borrowCap
    )
        external
    {
        _config.maxLtv = _maxLtv;
        _config.liquidationThreshold = _liquidationThreshold;
        _config.liquidationBonus = _liquidationBonus;
        _config.borrowCap = _borrowCap;
    }

    function setReserveFactor(uint256) external {}

    function setFeeCollector(address) external {}

    function setInterestRateModel(address) external {}

    function protocolReserves() external pure returns (uint256) {
        return 0;
    }

    function reserveFactorBps() external pure returns (uint256) {
        return 0;
    }
}
