// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title PancakeSwapAdapter
/// @notice Handles PancakeSwap V2 and V3 LP positions on BSC
/// @dev UUPS upgradeable, like the implemented adapters. An adapter is the custodian of the
///      collateral deposited through it, so it must never be deployable in a form whose only fix
///      path is registering a different address — the operation that would separate live positions
///      from their assets. Enforced here even though the methods are still stubs, so this one cannot
///      be built out into a live custodian that lacks the upgrade path.
contract PancakeSwapAdapter is ILPAdapter, Initializable, UUPSUpgradeable {
    // Storage, not immutables: see UniswapV2Adapter for why the custodian's wiring is set once by
    // initialize() rather than re-supplied by every replacement implementation.
    address public v2Factory;
    address public v2Router;
    address public v3NftManager;
    address public v3Factory;
    ProtocolCore public core;
    /// @dev Packs into the `core` slot (20 + 1 bytes), so the two together occupy one slot.
    bool public isV3;

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

    function initialize(
        address _v2Factory,
        address _v2Router,
        address _v3NftManager,
        address _v3Factory,
        address _core,
        bool _isV3
    )
        external
        initializer
    {
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

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

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
    /// @dev Every functional method reverts NOT_IMPLEMENTED, so this reports unsupported until
    ///      the adapter is built out — mirroring the other Phase 2 stubs. Returning true here would
    ///      let _detectLPType route collateral into an adapter that cannot service it.
    function isSupported(address) external pure returns (bool) {
        return false; // Phase 2 — not yet implemented
    }

    /// @inheritdoc ILPAdapter
    function supportsFeeCollection() external pure returns (bool) {
        return false; // Phase 2 — not yet implemented
    }

    /// @inheritdoc ILPAdapter
    /// @dev PancakeSwap's V2 and V3 pools are forks of the Uniswap ones and would be measured the
    ///      same way, branching on isV3 as lpType() above does. Left reverting with the rest of this
    ///      stub rather than implemented ahead of the paths that would deposit into it: a measure
    ///      that answers for pools no other method here can accept is untestable end to end.
    function poolHoldings(address) external pure returns (address, address, uint256, uint256) {
        revert("NOT_IMPLEMENTED");
    }

    // --- Storage Gap ---
    // 5 declared slots (0-4, with isV3 packed alongside core in slot 4) + 45 gap slots = 50 total.
    // When appending a state var, decrement __gap by the slots it consumes so the total stays 50
    // (UUPS storage-collision safety). Verified via `forge inspect ... storage-layout`.
    uint256[45] private __gap;
}
