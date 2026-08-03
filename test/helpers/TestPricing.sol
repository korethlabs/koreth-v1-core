// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";

/// @title TestPricing
/// @notice Wires the pricing a market now requires before ProtocolCore will list it.
/// @dev Most suites used to skip this and lean on the engines' $1 fallback, which is why a
///      borrow asset that was not worth a dollar went unnoticed for so long: the tests agreed
///      with the bug. With the fallback gone each suite has to state what its borrow asset is
///      worth, which is the point — the assumption is written down instead of inherited from a
///      pointer nobody set.
///
///      Deliberately the real PriceFeedRegistry and not a mock, so tests run the same price path
///      production does. Callers must be a pool admin (these are admin-gated calls).
library TestPricing {
    /// @notice Deploy a registry, install it on `core`, and declare `token` worth `priceE18`.
    /// @dev Suites needing more than one priced asset call setPeggedPrice on the returned registry.
    function wire(ProtocolCore core, address token, uint256 priceE18) internal returns (PriceFeedRegistry registry) {
        registry = new PriceFeedRegistry(address(core));
        core.setPriceFeedRegistry(address(registry));
        registry.setPeggedPrice(token, priceE18);
    }

    /// @notice wire() for the usual case: a stablecoin borrow asset worth exactly $1.
    function wireStable(ProtocolCore core, address token) internal returns (PriceFeedRegistry) {
        return wire(core, token, 1e18);
    }
}
