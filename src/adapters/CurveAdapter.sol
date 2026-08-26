// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title CurveAdapter
/// @notice Handles Curve LP token deposits, withdrawals, and unwinding
contract CurveAdapter is ILPAdapter {
    ProtocolCore public immutable core;
    address public immutable curveRegistry;

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyProtocol() {
        ACLManager acl = _acl();
        require(acl.isPositionManager(msg.sender) || acl.isLiquidationEngine(msg.sender), "NOT_AUTHORIZED");
        _;
    }

    constructor(address _curveRegistry, address _core) {
        require(_curveRegistry != address(0) && _core != address(0), "ZERO_ADDRESS");
        curveRegistry = _curveRegistry;
        core = ProtocolCore(_core);
    }

    /// @inheritdoc ILPAdapter
    function validateAndLock(
        address lpToken,
        uint256,
        uint256 amount,
        address from
    )
        external
        onlyProtocol
        returns (LPInfo memory info)
    {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    function unlock(address lpToken, uint256, uint256 amount, address to) external onlyProtocol {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    function unwind(
        address lpToken,
        uint256,
        uint128 liquidityToRemove
    )
        external
        onlyProtocol
        returns (uint256 amount0, uint256 amount1)
    {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    function removeLiquidity(address, uint256, uint128, address) external onlyProtocol returns (uint256, uint256) {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    function collectFees(address, uint256) external pure returns (uint256, uint256) {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    function addLiquidity(
        address,
        uint256,
        address,
        address,
        uint256,
        uint256,
        address
    )
        external
        onlyProtocol
        returns (uint256, uint256, uint256)
    {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    function getLiquidity(address, uint256, uint256) external pure override returns (uint128) {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    function lpType() external pure returns (LPType) {
        return LPType.Curve;
    }

    /// @inheritdoc ILPAdapter
    function isSupported(address) external pure returns (bool) {
        return false; // Phase 2 — not yet implemented
    }

    /// @inheritdoc ILPAdapter
    function supportsFeeCollection() external pure returns (bool) {
        return false; // Phase 2 — not yet implemented
    }

    /// @inheritdoc ILPAdapter
    /// @dev A Curve pool holds N tokens, not two, and its balances are tracked per coin index, so
    ///      the two-token shape here has no answer for it. Reverts rather than returning a pair,
    ///      which would silently measure a stablepool by two of its legs.
    function poolHoldings(address) external pure returns (address, address, uint256, uint256) {
        revert("NOT_IMPLEMENTED");
    }
}
