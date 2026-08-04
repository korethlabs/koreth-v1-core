// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {Handover} from "../../script/HandoverToDAO.s.sol";

/// @notice Stands in for the deploying team's key. The handover runs as a sequence of calls from
///         one account, so the tests need one — and routing through it means they exercise the
///         library the scripts use rather than a re-implementation of it.
contract DeployerAccount {
    function exec(address target, bytes memory data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function propose(ACLManager aclManager, ProtocolCore core, address dao) external {
        Handover.propose(aclManager, core, dao);
    }

    function finalize(ACLManager aclManager, ProtocolCore core, address dao, address deployer) external {
        Handover.finalize(aclManager, core, dao, deployer);
    }
}

/// @notice Stands in for the DAO. It only needs to be a contract that can accept ownership.
contract MockDAO {
    function accept(ProtocolCore core) external {
        core.acceptOwnership();
    }
}

/// @title HandoverTest
/// @notice The transfer from the deploying team to the DAO.
/// @dev The deploy deliberately leaves the deployer holding everything — the team runs the protocol
///      until it decides not to. What matters is that the ending is airtight, because every step of
///      it is irreversible.
contract HandoverTest is Test {
    ACLManager public aclManager;
    ProtocolCore public core;
    DeployerAccount public deployerAccount;
    MockDAO public dao;

    address public deployer;

    function setUp() public {
        deployerAccount = new DeployerAccount();
        deployer = address(deployerAccount);

        aclManager = new ACLManager(deployer);
        core = new ProtocolCore(deployer, address(aclManager));

        deployerAccount.exec(address(aclManager), abi.encodeCall(ACLManager.addRiskAdmin, (deployer)));

        dao = new MockDAO();
    }

    /// @dev The state the deploy scripts are supposed to leave behind. Asserted here so that
    ///      reintroducing a partial handoff at deploy time fails a test, rather than quietly
    ///      changing the launch posture.
    function test_deployerStartsWithEverything() public view {
        assertTrue(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(aclManager.isPoolAdmin(deployer));
        assertTrue(aclManager.isRiskAdmin(deployer));
        assertEq(core.owner(), deployer);
    }

    function test_propose_grantsDaoRolesAndKeepsDeployerOperating() public {
        deployerAccount.propose(aclManager, core, address(dao));

        assertTrue(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), address(dao)));
        assertTrue(aclManager.isPoolAdmin(address(dao)));
        assertTrue(aclManager.isRiskAdmin(address(dao)));

        // Still the deployer's protocol until the DAO accepts: the step is reversible on purpose.
        assertEq(core.owner(), deployer, "ownership does not move until accepted");
        assertEq(core.pendingOwner(), address(dao));
        assertTrue(aclManager.isPoolAdmin(deployer), "deployer must still be able to operate");
    }

    /// @dev The reason the handover is split in two. Revoking here would leave the ACL with the DAO
    ///      while ownership stayed with the deployer — and setACLManager is onlyOwner, so the
    ///      deployer could swap in an ACLManager granting itself everything back.
    function test_finalize_revertsBeforeDaoAcceptsOwnership() public {
        deployerAccount.propose(aclManager, core, address(dao));

        vm.expectRevert("DAO_HAS_NOT_ACCEPTED_OWNERSHIP");
        deployerAccount.finalize(aclManager, core, address(dao), deployer);

        assertTrue(aclManager.isRiskAdmin(deployer), "nothing may be revoked on a refused finalize");
        assertTrue(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer));
    }

    function test_finalize_revertsIfDaoWasNeverProposed() public {
        vm.expectRevert("DAO_HAS_NOT_ACCEPTED_OWNERSHIP");
        deployerAccount.finalize(aclManager, core, address(dao), deployer);
    }

    function test_fullHandover_leavesDeployerWithNothing() public {
        deployerAccount.propose(aclManager, core, address(dao));

        dao.accept(core);
        assertEq(core.owner(), address(dao));

        deployerAccount.finalize(aclManager, core, address(dao), deployer);

        assertFalse(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(aclManager.isPoolAdmin(deployer));
        assertFalse(aclManager.isRiskAdmin(deployer), "RISK_ADMIN is the one the old handoff kept");

        assertTrue(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), address(dao)));
        assertTrue(aclManager.isPoolAdmin(address(dao)));
        assertTrue(aclManager.isRiskAdmin(address(dao)));
    }

    /// @dev The takeover primitive the old half-handoff left open: ownership governs setACLManager,
    ///      so once it has moved the deployer can no longer swap the permission system out.
    function test_afterHandover_deployerCannotReplaceTheACL() public {
        deployerAccount.propose(aclManager, core, address(dao));
        dao.accept(core);
        deployerAccount.finalize(aclManager, core, address(dao), deployer);

        ACLManager hostile = new ACLManager(deployer);

        vm.expectRevert("NOT_OWNER");
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setACLManager, (address(hostile))));

        assertEq(address(core.aclManager()), address(aclManager));
    }

    /// @dev Before the handover this is exactly what the deployer *can* do. Stated as a test so the
    ///      launch posture is a documented property rather than something found during an audit.
    function test_beforeHandover_deployerCanReplaceTheACL() public {
        ACLManager replacement = new ACLManager(deployer);

        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setACLManager, (address(replacement))));

        assertEq(address(core.aclManager()), address(replacement));
    }
}
