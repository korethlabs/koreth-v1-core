// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ILPOracleHub} from "../interfaces/ILPOracleHub.sol";
import {ILPOracle} from "../interfaces/ILPOracle.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title LPOracleHub
/// @notice Central oracle router that delegates pricing to type-specific oracles
/// @dev UUPS upgradeable — referenced by PositionManager, address must stay stable.
///
///      Oracle registry: reads from ProtocolCore.oracles (single source of truth).
///      No local oracle mapping — eliminates dual-registry state drift risk.
///      Register oracles via ProtocolCore.registerOracle(), not through this hub.
///
///      Health checks: isOracleHealthy() is exposed for off-chain monitoring but
///      NOT enforced in getPrice(). Rationale: V2/V3 oracles always return true
///      (staleness is checked reactively inside PriceFeedRegistry.getPrice() on every call).
///      Adding a gate on a constant-true function wastes gas for zero safety gain.
///      If isHealthy() becomes meaningful (e.g., sequencer uptime on L2), add the gate then.
///
///      Confidence field: PriceResult.confidence is populated by sub-oracles and returned
///      for off-chain monitoring/analytics, but NOT used as a pricing haircut.
///      Confidence-based risk adjustments require per-LP-type calibration and are planned
///      for V1.1 (see docs/TODO.md). For V1, safety comes from LTV + liquidation threshold gap.
contract LPOracleHub is ILPOracleHub, Initializable, UUPSUpgradeable {
    ProtocolCore public core;

    /// @dev DEPRECATED — oracles now read from core.getOracle(). Kept for UUPS storage layout.
    mapping(ILPAdapter.LPType => address) private __deprecated_oracles;

    modifier onlyPoolAdmin() {
        require(core.aclManager().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _core) external initializer {
        require(_core != address(0), "ZERO_ADDRESS");
        core = ProtocolCore(_core);
    }

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

    /// @inheritdoc ILPOracleHub
    /// @dev Register via ProtocolCore.registerOracle() directly — single source of truth.
    ///      This wrapper exists only for interface compliance.
    function registerOracle(ILPAdapter.LPType, address) external view onlyPoolAdmin {
        revert("USE_CORE_REGISTER_ORACLE");
    }

    /// @notice Read the oracle address for an LP type (from ProtocolCore)
    function oracles(ILPAdapter.LPType lpType) external view returns (address) {
        return core.getOracle(lpType);
    }

    /// @inheritdoc ILPOracleHub
    function getPrice(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        ILPAdapter.LPType lpType
    )
        external
        view
        returns (PriceResult memory result)
    {
        address oracle = core.getOracle(lpType);
        require(oracle != address(0), "NO_ORACLE");
        result = ILPOracle(oracle).getPrice(lpToken, tokenId, amount);
    }

    /// @inheritdoc ILPOracleHub
    function getRawPrice(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        ILPAdapter.LPType lpType
    )
        external
        view
        returns (uint256)
    {
        address oracle = core.getOracle(lpType);
        require(oracle != address(0), "NO_ORACLE");
        return ILPOracle(oracle).getRawPrice(lpToken, tokenId, amount);
    }

    /// @inheritdoc ILPOracleHub
    /// @dev Exposed for off-chain monitoring. Not enforced in getPrice() — see contract NatSpec.
    function isOracleHealthy(ILPAdapter.LPType lpType) external view returns (bool) {
        address oracle = core.getOracle(lpType);
        if (oracle == address(0)) return false;
        return ILPOracle(oracle).isHealthy();
    }

    // --- Storage Gap (UUPS upgrade safety) ---
    uint256[50] private __gap;
}
