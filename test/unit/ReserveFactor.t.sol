// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {Market} from "../../src/markets/Market.sol";
import {IMarket} from "../../src/interfaces/IMarket.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title ReserveFactorTest
/// @notice Tests the interest reserve factor flow: Market → FeeCollector → Treasury
contract ReserveFactorTest is Test {
    ACLManager public aclManager;
    ProtocolCore public core;
    FeeCollector public fc;
    Market public market;
    MockERC20 public usdc;
    InterestRateModel public irm;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public insurance = makeAddr("insurance");
    address public lender = makeAddr("lender");
    address public borrower = makeAddr("borrower");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        irm = new InterestRateModel(200, 600, 10_000, 8000);

        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));
        fc = new FeeCollector(address(core), treasury, insurance);

        // Deploy Market proxy
        Market marketImpl = new Market();
        IMarket.MarketConfig memory config = IMarket.MarketConfig({
            lpType: ILPAdapter.LPType.UniswapV3,
            borrowAsset: address(usdc),
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            borrowCap: 10_000_000e18,
            minPoolTvl: 0,
            minPoolAge: 0
        });

        market = Market(
            address(
                new ERC1967Proxy(
                    address(marketImpl), abi.encodeCall(Market.initialize, (config, address(irm), address(core)))
                )
            )
        );

        // Grant LENDING_ENGINE to this test contract so we can call transferOut/transferIn
        vm.startPrank(owner);
        aclManager.addLendingEngine(address(this));
        core.registerMarket(address(market));
        market.setReserveFactor(2000); // 20%
        market.setFeeCollector(address(fc));
        vm.stopPrank();

        // Lender supplies (this is the market's liquidity)
        usdc.mint(lender, 100_000e18);
        vm.prank(lender);
        usdc.approve(address(market), 100_000e18);
        vm.prank(lender);
        market.supply(100_000e18);
    }

    // ========== Reserve Factor Split ==========

    function test_accrueInterest_splitsCorrectly() public {
        // Simulate a borrow
        market.transferOut(borrower, 50_000e18);

        // Advance time — 1 year
        vm.warp(block.timestamp + 365 days);

        IMarket.MarketState memory stateBefore = market.getMarketState();
        uint256 totalBorrowBefore = stateBefore.totalBorrow;

        market.accrueInterest();

        IMarket.MarketState memory stateAfter = market.getMarketState();
        uint256 interestAccrued = stateAfter.totalBorrow - totalBorrowBefore;

        // Protocol should get 20% of interest
        uint256 expectedProtocolShare = (interestAccrued * 2000) / 10_000;
        uint256 expectedLenderShare = interestAccrued - expectedProtocolShare;

        // totalSupply should increase by lenderShare only (not full interest)
        assertApproxEqAbs(
            stateAfter.totalSupply, stateBefore.totalSupply + expectedLenderShare, 1, "Lender share incorrect"
        );

        // protocolReserves should accumulate
        assertApproxEqAbs(market.protocolReserves(), expectedProtocolShare, 1, "Protocol reserves incorrect");
    }

    function test_accrueInterest_zeroReserveFactor() public {
        // Set reserve factor to 0 — all interest goes to lenders
        vm.prank(owner);
        market.setReserveFactor(0);

        market.transferOut(borrower, 50_000e18);
        vm.warp(block.timestamp + 365 days);

        IMarket.MarketState memory stateBefore = market.getMarketState();
        market.accrueInterest();
        IMarket.MarketState memory stateAfter = market.getMarketState();

        uint256 interestAccrued = stateAfter.totalBorrow - stateBefore.totalBorrow;

        // All interest goes to lenders
        assertEq(stateAfter.totalSupply, stateBefore.totalSupply + interestAccrued);
        assertEq(market.protocolReserves(), 0);
    }

    // ========== Distribute Reserves ==========

    function test_distributeReserves_sendsToFeeCollector() public {
        market.transferOut(borrower, 50_000e18);
        vm.warp(block.timestamp + 365 days);
        market.accrueInterest();

        uint256 reserves = market.protocolReserves();
        assertGt(reserves, 0, "Should have reserves");

        // Anyone can call distributeReserves
        market.distributeReserves();

        assertEq(market.protocolReserves(), 0, "Reserves should be cleared");
        assertEq(fc.accumulatedFees(address(usdc)), reserves, "FeeCollector should track reserves");
    }

    function test_distributeReserves_thenDistribute_toTreasuryAndInsurance() public {
        market.transferOut(borrower, 50_000e18);
        vm.warp(block.timestamp + 365 days);
        market.accrueInterest();

        uint256 reserves = market.protocolReserves();

        // Step 1: Market → FeeCollector
        market.distributeReserves();

        // Step 2: FeeCollector → Treasury + Insurance (90/10 split)
        vm.prank(owner);
        fc.distribute(address(usdc));

        uint256 expectedInsurance = (reserves * 1000) / 10_000; // 10%
        uint256 expectedTreasury = reserves - expectedInsurance;

        assertApproxEqAbs(usdc.balanceOf(treasury), expectedTreasury, 1, "Treasury amount wrong");
        assertApproxEqAbs(usdc.balanceOf(insurance), expectedInsurance, 1, "Insurance amount wrong");
    }

    function test_distributeReserves_revertsNoReserves() public {
        vm.expectRevert("NO_RESERVES");
        market.distributeReserves();
    }

    function test_distributeReserves_revertsNoFeeCollector() public {
        // Deploy market without feeCollector set
        Market marketImpl2 = new Market();
        IMarket.MarketConfig memory config2 = IMarket.MarketConfig({
            lpType: ILPAdapter.LPType.UniswapV3,
            borrowAsset: address(usdc),
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            borrowCap: 10_000_000e18,
            minPoolTvl: 0,
            minPoolAge: 0
        });
        Market market2 = Market(
            address(
                new ERC1967Proxy(
                    address(marketImpl2), abi.encodeCall(Market.initialize, (config2, address(irm), address(core)))
                )
            )
        );

        vm.prank(owner);
        market2.setReserveFactor(2000);

        // Supply and borrow (no direct mint — use supply() for proper accounting)
        usdc.mint(lender, 100_000e18);
        vm.prank(lender);
        usdc.approve(address(market2), 100_000e18);
        vm.prank(lender);
        market2.supply(100_000e18);
        market2.transferOut(borrower, 50_000e18);

        vm.warp(block.timestamp + 365 days);
        market2.accrueInterest();

        vm.expectRevert("NO_FEE_COLLECTOR");
        market2.distributeReserves();
    }

    function test_distributeReserves_capsAtBalance() public {
        // Borrow almost all liquidity so cash is low
        market.transferOut(borrower, 99_000e18);

        // Accrue a lot of interest — reserves grow but cash is only ~1K
        vm.warp(block.timestamp + 3 * 365 days);
        market.accrueInterest();

        uint256 reserves = market.protocolReserves();
        uint256 balance = usdc.balanceOf(address(market));

        // At 99% utilization + 3 years, reserves must exceed remaining cash
        assertGt(reserves, balance, "Reserves should exceed cash at high util");

        // distributeReserves caps at balance, doesn't revert
        market.distributeReserves();

        // Some reserves remain (the unfunded portion)
        assertGt(market.protocolReserves(), 0, "Should have remaining reserves");
    }

    // ========== Multiple Accruals ==========

    function test_multipleAccruals_accumulateReserves() public {
        market.transferOut(borrower, 50_000e18);

        // Accrue 3 times
        vm.warp(block.timestamp + 30 days);
        market.accrueInterest();
        uint256 r1 = market.protocolReserves();

        vm.warp(block.timestamp + 30 days);
        market.accrueInterest();
        uint256 r2 = market.protocolReserves();

        vm.warp(block.timestamp + 30 days);
        market.accrueInterest();
        uint256 r3 = market.protocolReserves();

        assertGe(r2, r1, "Reserves should not decrease");
        assertGe(r3, r2, "Reserves should not decrease");
        assertGt(r3, 0, "Should have accumulated reserves after 90 days");
    }

    // ========== Admin ==========

    function test_setReserveFactor_onlyRiskAdmin() public {
        vm.prank(borrower);
        vm.expectRevert("NOT_RISK_ADMIN");
        market.setReserveFactor(1000);
    }

    function test_setReserveFactor_maxLimit() public {
        vm.prank(owner);
        vm.expectRevert("RESERVE_TOO_HIGH");
        market.setReserveFactor(5001);
    }

    function test_setFeeCollector_onlyPoolAdmin() public {
        vm.prank(borrower);
        vm.expectRevert("NOT_POOL_ADMIN");
        market.setFeeCollector(address(fc));
    }

    function test_setFeeCollector_revertsCoresMismatch() public {
        ACLManager otherAcl = new ACLManager(owner);
        ProtocolCore otherCore = new ProtocolCore(owner, address(otherAcl));
        FeeCollector badFc = new FeeCollector(address(otherCore), treasury, insurance);

        vm.prank(owner);
        vm.expectRevert("CORE_MISMATCH");
        market.setFeeCollector(address(badFc));
    }

    // ========== Invariant: totalBorrow = totalSupply + protocolReserves ==========

    function test_invariant_borrowEqualsSplitSum() public {
        market.transferOut(borrower, 50_000e18);
        vm.warp(block.timestamp + 180 days);
        market.accrueInterest();

        IMarket.MarketState memory s = market.getMarketState();
        uint256 reserves = market.protocolReserves();

        // totalBorrow should equal what was originally supplied + all interest
        // totalSupply (lender portion) + protocolReserves should equal total interest + original supply
        // The key invariant: totalBorrow = totalSupply + protocolReserves - originalSupply + totalBorrow_original
        // Simpler: interestAccrued = (totalSupply - originalSupply) + protocolReserves
        uint256 originalSupply = 100_000e18;
        uint256 originalBorrow = 50_000e18;
        uint256 interestAccrued = s.totalBorrow - originalBorrow;
        uint256 lenderEarnings = s.totalSupply - originalSupply;

        assertApproxEqAbs(interestAccrued, lenderEarnings + reserves, 1, "Interest split invariant broken");
    }
}
