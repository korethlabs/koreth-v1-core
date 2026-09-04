// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
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

    function finalize(
        ACLManager aclManager,
        ProtocolCore core,
        FeeCollector feeCollector,
        address dao,
        address deployer
    )
        external
    {
        Handover.finalize(aclManager, core, feeCollector, dao, deployer);
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
    FeeCollector public feeCollector;
    DeployerAccount public deployerAccount;
    MockDAO public dao;

    address public deployer;
    address public treasury = makeAddr("treasury");
    address public insuranceFund = makeAddr("insuranceFund");

    function setUp() public {
        deployerAccount = new DeployerAccount();
        deployer = address(deployerAccount);

        aclManager = new ACLManager(deployer);
        core = new ProtocolCore(deployer, address(aclManager));
        feeCollector = new FeeCollector(address(core), treasury, insuranceFund);

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

        // No revocations in this step: the protocol still needs an operator until the DAO accepts.
        // The DAO could revoke the deployer itself from here, having just been given DEFAULT_ADMIN.
        assertEq(core.owner(), deployer, "ownership does not move until accepted");
        assertEq(core.pendingOwner(), address(dao));
        assertTrue(aclManager.isPoolAdmin(deployer), "deployer must still be able to operate");
    }

    /// @dev The reason the handover is split in two. Revoking here would leave the ACL with the DAO
    ///      while ownership stayed with the deployer — an owner-vs-DEFAULT_ADMIN split. The ACL swap
    ///      being two-step (owner proposes, the current DEFAULT_ADMIN accepts) already denies the
    ///      deployer a self-serving replacement in that window, but the handover still refuses to
    ///      revoke early so ownership and the role authority move together.
    function test_finalize_revertsBeforeDaoAcceptsOwnership() public {
        deployerAccount.propose(aclManager, core, address(dao));

        vm.expectRevert("DAO_HAS_NOT_ACCEPTED_OWNERSHIP");
        deployerAccount.finalize(aclManager, core, feeCollector, address(dao), deployer);

        assertTrue(aclManager.isRiskAdmin(deployer), "nothing may be revoked on a refused finalize");
        assertTrue(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer));
    }

    /// @dev Revoking a role an address does not hold is a no-op, so stripping the wrong address
    ///      would otherwise look like a completed handover while the real deployer kept everything.
    function test_finalize_revertsIfStrippingAnAddressThatHoldsNothing() public {
        deployerAccount.propose(aclManager, core, address(dao));
        dao.accept(core);

        vm.expectRevert("DEPLOYER_NOT_ADMIN");
        deployerAccount.finalize(aclManager, core, feeCollector, address(dao), makeAddr("wrongAddress"));

        assertTrue(aclManager.isRiskAdmin(deployer), "the real deployer must be untouched");
        assertTrue(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer));
    }

    function test_finalize_revertsIfDaoWasNeverProposed() public {
        vm.expectRevert("DAO_HAS_NOT_ACCEPTED_OWNERSHIP");
        deployerAccount.finalize(aclManager, core, feeCollector, address(dao), deployer);
    }

    function test_fullHandover_leavesDeployerWithNothing() public {
        deployerAccount.propose(aclManager, core, address(dao));

        dao.accept(core);
        assertEq(core.owner(), address(dao));

        deployerAccount.finalize(aclManager, core, feeCollector, address(dao), deployer);

        assertFalse(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(aclManager.isPoolAdmin(deployer));
        assertFalse(aclManager.isRiskAdmin(deployer), "RISK_ADMIN is the one the old handoff kept");

        assertTrue(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), address(dao)));
        assertTrue(aclManager.isPoolAdmin(address(dao)));
        assertTrue(aclManager.isRiskAdmin(address(dao)));
    }

    /// @dev Every deploy profile used to pass the deployer as both fee recipients, and nothing
    ///      downstream noticed: the handover reported success while all protocol revenue kept
    ///      flowing to the deploying EOA. It is only after this step that the state becomes a trap —
    ///      moving either address needs POOL_ADMIN, which the deployer has just given up, so the
    ///      only remaining route is a DAO proposal nobody knows to write.
    function test_finalize_revertsIfTreasuryIsStillTheDeployer() public {
        deployerAccount.exec(address(feeCollector), abi.encodeCall(FeeCollector.setTreasury, (deployer)));

        deployerAccount.propose(aclManager, core, address(dao));
        dao.accept(core);

        vm.expectRevert("TREASURY_IS_DEPLOYER");
        deployerAccount.finalize(aclManager, core, feeCollector, address(dao), deployer);

        // The check sits ahead of every revocation, so a refusal strands nothing: the deployer can
        // still call setTreasury and run the step again.
        assertTrue(aclManager.isPoolAdmin(deployer), "a refused finalize must revoke nothing");
        assertTrue(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer));
    }

    function test_finalize_revertsIfInsuranceFundIsStillTheDeployer() public {
        deployerAccount.exec(address(feeCollector), abi.encodeCall(FeeCollector.setInsuranceFund, (deployer)));

        deployerAccount.propose(aclManager, core, address(dao));
        dao.accept(core);

        vm.expectRevert("INSURANCE_FUND_IS_DEPLOYER");
        deployerAccount.finalize(aclManager, core, feeCollector, address(dao), deployer);

        assertTrue(aclManager.isPoolAdmin(deployer), "a refused finalize must revoke nothing");
    }

    /// @dev FeeCollector accepts the two addresses being equal, and the deploy scripts refuse it;
    ///      but both are settable afterwards, so the handover is where the guarantee has to hold.
    ///      Collapsed, the insurance fund is not segregated from revenue and the split the contract
    ///      performs is arithmetic with no effect.
    function test_finalize_revertsIfFeeRecipientsCollapsed() public {
        address shared = makeAddr("shared");
        deployerAccount.exec(address(feeCollector), abi.encodeCall(FeeCollector.setTreasury, (shared)));
        deployerAccount.exec(address(feeCollector), abi.encodeCall(FeeCollector.setInsuranceFund, (shared)));

        deployerAccount.propose(aclManager, core, address(dao));
        dao.accept(core);

        vm.expectRevert("TREASURY_EQUALS_INSURANCE_FUND");
        deployerAccount.finalize(aclManager, core, feeCollector, address(dao), deployer);

        assertTrue(aclManager.isPoolAdmin(deployer), "a refused finalize must revoke nothing");
    }

    /// @dev On a deployment where the deploying key was also the guardian, leaving it able to pause
    ///      the protocol is not the "handover complete" the script reports. The DAO holds
    ///      DEFAULT_ADMIN_ROLE by then and can appoint whatever guardian it wants.
    function test_fullHandover_alsoStripsEmergencyAdminWhenDeployerHeldIt() public {
        deployerAccount.exec(address(aclManager), abi.encodeCall(ACLManager.addEmergencyAdmin, (deployer)));
        assertTrue(aclManager.isEmergencyAdmin(deployer));

        deployerAccount.propose(aclManager, core, address(dao));
        dao.accept(core);
        deployerAccount.finalize(aclManager, core, feeCollector, address(dao), deployer);

        assertFalse(aclManager.isEmergencyAdmin(deployer), "deployer must not keep the pause lever");
    }

    /// @dev The usual case: the guardian is a separate key, and the handover has no business
    ///      revoking a role that belongs to someone else.
    function test_fullHandover_leavesASeparateGuardianAlone() public {
        address guardian = makeAddr("guardian");
        deployerAccount.exec(address(aclManager), abi.encodeCall(ACLManager.addEmergencyAdmin, (guardian)));

        deployerAccount.propose(aclManager, core, address(dao));
        dao.accept(core);
        deployerAccount.finalize(aclManager, core, feeCollector, address(dao), deployer);

        assertTrue(aclManager.isEmergencyAdmin(guardian), "the guardian is not the deployer's role to lose");
    }

    /// @dev The takeover primitive the old half-handoff left open: ownership governs the ACL swap, so
    ///      once it has moved the deployer cannot even propose a replacement permission system.
    function test_afterHandover_deployerCannotReplaceTheACL() public {
        deployerAccount.propose(aclManager, core, address(dao));
        dao.accept(core);
        deployerAccount.finalize(aclManager, core, feeCollector, address(dao), deployer);

        ACLManager hostile = new ACLManager(deployer);

        vm.expectRevert("NOT_OWNER");
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setPendingACLManager, (address(hostile))));

        assertEq(address(core.aclManager()), address(aclManager));
    }

    /// @dev Before the handover this is exactly what the deployer *can* do — but now in two steps,
    ///      because it holds both owner (proposes) and DEFAULT_ADMIN_ROLE (accepts). Stated as a test
    ///      so the launch posture is a documented property rather than something found during an audit.
    function test_beforeHandover_deployerCanReplaceTheACL() public {
        ACLManager replacement = new ACLManager(deployer);

        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setPendingACLManager, (address(replacement))));
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.acceptACLManager, ()));

        assertEq(address(core.aclManager()), address(replacement));
    }

    /// @dev With owner and DEFAULT_ADMIN_ROLE held by different parties — the exact mid-handover
    ///      window — a lone owner can no longer swap the ACL. It can propose, but acceptance is gated
    ///      on the *current* role authority, which it lacks.
    function test_aclSwap_loneOwnerCannotComplete_whenAdminDiverged() public {
        // Force the divergence: propose gives the DAO DEFAULT_ADMIN_ROLE (and makes it pending owner
        // without moving ownership), then the DAO revokes the deployer. Result: owner is still the
        // deployer, DEFAULT_ADMIN_ROLE is the DAO's alone.
        bytes32 adminRole = aclManager.DEFAULT_ADMIN_ROLE();
        deployerAccount.propose(aclManager, core, address(dao));
        vm.prank(address(dao));
        aclManager.revokeRole(adminRole, deployer);

        assertEq(core.owner(), deployer, "owner still the deployer");
        assertFalse(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer), "deployer lost DEFAULT_ADMIN");

        ACLManager hostile = new ACLManager(deployer);

        // Owner can still propose...
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setPendingACLManager, (address(hostile))));
        assertEq(core.pendingACLManager(), address(hostile));

        // ...but cannot accept: it no longer holds DEFAULT_ADMIN_ROLE on the current manager.
        vm.expectRevert("NOT_ACL_ADMIN");
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.acceptACLManager, ()));
        assertEq(address(core.aclManager()), address(aclManager), "hostile swap did not take effect");

        // The rightful authority (the DAO, which now holds DEFAULT_ADMIN) is the one that co-signs.
        vm.prank(address(dao));
        core.acceptACLManager();
        assertEq(address(core.aclManager()), address(hostile), "current admin completes the two-step");
    }

    /// @dev A pending manager that was a contract at proposal time can be codeless by acceptance
    ///      (SELFDESTRUCT, or a CREATE2 target not yet deployed). Accepting it would brick every
    ///      role-gated path, so acceptance re-validates code length.
    function test_acceptACLManager_revertsIfPendingLostCode() public {
        ACLManager replacement = new ACLManager(deployer);
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setPendingACLManager, (address(replacement))));

        // Simulate the pending manager losing its code between proposal and acceptance.
        vm.etch(address(replacement), "");

        vm.expectRevert("NOT_CONTRACT");
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.acceptACLManager, ()));
        assertEq(address(core.aclManager()), address(aclManager), "codeless swap did not take effect");
    }

    function test_setPendingACLManager_revertsZeroAddress() public {
        vm.expectRevert("ZERO_ADDRESS");
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setPendingACLManager, (address(0))));
    }

    function test_setPendingACLManager_revertsNonContract() public {
        vm.expectRevert("NOT_CONTRACT");
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setPendingACLManager, (makeAddr("eoa"))));
    }

    function test_setPendingACLManager_revertsNotOwner() public {
        ACLManager replacement = new ACLManager(deployer);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("NOT_OWNER");
        core.setPendingACLManager(address(replacement));
    }

    function test_acceptACLManager_revertsWhenNothingPending() public {
        vm.expectRevert("NO_PENDING_TRANSFER");
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.acceptACLManager, ()));
    }

    function test_cancelACLManagerTransfer_clearsPending() public {
        ACLManager replacement = new ACLManager(deployer);
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setPendingACLManager, (address(replacement))));
        assertEq(core.pendingACLManager(), address(replacement));

        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.cancelACLManagerTransfer, ()));
        assertEq(core.pendingACLManager(), address(0), "pending must be cleared");
        assertEq(address(core.aclManager()), address(aclManager), "current manager unchanged");
    }

    function test_cancelACLManagerTransfer_revertsWhenNothingPending() public {
        vm.expectRevert("NO_PENDING_TRANSFER");
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.cancelACLManagerTransfer, ()));
    }

    function test_cancelACLManagerTransfer_revertsNotOwner() public {
        ACLManager replacement = new ACLManager(deployer);
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setPendingACLManager, (address(replacement))));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("NOT_OWNER");
        core.cancelACLManagerTransfer();
    }

    /// @dev Re-proposing replaces the pending target and announces the withdrawal of the previous one.
    function test_setPendingACLManager_overwriteEmitsCancellation() public {
        ACLManager first = new ACLManager(deployer);
        ACLManager second = new ACLManager(deployer);
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setPendingACLManager, (address(first))));

        vm.expectEmit(true, true, false, false, address(core));
        emit ProtocolCore.ACLManagerTransferCancelled(address(aclManager), address(first));
        vm.expectEmit(true, true, false, false, address(core));
        emit ProtocolCore.ACLManagerTransferStarted(address(aclManager), address(second));
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setPendingACLManager, (address(second))));

        assertEq(core.pendingACLManager(), address(second));
    }

    function test_acceptACLManager_emitsUpdatedAndClearsPending() public {
        ACLManager replacement = new ACLManager(deployer);
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setPendingACLManager, (address(replacement))));

        vm.expectEmit(true, true, false, false, address(core));
        emit ProtocolCore.ACLManagerUpdated(address(aclManager), address(replacement));
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.acceptACLManager, ()));

        assertEq(address(core.aclManager()), address(replacement), "manager swapped");
        assertEq(core.pendingACLManager(), address(0), "pending cleared after accept");
    }

    /// @dev After the swap the role modifiers must read the NEW manager: a role granted only there
    ///      now authorises, and one granted only on the old manager no longer does.
    function test_afterSwap_roleChecksResolveAgainstNewManager() public {
        // The replacement's admin/POOL_ADMIN is a fresh account, not the deployer.
        address newAdmin = makeAddr("newAdmin");
        ACLManager replacement = new ACLManager(newAdmin);

        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.setPendingACLManager, (address(replacement))));
        // Accept still needs DEFAULT_ADMIN on the current manager, which the deployer holds.
        deployerAccount.exec(address(core), abi.encodeCall(ProtocolCore.acceptACLManager, ()));

        // Authorised only on the new manager: newAdmin (POOL_ADMIN there) can now whitelist. The pool
        // must be a contract (whitelistLpPool checks code length), so reuse an existing one.
        vm.prank(newAdmin);
        core.whitelistLpPool(address(aclManager), ILPAdapter.LPType.UniswapV2);

        // The deployer is POOL_ADMIN only on the old manager, so it no longer passes onlyPoolAdmin.
        assertFalse(replacement.isPoolAdmin(deployer), "deployer is not admin on the new manager");
        vm.expectRevert("NOT_POOL_ADMIN");
        deployerAccount.exec(
            address(core),
            abi.encodeCall(ProtocolCore.whitelistLpPool, (makeAddr("pool2"), ILPAdapter.LPType.UniswapV2))
        );
    }
}
