// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";

/// @title Stub contract for registration tests
contract StubContract {}

/// @title TimelockTest
/// @notice Tests timelock integration with ACLManager + ProtocolCore
/// @dev Validates: delayed execution, instant emergency, scheduled role transfer, cancellation
///      Note: In production, proposer and executor should be separate multisigs.
///      Tests use deployer as both for simplicity.
contract TimelockTest is Test {
    TimelockController public timelock;
    ACLManager public aclManager;
    ProtocolCore public core;
    RiskManager public riskManager;

    address public deployer = makeAddr("deployer");
    address public guardian = makeAddr("guardian");
    address public riskAdmin = makeAddr("riskAdmin");

    uint256 public constant MIN_DELAY = 48 hours;

    function setUp() public {
        vm.startPrank(deployer);

        aclManager = new ACLManager(deployer);

        // Deploy TimelockController (deployer = proposer + executor for testing)
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        core = new ProtocolCore(deployer, address(aclManager));
        riskManager = new RiskManager(address(core));

        // Grant roles
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addRiskAdmin(riskAdmin);

        // Grant admin to timelock (deployer keeps it temporarily)
        aclManager.grantRole(aclManager.POOL_ADMIN(), address(timelock));
        aclManager.grantRole(aclManager.DEFAULT_ADMIN_ROLE(), address(timelock));

        vm.stopPrank();
    }

    // ========== Delayed Operations ==========

    function test_registerAdapter_throughTimelock() public {
        address adapter = address(new StubContract());
        bytes memory data = abi.encodeCall(ProtocolCore.registerAdapter, (ILPAdapter.LPType.UniswapV3, adapter));

        // Schedule
        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        // Cannot execute before delay
        vm.prank(deployer);
        vm.expectRevert();
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        // Wait, then execute
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(deployer);
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        assertEq(core.adapters(ILPAdapter.LPType.UniswapV3), adapter);
    }

    function test_whitelistPool_throughTimelock() public {
        address pool = makeAddr("pool");
        bytes memory data = abi.encodeCall(ProtocolCore.whitelistPool, (pool));

        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        // Cannot execute before delay
        vm.prank(deployer);
        vm.expectRevert();
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(deployer);
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        assertTrue(core.isPoolSupported(pool));
    }

    // ========== Instant Operations (no timelock needed) ==========

    function test_pause_instantByGuardian() public {
        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused());
    }

    function test_unpause_byDeployer_whileStillPoolAdmin() public {
        // NOTE: This only works BEFORE deployer's POOL_ADMIN is revoked.
        // After full transfer, unpause requires going through the timelock.
        vm.prank(guardian);
        core.pause();

        vm.prank(deployer);
        core.unpause();
        assertFalse(core.paused());
    }

    function test_riskAdmin_canAdjustCapsInstantly() public {
        // RISK_ADMIN can change risk params without timelock
        vm.prank(riskAdmin);
        riskManager.setMaxPositionValue(5_000_000e18);
        assertEq(riskManager.maxPositionValue(), 5_000_000e18);

        vm.prank(riskAdmin);
        riskManager.setGlobalBorrowCap(50_000_000e18);
        assertEq(riskManager.globalBorrowCap(), 50_000_000e18);
    }

    // ========== Cannot Bypass Timelock ==========

    function test_registerAdapter_directCall_reverts_afterTransfer() public {
        // Revoke BOTH deployer roles through timelock (scheduled)
        _revokeDeployerRolesThroughTimelock();

        // Now deployer can't register directly (no POOL_ADMIN, can't re-grant via DEFAULT_ADMIN)
        address adapter = address(new StubContract());
        vm.prank(deployer);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, adapter);
    }

    function test_whitelistPool_directCall_reverts_afterTransfer() public {
        _revokeDeployerRolesThroughTimelock();

        vm.prank(deployer);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.whitelistPool(makeAddr("pool"));
    }

    /// @dev Helper: schedule + execute revocation of deployer's POOL_ADMIN and DEFAULT_ADMIN
    function _revokeDeployerRolesThroughTimelock() internal {
        bytes32 poolAdminRole = aclManager.POOL_ADMIN();
        bytes32 defaultAdminRole = aclManager.DEFAULT_ADMIN_ROLE();

        bytes memory revokePool = abi.encodeWithSelector(aclManager.revokeRole.selector, poolAdminRole, deployer);
        bytes memory revokeAdmin = abi.encodeWithSelector(aclManager.revokeRole.selector, defaultAdminRole, deployer);

        vm.startPrank(deployer);
        timelock.schedule(address(aclManager), 0, revokePool, bytes32(0), bytes32("rp"), MIN_DELAY);
        timelock.schedule(address(aclManager), 0, revokeAdmin, bytes32(0), bytes32("ra"), MIN_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        vm.startPrank(deployer);
        timelock.execute(address(aclManager), 0, revokePool, bytes32(0), bytes32("rp"));
        timelock.execute(address(aclManager), 0, revokeAdmin, bytes32(0), bytes32("ra"));
        vm.stopPrank();
    }

    // ========== Cancellation ==========

    function test_cancelScheduledOperation() public {
        address adapter = address(new StubContract());
        bytes memory data = abi.encodeCall(ProtocolCore.registerAdapter, (ILPAdapter.LPType.UniswapV3, adapter));
        bytes32 id = timelock.hashOperation(address(core), 0, data, bytes32(0), bytes32(0));

        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        assertTrue(timelock.isOperationPending(id));

        vm.prank(deployer);
        timelock.cancel(id);
        assertFalse(timelock.isOperationPending(id));

        // Cannot execute after cancel
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(deployer);
        vm.expectRevert();
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));
    }

    // ========== Role Transfer via Timelock (Bootstrap) ==========

    function test_fullRoleTransfer_throughTimelock() public {
        bytes32 poolAdminRole = aclManager.POOL_ADMIN();
        bytes32 defaultAdminRole = aclManager.DEFAULT_ADMIN_ROLE();

        // Before: deployer has both
        assertTrue(aclManager.hasRole(poolAdminRole, deployer));
        assertTrue(aclManager.hasRole(defaultAdminRole, deployer));

        // Transfer via timelock (48h delay)
        _revokeDeployerRolesThroughTimelock();

        // After: deployer lost all, timelock is sole admin
        assertFalse(aclManager.hasRole(poolAdminRole, deployer));
        assertFalse(aclManager.hasRole(defaultAdminRole, deployer));
        assertTrue(aclManager.hasRole(defaultAdminRole, address(timelock)));
        assertTrue(aclManager.hasRole(poolAdminRole, address(timelock)));
    }

    function test_afterTransfer_onlyTimelockCanGrantRoles() public {
        _revokeDeployerRolesThroughTimelock();

        // Deployer can no longer grant roles
        address newAdmin = makeAddr("newAdmin");
        bytes32 poolAdminRole = aclManager.POOL_ADMIN();
        vm.prank(deployer);
        vm.expectRevert();
        aclManager.grantRole(poolAdminRole, newAdmin);

        // Timelock can grant roles (through scheduled operation)
        bytes memory grantData = abi.encodeWithSelector(aclManager.grantRole.selector, poolAdminRole, newAdmin);
        vm.prank(deployer);
        timelock.schedule(address(aclManager), 0, grantData, bytes32(0), bytes32("grant"), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY + 1); // +1 to ensure past ready time
        vm.prank(deployer);
        timelock.execute(address(aclManager), 0, grantData, bytes32(0), bytes32("grant"));

        assertTrue(aclManager.isPoolAdmin(newAdmin));
    }

    // ========== Guardian After Full Transfer ==========

    function test_guardianCanPause_afterFullTransfer() public {
        // Full transfer through timelock
        _revokeDeployerRolesThroughTimelock();

        // Guardian can still pause instantly
        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused());

        // Guardian cannot unpause
        vm.prank(guardian);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.unpause();

        // Unpause requires timelock (48h delay)
        bytes memory unpauseData = abi.encodeCall(ProtocolCore.unpause, ());
        vm.prank(deployer);
        timelock.schedule(address(core), 0, unpauseData, bytes32(0), bytes32("unpause"), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.prank(deployer);
        timelock.execute(address(core), 0, unpauseData, bytes32(0), bytes32("unpause"));

        assertFalse(core.paused());
    }

    // ========== Timelock Config ==========

    function test_timelockDelay() public view {
        assertEq(timelock.getMinDelay(), MIN_DELAY);
    }

    // ========== Batch Operations ==========

    function test_batchOperation_registerAdapterAndWhitelistPool() public {
        address adapter = address(new StubContract());
        address pool = makeAddr("pool");

        address[] memory targets = new address[](2);
        targets[0] = address(core);
        targets[1] = address(core);

        uint256[] memory values = new uint256[](2);

        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(ProtocolCore.registerAdapter, (ILPAdapter.LPType.UniswapV3, adapter));
        payloads[1] = abi.encodeCall(ProtocolCore.whitelistPool, (pool));

        vm.prank(deployer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32("batch1"), MIN_DELAY);

        // Cannot execute before delay
        vm.prank(deployer);
        vm.expectRevert();
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32("batch1"));

        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(deployer);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32("batch1"));

        assertEq(core.adapters(ILPAdapter.LPType.UniswapV3), adapter);
        assertTrue(core.isPoolSupported(pool));
    }

    // ========== Direct Calls Blocked After Transfer ==========

    function test_directRegisterAdapter_reverts_afterTransfer() public {
        address adapter = address(new StubContract());
        _revokeDeployerRolesThroughTimelock();

        vm.prank(deployer);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, adapter);
    }

    function test_directWhitelistPool_reverts_afterTransfer() public {
        _revokeDeployerRolesThroughTimelock();

        vm.prank(deployer);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.whitelistPool(makeAddr("pool2"));
    }

    // ========== Ownership Transfer ==========

    function test_ownershipTransfer_throughTimelock() public {
        // Transfer ProtocolCore ownership to timelock
        vm.prank(deployer);
        core.transferOwnership(address(timelock));

        // Schedule acceptOwnership through timelock
        bytes memory acceptData = abi.encodeCall(ProtocolCore.acceptOwnership, ());
        vm.prank(deployer);
        timelock.schedule(address(core), 0, acceptData, bytes32(0), bytes32("accept"), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(deployer);
        timelock.execute(address(core), 0, acceptData, bytes32(0), bytes32("accept"));

        assertEq(core.owner(), address(timelock));
    }
}
