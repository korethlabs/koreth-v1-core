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
    /// @dev The deployer keeps its own roles here: until the DAO accepts, the protocol still needs
    ///      an operator. Nothing is lost if the DAO never accepts.
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
        require(core.owner() == dao, "DAO_HAS_NOT_ACCEPTED_OWNERSHIP");
        require(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), dao), "DAO_MISSING_DEFAULT_ADMIN");
        require(aclManager.isPoolAdmin(dao), "DAO_MISSING_POOL_ADMIN");
        require(aclManager.isRiskAdmin(dao), "DAO_MISSING_RISK_ADMIN");

        // RISK_ADMIN first: it is the one the previous handover forgot, and the one that can move
        // an LTV to 100%.
        aclManager.removeRiskAdmin(deployer);
        aclManager.removePoolAdmin(deployer);
        aclManager.revokeRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer);

        require(!aclManager.isRiskAdmin(deployer), "DEPLOYER_STILL_RISK_ADMIN");
        require(!aclManager.isPoolAdmin(deployer), "DEPLOYER_STILL_POOL_ADMIN");
        require(!aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer), "DEPLOYER_STILL_ADMIN");
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
        // Handing over to the deployer is not a handover, and it is the shape a copy-paste mistake
        // takes. Refuse it rather than emit a convincing set of no-op events.
        require(dao != deployer, "DAO_IS_DEPLOYER");
        require(dao.code.length > 0, "DAO_NOT_CONTRACT");
        require(address(core.aclManager()) == address(aclManager), "ACL_CORE_MISMATCH");
    }
}

/// @notice Step 1 of the handover. Reversible: nothing the deployer holds is given up here.
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
        console.log("Deployer roles:      none");
    }
}
