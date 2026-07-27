// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {Market} from "../../src/markets/Market.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IMarket} from "../../src/interfaces/IMarket.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title EdgeCasesTest
/// @notice Tests for edge cases: different decimals, dust amounts, extreme values,
///         multi-step scenarios, and attack vectors
contract EdgeCasesTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    LiquidationEngine public liq;
    FeeCollector public fc;
    LPOracleHub public oracleHub;

    MockLPAdapter public adapter;
    MockLPOracle public oracle;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public liquidator = makeAddr("liquidator");
    address public lpToken = makeAddr("lpToken");
    address public treasury = makeAddr("treasury");
    address public insurance = makeAddr("insurance");

    // ========================================================
    // Helper: deploy full protocol with a specific borrow token
    // ========================================================
    function _deployWithToken(MockERC20 borrowToken) internal returns (Market market, uint256 marketId) {
        InterestRateModel irm = new InterestRateModel(200, 600, 10_000, 8000);

        IMarket.MarketConfig memory mConfig = IMarket.MarketConfig({
            lpType: ILPAdapter.LPType.UniswapV3,
            borrowAsset: address(borrowToken),
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            borrowCap: 10_000_000_000e18, // Very high cap
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

        vm.prank(owner);
        marketId = core.registerMarket(address(market));

        // Supply liquidity
        borrowToken.mint(address(this), 10_000_000e18);
        borrowToken.approve(address(market), 10_000_000e18);
        market.supply(10_000_000e18);
    }

    function setUp() public {
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

        fc = new FeeCollector(address(core), treasury, insurance);

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        oracle.setPrice(50_000e18);

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(address(le));
        aclManager.addLiquidationEngine(address(liq));
        aclManager.addPositionManager(address(pm));
        aclManager.addKeeper(address(liq));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        pm.setLendingEngine(address(le));
        liq.setFeeCollector(address(fc));
        vm.stopPrank();
    }

    // ========================================================
    // TEST: 6-decimal token (USDC real-world)
    // ========================================================

    function test_sixDecimalToken_fullLifecycle() public {
        MockERC20 usdc6 = new MockERC20("USDC", "USDC", 6);
        (Market market6, uint256 mId) = _deployWithToken(usdc6);

        // Deposit LP
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, mId);
        vm.roll(block.number + 2);

        // Borrow 25K USDC (6 decimals)
        vm.prank(alice);
        le.borrow(posId, 25_000e6);

        assertEq(usdc6.balanceOf(alice), 25_000e6);
        assertEq(le.getDebt(posId), 25_000e6);

        // Repay
        vm.prank(alice);
        usdc6.approve(address(market6), 25_000e6);
        vm.prank(alice);
        le.repay(posId, type(uint256).max);

        assertEq(le.getDebt(posId), 0);
    }

    // ========================================================
    // TEST: 8-decimal token (WBTC real-world)
    // ========================================================

    function test_eightDecimalToken_fullLifecycle() public {
        MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
        (Market market8, uint256 mId) = _deployWithToken(wbtc);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, mId);
        vm.roll(block.number + 2);

        // Borrow 0.5 WBTC
        vm.prank(alice);
        le.borrow(posId, 50_000_000); // 0.5e8

        assertEq(wbtc.balanceOf(alice), 50_000_000);
        assertEq(le.getDebt(posId), 50_000_000);

        // Repay
        vm.prank(alice);
        wbtc.approve(address(market8), 50_000_000);
        vm.prank(alice);
        le.repay(posId, type(uint256).max);

        assertEq(le.getDebt(posId), 0);
    }

    // ========================================================
    // TEST: Dust amounts — borrow 1 wei
    // ========================================================

    function test_dustAmount_borrow1Wei() public {
        MockERC20 token = new MockERC20("TOKEN", "TKN", 18);
        (Market m, uint256 mId) = _deployWithToken(token);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, mId);
        vm.roll(block.number + 2);

        // Borrow 1 wei
        vm.prank(alice);
        le.borrow(posId, 1);

        assertEq(le.getDebt(posId), 1);

        // Repay 1 wei
        token.mint(alice, 1);
        vm.prank(alice);
        token.approve(address(m), 1);
        vm.prank(alice);
        le.repay(posId, type(uint256).max);

        assertEq(le.getDebt(posId), 0);
    }

    // ========================================================
    // TEST: Large amounts — borrow millions
    // ========================================================

    function test_largeAmount_borrowMillions() public {
        MockERC20 token = new MockERC20("DAI", "DAI", 18);

        // Supply $100M liquidity
        InterestRateModel irm2 = new InterestRateModel(200, 600, 10_000, 8000);
        IMarket.MarketConfig memory mConfig2 = IMarket.MarketConfig({
            lpType: ILPAdapter.LPType.UniswapV3,
            borrowAsset: address(token),
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            borrowCap: 100_000_000_000e18,
            minPoolTvl: 0,
            minPoolAge: 0
        });
        Market m = Market(
            address(
                new ERC1967Proxy(
                    address(new Market()), abi.encodeCall(Market.initialize, (mConfig2, address(irm2), address(core)))
                )
            )
        );
        vm.prank(owner);
        uint256 mId = core.registerMarket(address(m));
        token.mint(address(this), 100_000_000e18);
        token.approve(address(m), 100_000_000e18);
        m.supply(100_000_000e18);

        oracle.setPrice(100_000_000e18); // $100M collateral

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, mId);
        vm.roll(block.number + 2);

        // Borrow $50M
        vm.prank(alice);
        le.borrow(posId, 50_000_000e18);

        assertEq(le.getDebt(posId), 50_000_000e18);

        // Advance 1 year — interest on $50M
        vm.warp(block.timestamp + 365 days);
        m.accrueInterest();

        uint256 debtAfter = le.getDebt(posId);
        assertGt(debtAfter, 50_000_000e18, "Interest must accrue on large amounts");
    }

    // ========================================================
    // TEST: Multiple deposits by same user
    // ========================================================

    function test_multiplePositions_sameUser() public {
        MockERC20 token = new MockERC20("TOKEN", "TKN", 18);
        (Market m, uint256 mId) = _deployWithToken(token);

        // Alice creates 3 positions
        vm.startPrank(alice);
        uint256 pos1 = pm.deposit(lpToken, 1, 50e18, mId);
        uint256 pos2 = pm.deposit(lpToken, 2, 75e18, mId);
        uint256 pos3 = pm.deposit(lpToken, 3, 100e18, mId);
        vm.stopPrank();
        vm.roll(block.number + 2);

        // Borrow on each
        vm.prank(alice);
        le.borrow(pos1, 10_000e18);
        vm.prank(alice);
        le.borrow(pos2, 15_000e18);
        vm.prank(alice);
        le.borrow(pos3, 20_000e18);

        // Each tracked independently
        assertEq(le.getDebt(pos1), 10_000e18);
        assertEq(le.getDebt(pos2), 15_000e18);
        assertEq(le.getDebt(pos3), 20_000e18);

        // Owner positions tracked
        uint256[] memory positions = pm.getPositionsByOwner(alice);
        assertEq(positions.length, 3);
    }

    // ========================================================
    // TEST: Interest accrual over multiple time steps
    // ========================================================

    function test_interestAccrual_multipleSteps() public {
        MockERC20 token = new MockERC20("TOKEN", "TKN", 18);
        (Market m, uint256 mId) = _deployWithToken(token);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, mId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 25_000e18);

        uint256 prevDebt = le.getDebt(posId);

        // Accrue in 12 monthly steps
        for (uint256 i = 0; i < 12; i++) {
            vm.warp(block.timestamp + 30 days);
            m.accrueInterest();

            uint256 currentDebt = le.getDebt(posId);
            assertGe(currentDebt, prevDebt, "Debt must not decrease between accruals");
            prevDebt = currentDebt;
        }

        // After 12 months, debt should be higher (rate depends on utilization)
        assertGt(prevDebt, 25_000e18, "Must accrue some interest over 12 months");
    }

    // ========================================================
    // TEST: Borrow, partial repay, borrow more, full repay
    // ========================================================

    function test_complexBorrowRepaySequence() public {
        MockERC20 token = new MockERC20("TOKEN", "TKN", 18);
        (Market m, uint256 mId) = _deployWithToken(token);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, mId);
        vm.roll(block.number + 2);

        // Borrow $20K
        vm.prank(alice);
        le.borrow(posId, 20_000e18);
        assertEq(le.getDebt(posId), 20_000e18);

        // Partial repay $5K
        token.mint(alice, 5000e18);
        vm.prank(alice);
        token.approve(address(m), 5000e18);
        vm.prank(alice);
        le.repay(posId, 5000e18);
        assertEq(le.getDebt(posId), 15_000e18);

        // Borrow $10K more (total debt = $25K)
        vm.prank(alice);
        le.borrow(posId, 10_000e18);
        assertEq(le.getDebt(posId), 25_000e18);

        // Full repay
        token.mint(alice, 25_000e18);
        vm.prank(alice);
        token.approve(address(m), 25_000e18);
        vm.prank(alice);
        le.repay(posId, type(uint256).max);
        assertEq(le.getDebt(posId), 0);

        // Can withdraw
        vm.prank(alice);
        pm.withdraw(posId);
        assertEq(uint8(pm.getPosition(posId).status), uint8(IPositionManager.PositionStatus.Closed));
    }

    // ========================================================
    // TEST: Price increase — health factor improves
    // ========================================================

    function test_priceIncrease_healthFactorImproves() public {
        MockERC20 token = new MockERC20("TOKEN", "TKN", 18);
        (, uint256 mId) = _deployWithToken(token);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, mId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 30_000e18);

        uint256 hfBefore = pm.getHealthFactor(posId);

        // Price doubles
        oracle.setPrice(100_000e18);
        uint256 hfAfter = pm.getHealthFactor(posId);

        assertGt(hfAfter, hfBefore, "HF must improve when collateral price increases");
    }

    // ========================================================
    // TEST: Zero oracle price — health factor = 0
    // ========================================================

    function test_zeroOraclePrice_healthFactorZero() public {
        MockERC20 token = new MockERC20("TOKEN", "TKN", 18);
        (, uint256 mId) = _deployWithToken(token);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, mId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 10_000e18);

        // Oracle returns 0 (catastrophic failure)
        oracle.setPrice(0);

        uint256 hf = pm.getHealthFactor(posId);
        assertEq(hf, 0, "HF must be 0 when collateral value is 0");
    }

    // ========================================================
    // TEST: Withdraw requires zero debt (can't withdraw with dust debt)
    // ========================================================

    function test_withdrawBlockedWithDustDebt() public {
        MockERC20 token = new MockERC20("TOKEN", "TKN", 18);
        (Market m, uint256 mId) = _deployWithToken(token);

        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, mId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 10_000e18);

        // Repay almost all but leave 1 wei
        token.mint(alice, 10_000e18);
        vm.prank(alice);
        token.approve(address(m), 10_000e18 - 1);
        vm.prank(alice);
        le.repay(posId, 10_000e18 - 1);

        // Still has 1 wei debt — can't withdraw
        assertEq(le.getDebt(posId), 1);
        vm.prank(alice);
        vm.expectRevert("HAS_DEBT");
        pm.withdraw(posId);
    }

    // ========================================================
    // TEST: Market utilization boundaries
    // ========================================================

    function test_marketUtilization_boundaries() public {
        MockERC20 token = new MockERC20("TOKEN", "TKN", 18);
        (Market m, uint256 mId) = _deployWithToken(token);

        // 0% utilization
        IMarket.MarketState memory state0 = m.getMarketState();
        assertEq(state0.utilization, 0);

        // Borrow to ~50% utilization
        oracle.setPrice(20_000_000e18); // Very high collateral to borrow a lot
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, mId);
        vm.roll(block.number + 2);
        vm.prank(alice);
        le.borrow(posId, 5_000_000e18); // 50% of 10M supply

        IMarket.MarketState memory state50 = m.getMarketState();
        assertGt(state50.utilization, 4000); // ~50%
        assertLt(state50.utilization, 6000);

        // Borrow rate should be meaningful at 50%
        assertGt(state50.borrowRate, 0);
    }

    // ========================================================
    // TEST: Can't deposit to non-whitelisted pool
    // ========================================================

    function test_nonWhitelistedPool_rejected() public {
        MockERC20 token = new MockERC20("TOKEN", "TKN", 18);
        (, uint256 mId) = _deployWithToken(token);

        address fakeLP = makeAddr("fakeLP");
        adapter.setSupportedToken(fakeLP, true); // Adapter supports it
        // But pool is NOT whitelisted in core

        vm.prank(alice);
        vm.expectRevert("POOL_NOT_SUPPORTED");
        pm.deposit(fakeLP, 1, 100e18, mId);
    }

    // ========================================================
    // TEST: Can't deposit unsupported LP token
    // ========================================================

    function test_unsupportedLPToken_rejected() public {
        MockERC20 token = new MockERC20("TOKEN", "TKN", 18);
        (, uint256 mId) = _deployWithToken(token);

        address unknownLP = makeAddr("unknownLP");
        // Not registered with any adapter

        vm.prank(alice);
        vm.expectRevert("UNSUPPORTED_LP");
        pm.deposit(unknownLP, 1, 100e18, mId);
    }
}
