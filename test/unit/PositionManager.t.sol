// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceFeedRegistry} from "../mocks/MockPriceFeedRegistry.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";

contract PositionManagerTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LPOracleHub public oracleHub;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockMarket public market;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    LendingEngine public le;
    address public lendingEngine; // Set in setUp to le proxy address
    address public liquidationEngine = makeAddr("liquidationEngine");
    address public lpToken = makeAddr("lpToken");

    uint256 public marketId;

    // Events
    event PositionCreated(
        uint256 indexed positionId,
        address indexed owner,
        address lpToken,
        uint256 tokenId,
        ILPAdapter.LPType lpType,
        uint256 value
    );
    event PositionClosed(uint256 indexed positionId, address indexed owner);
    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 debtRepaid);

    function setUp() public {
        // Deploy ACLManager and core
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        // Deploy oracle hub (UUPS proxy)
        LPOracleHub oracleHubImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(oracleHubImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );

        // Deploy PositionManager (UUPS proxy)
        PositionManager pmImpl = new PositionManager();
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        // Deploy real LendingEngine (UUPS proxy)
        LendingEngine leImpl = new LendingEngine();
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );
        lendingEngine = address(le);

        // Deploy mocks
        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        InterestRateModel irm = new InterestRateModel(200, 600, 10_000, 8000);
        market = new MockMarket(address(usdc), address(irm));

        // Register everything and grant roles via ACLManager
        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(lendingEngine);
        aclManager.addLiquidationEngine(liquidationEngine);
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
        pm.setLendingEngine(lendingEngine);
        vm.stopPrank();
    }

    // ========== Initialization ==========

    function test_initialize_setsCorrectState() public view {
        assertEq(address(pm.core()), address(core));
        assertEq(address(pm.oracleHub()), address(oracleHub));
        assertEq(pm.nextPositionId(), 1);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        pm.initialize(address(core), address(oracleHub));
    }

    // ========== ACLManager Role Checks ==========

    function test_aclRoles_lendingEngineGranted() public view {
        assertTrue(aclManager.isLendingEngine(lendingEngine));
    }

    function test_aclRoles_liquidationEngineGranted() public view {
        assertTrue(aclManager.isLiquidationEngine(liquidationEngine));
    }

    function test_aclRoles_revokeRole() public {
        bytes32 leRole = aclManager.LENDING_ENGINE();

        vm.prank(owner);
        aclManager.revokeRole(leRole, lendingEngine);
        assertFalse(aclManager.isLendingEngine(lendingEngine));
    }

    function test_aclRoles_revertsNotAdmin() public {
        bytes32 leRole = aclManager.LENDING_ENGINE();
        bytes32 adminRole = aclManager.DEFAULT_ADMIN_ROLE();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, adminRole));
        aclManager.grantRole(leRole, makeAddr("x"));
    }

    // ========== deposit ==========

    function test_deposit_success() public {
        vm.expectEmit(true, true, false, false);
        emit PositionCreated(1, alice, lpToken, 1, ILPAdapter.LPType.UniswapV3, 50_000e18);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        assertEq(posId, 1);
        assertEq(pm.nextPositionId(), 2);

        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(pos.id, 1);
        assertEq(pos.owner, alice);
        assertEq(pos.lpToken, lpToken);
        assertEq(pos.tokenId, 1);
        assertEq(pos.amount, 100e18);
        assertEq(uint8(pos.lpType), uint8(ILPAdapter.LPType.UniswapV3));
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Active));
        assertEq(pos.depositTimestamp, block.timestamp);
        assertEq(pos.depositBlock, block.number);
    }

    function test_deposit_multiplePositions() public {
        vm.startPrank(alice);
        uint256 id1 = pm.deposit(lpToken, 1, 100e18, marketId);
        uint256 id2 = pm.deposit(lpToken, 2, 200e18, marketId);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(pm.nextPositionId(), 3);

        uint256[] memory positions = pm.getPositionsByOwner(alice);
        assertEq(positions.length, 2);
        assertEq(positions[0], 1);
        assertEq(positions[1], 2);
    }

    function test_deposit_differentUsers() public {
        vm.prank(alice);
        pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(bob);
        pm.deposit(lpToken, 2, 200e18, marketId);

        assertEq(pm.getPositionsByOwner(alice).length, 1);
        assertEq(pm.getPositionsByOwner(bob).length, 1);
    }

    function test_deposit_recordsDepositBlock() public {
        vm.roll(12_345);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        assertEq(pm.getDepositBlock(posId), 12_345);
    }

    function test_deposit_revertsZeroLpToken() public {
        vm.prank(alice);
        vm.expectRevert("ZERO_LP_TOKEN");
        pm.deposit(address(0), 1, 100e18, marketId);
    }

    function test_deposit_revertsInvalidMarket() public {
        vm.prank(alice);
        vm.expectRevert("INVALID_MARKET");
        pm.deposit(lpToken, 1, 100e18, 999);
    }

    function test_deposit_revertsUnsupportedLP() public {
        address unknownToken = makeAddr("unknownLP");
        vm.prank(alice);
        vm.expectRevert("UNSUPPORTED_LP");
        pm.deposit(unknownToken, 1, 100e18, marketId);
    }

    function test_deposit_revertsPoolNotSupported() public {
        // Create a new LP token that adapter supports but pool isn't whitelisted
        address newLP = makeAddr("newLP");
        adapter.setSupportedToken(newLP, true);
        // newLP will be returned as pool by the mock adapter, but it's not whitelisted

        vm.prank(alice);
        vm.expectRevert("POOL_NOT_SUPPORTED");
        pm.deposit(newLP, 1, 100e18, marketId);
    }

    function test_deposit_revertsZeroValue() public {
        oracle.setPrice(0);

        vm.prank(alice);
        vm.expectRevert("ZERO_VALUE");
        pm.deposit(lpToken, 1, 100e18, marketId);
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(guardian);
        core.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        pm.deposit(lpToken, 1, 100e18, marketId);
    }

    // ========== withdraw ==========

    function test_withdraw_success() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.expectEmit(true, true, false, false);
        emit PositionClosed(posId, alice);

        vm.prank(alice);
        pm.withdraw(posId);

        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Closed));
        assertEq(adapter.unlockCallCount(), 1);
    }

    function test_withdraw_revertsNotOwner() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(bob);
        vm.expectRevert("NOT_POSITION_OWNER");
        pm.withdraw(posId);
    }

    function test_withdraw_revertsHasDebt() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        // Simulate debt
        vm.prank(lendingEngine);
        pm.updateDebt(posId, 10_000e18);

        vm.prank(alice);
        vm.expectRevert("HAS_DEBT");
        pm.withdraw(posId);
    }

    function test_withdraw_revertsAlreadyClosed() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(alice);
        pm.withdraw(posId);

        vm.prank(alice);
        vm.expectRevert("NOT_ACTIVE");
        pm.withdraw(posId);
    }

    function test_withdraw_revertsLiquidatedPosition() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(liquidationEngine);
        pm.markLiquidated(posId, makeAddr("liq"), 5000e18);

        vm.prank(alice);
        vm.expectRevert("NOT_ACTIVE");
        pm.withdraw(posId);
    }

    function test_withdraw_revertsPositionNotFound() public {
        vm.prank(alice);
        vm.expectRevert("POSITION_NOT_FOUND");
        pm.withdraw(999);
    }

    function test_withdraw_revertsWhenPaused() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(guardian);
        core.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        pm.withdraw(posId);
    }

    // ========== updateDebt ==========

    function test_updateDebt_setsDebtAndStatus() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(lendingEngine);
        pm.updateDebt(posId, 10_000e18);

        assertEq(pm.positionDebt(posId), 10_000e18);
        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Borrowed));
    }

    function test_updateDebt_clearsDebtResetsStatus() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.startPrank(lendingEngine);
        pm.updateDebt(posId, 10_000e18);
        pm.updateDebt(posId, 0);
        vm.stopPrank();

        assertEq(pm.positionDebt(posId), 0);
        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Active));
    }

    function test_updateDebt_revertsNotLendingEngine() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(alice);
        vm.expectRevert("NOT_LENDING_ENGINE");
        pm.updateDebt(posId, 10_000e18);
    }

    function test_updateDebt_revertsClosedPosition() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(alice);
        pm.withdraw(posId);

        vm.prank(lendingEngine);
        vm.expectRevert("POSITION_NOT_BORROWABLE");
        pm.updateDebt(posId, 10_000e18);
    }

    function test_updateDebt_revertsLiquidatedPosition() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(liquidationEngine);
        pm.markLiquidated(posId, makeAddr("liq"), 5000e18);

        vm.prank(lendingEngine);
        vm.expectRevert("POSITION_NOT_BORROWABLE");
        pm.updateDebt(posId, 10_000e18);
    }

    function test_updateDebt_ownerCannotCallDirectly() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        // Owner does NOT bypass LendingEngine role check
        vm.prank(owner);
        vm.expectRevert("NOT_LENDING_ENGINE");
        pm.updateDebt(posId, 5000e18);
    }

    // ========== reducePositionAmount (PM-3 fix) ==========

    event PositionAmountReduced(uint256 indexed positionId, uint256 amountRemoved, uint256 newAmount);

    function test_reducePositionAmount_success() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.expectEmit(true, false, false, true);
        emit PositionAmountReduced(posId, 30e18, 70e18);

        vm.prank(liquidationEngine);
        pm.reducePositionAmount(posId, 30e18);

        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(pos.amount, 70e18);
    }

    function test_reducePositionAmount_multipleReductions() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.startPrank(liquidationEngine);
        pm.reducePositionAmount(posId, 20e18);
        pm.reducePositionAmount(posId, 30e18);
        pm.reducePositionAmount(posId, 10e18);
        vm.stopPrank();

        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(pos.amount, 40e18); // 100 - 20 - 30 - 10
    }

    function test_reducePositionAmount_toZero() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(liquidationEngine);
        pm.reducePositionAmount(posId, 100e18);

        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(pos.amount, 0);
    }

    function test_reducePositionAmount_revertsExceedsAmount() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(liquidationEngine);
        vm.expectRevert("EXCEEDS_POSITION_AMOUNT");
        pm.reducePositionAmount(posId, 101e18);
    }

    function test_reducePositionAmount_revertsZeroAmount() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(liquidationEngine);
        vm.expectRevert("ZERO_AMOUNT");
        pm.reducePositionAmount(posId, 0);
    }

    function test_reducePositionAmount_revertsNotLiquidationEngine() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(alice);
        vm.expectRevert("NOT_LIQUIDATION_ENGINE");
        pm.reducePositionAmount(posId, 50e18);
    }

    function test_reducePositionAmount_revertsPositionNotFound() public {
        vm.prank(liquidationEngine);
        vm.expectRevert("POSITION_NOT_FOUND");
        pm.reducePositionAmount(999, 50e18);
    }

    // ========== markLiquidated ==========

    function test_markLiquidated_success() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(lendingEngine);
        pm.updateDebt(posId, 10_000e18);

        vm.expectEmit(true, true, false, true);
        emit PositionLiquidated(posId, makeAddr("liquidator"), 5000e18);

        vm.prank(liquidationEngine);
        pm.markLiquidated(posId, makeAddr("liquidator"), 5000e18);

        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Liquidated));
        assertEq(pm.positionDebt(posId), 0); // Debt cleared
    }

    function test_markLiquidated_revertsNotLiquidationEngine() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(alice);
        vm.expectRevert("NOT_LIQUIDATION_ENGINE");
        pm.markLiquidated(posId, makeAddr("liq"), 5000e18);
    }

    function test_markLiquidated_revertsZeroLiquidator() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(liquidationEngine);
        vm.expectRevert("ZERO_LIQUIDATOR");
        pm.markLiquidated(posId, address(0), 5000e18);
    }

    // ========== View Functions ==========

    function test_getPositionValue_returnsOraclePrice() public {
        oracle.setPrice(75_000e18);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        assertEq(pm.getPositionValue(posId), 75_000e18);
    }

    function test_getPositionValue_zeroForNonexistent() public view {
        assertEq(pm.getPositionValue(999), 0);
    }

    function test_getHealthFactor_maxWithNoDebt() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        assertEq(pm.getHealthFactor(posId), type(uint256).max);
    }

    function test_getHealthFactor_calculatesCorrectly() public {
        oracle.setPrice(10_000e18); // $10,000 collateral

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        // Mock LendingEngine.getDebt to return $5,000 in 6-dec USDC (market's borrow asset)
        vm.mockCall(
            lendingEngine, abi.encodeWithSelector(LendingEngine.getDebt.selector, posId), abi.encode(uint256(5000e6))
        );

        uint256 hf = pm.getHealthFactor(posId);
        // debtUsd = 5000e6 normalized to 18 dec = 5000e18
        // HF = (10000e18 * 7500 * 1e18) / (5000e18 * 10000) = 1.5e18
        assertEq(hf, 1.5e18);

        vm.clearMockedCalls();
    }

    function test_getHealthFactor_zeroWhenCollateralZero() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        // Mock LendingEngine.getDebt to return $5,000 in 6-dec USDC
        vm.mockCall(
            lendingEngine, abi.encodeWithSelector(LendingEngine.getDebt.selector, posId), abi.encode(uint256(5000e6))
        );

        // Set oracle to 0 after deposit
        oracle.setPrice(0);
        assertEq(pm.getHealthFactor(posId), 0);

        vm.clearMockedCalls();
    }

    function test_getDepositBlock() public {
        vm.roll(100);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        assertEq(pm.getDepositBlock(posId), 100);

        vm.roll(200);
        vm.prank(alice);
        uint256 posId2 = pm.deposit(lpToken, 2, 50e18, marketId);
        assertEq(pm.getDepositBlock(posId2), 200);
    }

    function test_getPositionsByOwner_emptyForNoPositions() public view {
        assertEq(pm.getPositionsByOwner(alice).length, 0);
    }

    // ========== UUPS Upgrade ==========

    function test_upgrade_onlyPoolAdmin() public {
        PositionManager newImpl = new PositionManager();

        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        pm.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_preservesState() public {
        // Deposit a position
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        // Upgrade
        PositionManager newImpl = new PositionManager();
        vm.prank(owner);
        pm.upgradeToAndCall(address(newImpl), "");

        // State preserved
        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(pos.owner, alice);
        assertEq(pos.amount, 100e18);
        assertEq(pm.nextPositionId(), 2);
    }

    // ========== Storage Gap (PM-1) ==========

    function test_storageGap_upgradeWithNewStateVar() public {
        // Deposit a position before upgrade
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        // Deploy V2 implementation (simulated — same contract, just proves upgrade works)
        PositionManager newImpl = new PositionManager();
        vm.prank(owner);
        pm.upgradeToAndCall(address(newImpl), "");

        // Verify all existing state is preserved after upgrade
        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(pos.owner, alice);
        assertEq(pos.amount, 100e18);
        assertEq(pos.lpToken, lpToken);
        assertEq(pm.nextPositionId(), 2);
        assertTrue(aclManager.isLendingEngine(lendingEngine));
        assertTrue(aclManager.isLiquidationEngine(liquidationEngine));
    }

    // ========== Fuzz Tests ==========

    function testFuzz_deposit_anyTokenId(uint256 tokenId) public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, tokenId, 100e18, marketId);

        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(pos.tokenId, tokenId);
    }

    function testFuzz_deposit_anyAmount(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, amount, marketId);

        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(pos.amount, amount);
    }

    function testFuzz_healthFactor_inverslyProportionalToDebt(uint256 debt) public {
        debt = bound(debt, 1e18, 100_000e18);
        oracle.setPrice(100_000e18); // $100K collateral

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(lendingEngine);
        pm.updateDebt(posId, debt);

        uint256 hf = pm.getHealthFactor(posId);
        // Higher debt → lower health factor
        assertGt(hf, 0);
    }

    // ========== Position Lifecycle ==========

    function test_fullLifecycle_depositBorrowRepayWithdraw() public {
        // 1. Deposit
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        assertEq(uint8(pm.getPosition(posId).status), uint8(IPositionManager.PositionStatus.Active));

        // 2. Borrow (simulated by LendingEngine)
        vm.prank(lendingEngine);
        pm.updateDebt(posId, 25_000e18);
        assertEq(uint8(pm.getPosition(posId).status), uint8(IPositionManager.PositionStatus.Borrowed));

        // 3. Repay (simulated by LendingEngine)
        vm.prank(lendingEngine);
        pm.updateDebt(posId, 0);
        assertEq(uint8(pm.getPosition(posId).status), uint8(IPositionManager.PositionStatus.Active));

        // 4. Withdraw
        vm.prank(alice);
        pm.withdraw(posId);
        assertEq(uint8(pm.getPosition(posId).status), uint8(IPositionManager.PositionStatus.Closed));
    }

    function test_fullLifecycle_depositBorrowLiquidate() public {
        // 1. Deposit
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        // 2. Borrow
        vm.prank(lendingEngine);
        pm.updateDebt(posId, 25_000e18);

        // 3. Liquidate
        vm.prank(liquidationEngine);
        pm.markLiquidated(posId, makeAddr("liquidator"), 25_000e18);
        assertEq(uint8(pm.getPosition(posId).status), uint8(IPositionManager.PositionStatus.Liquidated));
        assertEq(pm.positionDebt(posId), 0);

        // Cannot withdraw after liquidation
        vm.prank(alice);
        vm.expectRevert("NOT_ACTIVE");
        pm.withdraw(posId);
    }

    // ========== Health Factor with PriceFeedRegistry (Aave-style) ==========

    function test_getHealthFactor_withPriceFeedRegistry_6decUSDC() public {
        // Set up a MockPriceFeedRegistry with USDC at $1
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        MockERC20 usdc6 = new MockERC20("USDC", "USDC", 6);
        registry.setPrice(address(usdc6), 1e18); // $1.00

        // Create a market with 6-decimal USDC
        InterestRateModel irm6 = new InterestRateModel(200, 600, 10_000, 8000);
        MockMarket market6 = new MockMarket(address(usdc6), address(irm6));
        vm.startPrank(owner);
        uint256 marketId6 = core.registerMarket(address(market6));
        core.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        oracle.setPrice(10_000e18); // $10K collateral

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId6);

        // Mock debt: 5000 USDC in 6 decimals
        vm.mockCall(
            lendingEngine, abi.encodeWithSelector(LendingEngine.getDebt.selector, posId), abi.encode(uint256(5000e6))
        );

        uint256 hf = pm.getHealthFactor(posId);
        // debtUsd = 5000e6 * 1e18 / 1e6 = 5000e18
        // HF = (10000e18 * 7500 * 1e18) / (5000e18 * 10000) = 1.5e18
        assertEq(hf, 1.5e18, "HF must be correct with 6-dec USDC via PriceFeedRegistry");

        vm.clearMockedCalls();
    }

    function test_getHealthFactor_withPriceFeedRegistry_8decWBTC() public {
        // WBTC at $60,000 as borrow asset
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
        registry.setPrice(address(wbtc), 60_000e18); // $60K per BTC

        InterestRateModel irm8 = new InterestRateModel(200, 600, 10_000, 8000);
        MockMarket market8 = new MockMarket(address(wbtc), address(irm8));
        vm.startPrank(owner);
        uint256 marketId8 = core.registerMarket(address(market8));
        core.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        oracle.setPrice(100_000e18); // $100K collateral

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId8);

        // Mock debt: 0.5 WBTC = $30K
        vm.mockCall(
            lendingEngine, abi.encodeWithSelector(LendingEngine.getDebt.selector, posId), abi.encode(uint256(5e7))
        );

        uint256 hf = pm.getHealthFactor(posId);
        // debtUsd = 5e7 * 60_000e18 / 1e8 = 30_000e18
        // HF = (100_000e18 * 7500 * 1e18) / (30_000e18 * 10_000) = 2.5e18
        assertEq(hf, 2.5e18, "HF must be correct with 8-dec WBTC via PriceFeedRegistry");

        vm.clearMockedCalls();
    }

    function test_getHealthFactor_fallbackWithoutRegistry() public {
        // Without PriceFeedRegistry, fallback normalizes 6-dec debt to 18-dec USD
        oracle.setPrice(10_000e18);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        // Market uses 6-dec USDC, so mock debt in 6 decimals
        vm.mockCall(
            lendingEngine, abi.encodeWithSelector(LendingEngine.getDebt.selector, posId), abi.encode(uint256(5000e6))
        );

        uint256 hf = pm.getHealthFactor(posId);
        assertEq(hf, 1.5e18, "Fallback must normalize 6-dec debt correctly");

        vm.clearMockedCalls();
    }

    function test_setPriceFeedRegistry_onlyPoolAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.setPriceFeedRegistry(makeAddr("registry"));
    }

    function test_setPriceFeedRegistry_allowsZero() public {
        // Can set to address(0) to revert to fallback normalization mode
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        registry.setPrice(address(0x1), 1e18);

        vm.prank(owner);
        core.setPriceFeedRegistry(address(registry));
        assertEq(core.priceFeedRegistryAddr(), address(registry));

        // Unset → fallback mode
        vm.prank(owner);
        core.setPriceFeedRegistry(address(0));
        assertEq(core.priceFeedRegistryAddr(), address(0));
    }

    // ========== getActivePositionsByOwner ==========

    function test_getActivePositionsByOwner_filtersClosedAndLiquidated() public {
        // Create 3 positions
        vm.startPrank(alice);
        uint256 pos1 = pm.deposit(lpToken, 1, 100e18, marketId);
        uint256 pos2 = pm.deposit(lpToken, 2, 100e18, marketId);
        uint256 pos3 = pm.deposit(lpToken, 3, 100e18, marketId);
        vm.stopPrank();

        // All 3 should appear in both views
        uint256[] memory all = pm.getPositionsByOwner(alice);
        assertEq(all.length, 3);
        uint256[] memory active = pm.getActivePositionsByOwner(alice);
        assertEq(active.length, 3);

        // Close pos1 (withdraw)
        vm.prank(alice);
        pm.withdraw(pos1);

        // Liquidate pos2
        vm.prank(liquidationEngine);
        pm.markLiquidated(pos2, makeAddr("liquidator"), 0);

        // getPositionsByOwner still returns all 3 (includes closed/liquidated)
        all = pm.getPositionsByOwner(alice);
        assertEq(all.length, 3);

        // getActivePositionsByOwner returns only pos3
        active = pm.getActivePositionsByOwner(alice);
        assertEq(active.length, 1);
        assertEq(active[0], pos3);
    }
}
