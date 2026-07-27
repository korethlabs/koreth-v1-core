// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";

/// @dev V2 mock that extends PositionManager with a new state variable appended after the __gap.
///      This simulates a future upgrade adding new storage — verifies existing state is preserved.
contract PositionManagerV2Mock is PositionManager {
    uint256 public newStateVar;

    function setNewStateVar(uint256 val) external {
        newStateVar = val;
    }
}

/// @title UpgradeE2E
/// @notice End-to-end tests for UUPS upgrade scenarios across Koreth protocol proxies.
contract UpgradeE2E is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    // ================================================================
    // 1. Upgrade preserves position state
    // ================================================================

    function test_upgrade_preservesPositionState() public {
        // Alice deposits a V3 position and borrows
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = maxBorrow / 4;

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Snapshot position state before upgrade
        IPositionManager.Position memory posBefore = positionManager.getPosition(positionId);
        uint256 debtBefore = lendingEngine.getDebt(positionId);

        // Deploy new implementation and upgrade
        vm.startPrank(deployer);
        PositionManager newImpl = new PositionManager();
        positionManager.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();

        // Verify all position fields are preserved
        IPositionManager.Position memory posAfter = positionManager.getPosition(positionId);
        assertEq(posAfter.owner, posBefore.owner, "owner mismatch after upgrade");
        assertEq(posAfter.lpToken, posBefore.lpToken, "lpToken mismatch after upgrade");
        assertEq(posAfter.tokenId, posBefore.tokenId, "tokenId mismatch after upgrade");
        assertEq(posAfter.amount, posBefore.amount, "amount mismatch after upgrade");
        assertEq(uint8(posAfter.status), uint8(posBefore.status), "status mismatch after upgrade");
        assertEq(posAfter.marketId, posBefore.marketId, "marketId mismatch after upgrade");

        uint256 debtAfter = lendingEngine.getDebt(positionId);
        assertEq(debtAfter, debtBefore, "debt mismatch after upgrade");
    }

    // ================================================================
    // 2. Upgrade preserves market state
    // ================================================================

    function test_upgrade_preservesMarketState() public {
        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);

        // Alice deposits and borrows to generate interest
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 4);

        // Advance time and accrue interest
        _advanceTime(1 hours);
        market.accrueInterest();

        // Snapshot market state before upgrade
        IMarket.MarketState memory stateBefore = market.getMarketState();
        uint256 borrowIndexBefore = market.borrowIndex();

        // Deploy new Market impl and upgrade
        vm.startPrank(deployer);
        Market newMarketImpl = new Market();
        Market(marketAddr).upgradeToAndCall(address(newMarketImpl), "");
        vm.stopPrank();

        // Verify market state preserved
        IMarket.MarketState memory stateAfter = market.getMarketState();
        assertEq(stateAfter.totalSupply, stateBefore.totalSupply, "totalSupply mismatch after upgrade");
        assertEq(stateAfter.totalBorrow, stateBefore.totalBorrow, "totalBorrow mismatch after upgrade");

        uint256 borrowIndexAfter = market.borrowIndex();
        assertEq(borrowIndexAfter, borrowIndexBefore, "borrowIndex mismatch after upgrade");
    }

    // ================================================================
    // 3. Mid-lifecycle upgrade — operations continue working
    // ================================================================

    function test_upgrade_midLifecycle_canContinueOps() public {
        // Alice deposits and borrows
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = maxBorrow / 4;

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Upgrade both PositionManager and LendingEngine
        vm.startPrank(deployer);
        PositionManager newPmImpl = new PositionManager();
        positionManager.upgradeToAndCall(address(newPmImpl), "");

        LendingEngine newLeImpl = new LendingEngine();
        lendingEngine.upgradeToAndCall(address(newLeImpl), "");
        vm.stopPrank();

        // Repay full debt
        uint256 debt = lendingEngine.getDebt(positionId);
        address marketAddr = core.markets(ethUsdcMarketId);
        IMarket.MarketConfig memory cfg = IMarket(marketAddr).getConfig();

        vm.startPrank(alice);
        IERC20(cfg.borrowAsset).approve(address(marketAddr), debt);
        lendingEngine.repay(positionId, debt);
        vm.stopPrank();

        // Verify debt is zero
        uint256 debtAfterRepay = lendingEngine.getDebt(positionId);
        assertEq(debtAfterRepay, 0, "debt should be zero after full repay");

        // Withdraw position
        vm.prank(alice);
        positionManager.withdraw(positionId);

        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Closed), "position should be closed");
    }

    // ================================================================
    // 4. Only pool admin can upgrade
    // ================================================================

    function test_upgrade_onlyPoolAdmin() public {
        PositionManager newPmImpl = new PositionManager();
        LendingEngine newLeImpl = new LendingEngine();
        LiquidationEngine newLiqImpl = new LiquidationEngine();

        address marketAddr = core.markets(ethUsdcMarketId);
        Market newMarketImpl = new Market();

        // Alice (non-admin) cannot upgrade PositionManager
        vm.startPrank(alice);

        vm.expectRevert("NOT_POOL_ADMIN");
        positionManager.upgradeToAndCall(address(newPmImpl), "");

        vm.expectRevert("NOT_POOL_ADMIN");
        lendingEngine.upgradeToAndCall(address(newLeImpl), "");

        vm.expectRevert("NOT_POOL_ADMIN");
        liquidationEngine.upgradeToAndCall(address(newLiqImpl), "");

        vm.expectRevert("NOT_POOL_ADMIN");
        Market(marketAddr).upgradeToAndCall(address(newMarketImpl), "");

        vm.stopPrank();
    }

    // ================================================================
    // 5. Cannot reinitialize after upgrade
    // ================================================================

    function test_upgrade_cannotReinitialize() public {
        // Upgrade PositionManager
        vm.startPrank(deployer);
        PositionManager newImpl = new PositionManager();
        positionManager.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();

        // Attempt to re-initialize should revert
        vm.prank(deployer);
        vm.expectRevert();
        positionManager.initialize(address(core), address(oracleHub));

        // Same for LendingEngine
        vm.startPrank(deployer);
        LendingEngine newLeImpl = new LendingEngine();
        lendingEngine.upgradeToAndCall(address(newLeImpl), "");
        vm.stopPrank();

        vm.prank(deployer);
        vm.expectRevert();
        lendingEngine.initialize(address(core), address(positionManager));

        // Same for Market
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(deployer);
        Market newMarketImpl = new Market();
        Market(marketAddr).upgradeToAndCall(address(newMarketImpl), "");
        vm.stopPrank();

        IMarket.MarketConfig memory cfg = IMarket(marketAddr).getConfig();
        vm.prank(deployer);
        vm.expectRevert();
        Market(marketAddr).initialize(cfg, address(volatileModel), address(core));
    }

    // ================================================================
    // 6. Upgrade with new state var — existing state preserved, new var accessible
    // ================================================================

    function test_upgrade_storageGap_newVarDoesNotCollide() public {
        // Alice deposits and borrows to create state
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = maxBorrow / 4;

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Snapshot state
        IPositionManager.Position memory posBefore = positionManager.getPosition(positionId);
        uint256 nextIdBefore = positionManager.nextPositionId();
        uint256 debtBefore = lendingEngine.getDebt(positionId);

        // Upgrade to V2 mock with extra state variable
        vm.startPrank(deployer);
        PositionManagerV2Mock v2Impl = new PositionManagerV2Mock();
        positionManager.upgradeToAndCall(address(v2Impl), "");
        vm.stopPrank();

        // Cast to V2 mock to access new function
        PositionManagerV2Mock pmV2 = PositionManagerV2Mock(address(positionManager));

        // New variable should be uninitialized (zero)
        assertEq(pmV2.newStateVar(), 0, "new var should be zero initially");

        // Set the new variable
        vm.prank(deployer);
        pmV2.setNewStateVar(42);
        assertEq(pmV2.newStateVar(), 42, "new var should be set");

        // All old state should be intact
        IPositionManager.Position memory posAfter = positionManager.getPosition(positionId);
        assertEq(posAfter.owner, posBefore.owner, "owner corrupted after V2 upgrade");
        assertEq(posAfter.lpToken, posBefore.lpToken, "lpToken corrupted after V2 upgrade");
        assertEq(posAfter.tokenId, posBefore.tokenId, "tokenId corrupted after V2 upgrade");
        assertEq(posAfter.amount, posBefore.amount, "amount corrupted after V2 upgrade");
        assertEq(uint8(posAfter.status), uint8(posBefore.status), "status corrupted after V2 upgrade");
        assertEq(positionManager.nextPositionId(), nextIdBefore, "nextPositionId corrupted after V2 upgrade");

        uint256 debtAfter = lendingEngine.getDebt(positionId);
        assertEq(debtAfter, debtBefore, "debt corrupted after V2 upgrade");
    }
}
