// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LendingPool} from "../../src/markets/LendingPool.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {ILendingPool} from "../../src/interfaces/ILendingPool.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {RiskConfig} from "../helpers/RiskConfig.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title ProtocolInvariantTest
/// @notice Fuzz-driven invariant tests that verify protocol-wide properties hold
///         across random sequences of deposits, borrows, repays, interest accrual, and price changes.
contract ProtocolInvariantTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    LendingPool public market;
    RiskManager public riskManager;
    LPOracleHub public oracleHub;
    FeeCollector public fc;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    // Second collateral type against the SAME pool — the whole point of the shared-pool model,
    // and impossible under the old isolated-market design.
    MockLPAdapter public adapterV2;
    MockLPOracle public oracleV2;
    MockERC20 public usdc;
    InterestRateModel public irm;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public lpToken = makeAddr("lpToken");
    address public lpTokenV2 = makeAddr("lpTokenV2");
    address public borrowAsset;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
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

        ILendingPool.PoolConfig memory mConfig = ILendingPool.PoolConfig({borrowAsset: address(usdc)});
        market = LendingPool(
            address(
                new ERC1967Proxy(
                    address(new LendingPool()),
                    abi.encodeCall(LendingPool.initialize, (mConfig, address(irm), address(core)))
                )
            )
        );

        address treasury = makeAddr("treasury");
        address insurance = makeAddr("insurance");
        fc = new FeeCollector(address(core), treasury, insurance);

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        adapterV2 = new MockLPAdapter(ILPAdapter.LPType.UniswapV2);
        adapterV2.setSupportedToken(lpTokenV2, true);
        oracleV2 = new MockLPOracle();
        riskManager = new RiskManager(address(core));

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(adapterV2));
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(oracleV2));
        core.whitelistPool(lpTokenV2);
        borrowAsset = address(usdc);
        core.registerPool(address(usdc), address(market));
        core.setRiskManager(address(riskManager));
        aclManager.addRiskAdmin(owner);
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.defaultConfig());
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV2, RiskConfig.defaultConfig());
        pm.setLendingEngine(address(le));
        vm.stopPrank();

        // Supply to market (so there's actual liquidity to borrow)
        address lender = makeAddr("initialLender");
        usdc.mint(lender, 10_000_000e18);
        vm.prank(lender);
        usdc.approve(address(market), 10_000_000e18);
        vm.prank(lender);
        market.supply(10_000_000e18);
    }

    // ================================================================
    // INVARIANT 1: Total debt across all positions must never exceed
    //              Market.totalBorrow (after accrual)
    // ================================================================

    function testFuzz_debtNeverExceedsMarketBorrow(uint256 price, uint256 borrowAmt, uint256 timeElapsed) public {
        price = bound(price, 10_000e18, 1_000_000e18);
        oracle.setPrice(price);

        // Deposit
        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        // Borrow within LTV
        uint256 maxBorrow = (price * 6500) / 10_000;
        borrowAmt = bound(borrowAmt, 1e18, maxBorrow);

        vm.prank(user);
        le.borrow(posId, borrowAmt);

        // Advance time
        timeElapsed = bound(timeElapsed, 0, 365 days);
        vm.warp(block.timestamp + timeElapsed);
        market.accrueInterest();

        // INVARIANT: individual debt <= market totalBorrow
        uint256 posDebt = le.getDebt(posId);
        ILendingPool.PoolState memory mState = market.getPoolState();

        assertLe(posDebt, mState.totalBorrow + 1, "Position debt must not exceed market totalBorrow");
    }

    // ================================================================
    // INVARIANT 2: borrowIndex must always increase or stay same
    // ================================================================

    function testFuzz_borrowIndexNeverDecreases(uint256 timeElapsed) public {
        oracle.setPrice(100_000e18);

        // Create a borrow so interest accrues
        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.prank(user);
        le.borrow(posId, 30_000e18);

        uint256 indexBefore = market.borrowIndex();

        timeElapsed = bound(timeElapsed, 1, 10 * 365 days);
        vm.warp(block.timestamp + timeElapsed);
        market.accrueInterest();

        uint256 indexAfter = market.borrowIndex();

        assertGe(indexAfter, indexBefore, "borrowIndex must never decrease");
    }

    // ================================================================
    // INVARIANT 3: Health factor must decrease as debt grows (price constant)
    // ================================================================

    function testFuzz_healthFactorDecreasesWithDebt(uint256 borrow1, uint256 borrow2) public {
        oracle.setPrice(100_000e18); // $100K collateral
        uint256 maxBorrow = 65_000e18; // 65% LTV

        borrow1 = bound(borrow1, 1e18, maxBorrow / 2);
        borrow2 = bound(borrow2, 1e18, maxBorrow - borrow1 - 1e18);

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        // First borrow
        vm.prank(user);
        le.borrow(posId, borrow1);
        uint256 hf1 = pm.getHealthFactor(posId);

        // Second borrow (more debt)
        vm.prank(user);
        le.borrow(posId, borrow2);
        uint256 hf2 = pm.getHealthFactor(posId);

        assertLt(hf2, hf1, "Health factor must decrease as debt increases");
    }

    // ================================================================
    // INVARIANT 4: Repaying all debt must restore health factor to max
    // ================================================================

    function testFuzz_fullRepayRestoresMaxHF(uint256 borrowAmt) public {
        oracle.setPrice(100_000e18);
        borrowAmt = bound(borrowAmt, 1e18, 65_000e18);

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(user);
        le.borrow(posId, borrowAmt);
        assertLt(pm.getHealthFactor(posId), type(uint256).max);

        // Repay all
        usdc.mint(user, borrowAmt);
        vm.prank(user);
        usdc.approve(address(market), borrowAmt);
        vm.prank(user);
        le.repay(posId, type(uint256).max);

        assertEq(pm.getHealthFactor(posId), type(uint256).max, "Full repay must restore max HF");
    }

    // ================================================================
    // INVARIANT 5: Market totalSupply >= totalBorrow always
    // ================================================================

    function testFuzz_supplyAlwaysExceedsBorrow(uint256 supplyAmt, uint256 borrowAmt, uint256 timeElapsed) public {
        supplyAmt = bound(supplyAmt, 10_000e18, 1_000_000e18);
        oracle.setPrice(100_000e18);

        // Supply
        address lender = makeAddr("lender");
        usdc.mint(lender, supplyAmt);
        vm.prank(lender);
        usdc.approve(address(market), supplyAmt);
        vm.prank(lender);
        market.supply(supplyAmt);

        // Borrow
        uint256 maxBorrow = 65_000e18;
        borrowAmt = bound(borrowAmt, 1e18, maxBorrow);
        // Make sure we don't borrow more than available
        ILendingPool.PoolState memory stateBefore = market.getPoolState();
        if (borrowAmt > stateBefore.totalSupply - stateBefore.totalBorrow) {
            borrowAmt = (stateBefore.totalSupply - stateBefore.totalBorrow) / 2;
        }
        if (borrowAmt == 0) return;

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.prank(user);
        le.borrow(posId, borrowAmt);

        // Advance time
        timeElapsed = bound(timeElapsed, 0, 5 * 365 days);
        vm.warp(block.timestamp + timeElapsed);
        market.accrueInterest();

        // INVARIANT
        ILendingPool.PoolState memory stateAfter = market.getPoolState();
        assertGe(stateAfter.totalSupply, stateAfter.totalBorrow, "totalSupply must always be >= totalBorrow");
    }

    // ================================================================
    // INVARIANT 6: Interest accrual must be consistent between
    //              Market.totalBorrow growth and borrowIndex growth
    // ================================================================

    function testFuzz_interestConsistency(uint256 borrowAmt, uint256 timeElapsed) public {
        oracle.setPrice(100_000e18);
        borrowAmt = bound(borrowAmt, 10_000e18, 65_000e18);

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(user);
        le.borrow(posId, borrowAmt);

        uint256 indexAtBorrow = market.borrowIndex();

        timeElapsed = bound(timeElapsed, 1 days, 365 days);
        vm.warp(block.timestamp + timeElapsed);
        market.accrueInterest();

        uint256 indexAfter = market.borrowIndex();
        ILendingPool.PoolState memory stateAfter = market.getPoolState();

        // Debt via borrowIndex
        uint256 debtViaIndex = (borrowAmt * indexAfter) / indexAtBorrow;
        // Debt via market totalBorrow
        uint256 debtViaMarket = stateAfter.totalBorrow;

        // They should be approximately equal (single borrower scenario)
        // Allow 0.01% tolerance for rounding
        uint256 diff = debtViaIndex > debtViaMarket ? debtViaIndex - debtViaMarket : debtViaMarket - debtViaIndex;
        uint256 tolerance = debtViaMarket / 10_000; // 0.01%

        assertLe(diff, tolerance + 1, "BorrowIndex debt must match Market.totalBorrow within 0.01%");
    }

    // ================================================================
    // INVARIANT 7: Position amount can only decrease (never increase)
    // ================================================================

    function testFuzz_positionAmountNeverIncreases(uint256 depositAmt) public {
        depositAmt = bound(depositAmt, 1e18, 1_000_000e18);
        oracle.setPrice(100_000e18);

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, depositAmt, borrowAsset);

        uint256 amountAfterDeposit = pm.getPosition(posId).amount;
        assertEq(amountAfterDeposit, depositAmt);

        // Only authorized contracts can reduce amount
        // The amount should never be MORE than what was deposited
        assertLe(pm.getPosition(posId).amount, depositAmt, "Position amount must never exceed deposit amount");
    }

    // ================================================================
    // INVARIANT 8: Closed/liquidated positions must have zero debt
    // ================================================================

    function testFuzz_closedPositionHasZeroDebt(uint256 borrowAmt) public {
        oracle.setPrice(100_000e18);
        borrowAmt = bound(borrowAmt, 1e18, 65_000e18);

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(user);
        le.borrow(posId, borrowAmt);

        // Repay all
        usdc.mint(user, borrowAmt);
        vm.prank(user);
        usdc.approve(address(market), borrowAmt);
        vm.prank(user);
        le.repay(posId, type(uint256).max);

        // Withdraw
        vm.prank(user);
        pm.withdraw(posId);

        // INVARIANT: closed position has zero debt
        assertEq(le.getDebt(posId), 0, "Closed position must have zero debt");
        assertEq(uint8(pm.getPosition(posId).status), uint8(IPositionManager.PositionStatus.Closed));
    }

    // ================================================================
    // INVARIANT 9: FeeCollector.accumulatedFees <= token balance
    // ================================================================

    function testFuzz_feeCollectorAccountingSound(uint256 feeAmount) public {
        feeAmount = bound(feeAmount, 1e18, 1_000_000e18);

        // Mint tokens and approve FeeCollector
        address feePayer = makeAddr("feePayer");
        usdc.mint(feePayer, feeAmount);
        vm.prank(feePayer);
        usdc.approve(address(fc), feeAmount);

        // Collect fee (need authorized caller)
        vm.prank(owner);
        aclManager.addKeeper(address(this));
        fc.collectFee(address(usdc), feeAmount, feePayer, "test");

        // INVARIANT: tracked fees <= actual balance
        uint256 tracked = fc.accumulatedFees(address(usdc));
        uint256 balance = usdc.balanceOf(address(fc));
        assertLe(tracked, balance, "accumulatedFees must not exceed actual balance");
        assertEq(tracked, feeAmount, "accumulatedFees must match collected amount");
    }

    // ================================================================
    // INVARIANT 10: activePositionCount tracks Active/Borrowed positions
    // ================================================================

    function testFuzz_activePositionCountConsistent(uint256 numPositions) public {
        numPositions = bound(numPositions, 1, 5);
        oracle.setPrice(100_000e18);

        address user = makeAddr("multiUser");

        // Deposit multiple positions
        uint256 firstPosId;
        for (uint256 i = 0; i < numPositions; i++) {
            vm.prank(user);
            uint256 posId = pm.deposit(lpToken, i + 1, 100e18, borrowAsset);
            if (i == 0) firstPosId = posId;
        }

        assertEq(pm.activePositionCount(user), numPositions, "activePositionCount must match deposits");

        // Withdraw first position
        vm.prank(user);
        pm.withdraw(firstPosId);

        assertEq(pm.activePositionCount(user), numPositions - 1, "activePositionCount must decrement on withdraw");
    }

    // ================================================================
    // INVARIANT 11: Position status must be consistent with debt
    //   - debt > 0 → Borrowed
    //   - debt == 0 → Active (if position has collateral)
    // ================================================================

    function testFuzz_statusConsistentWithDebt(uint256 borrowAmt) public {
        oracle.setPrice(100_000e18);
        borrowAmt = bound(borrowAmt, 1e18, 65_000e18);

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        // After deposit: Active, zero debt
        assertEq(uint8(pm.getPosition(posId).status), uint8(IPositionManager.PositionStatus.Active));
        assertEq(pm.positionDebt(posId), 0);

        // After borrow: Borrowed, debt > 0
        vm.prank(user);
        le.borrow(posId, borrowAmt);
        assertEq(uint8(pm.getPosition(posId).status), uint8(IPositionManager.PositionStatus.Borrowed));
        assertGt(pm.positionDebt(posId), 0, "Borrowed status must have debt > 0");

        // After full repay: Active, zero debt
        usdc.mint(user, borrowAmt);
        vm.prank(user);
        usdc.approve(address(market), borrowAmt);
        vm.prank(user);
        le.repay(posId, type(uint256).max);
        assertEq(uint8(pm.getPosition(posId).status), uint8(IPositionManager.PositionStatus.Active));
        assertEq(pm.positionDebt(posId), 0, "Active status must have zero debt");
    }

    // ================================================================
    // INVARIANT 12: Market balance >= totalSupply - totalBorrow
    //   (actual tokens in market >= what lenders can withdraw)
    // ================================================================

    function testFuzz_marketSolvency(uint256 borrowAmt, uint256 timeElapsed) public {
        oracle.setPrice(100_000e18);
        borrowAmt = bound(borrowAmt, 1e18, 65_000e18);

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.prank(user);
        le.borrow(posId, borrowAmt);

        timeElapsed = bound(timeElapsed, 0, 365 days);
        vm.warp(block.timestamp + timeElapsed);
        market.accrueInterest();

        ILendingPool.PoolState memory s = market.getPoolState();
        uint256 marketBalance = usdc.balanceOf(address(market));

        // Available liquidity = balance in market
        // Must be >= 0 (market can't owe more tokens than it holds minus what's borrowed)
        assertGe(
            marketBalance + s.totalBorrow, s.totalSupply, "Market must remain solvent: balance + borrows >= supply"
        );
    }

    // ================================================================
    // SHARED-POOL INVARIANT A: per-lpType borrowed <= its borrow cap
    // ================================================================

    function testFuzz_lpTypeBorrowNeverExceedsCap(uint256 cap, uint256 borrowAmt) public {
        oracle.setPrice(1_000_000e18); // large collateral so LTV isn't the binding constraint
        cap = bound(cap, 1e18, 500_000e18);
        borrowAmt = bound(borrowAmt, 1e18, 1_000_000e18);

        // Set a per-lpType borrow cap for UniswapV3
        vm.prank(owner);
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.config(6500, 7500, 500, 0, cap, true));

        address user = makeAddr("capUser");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        // Attempt to borrow; may revert if over cap/LTV — that's the point.
        vm.prank(user);
        try le.borrow(posId, borrowAmt) {} catch {}

        // INVARIANT: tracked per-lpType borrows never exceed the configured cap.
        assertLe(
            riskManager.lpTypeCurrentBorrows(ILPAdapter.LPType.UniswapV3),
            cap,
            "per-lpType borrowed must never exceed its cap"
        );
    }

    // ================================================================
    // SHARED-POOL INVARIANT B: single-pool share accounting conserved
    //   totalShares == sum(minted user shares) + DEAD_SHARES, and
    //   supplier assets round-trip within 0.1% (no phantom value).
    // ================================================================

    function testFuzz_sharesConservedAcrossSuppliers(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1e18, 500_000e18);
        b = bound(b, 1e18, 500_000e18);
        c = bound(c, 1e18, 500_000e18);

        // The pool already holds the initial lender's liquidity from setUp; measure the deltas.
        uint256 sharesBefore = market.totalShares();
        uint256 supplyBefore = market.getPoolState().totalSupply;

        address l1 = makeAddr("l1");
        address l2 = makeAddr("l2");
        address l3 = makeAddr("l3");

        uint256 s1 = _supply(l1, a);
        uint256 s2 = _supply(l2, b);
        uint256 s3 = _supply(l3, c);

        // Every minted share is tracked in totalShares (nothing conjured/lost across all suppliers).
        assertEq(market.totalShares() - sharesBefore, s1 + s2 + s3, "single-pool share accounting must be conserved");
        // And the pool's tracked supply grows by exactly the sum of deposits (no interest accrued yet).
        assertEq(market.getPoolState().totalSupply - supplyBefore, a + b + c, "totalSupply must grow by deposits");
    }

    function _supply(address lender, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(lender, amount);
        vm.prank(lender);
        usdc.approve(address(market), amount);
        vm.prank(lender);
        shares = market.supply(amount);
    }

    // ================================================================
    // SHARED-POOL INVARIANT C: disabled / over-cap collateral cannot borrow
    // ================================================================

    function test_disabledCollateralCannotDeposit() public {
        // Disable UniswapV3 collateral.
        vm.prank(owner);
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.config(6500, 7500, 500, 0, 0, false));

        address user = makeAddr("disabledUser");
        vm.prank(user);
        vm.expectRevert("COLLATERAL_NOT_ENABLED");
        pm.deposit(lpToken, 1, 100e18, borrowAsset);
    }

    function test_overCapCollateralCannotBorrow() public {
        oracle.setPrice(1_000_000e18);
        // Tiny per-lpType cap: any meaningful borrow must be rejected.
        vm.prank(owner);
        riskManager.setCollateralConfig(
            ILPAdapter.LPType.UniswapV3, RiskConfig.config(6500, 7500, 500, 0, 1000e18, true)
        );

        address user = makeAddr("overCapUser");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(user);
        vm.expectRevert("LP_TYPE_CAP_REACHED");
        le.borrow(posId, 2000e18); // exceeds the 1000e18 cap
    }

    /// @dev `enabled: false` must stop EXISTING positions drawing more from the shared pool, not
    ///      just block new deposits. Otherwise offboarding a compromised collateral type does
    ///      nothing for the lenders backing every other type — the ADR-001 failure mode.
    function test_disabledCollateralCannotBorrow() public {
        oracle.setPrice(1_000_000e18);

        address user = makeAddr("offboardedUser");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        // Borrowing works while the type is live.
        vm.prank(user);
        le.borrow(posId, 1000e18);

        // Offboard the type, keeping its risk params intact.
        vm.prank(owner);
        riskManager.setCollateralConfig(
            ILPAdapter.LPType.UniswapV3, RiskConfig.config(6500, 7500, 500, 0, 1_000_000e18, false)
        );

        vm.prank(user);
        vm.expectRevert("COLLATERAL_DISABLED");
        le.borrow(posId, 1000e18);

        // ...but the borrower can still repay their way out.
        usdc.mint(user, 1000e18);
        vm.prank(user);
        usdc.approve(address(market), 1000e18);
        vm.prank(user);
        le.repay(posId, 500e18);
    }

    // ================================================================
    // SHARED-POOL INVARIANT B: two collateral types, one pool
    // ================================================================

    /// @dev The core new risk of the shared-pool model: V2 and V3 collateral drawing on the same
    ///      USDC pool. Isolated markets made this impossible, so nothing used to cover it.
    ///      Interleaves borrows and repays across both types and asserts neither one's debt nor
    ///      the pool's own accounting is disturbed by the other's activity.
    function testFuzz_twoCollateralTypesShareOnePool(uint256 v3Borrow, uint256 v2Borrow) public {
        oracle.setPrice(1_000_000e18);
        oracleV2.setPrice(1_000_000e18);
        v3Borrow = bound(v3Borrow, 1e18, 500_000e18);
        v2Borrow = bound(v2Borrow, 1e18, 500_000e18);

        address v3User = makeAddr("v3User");
        address v2User = makeAddr("v2User");

        vm.prank(v3User);
        uint256 v3Pos = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.prank(v2User);
        uint256 v2Pos = pm.deposit(lpTokenV2, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(v3User);
        le.borrow(v3Pos, v3Borrow);

        // V3's borrow must not change what V2 can do, nor V2's (still zero) debt.
        assertEq(le.getDebt(v2Pos), 0, "V2 debt must be untouched by a V3 borrow");

        vm.prank(v2User);
        le.borrow(v2Pos, v2Borrow);

        // Each position owes exactly what it borrowed, and the shared pool owes the sum.
        assertEq(le.getDebt(v3Pos), v3Borrow, "V3 debt must be independent of V2");
        assertEq(le.getDebt(v2Pos), v2Borrow, "V2 debt must be independent of V3");
        assertEq(
            market.getPoolState().totalBorrow, v3Borrow + v2Borrow, "shared pool must owe the sum of both types"
        );

        // Per-type exposure is tracked separately and reconciles with the pool total.
        uint256 v3Tracked = riskManager.lpTypeCurrentBorrows(ILPAdapter.LPType.UniswapV3);
        uint256 v2Tracked = riskManager.lpTypeCurrentBorrows(ILPAdapter.LPType.UniswapV2);
        assertEq(v3Tracked, v3Borrow, "V3 exposure tracked separately");
        assertEq(v2Tracked, v2Borrow, "V2 exposure tracked separately");
        assertEq(v3Tracked + v2Tracked, market.getPoolState().totalBorrow, "per-type exposure must sum to the pool");

        // Accrue, then let V3 repay in full. V2's debt must be unaffected beyond its own interest.
        vm.warp(block.timestamp + 180 days);
        market.accrueInterest();
        uint256 v2DebtBefore = le.getDebt(v2Pos);

        uint256 v3Debt = le.getDebt(v3Pos);
        usdc.mint(v3User, v3Debt);
        vm.prank(v3User);
        usdc.approve(address(market), v3Debt);
        vm.prank(v3User);
        le.repay(v3Pos, v3Debt);

        assertEq(le.getDebt(v3Pos), 0, "V3 fully repaid");
        assertEq(le.getDebt(v2Pos), v2DebtBefore, "V2 debt must survive V3's full repayment");
        assertEq(
            riskManager.lpTypeCurrentBorrows(ILPAdapter.LPType.UniswapV3), 0, "V3 exposure released on full repay"
        );
        assertGe(riskManager.lpTypeCurrentBorrows(ILPAdapter.LPType.UniswapV2), v2Borrow, "V2 exposure retained");
    }

    /// @dev One collateral type pinned at its cap must not starve another type that still has
    ///      headroom — they only share liquidity, not risk budget.
    function test_capExhaustionIsolatedBetweenCollateralTypes() public {
        oracle.setPrice(1_000_000e18);
        oracleV2.setPrice(1_000_000e18);

        vm.prank(owner);
        riskManager.setCollateralConfig(
            ILPAdapter.LPType.UniswapV3, RiskConfig.config(6500, 7500, 500, 0, 10_000e18, true)
        );

        address v3User = makeAddr("cappedV3");
        address v2User = makeAddr("uncappedV2");

        vm.prank(v3User);
        uint256 v3Pos = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.prank(v2User);
        uint256 v2Pos = pm.deposit(lpTokenV2, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        // Exhaust the V3 cap exactly, then confirm it is closed.
        vm.prank(v3User);
        le.borrow(v3Pos, 10_000e18);
        vm.prank(v3User);
        vm.expectRevert("LP_TYPE_CAP_REACHED");
        le.borrow(v3Pos, 1e18);

        // V2 is unaffected and can still borrow far beyond V3's cap.
        vm.prank(v2User);
        le.borrow(v2Pos, 100_000e18);
        assertEq(le.getDebt(v2Pos), 100_000e18, "V2 must borrow freely while V3 is capped");
    }

    /// @dev Borrows record principal while repays subtract principal + interest. Without an
    ///      accrual sync the per-type counter ratchets toward zero, so a borrower could repay
    ///      interest repeatedly to free cap headroom that was never actually released, then
    ///      re-borrow the full cap. Tracked exposure must never fall below real debt.
    function test_capAccountingDoesNotDriftOnInterestRepay() public {
        oracle.setPrice(1_000_000e18);

        address user = makeAddr("interestPayer");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(user);
        le.borrow(posId, 100_000e18);

        usdc.mint(user, 1_000_000e18);
        vm.prank(user);
        usdc.approve(address(market), type(uint256).max);

        // Repeatedly let interest accrue and pay off exactly that interest, leaving the real
        // debt flat at the principal.
        // NOTE: the target instant is tracked in a local rather than re-read from block.timestamp
        // each round. solc treats TIMESTAMP as loop-invariant (it genuinely cannot change within
        // one transaction), so under via_ir the read is hoisted and every warp would land on the
        // same instant, accruing zero interest after the first pass.
        uint256 ts = block.timestamp;
        for (uint256 i = 0; i < 10; i++) {
            ts += 90 days;
            vm.warp(ts);
            market.accrueInterest();
            uint256 debt = le.getDebt(posId);
            vm.prank(user);
            le.repay(posId, debt - 100_000e18);

            assertApproxEqAbs(le.getDebt(posId), 100_000e18, 1, "real debt should stay at principal");
            assertGe(
                riskManager.lpTypeCurrentBorrows(ILPAdapter.LPType.UniswapV3),
                100_000e18,
                "tracked exposure must never drift below real debt"
            );
        }
    }

    // ================================================================
    // Haircut: a discount on borrowing capacity, applied consistently
    // ================================================================

    /// @dev The haircut is net-new in this refactor and must scale getMaxBorrow and the health
    ///      factor by the SAME factor — if the two diverged, a position could borrow its max and
    ///      be liquidatable in the same block (or vice versa).
    function testFuzz_haircutScalesMaxBorrowAndHealthIdentically(uint256 haircut) public {
        haircut = bound(haircut, 0, riskManager.MAX_HAIRCUT_BPS());
        oracle.setPrice(1_000_000e18);

        address user = makeAddr("haircutUser");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        // Baseline with no haircut: borrow a fixed amount so a health factor exists.
        uint256 maxBorrowNoHaircut = le.getMaxBorrow(posId);
        vm.prank(user);
        le.borrow(posId, 10_000e18);
        uint256 healthNoHaircut = pm.getHealthFactor(posId);

        vm.prank(owner);
        riskManager.setCollateralConfig(
            ILPAdapter.LPType.UniswapV3, RiskConfig.config(6500, 7500, 500, haircut, type(uint256).max, true)
        );

        uint256 expectedScale = 10_000 - haircut;
        assertApproxEqAbs(
            le.getMaxBorrow(posId),
            (maxBorrowNoHaircut * expectedScale) / 10_000,
            1,
            "max borrow must scale by (1 - haircut)"
        );
        assertApproxEqAbs(
            pm.getHealthFactor(posId),
            (healthNoHaircut * expectedScale) / 10_000,
            1,
            "health factor must scale by the same (1 - haircut)"
        );
    }

    /// @dev The haircut is bounded well below 100%: at 10000 it would zero every position's
    ///      collateral value and mark the whole collateral type liquidatable at once.
    function test_haircutCannotZeroCollateral() public {
        vm.prank(owner);
        vm.expectRevert("HAIRCUT_TOO_HIGH");
        riskManager.setCollateralConfig(
            ILPAdapter.LPType.UniswapV3, RiskConfig.config(6500, 7500, 500, 10_000, type(uint256).max, true)
        );
    }
}
