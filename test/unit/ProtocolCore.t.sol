// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";

/// @notice Minimal contract used to satisfy code.length > 0 checks in ProtocolCore
contract Stub {}

contract ProtocolCoreTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public user = makeAddr("user");

    // Events — must redeclare to test with vm.expectEmit
    event AdapterRegistered(ILPAdapter.LPType indexed lpType, address indexed adapter);
    event OracleRegistered(ILPAdapter.LPType indexed lpType, address indexed oracle);
    event MarketRegistered(uint256 indexed marketId, address indexed market);
    event PoolWhitelisted(address indexed pool);
    event PoolRemoved(address indexed pool);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        vm.stopPrank();
    }

    /// @dev Deploy a Stub contract to use where code.length > 0 is required
    function _stub() internal returns (address) {
        return address(new Stub());
    }

    // ========== Constructor ==========

    function test_constructor_setsOwnerAndACL() public view {
        assertEq(core.owner(), owner);
        assertEq(address(core.aclManager()), address(aclManager));
        assertFalse(core.paused());
        assertEq(core.nextMarketId(), 0);
    }

    function test_constructor_revertsZeroOwner() public {
        vm.expectRevert("ZERO_OWNER");
        new ProtocolCore(address(0), address(aclManager));
    }

    function test_constructor_revertsZeroACL() public {
        vm.expectRevert("ZERO_ACL");
        new ProtocolCore(owner, address(0));
    }

    // ========== registerAdapter ==========

    function test_registerAdapter_success() public {
        address adapter = _stub();

        vm.expectEmit(true, true, false, false);
        emit AdapterRegistered(ILPAdapter.LPType.UniswapV3, adapter);

        vm.prank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, adapter);

        assertEq(core.adapters(ILPAdapter.LPType.UniswapV3), adapter);
    }

    function test_registerAdapter_overwriteExisting() public {
        address adapter1 = _stub();
        address adapter2 = _stub();

        vm.startPrank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, adapter1);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, adapter2);
        vm.stopPrank();

        assertEq(core.adapters(ILPAdapter.LPType.UniswapV3), adapter2);
    }

    function test_registerAdapter_revertsNotPoolAdmin() public {
        vm.prank(user);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, makeAddr("adapter"));
    }

    function test_registerAdapter_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(0));
    }

    function test_registerAdapter_revertsNotContract() public {
        vm.prank(owner);
        vm.expectRevert("NOT_CONTRACT");
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, makeAddr("eoa"));
    }

    function test_registerAdapter_guardianCannotRegister() public {
        vm.prank(guardian);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, makeAddr("adapter"));
    }

    // ========== registerOracle ==========

    function test_registerOracle_success() public {
        address oracle = _stub();

        vm.expectEmit(true, true, false, false);
        emit OracleRegistered(ILPAdapter.LPType.UniswapV3, oracle);

        vm.prank(owner);
        core.registerOracle(ILPAdapter.LPType.UniswapV3, oracle);

        assertEq(core.oracles(ILPAdapter.LPType.UniswapV3), oracle);
    }

    function test_registerOracle_revertsNotPoolAdmin() public {
        vm.prank(user);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.registerOracle(ILPAdapter.LPType.UniswapV3, makeAddr("oracle"));
    }

    function test_registerOracle_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(0));
    }

    function test_registerOracle_revertsNotContract() public {
        vm.prank(owner);
        vm.expectRevert("NOT_CONTRACT");
        core.registerOracle(ILPAdapter.LPType.UniswapV3, makeAddr("eoa"));
    }

    // ========== maxRegisteredLPType (PM-4) ==========

    function test_registerAdapter_updatesMaxLPType() public {
        assertEq(core.maxRegisteredLPType(), 0);
        address s1 = _stub();
        address s2 = _stub();
        address s3 = _stub();

        vm.prank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, s1);
        assertEq(core.maxRegisteredLPType(), 0); // UniswapV2 = 0

        vm.prank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, s2);
        assertEq(core.maxRegisteredLPType(), 1); // UniswapV3 = 1

        vm.prank(owner);
        core.registerAdapter(ILPAdapter.LPType.PancakeSwapV3, s3);
        assertEq(core.maxRegisteredLPType(), 5); // PancakeSwapV3 = 5
    }

    function test_registerAdapter_maxOnlyIncreases() public {
        address s1 = _stub();
        address s2 = _stub();

        vm.startPrank(owner);
        core.registerAdapter(ILPAdapter.LPType.PancakeSwapV3, s1); // = 5
        assertEq(core.maxRegisteredLPType(), 5);

        core.registerAdapter(ILPAdapter.LPType.UniswapV2, s2); // = 0
        assertEq(core.maxRegisteredLPType(), 5); // Still 5, not downgraded
        vm.stopPrank();
    }

    // ========== registerMarket ==========

    function test_registerMarket_success() public {
        address market = _stub();

        vm.expectEmit(true, true, false, false);
        emit MarketRegistered(0, market);

        vm.prank(owner);
        uint256 id = core.registerMarket(market);

        assertEq(id, 0);
        assertEq(core.markets(0), market);
        assertEq(core.nextMarketId(), 1);
    }

    function test_registerMarket_incrementsId() public {
        vm.startPrank(owner);
        uint256 id1 = core.registerMarket(_stub());
        uint256 id2 = core.registerMarket(_stub());
        uint256 id3 = core.registerMarket(_stub());
        vm.stopPrank();

        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(id3, 2);
        assertEq(core.nextMarketId(), 3);
    }

    function test_registerMarket_revertsDuplicate() public {
        address market = _stub();
        vm.startPrank(owner);
        core.registerMarket(market);
        vm.expectRevert("MARKET_ALREADY_REGISTERED");
        core.registerMarket(market);
        vm.stopPrank();
    }

    function test_registerMarket_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.registerMarket(address(0));
    }

    function test_registerMarket_revertsNotContract() public {
        vm.prank(owner);
        vm.expectRevert("NOT_CONTRACT");
        core.registerMarket(makeAddr("eoa"));
    }

    function test_registerMarket_revertsNotAuthorized() public {
        vm.prank(user);
        vm.expectRevert("NOT_AUTHORIZED");
        core.registerMarket(makeAddr("market"));
    }

    // ========== whitelistPool ==========

    function test_whitelistPool_success() public {
        address pool = makeAddr("pool");

        vm.expectEmit(true, false, false, false);
        emit PoolWhitelisted(pool);

        vm.prank(owner);
        core.whitelistPool(pool);

        assertTrue(core.isPoolSupported(pool));
        assertEq(core.poolAddedAt(pool), block.timestamp);
    }

    function test_whitelistPool_revertsAlreadyWhitelisted() public {
        address pool = makeAddr("pool");
        vm.startPrank(owner);
        core.whitelistPool(pool);

        vm.expectRevert("ALREADY_WHITELISTED");
        core.whitelistPool(pool);
        vm.stopPrank();
    }

    function test_whitelistPool_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.whitelistPool(address(0));
    }

    function test_whitelistPool_revertsNotPoolAdmin() public {
        vm.prank(user);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.whitelistPool(makeAddr("pool"));
    }

    // ========== removePool ==========

    function test_removePool_success() public {
        address pool = makeAddr("pool");

        vm.startPrank(owner);
        core.whitelistPool(pool);
        assertTrue(core.isPoolSupported(pool));

        vm.expectEmit(true, false, false, false);
        emit PoolRemoved(pool);

        core.removePool(pool);
        vm.stopPrank();

        assertFalse(core.isPoolSupported(pool));
        // poolAddedAt cleared on removal
        assertEq(core.poolAddedAt(pool), 0);
    }

    function test_removePool_revertsNotWhitelisted() public {
        vm.prank(owner);
        vm.expectRevert("NOT_WHITELISTED");
        core.removePool(makeAddr("pool"));
    }

    function test_removePool_revertsNotPoolAdmin() public {
        address pool = makeAddr("pool");
        vm.prank(owner);
        core.whitelistPool(pool);

        vm.prank(user);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.removePool(pool);
    }

    function test_removePool_canReWhitelistAfterRemoval() public {
        address pool = makeAddr("pool");

        vm.startPrank(owner);
        core.whitelistPool(pool);
        core.removePool(pool);
        assertFalse(core.isPoolSupported(pool));

        // Advance time so new timestamp is different
        vm.warp(block.timestamp + 1000);

        // Re-whitelist should work (pool is no longer in whitelist)
        core.whitelistPool(pool);
        assertTrue(core.isPoolSupported(pool));
        vm.stopPrank();
    }

    // ========== ACLManager Keeper Role ==========

    function test_keeper_grantRole() public {
        address keeper = makeAddr("keeper");
        bytes32 keeperRole = aclManager.KEEPER();

        vm.prank(owner);
        aclManager.grantRole(keeperRole, keeper);

        assertTrue(aclManager.isKeeper(keeper));
    }

    function test_keeper_revokeRole() public {
        address keeper = makeAddr("keeper");
        bytes32 keeperRole = aclManager.KEEPER();

        vm.startPrank(owner);
        aclManager.grantRole(keeperRole, keeper);
        assertTrue(aclManager.isKeeper(keeper));

        aclManager.revokeRole(keeperRole, keeper);
        assertFalse(aclManager.isKeeper(keeper));
        vm.stopPrank();
    }

    function test_keeper_revertsNotAdmin() public {
        bytes32 keeperRole = aclManager.KEEPER();
        bytes32 adminRole = aclManager.DEFAULT_ADMIN_ROLE();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, adminRole));
        aclManager.grantRole(keeperRole, makeAddr("keeper"));
    }

    // ========== transferOwnership (two-step) ==========

    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);

    function test_transferOwnership_twoStep() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: Propose
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, newOwner);

        vm.prank(owner);
        core.transferOwnership(newOwner);

        // Owner hasn't changed yet
        assertEq(core.owner(), owner);
        assertEq(core.pendingOwner(), newOwner);

        // Step 2: Accept
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, newOwner);

        vm.prank(newOwner);
        core.acceptOwnership();

        assertEq(core.owner(), newOwner);
        assertEq(core.pendingOwner(), address(0));
    }

    function test_transferOwnership_onlyPendingCanAccept() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        core.transferOwnership(newOwner);

        vm.prank(user);
        vm.expectRevert("NOT_PENDING_OWNER");
        core.acceptOwnership();
    }

    function test_transferOwnership_overwriteEmitsCancellation() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vm.prank(owner);
        core.transferOwnership(alice);
        assertEq(core.pendingOwner(), alice);

        // Overwrite with bob — should emit cancellation for alice
        vm.recordLogs();
        vm.prank(owner);
        core.transferOwnership(bob);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundCancellation = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("OwnershipTransferCancelled(address,address)")) {
                foundCancellation = true;
            }
        }
        assertTrue(foundCancellation, "Must emit cancellation for overwritten pending transfer");
        assertEq(core.pendingOwner(), bob);
    }

    function test_transferOwnership_newOwnerCanAct() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        core.transferOwnership(newOwner);
        vm.prank(newOwner);
        core.acceptOwnership();

        // Old owner can no longer act (transferOwnership is onlyOwner)
        vm.prank(owner);
        vm.expectRevert("NOT_OWNER");
        core.transferOwnership(makeAddr("someone"));

        // New owner can act
        vm.prank(newOwner);
        core.transferOwnership(makeAddr("someone"));
    }

    function test_cancelOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        core.transferOwnership(newOwner);
        assertEq(core.pendingOwner(), newOwner);

        vm.prank(owner);
        core.cancelOwnershipTransfer();
        assertEq(core.pendingOwner(), address(0));

        // newOwner can no longer accept
        vm.prank(newOwner);
        vm.expectRevert("NOT_PENDING_OWNER");
        core.acceptOwnership();
    }

    function test_cancelOwnershipTransfer_revertsNoPending() public {
        vm.prank(owner);
        vm.expectRevert("NO_PENDING_TRANSFER");
        core.cancelOwnershipTransfer();
    }

    function test_transferOwnership_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.transferOwnership(address(0));
    }

    function test_transferOwnership_revertsNotOwner() public {
        vm.prank(user);
        vm.expectRevert("NOT_OWNER");
        core.transferOwnership(makeAddr("newOwner"));
    }

    // ========== ACLManager Emergency Admin ==========

    function test_emergencyAdmin_addAndCheck() public {
        address newGuardian = makeAddr("newGuardian");

        vm.prank(owner);
        aclManager.addEmergencyAdmin(newGuardian);

        assertTrue(aclManager.isEmergencyAdmin(newGuardian));
    }

    function test_emergencyAdmin_newAdminCanPause() public {
        address newGuardian = makeAddr("newGuardian");

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(newGuardian);
        aclManager.removeEmergencyAdmin(guardian);
        vm.stopPrank();

        // Old guardian can no longer pause
        vm.prank(guardian);
        vm.expectRevert("NOT_EMERGENCY_ADMIN");
        core.pause();

        // New guardian can pause
        vm.prank(newGuardian);
        core.pause();
        assertTrue(core.paused());
    }

    function test_emergencyAdmin_revertsNotAdmin() public {
        bytes32 adminRole = aclManager.DEFAULT_ADMIN_ROLE();

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, adminRole)
        );
        aclManager.addEmergencyAdmin(makeAddr("newGuardian"));
    }

    // ========== pause / unpause ==========

    function test_pause_byGuardian() public {
        vm.expectEmit(true, false, false, false);
        emit Paused(guardian);

        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused());
    }

    function test_pause_byOwner() public {
        vm.expectEmit(true, false, false, false);
        emit Paused(owner);

        vm.prank(owner);
        core.pause();
        assertTrue(core.paused());
    }

    function test_pause_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert("NOT_EMERGENCY_ADMIN");
        core.pause();
    }

    function test_pause_revertsAlreadyPaused() public {
        vm.prank(guardian);
        core.pause();

        vm.prank(guardian);
        vm.expectRevert("ALREADY_PAUSED");
        core.pause();
    }

    function test_unpause_byOwner() public {
        vm.prank(guardian);
        core.pause();

        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);

        vm.prank(owner);
        core.unpause();
        assertFalse(core.paused());
    }

    function test_unpause_revertsNotPoolAdmin() public {
        vm.prank(guardian);
        core.pause();

        // Guardian CANNOT unpause (security feature)
        vm.prank(guardian);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.unpause();
    }

    function test_unpause_revertsNotPaused() public {
        vm.prank(owner);
        vm.expectRevert("NOT_PAUSED");
        core.unpause();
    }

    function test_pause_unpause_cycle() public {
        // Pause
        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused());

        // Unpause
        vm.prank(owner);
        core.unpause();
        assertFalse(core.paused());

        // Pause again
        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused());
    }

    // ========== getAdapter / getOracle ==========

    function test_getAdapter_success() public {
        address adapter = _stub();
        vm.prank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, adapter);

        assertEq(core.getAdapter(ILPAdapter.LPType.UniswapV3), adapter);
    }

    function test_getAdapter_revertsNotFound() public {
        vm.expectRevert("ADAPTER_NOT_FOUND");
        core.getAdapter(ILPAdapter.LPType.UniswapV3);
    }

    function test_getOracle_success() public {
        address oracle = _stub();
        vm.prank(owner);
        core.registerOracle(ILPAdapter.LPType.Curve, oracle);

        assertEq(core.getOracle(ILPAdapter.LPType.Curve), oracle);
    }

    function test_getOracle_revertsNotFound() public {
        vm.expectRevert("ORACLE_NOT_FOUND");
        core.getOracle(ILPAdapter.LPType.Curve);
    }

    // ========== isPoolSupported ==========

    function test_isPoolSupported_falseByDefault() public view {
        assertFalse(core.isPoolSupported(address(0xdead)));
    }

    function test_isPoolSupported_trueAfterWhitelist() public {
        address pool = makeAddr("pool");
        vm.prank(owner);
        core.whitelistPool(pool);
        assertTrue(core.isPoolSupported(pool));
    }

    function test_isPoolSupported_falseAfterRemoval() public {
        address pool = makeAddr("pool");
        vm.startPrank(owner);
        core.whitelistPool(pool);
        core.removePool(pool);
        vm.stopPrank();
        assertFalse(core.isPoolSupported(pool));
    }

    // ========== getPoolAge ==========

    function test_getPoolAge_returnsZeroIfNeverAdded() public view {
        assertEq(core.getPoolAge(address(0xdead)), 0);
    }

    function test_getPoolAge_returnsCorrectAge() public {
        address pool = makeAddr("pool");
        vm.prank(owner);
        core.whitelistPool(pool);

        vm.warp(block.timestamp + 3600);
        assertEq(core.getPoolAge(pool), 3600);
    }

    function test_getPoolAge_zeroAfterRemoval() public {
        address pool = makeAddr("pool");
        vm.startPrank(owner);
        core.whitelistPool(pool);
        vm.stopPrank();

        vm.warp(block.timestamp + 5000);

        vm.prank(owner);
        core.removePool(pool);

        // Removed pool returns 0 age (not currently supported)
        assertEq(core.getPoolAge(pool), 0);
    }

    // ========== Multiple LP types ==========

    function test_registerMultipleAdaptersAndOracles() public {
        address v2a = _stub();
        address v3a = _stub();
        address ca = _stub();
        address v2o = _stub();
        address v3o = _stub();
        address co = _stub();

        vm.startPrank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, v2a);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, v3a);
        core.registerAdapter(ILPAdapter.LPType.Curve, ca);

        core.registerOracle(ILPAdapter.LPType.UniswapV2, v2o);
        core.registerOracle(ILPAdapter.LPType.UniswapV3, v3o);
        core.registerOracle(ILPAdapter.LPType.Curve, co);
        vm.stopPrank();

        assertEq(core.adapters(ILPAdapter.LPType.UniswapV2), v2a);
        assertEq(core.adapters(ILPAdapter.LPType.UniswapV3), v3a);
        assertEq(core.adapters(ILPAdapter.LPType.Curve), ca);

        assertEq(core.oracles(ILPAdapter.LPType.UniswapV2), v2o);
        assertEq(core.oracles(ILPAdapter.LPType.UniswapV3), v3o);
        assertEq(core.oracles(ILPAdapter.LPType.Curve), co);
    }

    // ========== Fuzz tests ==========

    function testFuzz_registerMarket_incrementsCorrectly(uint8 count) public {
        count = uint8(bound(count, 1, 10));
        vm.startPrank(owner);
        for (uint8 i = 0; i < count; i++) {
            address market = address(new Stub());
            uint256 id = core.registerMarket(market);
            assertEq(id, i);
            assertEq(core.markets(id), market);
        }
        vm.stopPrank();
        assertEq(core.nextMarketId(), count);
    }

    function testFuzz_whitelistPool_anyAddress(address pool) public {
        vm.assume(pool != address(0));
        vm.prank(owner);
        core.whitelistPool(pool);
        assertTrue(core.isPoolSupported(pool));
    }

    function testFuzz_getPoolAge_increases(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 365 days);
        address pool = makeAddr("pool");

        vm.prank(owner);
        core.whitelistPool(pool);

        vm.warp(block.timestamp + elapsed);
        assertEq(core.getPoolAge(pool), elapsed);
    }

    function testFuzz_transferOwnership_anyNonZero(address newOwner) public {
        vm.assume(newOwner != address(0));
        vm.prank(owner);
        core.transferOwnership(newOwner);
        assertEq(core.pendingOwner(), newOwner);

        vm.prank(newOwner);
        core.acceptOwnership();
        assertEq(core.owner(), newOwner);
    }
}
