// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title MarketShareInvariantTest
/// @notice Fuzz-driven invariant tests for Market supply/withdraw share math.
/// @dev Ensures no share inflation attacks and consistent share/asset conversion.
contract MarketShareInvariantTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    Market public market;
    LPOracleHub public oracleHub;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockERC20 public usdc;
    InterestRateModel public irm;

    address public owner = makeAddr("owner");
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

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();

        vm.startPrank(owner);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
        pm.setLendingEngine(address(le));
        vm.stopPrank();
    }

    // ================================================================
    // INVARIANT 1: First depositor gets shares proportional to deposit
    // ================================================================

    function testFuzz_firstDepositorFairShares(uint256 amount) public {
        amount = bound(amount, 1e18, 1_000_000e18);

        address lender = makeAddr("lender");
        usdc.mint(lender, amount);
        vm.prank(lender);
        usdc.approve(address(market), amount);
        vm.prank(lender);
        uint256 shares = market.supply(amount);

        // First depositor: shares should approximate amount (virtual offset may cause tiny deviation)
        uint256 diff = shares > amount ? shares - amount : amount - shares;
        assertLe(diff, amount / 1000 + 1, "First depositor shares must be ~1:1 (within 0.1%)");
    }

    // ================================================================
    // INVARIANT 2: Supply then full withdraw must return original amount
    //              (when no interest has accrued)
    // ================================================================

    function testFuzz_supplyWithdrawRoundTrip(uint256 amount) public {
        amount = bound(amount, 1e18, 1_000_000e18);

        address lender = makeAddr("lender");
        usdc.mint(lender, amount);
        vm.prank(lender);
        usdc.approve(address(market), amount);
        vm.prank(lender);
        uint256 shares = market.supply(amount);

        uint256 balBefore = usdc.balanceOf(lender);
        vm.prank(lender);
        uint256 withdrawn = market.withdraw(shares);

        // The returned amount must actually reach the lender's balance
        assertEq(usdc.balanceOf(lender) - balBefore, withdrawn, "Withdrawn tokens must reach the lender");

        // Virtual offset in share math may cause tiny rounding loss
        uint256 diff = amount > withdrawn ? amount - withdrawn : withdrawn - amount;
        assertLe(diff, amount / 1000 + 1, "Full withdraw must return ~original amount (within 0.1%)");
    }

    // ================================================================
    // INVARIANT 3: Two equal depositors get equal shares
    // ================================================================

    function testFuzz_equalDepositorsEqualShares(uint256 amount) public {
        amount = bound(amount, 1e18, 1_000_000e18);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        usdc.mint(alice, amount);
        usdc.mint(bob, amount);

        vm.prank(alice);
        usdc.approve(address(market), amount);
        vm.prank(alice);
        uint256 sharesAlice = market.supply(amount);

        vm.prank(bob);
        usdc.approve(address(market), amount);
        vm.prank(bob);
        uint256 sharesBob = market.supply(amount);

        // Virtual offset causes larger deviation on tiny amounts, proportional on large amounts
        uint256 diff = sharesAlice > sharesBob ? sharesAlice - sharesBob : sharesBob - sharesAlice;
        assertLe(diff, amount / 1000 + 1, "Equal deposits must yield equal shares (within 0.1%)");
    }

    // ================================================================
    // INVARIANT 4: Interest accrual benefits existing lenders
    //              (withdraw amount >= original supply after interest)
    // ================================================================

    function testFuzz_interestBenefitsLender(uint256 supplyAmt, uint256 borrowAmt, uint256 timeElapsed) public {
        supplyAmt = bound(supplyAmt, 100_000e18, 1_000_000e18);
        oracle.setPrice(100_000e18);

        // Lender supplies
        address lender = makeAddr("lender");
        usdc.mint(lender, supplyAmt);
        vm.prank(lender);
        usdc.approve(address(market), supplyAmt);
        vm.prank(lender);
        market.supply(supplyAmt);

        // Borrower creates demand for interest — bound to available liquidity
        uint256 maxBorrowable = supplyAmt / 2; // at most 50% of supply
        if (maxBorrowable < 10_000e18) return; // skip if supply too small for meaningful borrow
        borrowAmt = bound(borrowAmt, 10_000e18, maxBorrowable > 65_000e18 ? 65_000e18 : maxBorrowable);
        address borrower = makeAddr("borrower");
        vm.prank(borrower);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);
        vm.prank(borrower);
        le.borrow(posId, borrowAmt);

        // Time passes, interest accrues
        timeElapsed = bound(timeElapsed, 1 days, 365 days);
        vm.warp(block.timestamp + timeElapsed);
        market.accrueInterest();

        // INVARIANT: totalSupply grows from interest (lender earns)
        // We check totalSupply increased rather than withdrawing, because
        // liquidity may be borrowed out (INSUFFICIENT_LIQUIDITY is valid behavior)
        IMarket.MarketState memory s = market.getMarketState();
        assertGt(s.totalSupply, supplyAmt, "totalSupply must grow from interest accrual");
    }

    // ================================================================
    // INVARIANT 5: Total shares * exchange rate = total supply
    //              (no phantom value creation)
    // ================================================================

    function testFuzz_sharesExchangeRateConsistent(uint256 amt1, uint256 amt2) public {
        amt1 = bound(amt1, 1e18, 500_000e18);
        amt2 = bound(amt2, 1e18, 500_000e18);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        usdc.mint(alice, amt1);
        usdc.mint(bob, amt2);

        vm.prank(alice);
        usdc.approve(address(market), amt1);
        vm.prank(alice);
        uint256 shares1 = market.supply(amt1);

        vm.prank(bob);
        usdc.approve(address(market), amt2);
        vm.prank(bob);
        uint256 shares2 = market.supply(amt2);

        IMarket.MarketState memory s = market.getMarketState();

        // totalSupply should equal amt1 + amt2 (no interest yet)
        assertEq(s.totalSupply, amt1 + amt2, "totalSupply must equal sum of deposits");

        // Share accounting: every minted share is accounted for (both users + dead shares)
        uint256 ts = market.totalShares();
        assertEq(ts, shares1 + shares2 + market.DEAD_SHARES(), "totalShares must equal minted + dead shares");

        // Exchange-rate consistency: each depositor's shares priced at the current rate
        // (totalSupply / totalShares) redeem back to ~their original deposit.
        uint256 aliceAssets = Math.mulDiv(shares1, s.totalSupply, ts);
        uint256 bobAssets = Math.mulDiv(shares2, s.totalSupply, ts);
        assertApproxEqAbs(aliceAssets, amt1, amt1 / 1000 + 1, "Alice's shares must redeem to ~her deposit");
        assertApproxEqAbs(bobAssets, amt2, amt2 / 1000 + 1, "Bob's shares must redeem to ~his deposit");
    }

    // ================================================================
    // INVARIANT 6: Cannot withdraw more shares than owned
    // ================================================================

    function testFuzz_cannotWithdrawMoreThanOwned(uint256 supplyAmt, uint256 extraShares) public {
        supplyAmt = bound(supplyAmt, 1e18, 1_000_000e18);
        extraShares = bound(extraShares, 1, 1_000_000e18);

        address lender = makeAddr("lender");
        usdc.mint(lender, supplyAmt);
        vm.prank(lender);
        usdc.approve(address(market), supplyAmt);
        vm.prank(lender);
        uint256 shares = market.supply(supplyAmt);

        vm.prank(lender);
        vm.expectRevert();
        market.withdraw(shares + extraShares);
    }
}
