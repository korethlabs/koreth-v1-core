// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";

/// @title TestSecurity
/// @notice Wires the CircuitBreaker that PositionManager now requires.
/// @dev It used to be optional, and the freeze checks were wrapped in a null test — so a suite
///      that never wired one silently exercised a protocol with no circuit breaker at all, which
///      is not a configuration production is ever in. Attaching it here keeps the tests on the
///      same footing as a real deployment.
///
///      Caller must be a pool admin (setCircuitBreaker is admin-gated).
library TestSecurity {
    function wireBreaker(ProtocolCore core, PositionManager pm) internal returns (CircuitBreaker breaker) {
        breaker = new CircuitBreaker(address(core));
        pm.setCircuitBreaker(address(breaker));
    }

    /// @notice Attach a FeeCollector to the LiquidationEngine, which now requires one.
    /// @dev Suites that skipped this were liquidating with the protocol fee silently disabled —
    ///      the configuration that shipped to production and paid every bonus to the liquidator.
    function wireFeeCollector(
        ProtocolCore core,
        LiquidationEngine liq,
        address treasury
    )
        internal
        returns (FeeCollector collector)
    {
        collector = new FeeCollector(address(core), treasury, treasury);
        liq.setFeeCollector(address(collector));
    }
}
