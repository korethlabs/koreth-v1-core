// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILendingPool} from "../../src/interfaces/ILendingPool.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";

/// @notice Mock shared lending pool for testing — simulates LendingPool.sol with borrowIndex
contract MockLendingPool is ILendingPool {
    PoolConfig public _config;
    PoolState public _state;
    InterestRateModel public interestRateModel;

    /// @notice Cumulative borrow index (same as real LendingPool)
    uint256 public borrowIndex;
    uint256 internal constant RAY = 1e27;

    constructor(address _borrowAsset, address _irm) {
        interestRateModel = InterestRateModel(_irm);
        borrowIndex = RAY; // Initialize to 1.0
        _config = PoolConfig({borrowAsset: _borrowAsset});
    }

    /// @notice Accrue interest (simplified for testing — tests control the index directly)
    function accrueInterest() public {
        // In tests, we manually advance time with vm.warp and set the index via setBorrowIndex.
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

    function getPoolState() external view returns (PoolState memory) {
        return _state;
    }

    function getConfig() external view returns (PoolConfig memory) {
        return _config;
    }

    function borrowAsset() external view returns (address) {
        return _config.borrowAsset;
    }

    function recordDeficit(uint256 amount) external {
        uint256 burn = amount > _state.totalBorrow ? _state.totalBorrow : amount;
        _state.totalBorrow -= burn;
        // Mock holds no reserves, so the whole burn socializes onto suppliers (clamped).
        uint256 supplierLoss = burn > _state.totalSupply ? _state.totalSupply : burn;
        _state.totalSupply -= supplierLoss;
    }

    function eliminateDeficit() external {}

    function distributeReserves() external {}

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
