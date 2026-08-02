// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @title TestPools
/// @notice Gives a synthetic pool address enough of a body to be whitelisted.
/// @dev Most suites represent an AMM pool with a bare `makeAddr` label, which ProtocolCore now
///      rejects: a whitelisted pool that is not a contract can never be a real one, so accepting
///      it only defers the failure to the first call against it. The label stays — deterministic
///      addresses keep the tests readable — it just stops being an EOA.
library TestPools {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Put non-empty runtime code at `pool` so it passes the contract check.
    function asContract(address pool) internal returns (address) {
        vm.etch(pool, hex"01");
        return pool;
    }
}
