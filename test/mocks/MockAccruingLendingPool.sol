// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILendingPool} from "../../src/interfaces/ILendingPool.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";

/// @notice Lending pool mock whose accrueInterest() actually advances the borrow index, modelling
///         a real pool with interest pending since the last on-chain touch.
/// @dev The default MockLendingPool has a no-op accrueInterest(): a test using it cannot tell whether
///      a caller accrued before reading debt, because the index it reads is whatever the test set and
///      never moves on its own. This mock instead carries a `pendingIndex` that only materialises into
///      the live `borrowIndex` when accrueInterest() runs — so getDebt reads the STALE index until an
///      accrual pokes it. That is exactly the condition the accrue-before-health-check fix targets: a
///      position that reads healthy at the stale index but is underwater once interest is accrued.
contract MockAccruingLendingPool is ILendingPool {
    PoolConfig public _config;
    PoolState public _state;
    InterestRateModel public interestRateModel;

    /// @notice Live borrow index — what getDebt reads until the next accrual.
    uint256 public borrowIndex;
    /// @notice Index that has accrued but is not yet reflected; folded in by accrueInterest().
    uint256 public pendingIndex;
    uint256 internal constant RAY = 1e27;

    constructor(address _borrowAsset, address _irm) {
        interestRateModel = InterestRateModel(_irm);
        borrowIndex = RAY;
        pendingIndex = RAY;
        _config = PoolConfig({borrowAsset: _borrowAsset});
    }

    /// @notice Fold any pending interest into the live index.
    function accrueInterest() public {
        if (pendingIndex > borrowIndex) borrowIndex = pendingIndex;
    }

    /// @notice Test helper — schedule interest that only takes effect on the next accrueInterest().
    function setPendingIndex(uint256 _index) external {
        pendingIndex = _index;
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
