// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {CurveAdapter} from "../../src/adapters/CurveAdapter.sol";
import {AerodromeAdapter} from "../../src/adapters/AerodromeAdapter.sol";
import {PancakeSwapAdapter} from "../../src/adapters/PancakeSwapAdapter.sol";

/// @title AdapterCapabilities
/// @notice Verifies each adapter's self-declared capability flags: supportsFeeCollection()
///         and the stub isSupported() safety default.
contract AdapterCapabilities is Test {
    ProtocolCore internal core;

    address internal constant A = address(0xA11CE);
    address internal constant B = address(0xB0B);
    address internal constant C = address(0xC0FFEE);

    function setUp() public {
        ACLManager acl = new ACLManager(address(this));
        core = new ProtocolCore(address(this), address(acl));
    }

    // --- supportsFeeCollection() ---
    // Only concentrated-liquidity NFT adapters hold uncollected fees apart from principal, so the
    // liquidation fee-sweep must key off this flag rather than a hardcoded LP type.

    function test_uniswapV3_supportsFeeCollection_true() public {
        UniswapV3Adapter adapter = new UniswapV3Adapter(A, B, address(core));
        assertTrue(adapter.supportsFeeCollection(), "V3 holds fees in the NFT");
    }

    function test_uniswapV2_supportsFeeCollection_false() public {
        UniswapV2Adapter adapter = new UniswapV2Adapter(A, B, address(core));
        assertFalse(adapter.supportsFeeCollection(), "V2 fees compound into reserves");
    }

    function test_curve_supportsFeeCollection_false() public {
        CurveAdapter adapter = new CurveAdapter(A, address(core));
        assertFalse(adapter.supportsFeeCollection(), "Curve stub declares no separate fees");
    }

    function test_aerodrome_supportsFeeCollection_false() public {
        AerodromeAdapter adapter = new AerodromeAdapter(A, B, address(core));
        assertFalse(adapter.supportsFeeCollection(), "Aerodrome stub declares no separate fees");
    }

    function test_pancakeV3_supportsFeeCollection_false() public {
        PancakeSwapAdapter adapter = new PancakeSwapAdapter(address(0), address(0), A, B, address(core), true);
        assertFalse(adapter.supportsFeeCollection(), "Pancake stub declares no separate fees");
    }

    // --- isSupported() safety default on the PancakeSwap stub ---
    // Every functional method reverts NOT_IMPLEMENTED, so the V3 branch must not report support;
    // otherwise _detectLPType could route collateral into an adapter that cannot service it.

    function test_pancakeV3_isSupported_alwaysFalse() public {
        PancakeSwapAdapter adapter = new PancakeSwapAdapter(address(0), address(0), A, B, address(core), true);
        assertFalse(adapter.isSupported(A), "V3 NFT manager address must not report supported");
        assertFalse(adapter.isSupported(C), "arbitrary address must not report supported");
        assertFalse(adapter.isSupported(address(0)), "zero address must not report supported");
    }

    function test_pancakeV2_isSupported_alwaysFalse() public {
        PancakeSwapAdapter adapter = new PancakeSwapAdapter(A, B, address(0), address(0), address(core), false);
        assertFalse(adapter.isSupported(C), "V2 stub must not report supported");
    }
}
