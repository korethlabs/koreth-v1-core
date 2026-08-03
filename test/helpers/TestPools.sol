// SPDX-License-Identifier: MIT
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
        // STOP: a call into the stub returns cleanly. `01` is ADD, which underflows the stack and
        // reverts, so a test that ever touched the address would fail for an unrelated reason.
        vm.etch(pool, hex"00");
        return pool;
    }
}
