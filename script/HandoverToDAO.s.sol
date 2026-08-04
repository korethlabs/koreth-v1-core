// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ACLManager} from "../src/core/ACLManager.sol";
import {ProtocolCore} from "../src/core/ProtocolCore.sol";

/// @title Handover
/// @notice The two halves of transferring the protocol from the deploying team to the DAO.
/// @dev Kept as a library so the scripts below and the tests exercise the same code rather than
///      two copies that agree until one of them is edited.
///
///      Two steps rather than one because ProtocolCore.transferOwnership is a two-step transfer:
///      the DAO must call acceptOwnership() itself, and no script can do that on its behalf.
///
///      The order is not a preference. Revoking the deployer before the DAO owns ProtocolCore
///      would leave the ACL in the DAO's hands while ownership stayed with the deployer — and
///      setACLManager is onlyOwner, so the deployer could point the protocol at a fresh ACLManager
///      granting itself everything back. finalize() therefore refuses until ownership has moved.
library Handover {
    /// @notice Give the DAO the admin roles and start the ownership transfer.
    /// @dev Grants and a pending owner, no revocations: the protocol still needs an operator until
    ///      the DAO accepts. Note this is not "nothing has changed" — the DAO now holds
    ///      DEFAULT_ADMIN_ROLE, so from here it can revoke the deployer whenever it likes. What the
    ///      deployer keeps, it keeps at the DAO's discretion.
    function propose(ACLManager aclManager, ProtocolCore core, address dao) internal {
        aclManager.grantRole(aclManager.DEFAULT_ADMIN_ROLE(), dao);
        aclManager.addPoolAdmin(dao);
        aclManager.addRiskAdmin(dao);

        core.transferOwnership(dao);
    }

    /// @notice Verify the DAO owns the protocol, then strip the deployer of every admin role.
    /// @dev Every line here is a one-way door, so the precondition is enforced on-chain instead of
    ///      being left to whoever runs the script to remember.
    function finalize(ACLManager aclManager, ProtocolCore core, address dao, address deployer) internal {
        // Checked here and not only in the scripts' env loading, because this library is the shared
        // unit: called with the two the same it would strip the DAO of the roles it was just given.
        require(dao != deployer, "DAO_IS_DEPLOYER");
        require(core.owner() == dao, "DAO_HAS_NOT_ACCEPTED_OWNERSHIP");
        require(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), dao), "DAO_MISSING_DEFAULT_ADMIN");
        require(aclManager.isPoolAdmin(dao), "DAO_MISSING_POOL_ADMIN");
        require(aclManager.isRiskAdmin(dao), "DAO_MISSING_RISK_ADMIN");

        // Revoking a role an address does not hold is a no-op, so without this the script would
        // report a completed handover after stripping the wrong address — while the real deployer
        // kept everything. The whole value of this step is the assurance that it finished.
        require(deployer != address(0), "ZERO_DEPLOYER");
        require(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer), "DEPLOYER_NOT_ADMIN");
        require(aclManager.isPoolAdmin(deployer), "DEPLOYER_NOT_POOL_ADMIN");
        require(aclManager.isRiskAdmin(deployer), "DEPLOYER_NOT_RISK_ADMIN");

        // RISK_ADMIN first: it is the one the previous handover forgot, and the one that can move
        // an LTV to 100%.
        aclManager.removeRiskAdmin(deployer);
        aclManager.removePoolAdmin(deployer);

        // Only if held, because on most deployments the guardian is a different key and this would
        // be revoking someone else's role. But where the deploying key was also the guardian,
        // leaving it able to pause the protocol is not the "handover complete" this reports.
        // The DAO holds DEFAULT_ADMIN_ROLE by now and can appoint whatever guardian it wants.
        if (aclManager.isEmergencyAdmin(deployer)) {
            aclManager.removeEmergencyAdmin(deployer);
        }

        // DEFAULT_ADMIN_ROLE last: it is what authorises every revocation above, so giving it up
        // first would strand the rest.
        aclManager.revokeRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer);

        require(!aclManager.isRiskAdmin(deployer), "DEPLOYER_STILL_RISK_ADMIN");
        require(!aclManager.isPoolAdmin(deployer), "DEPLOYER_STILL_POOL_ADMIN");
        require(!aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer), "DEPLOYER_STILL_ADMIN");
        require(!aclManager.isEmergencyAdmin(deployer), "DEPLOYER_STILL_EMERGENCY_ADMIN");
    }
}

/// @dev Shared env loading and sanity checks for both steps.
abstract contract HandoverBase is Script {
    ACLManager internal aclManager;
    ProtocolCore internal core;
    address internal dao;
    address internal deployer;

    function _load() internal {
        deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        aclManager = ACLManager(vm.envAddress("ACL_MANAGER_ADDRESS"));
        core = ProtocolCore(vm.envAddress("PROTOCOL_CORE_ADDRESS"));
        dao = vm.envAddress("DAO_ADDRESS");

        require(dao != address(0), "ZERO_DAO");
        // Named checks rather than an opaque revert from calling into an empty address: the usual
        // way to get here wrong is a stale env var or the wrong chain.
        require(address(aclManager).code.length > 0, "ACL_MANAGER_NOT_CONTRACT");
        require(address(core).code.length > 0, "PROTOCOL_CORE_NOT_CONTRACT");
        // Handing over to the deployer is not a handover, and it is the shape a copy-paste mistake
        // takes. Refuse it rather than emit a convincing set of no-op events.
        require(dao != deployer, "DAO_IS_DEPLOYER");
        require(dao.code.length > 0, "DAO_NOT_CONTRACT");
        require(address(core.aclManager()) == address(aclManager), "ACL_CORE_MISMATCH");
    }
}

/// @notice Step 1 of the handover: grant the DAO its roles and set it as pending owner. No
///         revocations happen here — though the DAO can perform its own once it holds
///         DEFAULT_ADMIN_ROLE.
contract HandoverPropose is HandoverBase {
    function run() external {
        _load();

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        Handover.propose(aclManager, core, dao);
        vm.stopBroadcast();

        console.log("=== Handover proposed ===");
        console.log("DAO:                ", dao);
        console.log("DAO holds roles:     DEFAULT_ADMIN, POOL_ADMIN, RISK_ADMIN");
        console.log("ProtocolCore owner: ", core.owner());
        console.log("Pending owner:      ", core.pendingOwner());
        console.log("");
        console.log("NEXT: the DAO must call ProtocolCore.acceptOwnership().");
        console.log("Until it does, HandoverFinalize will refuse to revoke the deployer.");
    }
}

/// @notice Step 2 of the handover. One-way.
contract HandoverFinalize is HandoverBase {
    function run() external {
        _load();

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        Handover.finalize(aclManager, core, dao, deployer);
        vm.stopBroadcast();

        console.log("=== Handover complete ===");
        console.log("ProtocolCore owner: ", core.owner());
        console.log("Deployer roles:      DEFAULT_ADMIN_ROLE, POOL_ADMIN and RISK_ADMIN revoked");
        console.log("                     EMERGENCY_ADMIN revoked if the deployer held it");
    }
}
