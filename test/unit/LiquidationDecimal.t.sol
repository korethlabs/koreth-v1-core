// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceFeedRegistry} from "../mocks/MockPriceFeedRegistry.sol";

/// @title LiquidationDecimalTest
/// @notice Full liquidation flow tests with REAL decimal configurations
/// @dev Tests the complete borrow → price drop → liquidate → send underlying tokens flow
///      using 6-decimal USDC and 8-decimal WBTC to exercise all decimal conversion paths:
///      - PositionManager.getHealthFactor (debt → USD via PriceFeedRegistry)
///      - LendingEngine._getMaxBorrow (USD → borrow asset decimals)
///      - LiquidationEngine._getRepayValueUsd (borrow amount → USD)
///      - Underlying token transfer to liquidator
contract LiquidationDecimalTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    LiquidationEngine public liq;
    LPOracleHub public oracleHub;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    InterestRateModel public irm;

    MockERC20 public weth;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public liquidator = makeAddr("liquidator");
    address public lpToken = makeAddr("lpToken");

    function setUp() public {
        weth = new MockERC20("WETH", "WETH", 18);
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

        LiquidationEngine liqImpl = new LiquidationEngine();
        liq = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(liqImpl),
                    abi.encodeCall(LiquidationEngine.initialize, (address(core), address(pm), address(le)))
                )
            )
        );

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV2);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(address(le));
        aclManager.addLiquidationEngine(address(liq));
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(oracle));
        core.whitelistPool(lpToken);
        pm.setLendingEngine(address(le));
        vm.stopPrank();
    }

    // ========== 6-Decimal USDC Full Liquidation Flow ==========

    function test_fullFlow_6decUSDC_withPriceFeedRegistry() public {
        // Setup: 6-decimal USDC market with PriceFeedRegistry
        MockERC20 usdc6 = new MockERC20("USDC", "USDC", 6);
        MockMarket market6 = new MockMarket(address(usdc6), address(irm));
        market6.setLpType(ILPAdapter.LPType.UniswapV2);
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        registry.setPrice(address(usdc6), 1e18); // $1.00

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(market6));
        core.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        // Fund: market + adapter
        usdc6.mint(address(market6), 10_000_000e6);
        usdc6.mint(address(adapter), 10_000_000e6);
        weth.mint(address(adapter), 10_000_000e18);

        // Adapter: 100 units → 25 WETH + 25K USDC6
        adapter.setTokenReturns(address(weth), address(usdc6));
        adapter.setUnwindAmounts(25e18, 25_000e6);
        adapter.setTotalLiquidity(100e18);

        // Alice deposits, oracle = $50K
        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, marketId);
        vm.roll(block.number + 2);

        // Borrow 30K USDC (6 dec)
        vm.prank(alice);
        le.borrow(posId, 30_000e6);

        uint256 debt = le.getDebt(posId);
        assertEq(debt, 30_000e6, "Debt should be 30K in 6-dec");

        // Price drops to $39K → HF = (39K * 7500) / (30K * 10000) = 0.975
        oracle.setPrice(39_000e18);

        uint256 hf = pm.getHealthFactor(posId);
        assertLt(hf, 1e18, "Should be liquidatable");
        assertGt(hf, 0.95e18, "Should be partial liquidation (not critical)");

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq, "Must be liquidatable");
        assertGt(maxRepay, 0, "maxRepay must be > 0");

        // maxRepay is in 6-dec USDC (50% of 30K = 15K)
        assertEq(maxRepay, 15_000e6, "maxRepay should be 50% of 30K USDC");

        // Liquidate with full maxRepay
        usdc6.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc6.approve(address(liq), maxRepay);

        uint256 wethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        uint256 profit = liq.liquidate(posId, maxRepay, block.timestamp + 1 hours, 0, 0);

        // Verify outcomes
        uint256 debtAfter = le.getDebt(posId);
        assertEq(debtAfter, 15_000e6, "Debt should be halved");

        uint256 amountAfter = pm.getPosition(posId).amount;
        assertLt(amountAfter, 100e18, "Position amount must decrease");

        // Profit is always 0 (liquidator receives raw underlying tokens)
        assertEq(profit, 0, "Profit must be 0 in no-swap design");

        // Liquidator received underlying tokens (WETH + USDC6) from unwind
        uint256 wethAfter = weth.balanceOf(liquidator);
        assertGt(wethAfter, wethBefore, "Liquidator must receive WETH from unwind");
    }

    function test_fullFlow_6decUSDC_withoutRegistry_fallback() public {
        // Same flow but WITHOUT PriceFeedRegistry — tests fallback normalization
        MockERC20 usdc6 = new MockERC20("USDC", "USDC", 6);
        MockMarket market6 = new MockMarket(address(usdc6), address(irm));
        market6.setLpType(ILPAdapter.LPType.UniswapV2);

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(market6));
        // NO setPriceFeedRegistry — testing fallback path
        vm.stopPrank();

        usdc6.mint(address(market6), 10_000_000e6);
        usdc6.mint(address(adapter), 10_000_000e6);
        weth.mint(address(adapter), 10_000_000e18);

        adapter.setTokenReturns(address(weth), address(usdc6));
        adapter.setUnwindAmounts(25e18, 25_000e6);
        adapter.setTotalLiquidity(100e18);

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, marketId);
        vm.roll(block.number + 2);

        // Borrow — fallback _getMaxBorrow normalizes to 6-dec
        vm.prank(alice);
        le.borrow(posId, 30_000e6);

        // Drop price → liquidatable
        oracle.setPrice(39_000e18);

        // Fallback HF: debt=30_000e6, normalized=30_000e18
        uint256 hf = pm.getHealthFactor(posId);
        assertLt(hf, 1e18, "Should be liquidatable via fallback");

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq);

        usdc6.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc6.approve(address(liq), maxRepay);

        vm.prank(liquidator);
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours, 0, 0);

        assertLt(pm.getPosition(posId).amount, 100e18, "Position amount must decrease");
        assertLt(le.getDebt(posId), 30_000e6, "Debt must decrease");
    }

    // ========== 8-Decimal WBTC Full Liquidation Flow ==========

    function test_fullFlow_8decWBTC_withPriceFeedRegistry() public {
        // WBTC at $60K as borrow asset — exercises non-$1 price conversion
        MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
        MockMarket marketBtc = new MockMarket(address(wbtc), address(irm));
        marketBtc.setLpType(ILPAdapter.LPType.UniswapV2);
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        registry.setPrice(address(wbtc), 60_000e18); // $60K per BTC

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(marketBtc));
        core.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        wbtc.mint(address(marketBtc), 100e8); // 100 BTC
        wbtc.mint(address(adapter), 100e8);
        weth.mint(address(adapter), 10_000e18);

        // 100 units → 25 WETH + 0.5 WBTC
        adapter.setTokenReturns(address(weth), address(wbtc));
        adapter.setUnwindAmounts(25e18, 5e7); // 25 WETH + 0.5 WBTC
        adapter.setTotalLiquidity(100e18);

        oracle.setPrice(100_000e18); // $100K collateral
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, marketId);
        vm.roll(block.number + 2);

        // Borrow 0.5 WBTC ($30K)
        vm.prank(alice);
        le.borrow(posId, 5e7); // 0.5 WBTC

        uint256 debt = le.getDebt(posId);
        assertEq(debt, 5e7, "Debt should be 0.5 WBTC");

        // Price drops to $38K → HF = (38K * 7500) / (30K * 10K) = 0.95
        oracle.setPrice(38_000e18);

        uint256 hf = pm.getHealthFactor(posId);
        assertLt(hf, 1e18, "Should be liquidatable");

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq, "Must be liquidatable");

        // maxRepay is in 8-dec WBTC
        assertGt(maxRepay, 0);

        wbtc.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        wbtc.approve(address(liq), maxRepay);

        uint256 wethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours, 0, 0);

        assertLt(pm.getPosition(posId).amount, 100e18, "Position amount must decrease");
        // Liquidator receives underlying tokens (WETH + WBTC)
        assertGt(weth.balanceOf(liquidator), wethBefore, "Liquidator must receive WETH from unwind");
    }

    // ========== Underwater 6-dec Liquidation (Bad Debt Prevention) ==========

    function test_fullFlow_6decUSDC_underwater_liquidatable() public {
        // Critically underwater position (HF < 0.95) with 6-dec USDC
        MockERC20 usdc6 = new MockERC20("USDC", "USDC", 6);
        MockMarket market6 = new MockMarket(address(usdc6), address(irm));
        market6.setLpType(ILPAdapter.LPType.UniswapV2);
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        registry.setPrice(address(usdc6), 1e18);

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(market6));
        core.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        usdc6.mint(address(market6), 10_000_000e6);
        usdc6.mint(address(adapter), 10_000_000e6);
        weth.mint(address(adapter), 10_000_000e18);

        // Both tokens are WETH
        adapter.setTokenReturns(address(weth), address(weth));
        adapter.setUnwindAmounts(25e18, 25e18); // 50 WETH total
        adapter.setTotalLiquidity(100e18);

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, marketId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 30_000e6);

        // Drop to $30K → HF = 0.75 (critically underwater)
        oracle.setPrice(30_000e18);

        uint256 hf = pm.getHealthFactor(posId);
        assertLt(hf, 0.95e18, "Must be critically underwater");

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq);
        assertEq(maxRepay, 30_000e6, "Critical: 100% liquidation");

        usdc6.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc6.approve(address(liq), maxRepay);

        // This MUST succeed — underwater positions must be liquidatable
        vm.prank(liquidator);
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours, 0, 0);

        assertEq(le.getDebt(posId), 0, "Debt should be fully repaid");
    }

    // ========== MaxBorrow with PriceFeedRegistry ==========

    function test_maxBorrow_6dec_respectsLTV() public {
        MockERC20 usdc6 = new MockERC20("USDC", "USDC", 6);
        MockMarket market6 = new MockMarket(address(usdc6), address(irm));
        market6.setLpType(ILPAdapter.LPType.UniswapV2);
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        registry.setPrice(address(usdc6), 1e18);

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(market6));
        core.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        usdc6.mint(address(market6), 10_000_000e6);

        adapter.setTokenReturns(address(weth), address(usdc6));
        adapter.setUnwindAmounts(25e18, 25_000e6);
        adapter.setTotalLiquidity(100e18);

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, marketId);
        vm.roll(block.number + 2);

        // maxBorrow = 50_000 * 0.65 = 32_500 USDC
        uint256 maxBorrow = le.getMaxBorrow(posId);
        assertEq(maxBorrow, 32_500e6, "maxBorrow must be in 6-dec USDC");

        // Borrow at max
        vm.prank(alice);
        le.borrow(posId, 32_500e6);

        // Borrow 1 more should fail
        vm.prank(alice);
        vm.expectRevert("EXCEEDS_MAX_LTV");
        le.borrow(posId, 1);
    }

    function test_maxBorrow_8decWBTC_respectsLTV() public {
        MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
        MockMarket marketBtc = new MockMarket(address(wbtc), address(irm));
        marketBtc.setLpType(ILPAdapter.LPType.UniswapV2);
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        registry.setPrice(address(wbtc), 60_000e18);

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(marketBtc));
        core.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        wbtc.mint(address(marketBtc), 1000e8);

        adapter.setTokenReturns(address(weth), address(wbtc));
        adapter.setUnwindAmounts(25e18, 5e7);
        adapter.setTotalLiquidity(100e18);

        oracle.setPrice(100_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, marketId);
        vm.roll(block.number + 2);

        // maxBorrow = 100_000 * 0.65 / 60_000 = 1.0833 WBTC = 108_333_333 (8 dec)
        uint256 maxBorrow = le.getMaxBorrow(posId);
        // mulDiv(65_000e18, 1e8, 60_000e18) = 108_333_333 = ~1.083 WBTC
        assertApproxEqAbs(maxBorrow, 108_333_333, 1, "maxBorrow must be in 8-dec WBTC");

        // Borrow 0.5 WBTC — within LTV
        vm.prank(alice);
        le.borrow(posId, 5e7);

        assertEq(le.getDebt(posId), 5e7);
    }
}
