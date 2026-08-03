// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";

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
}
