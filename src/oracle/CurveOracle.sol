// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILPOracle} from "../interfaces/ILPOracle.sol";
import {ILPOracleHub} from "../interfaces/ILPOracleHub.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title CurveOracle
/// @notice Stub. Curve LP pricing is not implemented: every pricing entrypoint reverts and
///         isHealthy() reports false, so no Curve position can be valued or used as collateral.
/// @dev The intended design is virtual price cross-checked against Chainlink, which is why the
///      parameters below exist. None of it is built — get_virtual_price() is never called from
///      this contract, and no Chainlink round is ever read.
///
///      Reverting is the deliberate behaviour, not an oversight. An oracle that returned zero for
///      an unimplemented type would value the collateral at nothing and mark every position of
///      that type instantly liquidatable; one that returned a placeholder would let a position be
///      borrowed against at an invented price. Failing closed leaves the type unusable instead,
///      which is the correct state for pricing that does not exist.
///
///      The whole configuration surface is inert and kept only as the shape the build-out is
///      expected to take. None of it reaches a valuation, because there is no valuation:
///      priceFeeds and maxVirtualPriceDeviationBps are settable by POOL_ADMIN and then consumed by
///      no logic here at all — setPriceFeed emits from its call arguments and never loads the
///      mapping, and the single read of stored state anywhere in this contract is
///      setMaxVirtualPriceDeviation loading the previous deviation for its own event;
///      lastUpdateTimestamp is assigned once in the constructor and never again; and
///      lastVirtualPrice has no setter at all, so it is
///      permanently zero for every pool. All four are public and externally readable — what none
///      of them do is influence a price.
///
///      Anyone implementing the pricing must therefore start by writing this state rather than
///      assuming it is already maintained. lastVirtualPrice is the trap: a deviation check against
///      a value that is always zero has nothing to compare against and would pass unconditionally,
///      silently disabling the guard it looks like it implements.
///
///      Uses ProtocolCore for ownership — DAO controls all parameters.
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
