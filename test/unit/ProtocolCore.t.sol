// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {TestPricing} from "../helpers/TestPricing.sol";
import {TestPools} from "../helpers/TestPools.sol";

/// @notice Minimal contract used to satisfy code.length > 0 checks in ProtocolCore
contract Stub {}

/// @notice Minimal lending-pool stub — `registerLendingPool` cross-checks `borrowAsset()` against the key
contract PoolStub {
    address public borrowAsset;

    constructor(address _borrowAsset) {
        borrowAsset = _borrowAsset;
    }
}

contract ProtocolCoreTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PriceFeedRegistry public priceRegistry;
    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public user = makeAddr("user");

    // Events — must redeclare to test with vm.expectEmit
    event AdapterRegistered(ILPAdapter.LPType indexed lpType, address indexed oldAdapter, address indexed adapter);
    event OracleRegistered(ILPAdapter.LPType indexed lpType, address indexed oldOracle, address indexed oracle);
    event LendingPoolRegistered(address indexed borrowAsset, address indexed pool);
    event LpPoolWhitelisted(address indexed pool);
    event LpPoolRemoved(address indexed pool);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        // The suite declares its own asset prices, so give it the role directly rather than
        // wrapping every helper in a prank that would clash with the tests' startPrank blocks.
        aclManager.addPoolAdmin(address(this));
        priceRegistry = new PriceFeedRegistry(address(core));
        core.setPriceFeedRegistry(address(priceRegistry));
        vm.stopPrank();
    }

    /// @dev Deploy a Stub contract to use where code.length > 0 is required
    function _stub() internal returns (address) {
        return address(new Stub());
    }

    /// @dev Deploy a pool stub that reports `borrowAsset` as its own borrow asset
    function _poolStub(address borrowAsset) internal returns (address) {
        return address(new PoolStub(borrowAsset));
    }

    /// @dev A borrow asset the protocol can price. registerLendingPool refuses to list a market it cannot
    ///      value, so a bare stub is no longer a usable borrow asset.
    function _borrowAsset() internal returns (address asset) {
        asset = address(new Stub());
        TestPricing.priceAsset(priceRegistry, asset, 1e18);
    }

    /// @dev A whitelistable pool: an AMM pool is a contract, and ProtocolCore now insists.
    function _pool(string memory label) internal returns (address) {
        return TestPools.asContract(makeAddr(label));
    }

    // ========== Constructor ==========

    function test_constructor_setsOwnerAndACL() public view {
        assertEq(core.owner(), owner);
        assertEq(address(core.aclManager()), address(aclManager));
        assertFalse(core.paused());
        assertEq(core.poolFactory(), address(0));
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

        vm.expectEmit(true, true, true, false);
        emit AdapterRegistered(ILPAdapter.LPType.UniswapV3, address(0), adapter);

        vm.prank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, adapter);

        assertEq(core.adapters(ILPAdapter.LPType.UniswapV3), adapter);
    }

    /// @dev Replacing a live adapter has to be distinguishable from configuring one for the first
    ///      time: the event is the only record that a component handling real collateral was
    ///      swapped underneath the protocol.
    function test_registerAdapter_overwriteExisting() public {
        address adapter1 = _stub();
        address adapter2 = _stub();

        vm.startPrank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, adapter1);

        vm.expectEmit(true, true, true, false);
        emit AdapterRegistered(ILPAdapter.LPType.UniswapV3, adapter1, adapter2);
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

        vm.expectEmit(true, true, true, false);
        emit OracleRegistered(ILPAdapter.LPType.UniswapV3, address(0), oracle);

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

    // ========== registerLendingPool ==========

    function test_registerLendingPool_success() public {
        address borrowAsset = _borrowAsset();
        address pool = _poolStub(borrowAsset);

        vm.expectEmit(true, true, false, false);
        emit LendingPoolRegistered(borrowAsset, pool);

        vm.prank(owner);
        core.registerLendingPool(borrowAsset, pool);

        assertEq(core.lendingPool(borrowAsset), pool);
        assertTrue(core.isLendingPool(pool));
    }

    function test_registerLendingPool_multipleAssets() public {
        vm.startPrank(owner);
        address a1 = _borrowAsset();
        address a2 = _borrowAsset();
        address p1 = _poolStub(a1);
        address p2 = _poolStub(a2);
        core.registerLendingPool(a1, p1);
        core.registerLendingPool(a2, p2);
        vm.stopPrank();

        assertEq(core.lendingPool(a1), p1);
        assertEq(core.lendingPool(a2), p2);
    }

    function test_registerLendingPool_revertsDuplicateAsset() public {
        address borrowAsset = _borrowAsset();
        address stub2 = _poolStub(borrowAsset);
        vm.startPrank(owner);
        core.registerLendingPool(borrowAsset, _poolStub(borrowAsset));
        vm.expectRevert("LENDING_POOL_ALREADY_REGISTERED");
        core.registerLendingPool(borrowAsset, stub2);
        vm.stopPrank();
    }

    /// @dev A satellite bound to another core would read that core's admin roles, and neither the
    ///      registry nor the risk manager can be unset once wrong — so the link is checked here
    ///      rather than discovered at the next borrow.
    function test_setPriceFeedRegistry_rejectsForeignCore() public {
        ProtocolCore otherCore = new ProtocolCore(owner, address(aclManager));
        PriceFeedRegistry foreign = new PriceFeedRegistry(address(otherCore));

        vm.prank(owner);
        vm.expectRevert("WRONG_CORE");
        core.setPriceFeedRegistry(address(foreign));
    }

    /// @dev Mirrors getLendingPool/getAdapter/getOracle: the borrow-side consumers resolve the registry
    ///      through here, so a deployment that reaches them before wiring fails by name rather than
    ///      as a call into an empty address.
    function test_getPriceFeedRegistry_revertsWhenUnset() public {
        ProtocolCore fresh = new ProtocolCore(owner, address(aclManager));

        vm.expectRevert("PRICE_REGISTRY_UNSET");
        fresh.getPriceFeedRegistry();

        assertEq(core.getPriceFeedRegistry(), address(priceRegistry), "a configured core resolves it");
    }

    /// @dev Listing and pricing are atomic. A market whose borrow asset has no price source can be
    ///      borrowed from but not valued, so its debt would never count against a health factor —
    ///      the position would read as healthy no matter how much was drawn against it.
    function test_registerLendingPool_revertsWhenBorrowAssetNotPriceable() public {
        address borrowAsset = _stub(); // deliberately never declared priceable
        address pool = _poolStub(borrowAsset);

        vm.prank(owner);
        vm.expectRevert("BORROW_ASSET_NOT_PRICEABLE");
        core.registerLendingPool(borrowAsset, pool);

        assertEq(core.lendingPool(borrowAsset), address(0), "no market may exist for an unpriceable asset");
    }

    /// @dev The key must match the pool's own borrow asset, or every `lendingPool[asset]` lookup
    ///      would resolve to a pool that lends a different token.
    function test_registerLendingPool_revertsBorrowAssetMismatch() public {
        address pool = _poolStub(_stub());
        address otherAsset = _stub();
        vm.prank(owner);
        vm.expectRevert("BORROW_ASSET_MISMATCH");
        core.registerLendingPool(otherAsset, pool);
    }

    function test_registerLendingPool_revertsZeroAddress() public {
        address borrowAsset = _stub();
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.registerLendingPool(borrowAsset, address(0));
    }

    /// @dev An EOA key would satisfy the borrowAsset() cross-check and only fail later, on the
    ///      first transfer. PoolFactory screens this too; registerLendingPool is the path that bypasses it.
    function test_registerLendingPool_revertsBorrowAssetNotContract() public {
        address borrowAsset = makeAddr("eoa-usdc");
        address pool = _poolStub(borrowAsset);
        vm.prank(owner);
        vm.expectRevert("BORROW_ASSET_NOT_CONTRACT");
        core.registerLendingPool(borrowAsset, pool);
    }

    function test_registerLendingPool_revertsZeroBorrowAsset() public {
        address stub = _stub();
        vm.prank(owner);
        vm.expectRevert("ZERO_BORROW_ASSET");
        core.registerLendingPool(address(0), stub);
    }

    function test_registerLendingPool_revertsNotContract() public {
        address borrowAsset = _stub();
        vm.prank(owner);
        vm.expectRevert("NOT_CONTRACT");
        core.registerLendingPool(borrowAsset, makeAddr("eoa"));
    }

    function test_registerLendingPool_revertsNotAuthorized() public {
        vm.prank(user);
        vm.expectRevert("NOT_AUTHORIZED");
        core.registerLendingPool(makeAddr("usdc"), makeAddr("pool"));
    }

    // ========== whitelistLpPool ==========

    function test_whitelistLpPool_success() public {
        address pool = _pool("pool");

        vm.expectEmit(true, false, false, false);
        emit LpPoolWhitelisted(pool);

        vm.prank(owner);
        core.whitelistLpPool(pool);

        assertTrue(core.isLpPoolSupported(pool));
        assertEq(core.lpPoolAddedAt(pool), block.timestamp);
    }

    function test_whitelistLpPool_revertsAlreadyWhitelisted() public {
        address pool = _pool("pool");
        vm.startPrank(owner);
        core.whitelistLpPool(pool);

        vm.expectRevert("ALREADY_WHITELISTED");
        core.whitelistLpPool(pool);
        vm.stopPrank();
    }

    function test_whitelistLpPool_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.whitelistLpPool(address(0));
    }

    function test_whitelistLpPool_revertsNotPoolAdmin() public {
        vm.prank(user);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.whitelistLpPool(_pool("pool"));
    }

    // ========== removeLpPool ==========

    function test_removeLpPool_success() public {
        address pool = _pool("pool");

        vm.startPrank(owner);
        core.whitelistLpPool(pool);
        assertTrue(core.isLpPoolSupported(pool));

        vm.expectEmit(true, false, false, false);
        emit LpPoolRemoved(pool);

        core.removeLpPool(pool);
        vm.stopPrank();

        assertFalse(core.isLpPoolSupported(pool));
        // lpPoolAddedAt cleared on removal
        assertEq(core.lpPoolAddedAt(pool), 0);
    }

    function test_removeLpPool_revertsNotWhitelisted() public {
        vm.prank(owner);
        vm.expectRevert("NOT_WHITELISTED");
        core.removeLpPool(makeAddr("pool"));
    }

    function test_removeLpPool_revertsNotPoolAdmin() public {
        address pool = _pool("pool");
        vm.prank(owner);
        core.whitelistLpPool(pool);

        vm.prank(user);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.removeLpPool(pool);
    }

    function test_removeLpPool_canReWhitelistAfterRemoval() public {
        address pool = _pool("pool");

        vm.startPrank(owner);
        core.whitelistLpPool(pool);
        core.removeLpPool(pool);
        assertFalse(core.isLpPoolSupported(pool));

        // Advance time so new timestamp is different
        vm.warp(block.timestamp + 1000);

        // Re-whitelist should work (pool is no longer in whitelist)
        core.whitelistLpPool(pool);
        assertTrue(core.isLpPoolSupported(pool));
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

    function test_unpause_byGuardian() public {
        vm.prank(guardian);
        core.pause();

        // Symmetric with pause(): an emergency admin can also restore service (Aave V3 parity).
        vm.expectEmit(true, false, false, false);
        emit Unpaused(guardian);

        vm.prank(guardian);
        core.unpause();
        assertFalse(core.paused());
    }

    function test_unpause_byPoolAdmin() public {
        address poolAdmin = makeAddr("poolAdmin");
        vm.prank(owner);
        aclManager.addPoolAdmin(poolAdmin);

        vm.prank(guardian);
        core.pause();

        // Pool admins keep unpause authority after the change (onlyEmergencyAdmin includes them).
        vm.prank(poolAdmin);
        core.unpause();
        assertFalse(core.paused());
    }

    function test_unpause_revertsNotEmergencyAdmin() public {
        vm.prank(guardian);
        core.pause();

        vm.prank(user);
        vm.expectRevert("NOT_EMERGENCY_ADMIN");
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

    // ========== isLpPoolSupported ==========

    function test_isLpPoolSupported_falseByDefault() public view {
        assertFalse(core.isLpPoolSupported(address(0xdead)));
    }

    function test_isLpPoolSupported_trueAfterWhitelist() public {
        address pool = _pool("pool");
        vm.prank(owner);
        core.whitelistLpPool(pool);
        assertTrue(core.isLpPoolSupported(pool));
    }

    function test_isLpPoolSupported_falseAfterRemoval() public {
        address pool = _pool("pool");
        vm.startPrank(owner);
        core.whitelistLpPool(pool);
        core.removeLpPool(pool);
        vm.stopPrank();
        assertFalse(core.isLpPoolSupported(pool));
    }

    // ========== getLpPoolAge ==========

    function test_getLpPoolAge_returnsZeroIfNeverAdded() public view {
        assertEq(core.getLpPoolAge(address(0xdead)), 0);
    }

    function test_getLpPoolAge_returnsCorrectAge() public {
        address pool = _pool("pool");
        vm.prank(owner);
        core.whitelistLpPool(pool);

        vm.warp(block.timestamp + 3600);
        assertEq(core.getLpPoolAge(pool), 3600);
    }

    function test_getLpPoolAge_zeroAfterRemoval() public {
        address pool = _pool("pool");
        vm.startPrank(owner);
        core.whitelistLpPool(pool);
        vm.stopPrank();

        vm.warp(block.timestamp + 5000);

        vm.prank(owner);
        core.removeLpPool(pool);

        // Removed pool returns 0 age (not currently supported)
        assertEq(core.getLpPoolAge(pool), 0);
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

    function testFuzz_registerLendingPool_distinctAssets(uint8 count) public {
        count = uint8(bound(count, 1, 10));
        vm.startPrank(owner);
        for (uint8 i = 0; i < count; i++) {
            address borrowAsset = _borrowAsset();
            address pool = address(new PoolStub(borrowAsset));
            core.registerLendingPool(borrowAsset, pool);
            assertEq(core.lendingPool(borrowAsset), pool);
        }
        vm.stopPrank();
    }

    /// @dev Any contract may be curated as collateral backing — the adapters, not this registry,
    ///      decide whether it is an authentic pool from the configured factory.
    function testFuzz_whitelistLpPool_anyContract(address pool) public {
        // Precompiles cannot be etched, and are not addresses a pool would ever live at.
        vm.assume(pool > address(0x0a) && pool.code.length == 0);
        TestPools.asContract(pool);

        vm.prank(owner);
        core.whitelistLpPool(pool);
        assertTrue(core.isLpPoolSupported(pool));
    }

    /// @dev An address with no code cannot be a pool, so accepting it would only defer the failure
    ///      to the first call made against it.
    function testFuzz_whitelistLpPool_rejectsNonContract(address pool) public {
        vm.assume(pool != address(0) && pool.code.length == 0);

        vm.prank(owner);
        vm.expectRevert("NOT_CONTRACT");
        core.whitelistLpPool(pool);
    }

    function testFuzz_getLpPoolAge_increases(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 365 days);
        address pool = _pool("pool");

        vm.prank(owner);
        core.whitelistLpPool(pool);

        vm.warp(block.timestamp + elapsed);
        assertEq(core.getLpPoolAge(pool), elapsed);
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
