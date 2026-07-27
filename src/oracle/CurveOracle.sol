// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILPOracle} from "../interfaces/ILPOracle.sol";
import {ILPOracleHub} from "../interfaces/ILPOracleHub.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title CurveOracle
/// @notice Prices Curve LP tokens using virtual price + Chainlink validation
/// @dev Uses ProtocolCore for ownership — DAO controls all parameters.
contract CurveOracle is ILPOracle {
    ProtocolCore public immutable core;

    mapping(address => address) public priceFeeds;

    // --- Configurable Parameters ---
    uint256 public maxVirtualPriceDeviationBps = 100; // 1%

    mapping(address => uint256) public lastVirtualPrice;

    // --- Absolute Bounds ---
    uint256 public constant MIN_VP_DEVIATION_BPS = 50;
    uint256 public constant MAX_VP_DEVIATION_BPS = 500;

    uint256 public lastUpdateTimestamp;

    event VPDeviationUpdated(uint256 oldValue, uint256 newValue);
    event PriceFeedUpdated(address indexed token, address indexed feed);

    modifier onlyPoolAdmin() {
        require(core.aclManager().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    constructor(address _core) {
        core = ProtocolCore(_core);
        lastUpdateTimestamp = block.timestamp;
    }

    function setMaxVirtualPriceDeviation(uint256 _deviationBps) external onlyPoolAdmin {
        require(_deviationBps >= MIN_VP_DEVIATION_BPS && _deviationBps <= MAX_VP_DEVIATION_BPS, "OUT_OF_BOUNDS");
        emit VPDeviationUpdated(maxVirtualPriceDeviationBps, _deviationBps);
        maxVirtualPriceDeviationBps = _deviationBps;
    }

    function setPriceFeed(address token, address feed) external onlyPoolAdmin {
        require(token != address(0) && feed != address(0), "ZERO_ADDRESS");
        emit PriceFeedUpdated(token, feed);
        priceFeeds[token] = feed;
    }

    /// @inheritdoc ILPOracle
    /// @dev Stub — Curve LP pricing not yet implemented. Reverts to prevent silent zero-valuation.
    function getPrice(address, uint256, uint256) external pure returns (ILPOracleHub.PriceResult memory) {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPOracle
    function getRawPrice(address, uint256, uint256) external pure returns (uint256) {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc ILPOracle
    /// @dev Stub — pricing not implemented, so report unhealthy (fail-closed) until it is.
    function isHealthy() external pure returns (bool) {
        return false;
    }
}
