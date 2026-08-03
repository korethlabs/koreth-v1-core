// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {MockConstantFeed} from "../mocks/MockConstantFeed.sol";

/// @title TestPricing
/// @notice Wires the pricing a market needs before ProtocolCore will list it.
/// @dev Most suites used to skip this and lean on the engines' $1 fallback, which is why a borrow
///      asset that was not worth a dollar went unnoticed for so long: the tests agreed with the
///      bug. With the fallback gone, each suite states what its borrow asset is worth.
///
///      Every asset gets a real feed, so nothing here bypasses the sequencer check, staleness or
///      the sanity bounds — tests price through the same path production does. Callers must be a
///      pool admin (these are admin-gated calls).
library TestPricing {
    /// @notice Deploy a registry, install it on `core`, and give `token` a feed at `priceE18`.
    /// @dev Suites needing more than one priced asset call priceAsset() on the returned registry.
    function wire(ProtocolCore core, address token, uint256 priceE18) internal returns (PriceFeedRegistry registry) {
        registry = new PriceFeedRegistry(address(core));
        core.setPriceFeedRegistry(address(registry));
        priceAsset(registry, token, priceE18);
    }

    /// @notice wire() for the usual case: a stablecoin borrow asset worth exactly $1.
    function wireStable(ProtocolCore core, address token) internal returns (PriceFeedRegistry) {
        return wire(core, token, 1e18);
    }

    /// @notice Give `token` a constant feed at `priceE18` on an already-installed registry.
    /// @return feed The aggregator, so a test can move the price with setAnswer — a borrow asset
    ///         that never moves is the case the fail-closed pricing work exists to handle.
    function priceAsset(
        PriceFeedRegistry registry,
        address token,
        uint256 priceE18
    )
        internal
        returns (MockConstantFeed feed)
    {
        feed = new MockConstantFeed(int256(priceE18));
        registry.setPriceFeed(token, address(feed));
    }

    /// @notice The feed backing `token`, for suites that wired it through wire()/wireStable().
    function feedFor(PriceFeedRegistry registry, address token) internal view returns (MockConstantFeed) {
        return MockConstantFeed(registry.priceFeeds(token));
    }
}
