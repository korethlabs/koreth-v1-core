// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title CurveAdapter
/// @notice Handles Curve LP token deposits, withdrawals, and unwinding
/// @dev UUPS upgradeable, like the implemented adapters. An adapter is the custodian of the
///      collateral deposited through it, so it must never be deployable in a form whose only fix
///      path is registering a different address — the operation that would separate live positions
///      from their assets. Enforced here even though the methods are still stubs, so this one cannot
///      be built out into a live custodian that lacks the upgrade path.
contract CurveAdapter is ILPAdapter, Initializable, UUPSUpgradeable {
    // Storage, not immutables: see UniswapV2Adapter for why the custodian's wiring is set once by
    // initialize() rather than re-supplied by every replacement implementation.
    ProtocolCore public core;
    address public curveRegistry;

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyProtocol() {
        ACLManager acl = _acl();
        require(acl.isPositionManager(msg.sender) || acl.isLiquidationEngine(msg.sender), "NOT_AUTHORIZED");
        _;
    }

    modifier onlyPoolAdmin() {
        require(_acl().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _curveRegistry, address _core) external initializer {
        require(_curveRegistry != address(0) && _core != address(0), "ZERO_ADDRESS");
        curveRegistry = _curveRegistry;
        core = ProtocolCore(_core);
    }

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

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

    // --- Storage Gap ---
    // 2 declared slots (0-1) + 48 gap slots = 50 total. When appending a state var, decrement __gap
    // by the slots it consumes so the total stays 50 (UUPS storage-collision safety). Verified via
    // `forge inspect ... storage-layout`.
    uint256[48] private __gap;
}
