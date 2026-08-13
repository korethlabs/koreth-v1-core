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
import {MockLendingPool} from "../mocks/MockLendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RiskConfig} from "../helpers/RiskConfig.sol";
import {TestPricing} from "../helpers/TestPricing.sol";
import {TestPools} from "../helpers/TestPools.sol";
import {TestSecurity} from "../helpers/TestSecurity.sol";

contract RiskManagerIntegrationTest is Test {
    ACLManager public aclManager;
    ProtocolCore public core;
    PositionManager public pm;
    LendingEngine public le;
    LPOracleHub public oracleHub;
    RiskManager public rm;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockLendingPool public market;
    MockERC20 public usdc;
    InterestRateModel public irm;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public lpToken = makeAddr("lpToken");

    address public borrowAsset;

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
        market = new MockLendingPool(address(usdc), address(irm));
        borrowAsset = address(usdc);
        rm = new RiskManager(address(core));

        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        aclManager.addRiskAdmin(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistLpPool(TestPools.asContract(lpToken));
        TestPricing.wireStable(core, address(usdc));
        core.registerLendingPool(address(usdc), address(market));
        TestSecurity.wireBreaker(core, pm);
        pm.setLendingEngine(address(le));
        core.setRiskManager(address(rm));
        rm.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.defaultConfig());
        // V2 is configured too so the direct-call cap/event tests below exercise an enabled type.
        rm.setCollateralConfig(ILPAdapter.LPType.UniswapV2, RiskConfig.defaultConfig());
        vm.stopPrank();

        usdc.mint(address(market), 200_000_000e18);
    }

    // ========== Max Positions Per User ==========

    function test_deposit_enforces_maxPositionsPerUser() public {
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(alice);
            pm.deposit(lpToken, i + 1, 100e18, borrowAsset);
        }

        vm.prank(alice);
        vm.expectRevert("MAX_POSITIONS_REACHED");
        pm.deposit(lpToken, 21, 100e18, borrowAsset);
    }

    function test_deposit_differentUsersIndependent() public {
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(alice);
            pm.deposit(lpToken, i + 1, 100e18, borrowAsset);
        }

        vm.prank(bob);
        pm.deposit(lpToken, 100, 100e18, borrowAsset);
    }

    function test_deposit_adminCanChangeLimit() public {
        vm.prank(owner);
        rm.setMaxPositionsPerUser(5);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            pm.deposit(lpToken, i + 1, 100e18, borrowAsset);
        }

        vm.prank(alice);
        vm.expectRevert("MAX_POSITIONS_REACHED");
        pm.deposit(lpToken, 6, 100e18, borrowAsset);

        vm.prank(owner);
        rm.setMaxPositionsPerUser(10);

        vm.prank(alice);
        pm.deposit(lpToken, 6, 100e18, borrowAsset);
    }

    // ========== Max Position Value ==========

    function test_deposit_enforces_maxPositionValue() public {
        vm.prank(alice);
        pm.deposit(lpToken, 1, 100e18, borrowAsset); // $50K OK

        oracle.setPrice(11_000_000e18); // $11M > $10M cap

        vm.prank(alice);
        vm.expectRevert("POSITION_TOO_LARGE");
        pm.deposit(lpToken, 2, 100e18, borrowAsset);
    }

    // ========== Supply Cap ==========

    function test_deposit_enforces_supplyCap() public {
        vm.prank(owner);
        rm.setPoolSupplyCap(borrowAsset, 100_000e18); // $100K cap

        // $50K deposit OK
        vm.prank(alice);
        pm.deposit(lpToken, 1, 100e18, borrowAsset);

        // Second $50K deposit OK (total = $100K)
        vm.prank(alice);
        pm.deposit(lpToken, 2, 100e18, borrowAsset);

        // Third would exceed $100K cap
        vm.prank(alice);
        vm.expectRevert("SUPPLY_CAP_REACHED");
        pm.deposit(lpToken, 3, 100e18, borrowAsset);
    }

    /// @notice recordDeposit itself enforces the cap (choke point) — protects EVERY value-in path.
    function test_recordDeposit_enforcesSupplyCapAtChokePoint() public {
        vm.prank(owner);
        rm.setPoolSupplyCap(borrowAsset, 10_000e18);

        vm.prank(address(pm));
        rm.recordDeposit(6000e18, borrowAsset);

        // Exceeding the cap reverts...
        vm.prank(address(pm));
        vm.expectRevert("SUPPLY_CAP_REACHED");
        rm.recordDeposit(5000e18, borrowAsset);

        // ...but filling exactly to the cap is allowed.
        vm.prank(address(pm));
        rm.recordDeposit(4000e18, borrowAsset);
        assertEq(rm.poolCurrentSupply(borrowAsset), 10_000e18);
    }

    /// @notice cap == 0 means uncapped (Aave-style default) — recordDeposit never reverts.
    function test_recordDeposit_uncappedWhenCapZero() public {
        vm.prank(address(pm));
        rm.recordDeposit(1_000_000_000e18, borrowAsset);
        assertEq(rm.poolCurrentSupply(borrowAsset), 1_000_000_000e18);
    }

    /// @notice Compounding a position's own fees is TRACKED but NOT cap-blocked (organic growth).
    ///         recordDeposit reverts at the cap; recordCompoundReinvest does not.
    function test_recordCompoundReinvest_tracksWithoutCap() public {
        vm.prank(owner);
        rm.setPoolSupplyCap(borrowAsset, 10_000e18);

        // Fill the market to its cap.
        vm.prank(address(pm));
        rm.recordDeposit(10_000e18, borrowAsset);

        // A further deposit is blocked by the cap...
        vm.prank(address(pm));
        vm.expectRevert("SUPPLY_CAP_REACHED");
        rm.recordDeposit(1, borrowAsset);

        // ...but compounding is tracked past the cap without reverting (fees aren't new capital).
        vm.prank(address(pm));
        rm.recordCompoundReinvest(500e18, borrowAsset);
        assertEq(rm.poolCurrentSupply(borrowAsset), 10_500e18, "compound reinvest tracked past cap");
    }

    function test_recordCompoundReinvest_onlyPositionManager() public {
        vm.prank(alice);
        vm.expectRevert("NOT_POSITION_MANAGER");
        rm.recordCompoundReinvest(1, borrowAsset);
    }

    function test_withdraw_freesSupplyCapacity() public {
        vm.prank(owner);
        rm.setPoolSupplyCap(borrowAsset, 100_000e18);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);

        vm.prank(alice);
        pm.deposit(lpToken, 2, 100e18, borrowAsset);

        // At cap, can't deposit more
        vm.prank(alice);
        vm.expectRevert("SUPPLY_CAP_REACHED");
        pm.deposit(lpToken, 3, 100e18, borrowAsset);

        // Withdraw first position → frees capacity
        vm.prank(alice);
        pm.withdraw(posId);

        // Now can deposit again
        vm.prank(alice);
        pm.deposit(lpToken, 3, 100e18, borrowAsset);
    }

    // ========== Global Borrow Cap ==========

    function test_borrow_enforces_globalBorrowCap() public {
        vm.prank(owner);
        rm.setGlobalBorrowCap(50_000e18);

        oracle.setPrice(100_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
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
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
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
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 25_000e18);

        vm.prank(alice);
        vm.expectRevert("LP_TYPE_CAP_REACHED");
        le.borrow(posId, 10_000e18);
    }

    // ========== Daily Borrow-Increase Rate Limit (Oracle M-1 defense-in-depth) ==========

    /// @dev The limit sums NEW principal within a tumbling 24h window and cannot be evaded by
    ///      chunking: two sub-limit borrows in the same window still add up to a breach.
    function test_borrow_enforces_dailyBorrowIncreaseLimit() public {
        vm.prank(owner);
        rm.setDailyBorrowIncreaseLimit(30_000e18);

        oracle.setPrice(100_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 20_000e18);

        // 20K already drawn this window; another 15K would total 35K > 30K.
        vm.prank(alice);
        vm.expectRevert("DAILY_BORROW_LIMIT");
        le.borrow(posId, 15_000e18);
    }

    /// @dev A tumbling window: once DAILY_BORROW_WINDOW elapses the bucket resets to zero, so the
    ///      same borrower can draw a fresh day's worth.
    function test_borrow_dailyLimitResetsAfterWindow() public {
        vm.prank(owner);
        rm.setDailyBorrowIncreaseLimit(30_000e18);

        oracle.setPrice(100_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 30_000e18); // exhausts the window

        vm.prank(alice);
        vm.expectRevert("DAILY_BORROW_LIMIT");
        le.borrow(posId, 1e18);

        // Past the window: bucket resets, borrowing resumes.
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        le.borrow(posId, 25_000e18);
    }

    /// @dev 0 disables the throttle — it must not block any borrow (safe-by-default, unlike the
    ///      per-type cap whose 0 means "blocked").
    function test_borrow_dailyLimitDisabledByDefault() public {
        oracle.setPrice(100_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 50_000e18); // no daily limit set → passes
    }

    // The property tests below drive validateAndRecordBorrow directly (as the LendingEngine) to
    // exercise the accumulator in isolation, without the deposit/oracle/block plumbing borrow() needs.
    // positionValue 1M is under maxPositionValue (10M) and the default V2 cap is NO_BORROW_CAP, so
    // only the daily limit is under test.

    /// @dev The window sums GROSS new principal and is NOT reduced on repay: a repay+re-borrow churn
    ///      within one window still hits the limit even though live exposure never exceeded it.
    ///      Netting repays would let churn evade the throttle — the one thing a flow limit must
    ///      resist — so this pins that invariant. (test_borrow_repayFreesCapacity proves the opposite
    ///      for the GLOBAL cap, so the two must not be conflated.)
    function test_dailyLimit_isGrossFlowNotReducedByRepay() public {
        vm.prank(owner);
        rm.setDailyBorrowIncreaseLimit(30_000e18);

        vm.prank(address(le));
        rm.validateAndRecordBorrow(30_000e18, 1_000_000e18, ILPAdapter.LPType.UniswapV2);

        // Repaying frees global + per-type capacity but must NOT refill the daily window.
        vm.prank(address(le));
        rm.recordRepay(30_000e18, ILPAdapter.LPType.UniswapV2);

        vm.prank(address(le));
        (bool valid, string memory reason) = rm.validateAndRecordBorrow(1e18, 1_000_000e18, ILPAdapter.LPType.UniswapV2);
        assertFalse(valid, "repay must not refill the daily window");
        assertEq(reason, "DAILY_BORROW_LIMIT");
    }

    /// @dev Only NEW principal counts. Interest accrual routes through recordAccrual, which must not
    ///      consume daily headroom — otherwise a long-lived position's accrual would throttle
    ///      unrelated healthy borrowers.
    function test_dailyLimit_accrualDoesNotConsumeWindow() public {
        vm.prank(owner);
        rm.setDailyBorrowIncreaseLimit(30_000e18);

        // A large accrual moves the global counter but must leave the daily window untouched.
        vm.prank(address(le));
        rm.recordAccrual(100_000e18, ILPAdapter.LPType.UniswapV2);

        vm.prank(address(le));
        (bool valid,) = rm.validateAndRecordBorrow(30_000e18, 1_000_000e18, ILPAdapter.LPType.UniswapV2);
        assertTrue(valid, "accrual must not consume the daily window");
    }

    /// @dev The check is `used + amount > limit`, so a borrow of EXACTLY the limit passes and only
    ///      the next wei is rejected.
    function test_dailyLimit_exactLimitPassesThenOneWeiReverts() public {
        vm.prank(owner);
        rm.setDailyBorrowIncreaseLimit(30_000e18);

        vm.prank(address(le));
        (bool valid,) = rm.validateAndRecordBorrow(30_000e18, 1_000_000e18, ILPAdapter.LPType.UniswapV2);
        assertTrue(valid, "a borrow of exactly the limit must pass");

        vm.prank(address(le));
        (bool valid2, string memory reason) = rm.validateAndRecordBorrow(1, 1_000_000e18, ILPAdapter.LPType.UniswapV2);
        assertFalse(valid2, "one wei past the limit must be rejected");
        assertEq(reason, "DAILY_BORROW_LIMIT");
    }

    /// @dev Lowering the limit mid-window is an operational lever: if usage already meets or exceeds
    ///      the new limit, further borrows are blocked immediately without waiting for a window reset.
    function test_dailyLimit_loweringMidWindowBlocksFurtherBorrows() public {
        vm.prank(owner);
        rm.setDailyBorrowIncreaseLimit(30_000e18);

        vm.prank(address(le));
        rm.validateAndRecordBorrow(20_000e18, 1_000_000e18, ILPAdapter.LPType.UniswapV2);

        vm.prank(owner);
        rm.setDailyBorrowIncreaseLimit(15_000e18); // below the 20k already drawn this window

        vm.prank(address(le));
        (bool valid, string memory reason) = rm.validateAndRecordBorrow(1e18, 1_000_000e18, ILPAdapter.LPType.UniswapV2);
        assertFalse(valid, "lowering the limit below current usage blocks further borrows");
        assertEq(reason, "DAILY_BORROW_LIMIT");
    }

    // ========== Position Value Cap on Borrow ==========

    function test_borrow_enforces_positionValueCap() public {
        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(owner);
        rm.setMaxPositionValue(5000e18);

        vm.prank(alice);
        vm.expectRevert("POSITION_TOO_LARGE");
        le.borrow(posId, 1000e18);
    }

    // ========== Without RiskManager ==========

    // ========== Collateral config bounds ==========

    /// @dev At maxLtv == liquidationThreshold a position is liquidatable the instant it borrows
    ///      its maximum, with no room to react to a price move.
    function test_setCollateralConfig_revertsLtvNotBelowThreshold() public {
        vm.prank(owner);
        vm.expectRevert("LTV_GE_THRESHOLD");
        rm.setCollateralConfig(
            ILPAdapter.LPType.UniswapV3, RiskConfig.config(7500, 7500, 500, 0, type(uint256).max, true)
        );
    }

    function test_setCollateralConfig_revertsLtvAboveCeiling() public {
        vm.prank(owner);
        vm.expectRevert("LTV_TOO_HIGH");
        rm.setCollateralConfig(
            ILPAdapter.LPType.UniswapV3, RiskConfig.config(9600, 9700, 500, 0, type(uint256).max, true)
        );
    }

    function test_setCollateralConfig_revertsThresholdAboveCeiling() public {
        vm.prank(owner);
        vm.expectRevert("THRESHOLD_TOO_HIGH");
        rm.setCollateralConfig(
            ILPAdapter.LPType.UniswapV3, RiskConfig.config(9000, 9900, 500, 0, type(uint256).max, true)
        );
    }

    /// @dev An unbounded bonus would let a liquidator seize arbitrarily more than the debt repaid.
    function test_setCollateralConfig_revertsBonusAboveCeiling() public {
        vm.prank(owner);
        vm.expectRevert("BONUS_TOO_HIGH");
        rm.setCollateralConfig(
            ILPAdapter.LPType.UniswapV3, RiskConfig.config(6500, 7500, 1600, 0, type(uint256).max, true)
        );
    }

    /// @dev Zero bonus leaves liquidators with no incentive, so underwater positions would just
    ///      sit there accruing bad debt while the borrower stays stuck below HF 1.
    function test_setCollateralConfig_revertsEnabledWithZeroBonus() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_BONUS");
        rm.setCollateralConfig(
            ILPAdapter.LPType.UniswapV3, RiskConfig.config(6500, 7500, 0, 0, type(uint256).max, true)
        );
    }

    /// @dev borrowCap is restrictive-by-default — 0 blocks borrowing rather than meaning
    ///      "unlimited", so an enabled type must state a cap (or NO_BORROW_CAP) explicitly.
    function test_setCollateralConfig_revertsEnabledWithZeroBorrowCap() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_BORROW_CAP");
        rm.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.config(6500, 7500, 500, 0, 0, true));
    }

    /// @dev A zero borrowCap fails CLOSED: the per-collateral cap is the blast-radius control for
    ///      the shared pool, so a forgotten config must block borrowing, never silently uncap it.
    function test_zeroBorrowCapBlocksBorrowing() public {
        vm.prank(owner);
        rm.setLPTypeBorrowCap(ILPAdapter.LPType.UniswapV3, 0);

        vm.prank(address(le));
        (bool valid, string memory reason) = rm.validateAndRecordBorrow(1e18, 1000e18, ILPAdapter.LPType.UniswapV3);
        assertFalse(valid, "zero cap must block borrowing");
        assertEq(reason, "LP_TYPE_CAP_REACHED");
    }

    /// @dev The registry cannot be unset once wired. Clearing it would zero liquidationThreshold
    ///      for every live position (health factor 0 across the board) and wipe the per-type
    ///      borrow-cap accounting for debt that is still outstanding.
    function test_setRiskManager_cannotUnset() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.setRiskManager(address(0));
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

    event BorrowRecorded(uint256 amountUsd, ILPAdapter.LPType indexed lpType, uint256 newGlobalBorrows);
    event RepayRecorded(uint256 amountUsd, ILPAdapter.LPType indexed lpType, uint256 newGlobalBorrows);
    event DepositRecorded(uint256 valueUsd, address indexed pool, uint256 newPoolSupply);
    event WithdrawRecorded(uint256 valueUsd, address indexed pool, uint256 newPoolSupply);
    event BorrowTrackingDrift(uint256 tracked, uint256 repaid, bool isGlobal);
    event DailyBorrowIncreaseLimitUpdated(uint256 oldValue, uint256 newValue);
    event MinBorrowUsdUpdated(uint256 oldValue, uint256 newValue);

    function test_setDailyBorrowIncreaseLimit_emitsEventAndStores() public {
        vm.expectEmit(false, false, false, true);
        emit DailyBorrowIncreaseLimitUpdated(0, 30_000e18);
        vm.prank(owner);
        rm.setDailyBorrowIncreaseLimit(30_000e18);
        assertEq(rm.dailyBorrowIncreaseLimit(), 30_000e18, "setter must store the new limit");
    }

    function test_setMinBorrowUsd_emitsEventAndStores() public {
        vm.expectEmit(false, false, false, true);
        emit MinBorrowUsdUpdated(0, 1000e18);
        vm.prank(owner);
        rm.setMinBorrowUsd(1000e18);
        assertEq(rm.minBorrowUsd(), 1000e18, "setter must store the new floor");
    }

    function test_setMinBorrowUsd_onlyRiskAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NOT_RISK_ADMIN");
        rm.setMinBorrowUsd(1000e18);
    }

    /// @dev lpType is checked as topic1: indexers reconstruct per-collateral exposure from these
    ///      events, so attributing a borrow to the wrong type is a real (silent) bug.
    function test_validateAndRecordBorrow_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit BorrowRecorded(1000e18, ILPAdapter.LPType.UniswapV2, 1000e18);
        vm.prank(address(le));
        rm.validateAndRecordBorrow(1000e18, 50_000e18, ILPAdapter.LPType.UniswapV2);
    }

    function test_recordRepay_emitsEvent() public {
        vm.prank(address(le));
        rm.validateAndRecordBorrow(1000e18, 50_000e18, ILPAdapter.LPType.UniswapV2);
        vm.expectEmit(true, false, false, true);
        emit RepayRecorded(500e18, ILPAdapter.LPType.UniswapV2, 500e18);
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
        emit DepositRecorded(5000e18, borrowAsset, 5000e18);
        vm.prank(address(pm));
        rm.recordDeposit(5000e18, borrowAsset);
    }

    function test_recordWithdraw_emitsEvent() public {
        vm.prank(address(pm));
        rm.recordDeposit(5000e18, borrowAsset);
        vm.expectEmit(true, false, false, true);
        emit WithdrawRecorded(3000e18, borrowAsset, 2000e18);
        vm.prank(address(pm));
        rm.recordWithdraw(3000e18, borrowAsset);
    }
}
