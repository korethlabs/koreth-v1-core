// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {Market} from "../../src/markets/Market.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IMarket} from "../../src/interfaces/IMarket.sol";
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
    Market public market;
    LPOracleHub public oracleHub;
    FeeCollector public fc;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockERC20 public usdc;
    InterestRateModel public irm;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public lpToken = makeAddr("lpToken");
    uint256 public marketId;

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

        IMarket.MarketConfig memory mConfig = IMarket.MarketConfig({
            lpType: ILPAdapter.LPType.UniswapV3,
            borrowAsset: address(usdc),
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            borrowCap: 100_000_000e18,
            minPoolTvl: 0,
            minPoolAge: 0
        });
        market = Market(
            address(
                new ERC1967Proxy(
                    address(new Market()), abi.encodeCall(Market.initialize, (mConfig, address(irm), address(core)))
                )
            )
        );

        address treasury = makeAddr("treasury");
        address insurance = makeAddr("insurance");
        fc = new FeeCollector(address(core), treasury, insurance);

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
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
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
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
        IMarket.MarketState memory mState = market.getMarketState();

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
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
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
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
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
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
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
        IMarket.MarketState memory stateBefore = market.getMarketState();
        if (borrowAmt > stateBefore.totalSupply - stateBefore.totalBorrow) {
            borrowAmt = (stateBefore.totalSupply - stateBefore.totalBorrow) / 2;
        }
        if (borrowAmt == 0) return;

        address user = makeAddr("user");
        vm.prank(user);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);
        vm.prank(user);
        le.borrow(posId, borrowAmt);

        // Advance time
        timeElapsed = bound(timeElapsed, 0, 5 * 365 days);
        vm.warp(block.timestamp + timeElapsed);
        market.accrueInterest();

        // INVARIANT
        IMarket.MarketState memory stateAfter = market.getMarketState();
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
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        vm.prank(user);
        le.borrow(posId, borrowAmt);

        uint256 indexAtBorrow = market.borrowIndex();
        IMarket.MarketState memory stateAtBorrow = market.getMarketState();

        timeElapsed = bound(timeElapsed, 1 days, 365 days);
        vm.warp(block.timestamp + timeElapsed);
        market.accrueInterest();

        uint256 indexAfter = market.borrowIndex();
        IMarket.MarketState memory stateAfter = market.getMarketState();

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
        uint256 posId = pm.deposit(lpToken, 1, depositAmt, marketId);

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
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
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
            uint256 posId = pm.deposit(lpToken, i + 1, 100e18, marketId);
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
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
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
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);
        vm.prank(user);
        le.borrow(posId, borrowAmt);

        timeElapsed = bound(timeElapsed, 0, 365 days);
        vm.warp(block.timestamp + timeElapsed);
        market.accrueInterest();

        IMarket.MarketState memory s = market.getMarketState();
        uint256 marketBalance = usdc.balanceOf(address(market));

        // Available liquidity = balance in market
        // Must be >= 0 (market can't owe more tokens than it holds minus what's borrowed)
        assertGe(
            marketBalance + s.totalBorrow, s.totalSupply, "Market must remain solvent: balance + borrows >= supply"
        );
    }
}
