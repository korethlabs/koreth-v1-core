// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title AerodromeAdapter
/// @notice Handles Aerodrome/Velodrome LP deposits, withdrawals, and unwinding
/// @dev UUPS upgradeable, like the implemented adapters. An adapter is the custodian of the
///      collateral deposited through it, so it must never be deployable in a form whose only fix
///      path is registering a different address — the operation that would separate live positions
///      from their assets. Enforced here even though the methods are still stubs, so this one cannot
///      be built out into a live custodian that lacks the upgrade path.
contract AerodromeAdapter is ILPAdapter, Initializable, UUPSUpgradeable {
    // Storage, not immutables: see UniswapV2Adapter for why the custodian's wiring is set once by
    // initialize() rather than re-supplied by every replacement implementation.
    address public aerodromeRouter;
    address public aerodromeFactory;
    ProtocolCore public core;

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

    function initialize(address _router, address _factory, address _core) external initializer {
        require(_router != address(0) && _factory != address(0) && _core != address(0), "ZERO_ADDRESS");
        aerodromeRouter = _router;
        aerodromeFactory = _factory;
        core = ProtocolCore(_core);
    }

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

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

    // --- Storage Gap ---
    // 3 declared slots (0-2) + 47 gap slots = 50 total. When appending a state var, decrement __gap
    // by the slots it consumes so the total stays 50 (UUPS storage-collision safety). Verified via
    // `forge inspect ... storage-layout`.
    uint256[47] private __gap;
}
