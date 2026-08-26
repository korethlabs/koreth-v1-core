// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title AerodromeAdapter
/// @notice Handles Aerodrome/Velodrome LP deposits, withdrawals, and unwinding
contract AerodromeAdapter is ILPAdapter {
    address public immutable aerodromeRouter;
    address public immutable aerodromeFactory;
    ProtocolCore public immutable core;

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyProtocol() {
        ACLManager acl = _acl();
        require(acl.isPositionManager(msg.sender) || acl.isLiquidationEngine(msg.sender), "NOT_AUTHORIZED");
        _;
    }

    constructor(address _router, address _factory, address _core) {
        require(_router != address(0) && _factory != address(0) && _core != address(0), "ZERO_ADDRESS");
        aerodromeRouter = _router;
        aerodromeFactory = _factory;
        core = ProtocolCore(_core);
    }

    /// @inheritdoc ILPAdapter
    function validateAndLock(address, uint256, uint256, address) external onlyProtocol returns (LPInfo memory info) {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    function unlock(address, uint256, uint256, address) external onlyProtocol {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPAdapter
    function unwind(address, uint256, uint128) external onlyProtocol returns (uint256 amount0, uint256 amount1) {
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
    function lpType() external pure returns (LPType) {
        return LPType.Aerodrome;
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
    /// @dev Aerodrome pools are Solidly forks, whose getReserves() returns uint256 where a Uniswap
    ///      V2 pair returns uint112 — a different ABI, so the V2 measure cannot simply be reused
    ///      here. Reverts until this adapter is implemented against it.
    function poolHoldings(address) external pure returns (address, address, uint256, uint256) {
        revert("NOT_IMPLEMENTED");
    }
}
