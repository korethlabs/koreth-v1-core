// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract RiskManagerIntegrationTest is Test {
    ACLManager public aclManager;
    ProtocolCore public core;
    PositionManager public pm;
    LendingEngine public le;
    LPOracleHub public oracleHub;
    RiskManager public rm;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockMarket public market;
    MockERC20 public usdc;
    InterestRateModel public irm;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public lpToken = makeAddr("lpToken");

    uint256 public marketId;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        irm = new InterestRateModel(200, 600, 10_000, 8000);

        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        LPOracleHub ohImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(ohImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );

        PositionManager pmImpl = new PositionManager();
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        LendingEngine leImpl = new LendingEngine();
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        oracle.setPrice(50_000e18);
        market = new MockMarket(address(usdc), address(irm));
        rm = new RiskManager(address(core));

        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
        pm.setLendingEngine(address(le));
        core.setRiskManager(address(rm));
        vm.stopPrank();

        usdc.mint(address(market), 200_000_000e18);
    }

    // ========== Max Positions Per User ==========

    function test_deposit_enforces_maxPositionsPerUser() public {
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(alice);
            pm.deposit(lpToken, i + 1, 100e18, marketId);
        }

        vm.prank(alice);
        vm.expectRevert("MAX_POSITIONS_REACHED");
        pm.deposit(lpToken, 21, 100e18, marketId);
    }

    function test_deposit_differentUsersIndependent() public {
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(alice);
            pm.deposit(lpToken, i + 1, 100e18, marketId);
        }

        vm.prank(bob);
        pm.deposit(lpToken, 100, 100e18, marketId);
    }

    function test_deposit_adminCanChangeLimit() public {
        vm.prank(owner);
        rm.setMaxPositionsPerUser(5);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            pm.deposit(lpToken, i + 1, 100e18, marketId);
        }

        vm.prank(alice);
        vm.expectRevert("MAX_POSITIONS_REACHED");
        pm.deposit(lpToken, 6, 100e18, marketId);

        vm.prank(owner);
        rm.setMaxPositionsPerUser(10);

        vm.prank(alice);
        pm.deposit(lpToken, 6, 100e18, marketId);
    }

    // ========== Max Position Value ==========

    function test_deposit_enforces_maxPositionValue() public {
        vm.prank(alice);
        pm.deposit(lpToken, 1, 100e18, marketId); // $50K OK

        oracle.setPrice(11_000_000e18); // $11M > $10M cap

        vm.prank(alice);
        vm.expectRevert("POSITION_TOO_LARGE");
        pm.deposit(lpToken, 2, 100e18, marketId);
    }

    // ========== Supply Cap ==========

    function test_deposit_enforces_supplyCap() public {
        vm.prank(owner);
        rm.setMarketSupplyCap(marketId, 100_000e18); // $100K cap

        // $50K deposit OK
        vm.prank(alice);
        pm.deposit(lpToken, 1, 100e18, marketId);

        // Second $50K deposit OK (total = $100K)
        vm.prank(alice);
        pm.deposit(lpToken, 2, 100e18, marketId);

        // Third would exceed $100K cap
        vm.prank(alice);
        vm.expectRevert("SUPPLY_CAP_REACHED");
        pm.deposit(lpToken, 3, 100e18, marketId);
    }

    /// @notice recordDeposit itself enforces the cap (choke point) — protects EVERY value-in path.
    function test_recordDeposit_enforcesSupplyCapAtChokePoint() public {
        vm.prank(owner);
        rm.setMarketSupplyCap(marketId, 10_000e18);

        vm.prank(address(pm));
        rm.recordDeposit(6000e18, marketId);

        // Exceeding the cap reverts...
        vm.prank(address(pm));
        vm.expectRevert("SUPPLY_CAP_REACHED");
        rm.recordDeposit(5000e18, marketId);

        // ...but filling exactly to the cap is allowed.
        vm.prank(address(pm));
        rm.recordDeposit(4000e18, marketId);
        assertEq(rm.marketCurrentSupply(marketId), 10_000e18);
    }

    /// @notice cap == 0 means uncapped (Aave-style default) — recordDeposit never reverts.
    function test_recordDeposit_uncappedWhenCapZero() public {
        vm.prank(address(pm));
        rm.recordDeposit(1_000_000_000e18, marketId);
        assertEq(rm.marketCurrentSupply(marketId), 1_000_000_000e18);
    }

    /// @notice Compounding a position's own fees is TRACKED but NOT cap-blocked (organic growth).
    ///         recordDeposit reverts at the cap; recordCompoundReinvest does not.
    function test_recordCompoundReinvest_tracksWithoutCap() public {
        vm.prank(owner);
        rm.setMarketSupplyCap(marketId, 10_000e18);

        // Fill the market to its cap.
        vm.prank(address(pm));
        rm.recordDeposit(10_000e18, marketId);

        // A further deposit is blocked by the cap...
        vm.prank(address(pm));
        vm.expectRevert("SUPPLY_CAP_REACHED");
        rm.recordDeposit(1, marketId);

        // ...but compounding is tracked past the cap without reverting (fees aren't new capital).
        vm.prank(address(pm));
        rm.recordCompoundReinvest(500e18, marketId);
        assertEq(rm.marketCurrentSupply(marketId), 10_500e18, "compound reinvest tracked past cap");
    }

    function test_recordCompoundReinvest_onlyPositionManager() public {
        vm.prank(alice);
        vm.expectRevert("NOT_POSITION_MANAGER");
        rm.recordCompoundReinvest(1, marketId);
    }

    function test_withdraw_freesSupplyCapacity() public {
        vm.prank(owner);
        rm.setMarketSupplyCap(marketId, 100_000e18);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);

        vm.prank(alice);
        pm.deposit(lpToken, 2, 100e18, marketId);

        // At cap, can't deposit more
        vm.prank(alice);
        vm.expectRevert("SUPPLY_CAP_REACHED");
        pm.deposit(lpToken, 3, 100e18, marketId);

        // Withdraw first position → frees capacity
        vm.prank(alice);
        pm.withdraw(posId);

        // Now can deposit again
        vm.prank(alice);
        pm.deposit(lpToken, 3, 100e18, marketId);
    }

    // ========== Global Borrow Cap ==========

    function test_borrow_enforces_globalBorrowCap() public {
        vm.prank(owner);
        rm.setGlobalBorrowCap(50_000e18);

        oracle.setPrice(100_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 40_000e18);

        vm.prank(alice);
        vm.expectRevert("GLOBAL_CAP_REACHED");
        le.borrow(posId, 15_000e18);
    }

    function test_borrow_repayFreesCapacity() public {
        vm.prank(owner);
        rm.setGlobalBorrowCap(50_000e18);

        oracle.setPrice(100_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 40_000e18);

        usdc.mint(alice, 20_000e18);
        vm.prank(alice);
        usdc.approve(address(market), 20_000e18);
        vm.prank(alice);
        le.repay(posId, 20_000e18);

        // Now can borrow more (40K - 20K + 25K = 45K < 50K)
        vm.prank(alice);
        le.borrow(posId, 25_000e18);
    }

    // ========== LP Type Borrow Cap ==========

    function test_borrow_enforces_lpTypeCap() public {
        vm.prank(owner);
        rm.setLPTypeBorrowCap(ILPAdapter.LPType.UniswapV3, 30_000e18);

        oracle.setPrice(100_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 25_000e18);

        vm.prank(alice);
        vm.expectRevert("LP_TYPE_CAP_REACHED");
        le.borrow(posId, 10_000e18);
    }

    // ========== Position Value Cap on Borrow ==========

    function test_borrow_enforces_positionValueCap() public {
        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        vm.prank(owner);
        rm.setMaxPositionValue(5000e18);

        vm.prank(alice);
        vm.expectRevert("POSITION_TOO_LARGE");
        le.borrow(posId, 1000e18);
    }

    // ========== Without RiskManager ==========

    function test_worksWithoutRiskManager() public {
        vm.startPrank(owner);
        core.setRiskManager(address(0));
        vm.stopPrank();

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 30_000e18);
        assertEq(le.getDebt(posId), 30_000e18);
    }

    // ========== Admin ==========

    function test_setRiskManager_onlyPoolAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.setRiskManager(makeAddr("rm"));
    }

    function test_setGlobalBorrowCap_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_CAP");
        rm.setGlobalBorrowCap(0);
    }

    function test_setMaxPositionValue_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_VALUE");
        rm.setMaxPositionValue(0);
    }

    // ========== Event Emission ==========

    event BorrowRecorded(uint256 amountUsd, uint256 newGlobalBorrows);
    event RepayRecorded(uint256 amountUsd, uint256 newGlobalBorrows);
    event DepositRecorded(uint256 valueUsd, uint256 indexed marketId, uint256 newMarketSupply);
    event WithdrawRecorded(uint256 valueUsd, uint256 indexed marketId, uint256 newMarketSupply);
    event BorrowTrackingDrift(uint256 tracked, uint256 repaid, bool isGlobal);

    function test_validateAndRecordBorrow_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit BorrowRecorded(1000e18, 1000e18);
        vm.prank(address(le));
        rm.validateAndRecordBorrow(1000e18, 50_000e18, ILPAdapter.LPType.UniswapV2);
    }

    function test_recordRepay_emitsEvent() public {
        vm.prank(address(le));
        rm.validateAndRecordBorrow(1000e18, 50_000e18, ILPAdapter.LPType.UniswapV2);
        vm.expectEmit(false, false, false, true);
        emit RepayRecorded(500e18, 500e18);
        vm.prank(address(le));
        rm.recordRepay(500e18, ILPAdapter.LPType.UniswapV2);
    }

    function test_recordRepay_emitsDriftOnClamp() public {
        vm.prank(address(le));
        rm.validateAndRecordBorrow(100e18, 50_000e18, ILPAdapter.LPType.UniswapV2);
        vm.expectEmit(false, false, false, true);
        emit BorrowTrackingDrift(100e18, 200e18, true);
        vm.prank(address(le));
        rm.recordRepay(200e18, ILPAdapter.LPType.UniswapV2);
        assertEq(rm.currentGlobalBorrows(), 0);
    }

    function test_recordDeposit_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit DepositRecorded(5000e18, marketId, 5000e18);
        vm.prank(address(pm));
        rm.recordDeposit(5000e18, marketId);
    }

    function test_recordWithdraw_emitsEvent() public {
        vm.prank(address(pm));
        rm.recordDeposit(5000e18, marketId);
        vm.expectEmit(true, false, false, true);
        emit WithdrawRecorded(3000e18, marketId, 2000e18);
        vm.prank(address(pm));
        rm.recordWithdraw(3000e18, marketId);
    }
}
