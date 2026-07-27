// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title PancakeSwapAdapter
/// @notice Handles PancakeSwap V2 and V3 LP positions on BSC
contract PancakeSwapAdapter is ILPAdapter {
    address public immutable v2Factory;
    address public immutable v2Router;
    address public immutable v3NftManager;
    address public immutable v3Factory;
    ProtocolCore public immutable core;
    bool public immutable isV3;

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyProtocol() {
        ACLManager acl = _acl();
        require(acl.isPositionManager(msg.sender) || acl.isLiquidationEngine(msg.sender), "NOT_AUTHORIZED");
        _;
    }

    constructor(
        address _v2Factory,
        address _v2Router,
        address _v3NftManager,
        address _v3Factory,
        address _core,
        bool _isV3
    ) {
        require(_core != address(0), "ZERO_ADDRESS");
        if (_isV3) {
            require(_v3NftManager != address(0) && _v3Factory != address(0), "ZERO_V3_DEPS");
        } else {
            require(_v2Factory != address(0) && _v2Router != address(0), "ZERO_V2_DEPS");
        }
        v2Factory = _v2Factory;
        v2Router = _v2Router;
        v3NftManager = _v3NftManager;
        v3Factory = _v3Factory;
        core = ProtocolCore(_core);
        isV3 = _isV3;
    }

    /// @inheritdoc ILPAdapter
    function validateAndLock(address, uint256, uint256, address) external onlyProtocol returns (LPInfo memory info) {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    /// @dev Fail closed — unimplemented exit path must revert (never silently no-op on collateral).
    function unlock(address, uint256, uint256, address) external onlyProtocol {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    function unwind(address, uint256, uint128) external onlyProtocol returns (uint256, uint256) {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    function collectFees(address, uint256) external onlyProtocol returns (uint256, uint256) {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    function removeLiquidity(address, uint256, uint128, address) external onlyProtocol returns (uint256, uint256) {
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
    function lpType() external view returns (LPType) {
        return isV3 ? LPType.PancakeSwapV3 : LPType.PancakeSwapV2;
    }

    /// @inheritdoc ILPAdapter
    function isSupported(address lpToken) external view returns (bool) {
        if (isV3) return lpToken == v3NftManager;
        return false; // Phase 2 — not yet implemented
    }
}
