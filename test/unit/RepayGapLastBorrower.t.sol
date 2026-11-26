// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {LendingPool} from "../../src/markets/LendingPool.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {ILendingPool} from "../../src/interfaces/ILendingPool.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RiskConfig} from "../helpers/RiskConfig.sol";
import {TestPricing} from "../helpers/TestPricing.sol";
import {TestPools} from "../helpers/TestPools.sol";
import {TestSecurity} from "../helpers/TestSecurity.sol";

/// @title RepayGapLastBorrowerTest
/// @notice Pool-level `totalBorrow` and position-level debt round differently: each accrual floors the
///         interest added to `totalBorrow` to a whole base unit, while a position's debt derives from
///         `borrowIndex` at RAY precision. The sum of position debts therefore drifts above
///         `totalBorrow`, by just under one base unit per accrual at most, whatever the decimals. These
///         tests pin what must stay true for the borrower who holds that gap when the pool runs out of
///         `totalBorrow`: every way of settling the debt keeps working and the books stay balanced.
/// @dev Runs the real LendingPool and real engines. MockLendingPool cannot reproduce any of this: its
///      index is set by hand, `totalBorrow` never accrues, and its transferIn tolerates over-delivery.
///
///      Time is read through vm.getBlockTimestamp()/vm.getBlockNumber() rather than block.timestamp:
///      under via_ir a `vm.warp(block.timestamp + step)` in a loop can stop advancing depending on
///      inlining, and a clock that stands still accrues nothing and passes everything. _accrue() also
///      asserts the elapsed time and the interest booked, so a stalled clock fails instead of passing.
contract RepayGapLastBorrowerTest is Test {
    ProtocolCore internal core;
    ACLManager internal aclManager;
    PositionManager internal pm;
    LendingEngine internal le;
    LiquidationEngine internal liq;
    LPOracleHub internal oracleHub;
    RiskManager internal riskManager;
    InterestRateModel internal irm;
    PriceFeedRegistry internal priceRegistry;
    MockLPAdapter internal adapter;
    MockLPOracle internal oracle;
    MockERC20 internal weth;
    MockERC20 internal usd18;

    // Selected per test by _wire(): the borrow asset under test and its pool.
    LendingPool internal pool;
    MockERC20 internal tok;
    uint256 internal unit;

    address internal owner = makeAddr("owner");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal lender = makeAddr("lender");
    address internal liquidator = makeAddr("liquidator");
    address internal lpToken = makeAddr("lpToken");

    uint256 internal constant BORROW_WHOLE = 10_000;
    uint256 internal constant ACCRUALS = 200;
    uint256 internal constant STEP = 12;

    /// LP values, in USD, for each liquidation regime against a 10,000-token debt at a 75% threshold.
    uint256 internal constant VALUE_OPEN = 50_000e18;
    uint256 internal constant VALUE_FULL_LIQ = 11_000e18; // HF ~0.82: full repay allowed
    uint256 internal constant VALUE_CAPPED_LIQ = 13_000e18; // HF ~0.97: repay capped at 50%
    uint256 internal constant VALUE_BAD_DEBT = 0.5e18; // below the $1 dust threshold: seize all, write off

    function setUp() public {
        weth = new MockERC20("WETH", "WETH", 18);
        usd18 = new MockERC20("USD18", "USD18", 18);
        irm = new InterestRateModel(200, 600, 10_000, 8000);
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        oracleHub = LPOracleHub(
            address(
                new ERC1967Proxy(address(new LPOracleHub()), abi.encodeCall(LPOracleHub.initialize, (address(core))))
            )
        );
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(new LendingEngine()), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );
        liq = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(new LiquidationEngine()),
                    abi.encodeCall(LiquidationEngine.initialize, (address(core), address(pm), address(le)))
                )
            )
        );

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV2);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        oracle.setPrice(VALUE_OPEN);
        riskManager = new RiskManager(address(core));

        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addLiquidationEngine(address(liq));
        aclManager.addPositionManager(address(pm));
        aclManager.addRiskAdmin(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(oracle));
        core.whitelistLpPool(TestPools.asContract(lpToken), ILPAdapter.LPType.UniswapV2);
        priceRegistry = TestPricing.wireStable(core, address(usd18));
        TestPricing.priceAsset(priceRegistry, address(weth), 200e18);
        core.setRiskManager(address(riskManager));
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV2, RiskConfig.defaultConfig());
        TestSecurity.wireBreaker(core, pm);
        TestSecurity.wireFeeCollector(core, liq, makeAddr("treasury"));
        pm.setLendingEngine(address(le));
        vm.stopPrank();

        adapter.setTokenReturns(address(weth), address(usd18));
        adapter.setUnwindAmounts(25e18, 25_000e18);
        adapter.setTotalLiquidity(100e18);
        weth.mint(address(adapter), 1_000_000e18);
        usd18.mint(address(adapter), 1_000_000e18);
    }

    // --- Helpers ---

    /// @dev Lists a real pool for a fresh borrow asset of `dec` decimals, with a 10% reserve factor so
    ///      protocolReserves is live in every scenario, and 100,000 tokens of lender liquidity.
    function _wire(uint8 dec) internal {
        unit = 10 ** dec;
        tok = new MockERC20("T", "T", dec);
        ILendingPool.PoolConfig memory c = ILendingPool.PoolConfig({borrowAsset: address(tok)});
        pool = LendingPool(
            address(
                new ERC1967Proxy(
                    address(new LendingPool()), abi.encodeCall(LendingPool.initialize, (c, address(irm), address(core)))
                )
            )
        );
        vm.startPrank(owner);
        TestPricing.priceAsset(priceRegistry, address(tok), 1e18);
        core.registerLendingPool(address(tok), address(pool));
        pool.setReserveFactor(1000);
        vm.stopPrank();

        tok.mint(lender, 100_000 * unit);
        vm.startPrank(lender);
        tok.approve(address(pool), type(uint256).max);
        pool.supply(100_000 * unit);
        vm.stopPrank();
    }

    function _open(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = pm.deposit(lpToken, 0, 100e18, address(tok));
        vm.roll(vm.getBlockNumber() + 4);
        vm.prank(who);
        le.borrow(id, BORROW_WHOLE * unit);
        tok.mint(who, 1_000_000 * unit);
        vm.prank(who);
        tok.approve(address(pool), type(uint256).max);
    }

    /// @dev `n` permissionless accruals, `step` seconds apart. Fails loudly unless the clock really
    ///      moved and at least the simple interest over that time was booked (less the floors).
    function _accrue(uint256 n, uint256 step) internal {
        uint256 start = vm.getBlockTimestamp();
        uint256 borrowedBefore = _tb();
        uint256 rate = pool.getPoolState().borrowRate;
        for (uint256 i; i < n; ++i) {
            vm.warp(vm.getBlockTimestamp() + step);
            vm.roll(vm.getBlockNumber() + 1);
            pool.accrueInterest();
        }
        assertEq(vm.getBlockTimestamp(), start + n * step, "clock stalled");
        assertEq(pool.getPoolState().lastAccrualTimestamp, start + n * step, "pool did not accrue to now");
        uint256 simpleInterest = (borrowedBefore * rate * n * step) / 1e18;
        assertGe(_tb() + n, borrowedBefore + simpleInterest, "interest not booked");
    }

    function _tb() internal view returns (uint256) {
        return pool.getPoolState().totalBorrow;
    }

    /// @dev The identity every path must preserve, including an over-delivery.
    function _assertBooksBalance() internal view {
        ILendingPool.PoolState memory s = pool.getPoolState();
        assertEq(
            tok.balanceOf(address(pool)) + s.totalBorrow,
            s.totalSupply + pool.protocolReserves(),
            "balance + totalBorrow != totalSupply + protocolReserves"
        );
    }

    function _assertCountersCleared() internal view {
        assertEq(riskManager.currentGlobalBorrows(), 0, "global borrow counter not cleared");
        assertEq(riskManager.lpTypeCurrentBorrows(ILPAdapter.LPType.UniswapV2), 0, "lpType counter not cleared");
    }

    function _assertStatus(uint256 id, IPositionManager.PositionStatus want) internal view {
        assertEq(uint8(pm.getPosition(id).status), uint8(want), "position status");
    }

    function _fundLiquidator() internal {
        tok.mint(liquidator, 1_000_000 * unit);
        vm.prank(liquidator);
        tok.approve(address(liq), type(uint256).max);
    }

    function _liquidate(uint256 id, uint256 amount) internal {
        vm.prank(liquidator);
        liq.liquidate(id, amount, vm.getBlockTimestamp() + 1, 0, 0);
    }

    /// @dev A position carrying a gap, with lenders and reserves live.
    function _openWithGap(uint8 dec) internal returns (uint256 id, uint256 gap) {
        _wire(dec);
        id = _open(bob);
        _accrue(ACCRUALS, STEP);
        gap = le.getDebt(id) - _tb();
        assertGt(gap, 0, "scenario needs a gap");
    }

    // --- The drift itself ---

    function _driftIsBoundedPerAccrual(uint8 dec) internal {
        _wire(dec);
        uint256 id = _open(bob);
        _accrue(1, STEP);
        assertEq(le.getDebt(id), _tb(), "one accrual leaves no gap for a single borrower");

        _accrue(ACCRUALS, STEP);
        uint256 gap = le.getDebt(id) - _tb();
        assertGt(gap, 0, "floors accumulate");
        assertLe(gap, ACCRUALS + 1, "under one base unit per accrual");
        _assertBooksBalance();
    }

    function test_drift_boundedPerAccrual_6dec() public {
        _driftIsBoundedPerAccrual(6);
    }

    function test_drift_boundedPerAccrual_18dec() public {
        _driftIsBoundedPerAccrual(18);
    }

    // --- Full repay ---

    function _fullRepay(uint8 dec, uint256 n, uint256 step) internal {
        _wire(dec);
        uint256 id = _open(bob);
        _accrue(n, step);

        uint256 debt = le.getDebt(id);
        uint256 borrowed = _tb();
        uint256 reserves = pool.protocolReserves();
        uint256 bobBefore = tok.balanceOf(bob);

        vm.prank(bob);
        le.repay(id, type(uint256).max);

        assertEq(le.getDebt(id), 0, "debt settled");
        assertEq(bobBefore - tok.balanceOf(bob), debt, "borrower paid exactly the debt quoted");
        assertEq(_tb(), borrowed > debt ? borrowed - debt : 0, "totalBorrow");
        assertEq(pool.protocolReserves() - reserves, debt > borrowed ? debt - borrowed : 0, "excess into reserves");
        _assertBooksBalance();
        _assertCountersCleared();

        vm.prank(bob);
        pm.withdraw(id);
        _assertStatus(id, IPositionManager.PositionStatus.Closed);
    }

    function test_fullRepay_lastBorrower_6dec() public {
        _fullRepay(6, ACCRUALS, STEP);
    }

    function test_fullRepay_lastBorrower_18dec() public {
        _fullRepay(18, ACCRUALS, STEP);
    }

    function test_fullRepay_lastBorrower_dailyAccruals_6dec() public {
        _fullRepay(6, 20, 1 days);
    }

    function test_fullRepay_lastBorrower_dailyAccruals_18dec() public {
        _fullRepay(18, 20, 1 days);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_fullRepay_lastBorrower(uint256 n, uint256 step, bool sixDecimals) public {
        n = bound(n, 1, 120);
        step = bound(step, 1, 7 days);
        _fullRepay(sixDecimals ? 6 : 18, n, step);
    }

    // --- Full liquidation ---

    function _fullLiquidation(uint8 dec, uint256 n, uint256 step) internal {
        _wire(dec);
        uint256 id = _open(bob);
        _accrue(n, step);
        oracle.setPrice(VALUE_FULL_LIQ);
        _fundLiquidator();

        uint256 debt = le.getDebt(id);
        uint256 borrowed = _tb();
        uint256 reserves = pool.protocolReserves();
        (bool liquidatable, uint256 maxRepay) = liq.isLiquidatable(id);
        assertTrue(liquidatable, "liquidatable");
        assertEq(maxRepay, debt, "below the critical HF the whole debt is repayable");

        _liquidate(id, maxRepay);

        assertEq(le.getDebt(id), 0, "debt cleared");
        assertEq(_tb(), borrowed > debt ? borrowed - debt : 0, "totalBorrow");
        assertEq(pool.protocolReserves() - reserves, debt > borrowed ? debt - borrowed : 0, "excess into reserves");
        _assertStatus(id, IPositionManager.PositionStatus.Liquidated);
        _assertBooksBalance();
        _assertCountersCleared();
    }

    function test_fullLiquidation_lastBorrower_6dec() public {
        _fullLiquidation(6, ACCRUALS, STEP);
    }

    function test_fullLiquidation_lastBorrower_18dec() public {
        _fullLiquidation(18, ACCRUALS, STEP);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_fullLiquidation_lastBorrower(uint256 n, uint256 step, bool sixDecimals) public {
        n = bound(n, 1, 120);
        step = bound(step, 1, 7 days);
        _fullLiquidation(sixDecimals ? 6 : 18, n, step);
    }

    // --- Partial liquidation ---

    /// @dev The capped liquidation never reaches the gap on its own; the borrower repaying what is left
    ///      afterwards does, so the position has to stay closable through both steps.
    function _partialLiquidation(uint8 dec) internal {
        (uint256 id, uint256 gap) = _openWithGap(dec);
        oracle.setPrice(VALUE_CAPPED_LIQ);
        _fundLiquidator();

        uint256 debt = le.getDebt(id);
        (, uint256 maxRepay) = liq.isLiquidatable(id);
        assertLt(maxRepay, debt, "capped");

        _liquidate(id, maxRepay);
        assertEq(le.getDebt(id), debt - maxRepay, "remainder");
        assertEq(le.getDebt(id) - _tb(), gap, "the gap stays with the position");
        _assertStatus(id, IPositionManager.PositionStatus.Borrowed);
        _assertBooksBalance();

        uint256 reserves = pool.protocolReserves();
        vm.prank(bob);
        le.repay(id, type(uint256).max);

        assertEq(le.getDebt(id), 0, "remainder settled");
        assertEq(_tb(), 0, "totalBorrow");
        assertEq(pool.protocolReserves() - reserves, gap, "excess into reserves");
        _assertBooksBalance();
        _assertCountersCleared();
    }

    function test_partialLiquidation_thenRepay_lastBorrower_6dec() public {
        _partialLiquidation(6);
    }

    function test_partialLiquidation_thenRepay_lastBorrower_18dec() public {
        _partialLiquidation(18);
    }

    // --- Write-off ---

    /// @dev Reaches the write-off with `totalBorrow` still positive: the burn clamps to it and the part
    ///      of the debt above it is simply gone, since no one was ever credited for it.
    function _writeOff(uint8 dec) internal {
        (uint256 id,) = _openWithGap(dec);
        oracle.setPrice(VALUE_BAD_DEBT);
        _fundLiquidator();

        uint256 repaid = 1000 * unit;
        uint256 burn = _tb() - repaid;
        uint256 reserves = pool.protocolReserves();
        uint256 supply = pool.getPoolState().totalSupply;

        _liquidate(id, repaid);

        assertEq(le.getDebt(id), 0, "debt written off");
        assertEq(_tb(), 0, "totalBorrow");
        uint256 reservesUsed = reserves > burn ? burn : reserves;
        assertEq(pool.protocolReserves(), reserves - reservesUsed, "reserves absorb first");
        assertEq(pool.deficit(), burn - reservesUsed, "deficit is the supplier loss");
        assertEq(supply - pool.getPoolState().totalSupply, burn - reservesUsed, "socialised immediately");
        _assertStatus(id, IPositionManager.PositionStatus.Liquidated);
        _assertBooksBalance();
        _assertCountersCleared();
    }

    function test_writeOff_lastBorrower_6dec() public {
        _writeOff(6);
    }

    function test_writeOff_lastBorrower_18dec() public {
        _writeOff(18);
    }

    /// @dev Repaying exactly `totalBorrow` leaves it at zero with the gap still owed, and the seize takes
    ///      all the collateral, so the write-off finds nothing to burn. It must not revert: the whole
    ///      liquidation would go with it. The remainder was never on the pool's books, so nothing is
    ///      socialised and no deficit appears.
    function _writeOffWithNothingToBurn(uint8 dec, bool aboveTotalBorrow) internal {
        (uint256 id, uint256 gap) = _openWithGap(dec);
        oracle.setPrice(VALUE_BAD_DEBT);
        _fundLiquidator();

        uint256 excess = aboveTotalBorrow ? gap / 2 : 0;
        uint256 repaid = _tb() + excess;
        uint256 reserves = pool.protocolReserves();
        uint256 supply = pool.getPoolState().totalSupply;

        _liquidate(id, repaid);

        assertEq(le.getDebt(id), 0, "remainder written off");
        assertEq(_tb(), 0, "totalBorrow");
        assertEq(pool.deficit(), 0, "nothing on the books to socialise");
        assertEq(pool.getPoolState().totalSupply, supply, "lenders untouched");
        assertEq(pool.protocolReserves() - reserves, excess, "only a real over-delivery reaches reserves");
        _assertStatus(id, IPositionManager.PositionStatus.Liquidated);
        _assertBooksBalance();
        _assertCountersCleared();
    }

    function test_writeOff_nothingToBurn_doesNotRevertLiquidation_6dec() public {
        _writeOffWithNothingToBurn(6, false);
    }

    function test_writeOff_nothingToBurn_doesNotRevertLiquidation_18dec() public {
        _writeOffWithNothingToBurn(18, false);
    }

    function test_writeOff_afterRepayAboveTotalBorrow_doesNotRevertLiquidation_6dec() public {
        _writeOffWithNothingToBurn(6, true);
    }

    function test_writeOff_afterRepayAboveTotalBorrow_doesNotRevertLiquidation_18dec() public {
        _writeOffWithNothingToBurn(18, true);
    }

    // --- Debt left over once totalBorrow is exhausted ---

    /// @dev With no debt floor a partial repay can spend all of `totalBorrow` and leave the gap behind.
    ///      accrueInterest() returns early on `totalBorrow == 0`, so that remainder stops accruing:
    ///      it stays exactly the size of the gap, and it stays repayable.
    function _leftoverDebtIsFrozenAndRepayable(uint8 dec) internal {
        (uint256 id, uint256 gap) = _openWithGap(dec);

        uint256 borrowed = _tb();
        vm.prank(bob);
        le.repay(id, borrowed);
        assertEq(_tb(), 0, "totalBorrow exhausted");
        assertEq(le.getDebt(id), gap, "the gap is what remains");

        uint256 index = pool.borrowIndex();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        pool.accrueInterest();
        assertEq(pool.borrowIndex(), index, "no accrual on an empty book");
        assertEq(le.getDebt(id), gap, "remainder does not grow");

        vm.prank(bob);
        vm.expectRevert("HAS_DEBT");
        pm.withdraw(id);

        uint256 reserves = pool.protocolReserves();
        vm.prank(bob);
        le.repay(id, type(uint256).max);

        assertEq(le.getDebt(id), 0, "remainder settled");
        assertEq(pool.protocolReserves() - reserves, gap, "excess into reserves");
        _assertBooksBalance();
        _assertCountersCleared();

        vm.prank(bob);
        pm.withdraw(id);
        _assertStatus(id, IPositionManager.PositionStatus.Closed);
    }

    function test_leftoverDebt_frozenAndRepayable_6dec() public {
        _leftoverDebtIsFrozenAndRepayable(6);
    }

    function test_leftoverDebt_frozenAndRepayable_18dec() public {
        _leftoverDebtIsFrozenAndRepayable(18);
    }

    /// @dev A liquidation of exactly `totalBorrow` with collateral to spare leaves the same remainder,
    ///      on a position that must remain closable by its owner.
    function _liquidationOfTotalBorrowLeavesClosablePosition(uint8 dec) internal {
        (uint256 id, uint256 gap) = _openWithGap(dec);
        oracle.setPrice(VALUE_FULL_LIQ);
        _fundLiquidator();

        _liquidate(id, _tb());
        assertEq(_tb(), 0, "totalBorrow exhausted");
        assertEq(le.getDebt(id), gap, "the gap is what remains");
        _assertStatus(id, IPositionManager.PositionStatus.Borrowed);

        vm.prank(bob);
        le.repay(id, type(uint256).max);
        assertEq(le.getDebt(id), 0, "remainder settled");
        _assertStatus(id, IPositionManager.PositionStatus.Active);
        _assertBooksBalance();
        _assertCountersCleared();
    }

    function test_liquidationOfTotalBorrow_leavesClosablePosition_6dec() public {
        _liquidationOfTotalBorrowLeavesClosablePosition(6);
    }

    function test_liquidationOfTotalBorrow_leavesClosablePosition_18dec() public {
        _liquidationOfTotalBorrowLeavesClosablePosition(18);
    }

    /// @dev A leftover that sits outside `totalBorrow` starts accruing again the moment someone else
    ///      borrows, because accrual is per-index and not per-position. Everyone still settles.
    function test_leftoverDebt_resumesAccruingWithNewBorrower_bothSettle() public {
        (uint256 a, uint256 gap) = _openWithGap(6);
        uint256 borrowed = _tb();
        vm.prank(bob);
        le.repay(a, borrowed);

        uint256 index = pool.borrowIndex();
        assertEq(le.getDebt(a), gap, "the gap is what remains");

        uint256 b = _open(carol);
        _accrue(ACCRUALS, 1 days);
        assertGt(pool.borrowIndex(), index, "index moved again");
        assertGt(le.getDebt(a), gap, "and the leftover with it");

        vm.prank(bob);
        le.repay(a, type(uint256).max);
        vm.prank(carol);
        le.repay(b, type(uint256).max);

        assertEq(le.getDebt(a) + le.getDebt(b), 0, "both settled");
        assertEq(_tb(), 0, "totalBorrow");
        _assertBooksBalance();
        _assertCountersCleared();
    }

    /// @dev The debt floor still does its job on the user path: repaying down to the gap is a dust
    ///      remainder and is refused. Repaying in full is the way out, and it now works.
    function test_debtFloor_stillRefusesDustRemainder_fullRepayIsTheExit() public {
        (uint256 id,) = _openWithGap(6);
        vm.prank(owner);
        riskManager.setMinBorrowUsd(100e18);

        uint256 borrowed = _tb();
        vm.prank(bob);
        vm.expectRevert("DUST_REMAINDER");
        le.repay(id, borrowed);

        vm.prank(bob);
        le.repay(id, type(uint256).max);
        assertEq(le.getDebt(id), 0, "settled");
        assertEq(_tb(), 0, "totalBorrow");
        _assertBooksBalance();
    }

    // --- More than one borrower ---

    /// @dev The first to leave takes its debt out of the shared `totalBorrow`, gap included, so the gap
    ///      lands on whoever is last. Either order has to settle, and the sum is what reaches reserves.
    function _twoBorrowers(bool bobFirst) internal {
        _wire(6);
        uint256 a = _open(bob);
        _accrue(ACCRUALS, STEP);
        uint256 b = _open(carol);
        _accrue(ACCRUALS, STEP);

        uint256 debts = le.getDebt(a) + le.getDebt(b);
        uint256 borrowed = _tb();
        assertGt(debts, borrowed, "drift");
        uint256 reserves = pool.protocolReserves();

        vm.prank(bobFirst ? bob : carol);
        le.repay(bobFirst ? a : b, type(uint256).max);
        vm.prank(bobFirst ? carol : bob);
        le.repay(bobFirst ? b : a, type(uint256).max);

        assertEq(le.getDebt(a) + le.getDebt(b), 0, "both settled");
        assertEq(_tb(), 0, "totalBorrow");
        assertEq(pool.protocolReserves() - reserves, debts - borrowed, "the sum of the gaps");
        _assertBooksBalance();
        _assertCountersCleared();
    }

    function test_twoBorrowers_firstThenSecond_bothSettle() public {
        _twoBorrowers(true);
    }

    function test_twoBorrowers_secondThenFirst_bothSettle() public {
        _twoBorrowers(false);
    }

    // --- Interaction with deficit ---

    /// @dev An over-delivery is ordinary reserves: it leaves `deficit` alone, and eliminateDeficit() can
    ///      then hand it back to the suppliers who took the loss.
    function test_overDelivery_reachesSuppliersThroughEliminateDeficit() public {
        _wire(6);
        uint256 a = _open(bob);
        uint256 b = _open(carol);
        _accrue(ACCRUALS, STEP);

        oracle.setPrice(VALUE_BAD_DEBT);
        _fundLiquidator();
        _liquidate(b, 1000 * unit);
        oracle.setPrice(VALUE_OPEN);

        uint256 deficit = pool.deficit();
        assertGt(deficit, 0, "scenario needs a deficit");
        assertEq(pool.protocolReserves(), 0, "reserves spent by the write-off");

        uint256 excess = le.getDebt(a) - _tb();
        assertGt(excess, 0, "scenario needs a gap");
        vm.prank(bob);
        le.repay(a, type(uint256).max);

        assertEq(pool.protocolReserves(), excess, "excess into reserves");
        assertEq(pool.deficit(), deficit, "deficit untouched by the repay");
        _assertBooksBalance();

        uint256 supply = pool.getPoolState().totalSupply;
        vm.prank(owner);
        pool.eliminateDeficit();
        assertEq(pool.deficit(), deficit - excess, "deficit covered");
        assertEq(pool.getPoolState().totalSupply, supply + excess, "credited back to suppliers");
        _assertBooksBalance();
    }
}
