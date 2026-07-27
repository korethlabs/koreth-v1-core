// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {AerodromeOracle} from "../../src/oracle/AerodromeOracle.sol";
import {CurveOracle} from "../../src/oracle/CurveOracle.sol";

/// @title StubOraclesTest
/// @notice B4: unimplemented oracles must fail closed (isHealthy == false, pricing reverts)
///         until real implementations land.
contract StubOraclesTest is Test {
    AerodromeOracle public aeroOracle;
    CurveOracle public curveOracle;

    function setUp() public {
        address owner = makeAddr("owner");
        ACLManager acl = new ACLManager(owner);
        ProtocolCore core = new ProtocolCore(owner, address(acl));
        aeroOracle = new AerodromeOracle(address(core));
        curveOracle = new CurveOracle(address(core));
    }

    function test_aerodromeOracle_isNotHealthy() public view {
        assertFalse(aeroOracle.isHealthy());
    }

    function test_curveOracle_isNotHealthy() public view {
        assertFalse(curveOracle.isHealthy());
    }

    function test_aerodromeOracle_getPriceReverts() public {
        vm.expectRevert("NOT_IMPLEMENTED");
        aeroOracle.getPrice(address(0), 0, 0);
    }

    function test_curveOracle_getPriceReverts() public {
        vm.expectRevert("NOT_IMPLEMENTED");
        curveOracle.getPrice(address(0), 0, 0);
    }
}
