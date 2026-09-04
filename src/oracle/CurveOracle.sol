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
///      expected to take. There is no valuation logic in this contract, so nothing any of it holds
///      can reach a price. Taken one variable at a time: priceFeeds is written by setPriceFeed and
///      never loaded, there or anywhere else — the PriceFeedUpdated event is built from the call
///      arguments. maxVirtualPriceDeviationBps is loaded in exactly one place,
///      setMaxVirtualPriceDeviation, which reads the previous value only in order to emit it; that
///      is the single read of stored state in the file. lastUpdateTimestamp is assigned once in the
///      constructor and never again. lastVirtualPrice has no setter at all, so it is permanently
///      zero for every pool. All four are public and externally readable — what none of them do is
///      influence a price.
///
///      Anyone implementing the pricing must therefore start by writing this state rather than
///      assuming it is already maintained. lastVirtualPrice is the trap: it is the baseline a
///      deviation check would measure against, and nothing advances it, so such a check would be
///      comparing every reading against zero rather than against the previous virtual price — a
///      guard in the shape of the one it appears to implement, measuring something else.
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
