// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {AerodromeAdapter} from "../../src/adapters/AerodromeAdapter.sol";
import {CurveAdapter} from "../../src/adapters/CurveAdapter.sol";
import {PancakeSwapAdapter} from "../../src/adapters/PancakeSwapAdapter.sol";

/// @title TestAdapters
/// @notice Deploys an adapter the way a deployment does: implementation plus ERC1967 proxy,
///         initialized in the same transaction.
/// @dev Adapters custody the collateral deposited through them, so they run behind proxies and
///      their constructors disable the initializers. A bare `new` therefore produces a contract
///      that can never be initialized — a shape no deployment has. Every call site goes through
///      here so the tests exercise the deployed configuration rather than a shape of their own.
library TestAdapters {
    function uniswapV2(address factory, address router, address core) internal returns (UniswapV2Adapter adapter) {
        adapter = UniswapV2Adapter(
            address(
                new ERC1967Proxy(
                    address(new UniswapV2Adapter()),
                    abi.encodeCall(UniswapV2Adapter.initialize, (factory, router, core))
                )
            )
        );
    }

    function uniswapV3(address nftManager, address factory, address core) internal returns (UniswapV3Adapter adapter) {
        adapter = UniswapV3Adapter(
            address(
                new ERC1967Proxy(
                    address(new UniswapV3Adapter()),
                    abi.encodeCall(UniswapV3Adapter.initialize, (nftManager, factory, core))
                )
            )
        );
    }

    function aerodrome(address router, address factory, address core) internal returns (AerodromeAdapter adapter) {
        adapter = AerodromeAdapter(
            address(
                new ERC1967Proxy(
                    address(new AerodromeAdapter()),
                    abi.encodeCall(AerodromeAdapter.initialize, (router, factory, core))
                )
            )
        );
    }

    function curve(address registry, address core) internal returns (CurveAdapter adapter) {
        adapter = CurveAdapter(
            address(
                new ERC1967Proxy(address(new CurveAdapter()), abi.encodeCall(CurveAdapter.initialize, (registry, core)))
            )
        );
    }

    function pancakeSwapV3(
        address v3NftManager,
        address v3Factory,
        address core
    )
        internal
        returns (PancakeSwapAdapter adapter)
    {
        adapter = _pancakeSwap(address(0), address(0), v3NftManager, v3Factory, core, true);
    }

    function pancakeSwapV2(
        address v2Factory,
        address v2Router,
        address core
    )
        internal
        returns (PancakeSwapAdapter adapter)
    {
        adapter = _pancakeSwap(v2Factory, v2Router, address(0), address(0), core, false);
    }

    function _pancakeSwap(
        address v2Factory,
        address v2Router,
        address v3NftManager,
        address v3Factory,
        address core,
        bool isV3
    )
        private
        returns (PancakeSwapAdapter adapter)
    {
        adapter = PancakeSwapAdapter(
            address(
                new ERC1967Proxy(
                    address(new PancakeSwapAdapter()),
                    abi.encodeCall(
                        PancakeSwapAdapter.initialize, (v2Factory, v2Router, v3NftManager, v3Factory, core, isV3)
                    )
                )
            )
        );
    }
}
