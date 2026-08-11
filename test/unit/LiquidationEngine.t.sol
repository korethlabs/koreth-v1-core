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
import {MockLendingPool} from "../mocks/MockLendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {RiskConfig} from "../helpers/RiskConfig.sol";
import {TestPricing} from "../helpers/TestPricing.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {TestPools} from "../helpers/TestPools.sol";
import {TestSecurity} from "../helpers/TestSecurity.sol";

contract LiquidationEngineTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    LiquidationEngine public liq;
    LPOracleHub public oracleHub;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockLendingPool public market;
    PriceFeedRegistry public priceRegistry;
    MockERC20 public usdc;
    MockERC20 public weth;
    InterestRateModel public irm;
    RiskManager public riskManager;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public liquidator = makeAddr("liquidator");
    address public lpToken = makeAddr("lpToken");

    address public borrowAsset;

    // Events
    event LiquidationExecuted(
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 repayAmount,
        uint256 collateralSeized,
        uint256 liquidatorProfit
    );
    event MaxLiquidationPortionUpdated(uint256 oldValue, uint256 newValue);
    event LiquidationOverSeizeRefunded(uint256 indexed positionId, uint256 refund0, uint256 refund1);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        weth = new MockERC20("WETH", "WETH", 18);
        irm = new InterestRateModel(200, 600, 10_000, 8000);

        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        // OracleHub proxy
        LPOracleHub ohImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(ohImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );

        // PositionManager proxy
        PositionManager pmImpl = new PositionManager();
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        // LendingEngine proxy
        LendingEngine leImpl = new LendingEngine();
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        // LiquidationEngine proxy
        LiquidationEngine liqImpl = new LiquidationEngine();
        liq = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(liqImpl),
                    abi.encodeCall(LiquidationEngine.initialize, (address(core), address(pm), address(le)))
                )
            )
        );

        // Mocks
        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV2);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        oracle.setPrice(50_000e18);
        market = new MockLendingPool(address(usdc), address(irm));
        borrowAsset = address(usdc);
        riskManager = new RiskManager(address(core));

        // Register and grant roles
        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(address(le));
        aclManager.addLiquidationEngine(address(liq));
        aclManager.addPositionManager(address(pm));
        aclManager.addRiskAdmin(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(oracle));
        core.whitelistLpPool(TestPools.asContract(lpToken));
        priceRegistry = TestPricing.wireStable(core, address(usdc));
        // WETH is the pool's other underlying. At liquidation time the default position holds
        // 25 WETH + 25,000 USDC and the oracle values it at $30k, so WETH is worth $200 here: the
        // registry-valued underlying then equals the oracle target and the over-seize clamp
        // (Liquidation M-1) is a no-op for the default tests. Tests that deliberately diverge WETH
        // from this move the feed themselves.
        TestPricing.priceAsset(priceRegistry, address(weth), 200e18);
        core.registerLendingPool(address(usdc), address(market));
        core.setRiskManager(address(riskManager));
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV2, RiskConfig.defaultConfig());
        TestSecurity.wireBreaker(core, pm);
        TestSecurity.wireFeeCollector(core, liq, makeAddr("treasury"));
        pm.setLendingEngine(address(le));
        vm.stopPrank();

        // Configure realistic values consistent with oracle price ($50K for 100 units):
        // Position has 25 WETH + 25,000 USDC for 100 units
        // Total value: $50,000 ≈ oracle price
        adapter.setTokenReturns(address(weth), address(usdc));
        adapter.setUnwindAmounts(25e18, 25_000e18); // Per 100 units total
        adapter.setTotalLiquidity(100e18); // Match deposit amount

        // Fund
        usdc.mint(address(market), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);
        usdc.mint(address(adapter), 1_000_000e18);
    }

    // --- Helpers ---

    /// @notice Create a position and borrow, then make it liquidatable by dropping oracle price
    function _createLiquidatablePosition() internal returns (uint256 posId) {
        // Alice deposits LP worth $50K
        vm.prank(alice);
        posId = pm.deposit(lpToken, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        // Advance past borrow cooldown
        vm.roll(block.number + 2);

        // Alice borrows $30K (within 65% LTV of $50K)
        vm.prank(alice);
        le.borrow(posId, 30_000e18);

        // Oracle price drops to $30K → health factor drops below 1.0
        // HF = ($30K * 7500 / 10000) / $30K = 0.75 → liquidatable
        oracle.setPrice(30_000e18);
    }

    // ========== Initialization ==========

    function test_initialize_setsState() public view {
        assertEq(address(liq.core()), address(core));
        assertEq(address(liq.positionManager()), address(pm));
        assertEq(address(liq.lendingEngine()), address(le));
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        liq.initialize(address(core), address(pm), address(le));
    }

    function test_initialize_defaults() public view {
        assertEq(liq.maxLiquidationPortion(), 5000);
    }

    // ========== Admin Setters ==========

    function test_setMaxLiquidationPortion_success() public {
        vm.expectEmit(false, false, false, true);
        emit MaxLiquidationPortionUpdated(5000, 7500);

        vm.prank(owner);
        liq.setMaxLiquidationPortion(7500);
        assertEq(liq.maxLiquidationPortion(), 7500);
    }

    function test_setMaxLiquidationPortion_revertsBelowMin() public {
        vm.prank(owner);
        vm.expectRevert("BELOW_MIN");
        liq.setMaxLiquidationPortion(500); // Below 10%
    }

    function test_setMaxLiquidationPortion_revertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert("ABOVE_MAX");
        liq.setMaxLiquidationPortion(10_001);
    }

    // ========== isLiquidatable ==========

    function test_isLiquidatable_falseWhenHealthy() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 10_000e18); // Low borrow, healthy position

        (bool canLiq,) = liq.isLiquidatable(posId);
        assertFalse(canLiq);
    }

    function test_isLiquidatable_trueWhenUnhealthy() public {
        uint256 posId = _createLiquidatablePosition();

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq);
        assertGt(maxRepay, 0);
    }

    function test_isLiquidatable_maxRepayIsPortionOfDebt() public {
        // Create a position that's liquidatable but NOT critically underwater
        // HF must be >= 0.95 and < 1.0 for partial liquidation rules to apply
        // HF = (collateral * liqThreshold) / (debt * 10000)
        // With liqThreshold = 7500: HF = (collateral * 7500) / (debt * 10000)
        // For HF = 0.975: collateral = debt * 10000 * 0.975 / 7500 = debt * 1.3
        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.prank(alice);
        le.borrow(posId, 30_000e18);

        // Drop price so HF is between 0.95 and 1.0
        // HF = (price * 7500) / (30000 * 10000)
        // For HF = 0.975: price = 0.975 * 30000 * 10000 / 7500 = 39000
        oracle.setPrice(39_000e18);

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq);

        uint256 totalDebt = le.getDebt(posId);
        // HF >= 0.95 → partial liquidation (not full)
        uint256 expectedMaxRepay = totalDebt * 5000 / 10_000;
        if (expectedMaxRepay == 0) expectedMaxRepay = 1;
        assertEq(maxRepay, expectedMaxRepay);
    }

    function test_isLiquidatable_fullLiquidationWhenCritical() public {
        // Create critically underwater position (HF < 0.95)
        uint256 posId = _createLiquidatablePosition(); // HF = 0.75

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq);

        uint256 totalDebt = le.getDebt(posId);
        // HF < 0.95 → full liquidation allowed (LIQ-4)
        assertEq(maxRepay, totalDebt);
    }

    function test_isLiquidatable_falseForNoDebt() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.roll(block.number + 2);

        (bool canLiq,) = liq.isLiquidatable(posId);
        assertFalse(canLiq);
    }

    // ========== getLiquidationBonus ==========

    function test_getLiquidationBonus_returnsRiskConfig() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.roll(block.number + 2);

        uint256 bonus = liq.getLiquidationBonus(posId);
        assertEq(bonus, 500); // 5% from MockMarket config
    }

    // ========== liquidate ==========

    function test_liquidate_revertsNotLiquidatable() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 10_000e18); // Healthy position

        usdc.mint(liquidator, 5000e18);
        vm.prank(liquidator);
        usdc.approve(address(liq), 5000e18);

        vm.prank(liquidator);
        vm.expectRevert("NOT_LIQUIDATABLE");
        liq.liquidate(posId, 5000e18, block.timestamp + 1 hours, 0, 0);
    }

    function test_liquidate_revertsZeroAmount() public {
        uint256 posId = _createLiquidatablePosition();

        vm.prank(liquidator);
        vm.expectRevert("ZERO_AMOUNT");
        liq.liquidate(posId, 0, block.timestamp + 1 hours, 0, 0);
    }

    function test_liquidate_revertsExceedsMaxRepay() public {
        uint256 posId = _createLiquidatablePosition();

        (, uint256 maxRepay) = liq.isLiquidatable(posId);

        usdc.mint(liquidator, maxRepay + 1);
        vm.prank(liquidator);
        usdc.approve(address(liq), maxRepay + 1);

        vm.prank(liquidator);
        vm.expectRevert("EXCEEDS_MAX_REPAY");
        liq.liquidate(posId, maxRepay + 1, block.timestamp + 1 hours, 0, 0);
    }

    function test_liquidate_revertsSlippageAmount0() public {
        uint256 posId = _createLiquidatablePosition();
        (, uint256 maxRepay) = liq.isLiquidatable(posId);

        usdc.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc.approve(address(liq), maxRepay);

        // minAmount0 set impossibly high → slippage revert on token0
        vm.prank(liquidator);
        vm.expectRevert("SLIPPAGE_AMOUNT0");
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours, type(uint256).max, 0);
    }

    function test_liquidate_revertsSlippageAmount1() public {
        uint256 posId = _createLiquidatablePosition();
        (, uint256 maxRepay) = liq.isLiquidatable(posId);

        usdc.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc.approve(address(liq), maxRepay);

        // minAmount1 set impossibly high → slippage revert on token1
        vm.prank(liquidator);
        vm.expectRevert("SLIPPAGE_AMOUNT1");
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours, 0, type(uint256).max);
    }

    function test_liquidate_revertsWhenPaused() public {
        uint256 posId = _createLiquidatablePosition();

        vm.prank(guardian);
        core.pause();

        vm.prank(liquidator);
        vm.expectRevert("PAUSED");
        liq.liquidate(posId, 1000e18, block.timestamp + 1 hours, 0, 0);
    }

    function test_liquidate_reducesDebt() public {
        uint256 posId = _createLiquidatablePosition();

        uint256 debtBefore = le.getDebt(posId);
        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        // Use a meaningful portion (not /2 which could round to 0 for tiny maxRepay)
        uint256 repayAmount = maxRepay > 1 ? maxRepay : 1;

        usdc.mint(liquidator, repayAmount);
        vm.prank(liquidator);
        usdc.approve(address(liq), repayAmount);

        vm.prank(liquidator);
        liq.liquidate(posId, repayAmount, block.timestamp + 1 hours, 0, 0);

        uint256 debtAfter = le.getDebt(posId);
        assertLt(debtAfter, debtBefore);
    }

    function test_liquidate_emitsEvent() public {
        uint256 posId = _createLiquidatablePosition();
        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        uint256 repayAmount = maxRepay > 1 ? maxRepay : 1;

        usdc.mint(liquidator, repayAmount);
        vm.prank(liquidator);
        usdc.approve(address(liq), repayAmount);

        // Record logs and verify LiquidationExecuted was emitted
        vm.recordLogs();

        vm.prank(liquidator);
        liq.liquidate(posId, repayAmount, block.timestamp + 1 hours, 0, 0);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        // LiquidationExecuted should be the last event
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("LiquidationExecuted(uint256,address,uint256,uint256,uint256)")) {
                found = true;
                assertEq(entries[i].topics[1], bytes32(posId));
                assertEq(entries[i].topics[2], bytes32(uint256(uint160(liquidator))));
            }
        }
        assertTrue(found, "LiquidationExecuted event not found");
    }

    // ========== Configurable Portion ==========

    function test_liquidate_respectsCustomPortion() public {
        // Set max liquidation to 100%
        vm.prank(owner);
        liq.setMaxLiquidationPortion(10_000);

        uint256 posId = _createLiquidatablePosition();
        uint256 totalDebt = le.getDebt(posId);

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertEq(maxRepay, totalDebt); // 100% of debt
    }

    function test_liquidate_respectsMinPortion() public {
        vm.prank(owner);
        liq.setMaxLiquidationPortion(1000); // 10%

        // Create position with HF between 0.95-1.0 (partial liq rules apply)
        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.prank(alice);
        le.borrow(posId, 30_000e18);
        oracle.setPrice(39_000e18); // HF ≈ 0.975

        uint256 totalDebt = le.getDebt(posId);

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertEq(maxRepay, totalDebt * 1000 / 10_000);
    }

    // ========== UUPS Upgrade ==========

    function test_upgrade_onlyOwner() public {
        LiquidationEngine newImpl = new LiquidationEngine();

        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        liq.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_preservesConfig() public {
        vm.prank(owner);
        liq.setMaxLiquidationPortion(7500);

        LiquidationEngine newImpl = new LiquidationEngine();
        vm.prank(owner);
        liq.upgradeToAndCall(address(newImpl), "");

        assertEq(liq.maxLiquidationPortion(), 7500);
    }

    // ========== Rescue ==========

    function test_rescueTokens_success() public {
        // Simulate stuck tokens in LiquidationEngine
        weth.mint(address(liq), 5e18);

        address recipient = makeAddr("recipient");
        vm.prank(owner);
        liq.rescueTokens(address(weth), recipient, 5e18);

        assertEq(weth.balanceOf(recipient), 5e18);
        assertEq(weth.balanceOf(address(liq)), 0);
    }

    function test_rescueTokens_revertsNotOwner() public {
        weth.mint(address(liq), 5e18);

        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        liq.rescueTokens(address(weth), alice, 5e18);
    }

    function test_rescueTokens_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        liq.rescueTokens(address(0), makeAddr("x"), 1e18);

        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        liq.rescueTokens(address(weth), address(0), 1e18);
    }

    function test_rescueTokens_revertsZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_AMOUNT");
        liq.rescueTokens(address(weth), makeAddr("x"), 0);
    }

    function test_rescueTokens_multipleTokens() public {
        // Rescue different token types
        weth.mint(address(liq), 3e18);
        usdc.mint(address(liq), 1000e18);

        address recipient = makeAddr("recipient");
        vm.startPrank(owner);
        liq.rescueTokens(address(weth), recipient, 3e18);
        liq.rescueTokens(address(usdc), recipient, 1000e18);
        vm.stopPrank();

        assertEq(weth.balanceOf(recipient), 3e18);
        assertEq(usdc.balanceOf(recipient), 1000e18);
    }

    // ========== Borrow-asset price movement ==========

    /// @dev The case the fail-closed pricing work exists for, and the one nothing covered: the
    ///      collateral does not move at all — the *debt* becomes more valuable. Under the deleted
    ///      $1 fallback this position stays healthy forever no matter what the borrow asset does,
    ///      which is how a market could be drained without a single liquidation firing.
    function test_borrowAssetAppreciation_makesPositionLiquidatable() public {
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 30_000e18);

        (bool canLiqBefore,) = liq.isLiquidatable(posId);
        assertFalse(canLiqBefore, "healthy while the borrow asset is worth $1");

        // Collateral untouched — only the debt is now worth more.
        TestPricing.feedFor(priceRegistry, borrowAsset).setAnswer(1.5e18);

        (bool canLiqAfter, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiqAfter, "a 50% rise in the debt asset must be seen");
        assertGt(maxRepay, 0);

        // HF = collateral($50K) * 7500bps / debt(30_000 x $1.50 = $45K) = 0.833
        assertApproxEqRel(pm.getHealthFactor(posId), 0.8333e18, 0.001e18, "HF must track the debt price");
    }

    /// @dev The mirror image: a depegging borrow asset makes the debt cheaper, so a position that
    ///      was underwater recovers. Proves the health factor tracks the price in both directions
    ///      rather than merely being sensitive to it.
    function test_borrowAssetDepeg_healsPosition() public {
        uint256 posId = _createLiquidatablePosition();

        (bool canLiqBefore,) = liq.isLiquidatable(posId);
        assertTrue(canLiqBefore, "underwater after the collateral drop");

        TestPricing.feedFor(priceRegistry, borrowAsset).setAnswer(0.5e18);

        (bool canLiqAfter,) = liq.isLiquidatable(posId);
        assertFalse(canLiqAfter, "debt worth half as much must restore health");
    }

    /// @dev A borrow asset whose feed stops updating must stop the protocol, not be waved through:
    ///      every borrow-side conversion goes through getPrice(), which rejects stale data.
    function test_staleBorrowAssetFeed_blocksLiquidation() public {
        uint256 posId = _createLiquidatablePosition();

        // MockConstantFeed reports block.timestamp, so it can never go stale on its own — the whole
        // point of this test is the case it cannot produce. Answer from a fixed early timestamp and
        // move well past maxStaleness (1h). The collateral oracle is left live, so a revert here can
        // only be coming from the borrow leg.
        uint256 answeredAt = 1000;
        vm.warp(answeredAt + 2 hours);
        vm.mockCall(
            address(TestPricing.feedFor(priceRegistry, borrowAsset)),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(1e18), answeredAt, answeredAt, uint80(1))
        );

        vm.expectRevert("STALE_PRICE");
        liq.isLiquidatable(posId);

        vm.clearMockedCalls();
    }

    // ========== LIQ-3: Decimal normalization ==========

    function test_liquidate_worksWithSixDecimalUSDC() public {
        // Deploy a 6-decimal USDC (real-world scenario)
        MockERC20 usdc6 = new MockERC20("USDC", "USDC", 6);
        InterestRateModel irm6 = new InterestRateModel(200, 600, 10_000, 8000);
        MockLendingPool market6 = new MockLendingPool(address(usdc6), address(irm6));

        // Register the new pool (keyed by its borrow asset). Declaring its price first is not
        // optional: a market the protocol cannot value cannot be listed.
        vm.startPrank(owner);
        TestPricing.priceAsset(priceRegistry, address(usdc6), 1e18);
        core.registerLendingPool(address(usdc6), address(market6));
        vm.stopPrank();

        // Fund market
        usdc6.mint(address(market6), 1_000_000e6);
        weth.mint(address(adapter), 1_000_000e18);
        usdc6.mint(address(adapter), 1_000_000e6);

        // Configure adapter to return WETH and USDC6
        adapter.setTokenReturns(address(weth), address(usdc6));
        adapter.setUnwindAmounts(25e18, 25_000e6); // 25 WETH + 25K USDC (6 dec) per 100 units

        // Alice deposits LP worth $50K
        oracle.setPrice(50_000e18); // Oracle always returns 18 decimals
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, address(usdc6));
        vm.roll(block.number + 2);
        vm.roll(block.number + 2);

        // Alice borrows 30K USDC (6 decimals)
        vm.prank(alice);
        le.borrow(posId, 30_000e6);

        // Price drops → position underwater
        oracle.setPrice(30_000e18);

        // Asserted unconditionally on purpose. This used to sit inside `if (canLiq && maxRepay > 0)`
        // and was followed by a test whose body was `assertTrue(true)` — so pricing broken badly
        // enough that the position never became liquidatable would have passed both without
        // executing a single meaningful assertion.
        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq, "position must be liquidatable once the collateral halves");
        assertGt(maxRepay, 0, "a liquidatable position must have something to repay");

        usdc6.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc6.approve(address(liq), maxRepay);

        vm.prank(liquidator);
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours, 0, 0);

        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertLt(pos.amount, 100e18, "Position amount must decrease after liquidation with 6-dec USDC");
    }

    function test_liquidate_worksWithEighteenDecimalDAI() public {
        // 18-decimal borrow asset (like DAI) — should work without normalization issues
        // This is what our default setup already uses (usdc mock is 18 dec in this test)
        uint256 posId = _createLiquidatablePosition();

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        uint256 repayAmount = maxRepay > 1 ? maxRepay : 1;

        usdc.mint(liquidator, repayAmount);
        vm.prank(liquidator);
        usdc.approve(address(liq), repayAmount);

        uint256 amountBefore = pm.getPosition(posId).amount;

        vm.prank(liquidator);
        liq.liquidate(posId, repayAmount, block.timestamp + 1 hours, 0, 0);

        uint256 amountAfter = pm.getPosition(posId).amount;
        assertLt(amountAfter, amountBefore, "Must work with 18-dec token too");
    }

    // ========== PM-3: Position amount updated after partial liquidation ==========

    function test_liquidate_partialUpdatesPositionAmount() public {
        uint256 posId = _createLiquidatablePosition();

        IPositionManager.Position memory posBefore = pm.getPosition(posId);
        uint256 amountBefore = posBefore.amount;
        assertEq(amountBefore, 100e18); // Original deposit amount

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        uint256 repayAmount = maxRepay > 1 ? maxRepay : 1;

        usdc.mint(liquidator, repayAmount);
        vm.prank(liquidator);
        usdc.approve(address(liq), repayAmount);

        vm.prank(liquidator);
        liq.liquidate(posId, repayAmount, block.timestamp + 1 hours, 0, 0);

        // Position amount should be REDUCED after partial liquidation
        IPositionManager.Position memory posAfter = pm.getPosition(posId);
        assertLt(posAfter.amount, amountBefore, "Position amount must decrease after partial liquidation");
    }

    function test_liquidate_twoPartialLiquidations_amountDecreasesBoth() public {
        uint256 posId = _createLiquidatablePosition();

        // First partial liquidation
        (, uint256 maxRepay1) = liq.isLiquidatable(posId);
        uint256 repay1 = maxRepay1 / 3;
        if (repay1 == 0) repay1 = 1;

        usdc.mint(liquidator, repay1);
        vm.prank(liquidator);
        usdc.approve(address(liq), repay1);
        vm.prank(liquidator);
        liq.liquidate(posId, repay1, block.timestamp + 1 hours, 0, 0);

        uint256 amountAfterFirst = pm.getPosition(posId).amount;
        assertLt(amountAfterFirst, 100e18);

        // Second partial liquidation (position still underwater)
        (, uint256 maxRepay2) = liq.isLiquidatable(posId);
        if (maxRepay2 > 0) {
            uint256 repay2 = maxRepay2 / 3;
            if (repay2 == 0) repay2 = 1;

            usdc.mint(liquidator, repay2);
            vm.prank(liquidator);
            usdc.approve(address(liq), repay2);
            vm.prank(liquidator);
            liq.liquidate(posId, repay2, block.timestamp + 1 hours, 0, 0);

            uint256 amountAfterSecond = pm.getPosition(posId).amount;
            assertLt(amountAfterSecond, amountAfterFirst, "Amount must decrease further on second liquidation");
        }
    }

    // ========== LIQ-1: Remaining LP returned after full liquidation ==========

    function test_liquidate_fullDebt_marksLiquidated() public {
        // Allow 100% liquidation so we can repay full debt in one call
        vm.prank(owner);
        liq.setMaxLiquidationPortion(10_000);

        uint256 posId = _createLiquidatablePosition();
        uint256 totalDebt = le.getDebt(posId);

        usdc.mint(liquidator, totalDebt);
        vm.prank(liquidator);
        usdc.approve(address(liq), totalDebt);

        vm.prank(liquidator);
        liq.liquidate(posId, totalDebt, block.timestamp + 1 hours, 0, 0);

        // Verify debt is fully repaid
        assertEq(le.getDebt(posId), 0);

        // Verify position is marked as liquidated
        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Liquidated));

        // Amount should be reduced (liquidity was unwound)
        assertLt(pos.amount, 100e18, "Amount must decrease after liquidation");
    }

    function test_liquidate_fullDebt_returnsRemainingLP_whenPartialUnwind() public {
        // Scenario: position has $50K collateral, $10K debt, price drops to $12K
        // Debt is small relative to collateral → only partial LP unwind needed
        // After repaying full debt, remaining LP should be returned

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.roll(block.number + 2);

        // Borrow only $10K (small relative to $50K)
        vm.prank(alice);
        le.borrow(posId, 10_000e18);

        // Price drops to $12K → HF = (12000 * 7500) / (10000 * 10000) = 0.9 → liquidatable
        oracle.setPrice(12_000e18);

        // Allow 100% liquidation
        vm.prank(owner);
        liq.setMaxLiquidationPortion(10_000);

        uint256 totalDebt = le.getDebt(posId);
        usdc.mint(liquidator, totalDebt);
        vm.prank(liquidator);
        usdc.approve(address(liq), totalDebt);

        uint256 unlocksBefore = adapter.unlockCallCount();

        vm.prank(liquidator);
        liq.liquidate(posId, totalDebt, block.timestamp + 1 hours, 0, 0);

        assertEq(le.getDebt(posId), 0);

        // Position amount was partially reduced but not to 0
        // (collateralToSeize < positionValue because debt is small vs collateral)
        IPositionManager.Position memory pos = pm.getPosition(posId);

        // If there's remaining LP, unlock should have been called
        if (pos.amount > 0) {
            uint256 unlocksAfter = adapter.unlockCallCount();
            assertEq(unlocksAfter, unlocksBefore + 1, "Remaining LP must be returned");
        }

        // Position should be marked liquidated
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Liquidated));
    }

    function test_liquidate_partialDebt_doesNotReturnLP() public {
        uint256 posId = _createLiquidatablePosition();

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        // Partial — only repay half of maxRepay
        uint256 repayAmount = maxRepay / 2;
        if (repayAmount == 0) repayAmount = 1;

        usdc.mint(liquidator, repayAmount);
        vm.prank(liquidator);
        usdc.approve(address(liq), repayAmount);

        uint256 unlocksBefore = adapter.unlockCallCount();

        vm.prank(liquidator);
        liq.liquidate(posId, repayAmount, block.timestamp + 1 hours, 0, 0);

        // Debt still exists — position should NOT be marked liquidated
        assertGt(le.getDebt(posId), 0);

        // LP should NOT be unlocked (partial liquidation, debt remains)
        uint256 unlocksAfter = adapter.unlockCallCount();
        assertEq(unlocksAfter, unlocksBefore, "LP must NOT be returned during partial liquidation");

        // Position still in Borrowed status
        IPositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Borrowed));
    }

    // ========== Liquidation M-1: over-seize clamp ==========

    /// @dev The seize is sized against the Chainlink fair value (oracle), but unwind hands over
    ///      tokens at the pool's spot composition. When the underlying is worth more at Chainlink
    ///      than the seize target, the surplus must go back to the borrower — not the liquidator.
    ///      Here WETH is moved to $400 while the oracle still values the position at $30k, so a
    ///      partial seize realizes more than repay+bonus. The excess of each token is refunded.
    function test_liquidate_overSeize_refundsExcessToBorrower() public {
        uint256 posId = _createLiquidatablePosition(); // oracle $30k, HF 0.75

        // WETH is really worth $400 at Chainlink — double what the default position assumes.
        vm.prank(owner);
        TestPricing.feedFor(priceRegistry, address(weth)).setAnswer(400e18);

        // Partial seize: repay $10k of the $30k debt. collateralToSeize = 10.5k < positionValue 30k.
        uint256 repayAmount = 10_000e18;
        usdc.mint(liquidator, repayAmount);
        vm.prank(liquidator);
        usdc.approve(address(liq), repayAmount);

        // liquidityToRemove = 100e18 * 10_500 / 30_000 = 35e18 → unwind gives 8.75 WETH + 8_750 USDC.
        // realized @ Chainlink = 8.75*400 + 8_750 = 12_250; target 10_500 → keep 10_500/12_250.
        // keep0 = 8.75 * 10_500/12_250 = 7.5 WETH; refund0 = 1.25 WETH.
        // keep1 = 8_750 * 10_500/12_250 = 7_500 USDC; refund1 = 1_250 USDC.
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 liqWethBefore = weth.balanceOf(liquidator);
        uint256 liqUsdcBefore = usdc.balanceOf(liquidator);

        vm.expectEmit(true, false, false, true, address(liq));
        emit LiquidationOverSeizeRefunded(posId, 1.25e18, 1250e18);

        vm.prank(liquidator);
        liq.liquidate(posId, repayAmount, block.timestamp + 1 hours, 0, 0);

        assertEq(weth.balanceOf(alice) - aliceWethBefore, 1.25e18, "borrower refunded the excess WETH");
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, 1250e18, "borrower refunded the excess USDC");

        // The M-1 invariant: the liquidator cannot pocket more than the Chainlink seize target
        // (repay + bonus). Pre-clamp the unwind produced 8.75 WETH + 8_750 USDC; after the clamp the
        // liquidator's take is the kept 7.5 WETH + 7_500 USDC (minus any protocol fee, never more).
        // Bounding each token catches a double-spend where the borrower is refunded yet the liquidator
        // is still paid the full pre-clamp amount, and bounding their Chainlink value pins the target.
        // token1 is USDC, which is also the borrow asset the liquidator just paid out, so its balance
        // net-decreases; add back the repay to isolate the seized-collateral inflow.
        uint256 liqWeth = weth.balanceOf(liquidator) - liqWethBefore;
        uint256 liqUsdc = usdc.balanceOf(liquidator) + repayAmount - liqUsdcBefore;
        assertLe(liqWeth, 7.5e18, "liquidator WETH take capped at the kept share");
        assertLe(liqUsdc, 7500e18, "liquidator USDC take capped at the kept share");
        // WETH is $400, USDC $1 (both 18-dec here) → value in 18-dec USD.
        assertLe(liqWeth * 400 + liqUsdc, 10_500e18, "liquidator's realized value capped at repay+bonus");
    }

    /// @dev The mirror case: when the pool's spot composition agrees with Chainlink, the clamp is a
    ///      no-op — no refund, no event. WETH stays at its consistent $200, so realized == target.
    function test_liquidate_noOverSeize_whenConsistent_noRefund() public {
        uint256 posId = _createLiquidatablePosition();

        uint256 repayAmount = 10_000e18; // partial
        usdc.mint(liquidator, repayAmount);
        vm.prank(liquidator);
        usdc.approve(address(liq), repayAmount);

        uint256 aliceWethBefore = weth.balanceOf(alice);

        vm.recordLogs();
        vm.prank(liquidator);
        liq.liquidate(posId, repayAmount, block.timestamp + 1 hours, 0, 0);

        assertEq(weth.balanceOf(alice), aliceWethBefore, "no refund when realized equals the target");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            assertTrue(
                entries[i].topics[0] != keccak256("LiquidationOverSeizeRefunded(uint256,uint256,uint256)"),
                "clamp must not fire when pricing is consistent"
            );
        }
    }

    /// @dev The clamp runs on FULL seizes too (Liquidation M-1 correctness gap). Fair LP pricing values
    ///      the position at 2*sqrt(r0*p0 * r1*p1) while unwind realizes r0*p0 + r1*p1; by AM-GM the
    ///      realized value is >= the fair value on an imbalanced pool, so a full seize can over-realize.
    ///      Here WETH is marked to $400 (registry) while a full unwind is 25 WETH + 25,000 USDC = $35k
    ///      realized against a repay+bonus target below that — the excess must be clamped. Because the
    ///      full repay clears the debt (solvent close), the excess is refunded to the borrower, not the
    ///      liquidator. An earlier version wrongly gated the clamp to partial seizes and left this surplus
    ///      with the liquidator.
    function test_liquidate_fullSeize_overSeize_refundsToBorrower() public {
        vm.prank(owner);
        liq.setMaxLiquidationPortion(10_000);

        uint256 posId = _createLiquidatablePosition(); // oracle $30k, HF 0.75 → full seize on full repay

        vm.prank(owner);
        TestPricing.feedFor(priceRegistry, address(weth)).setAnswer(400e18);

        uint256 totalDebt = le.getDebt(posId);
        usdc.mint(liquidator, totalDebt);
        vm.prank(liquidator);
        usdc.approve(address(liq), totalDebt);

        // Full unwind (100 units) → 25 WETH + 25,000 USDC. Realized @ Chainlink = 25*400 + 25_000 = 35_000.
        // Target = repay + 5% bonus (USDC is $1, 18-dec here). realized 35_000 > target → clamp fires.
        // keep = amount * target / realized (mulDiv floor); refund = amount - keep.
        uint256 target = totalDebt + (totalDebt * 500) / 10_000;
        uint256 realizedUsd = 35_000e18;
        assertGt(realizedUsd, target, "full seize over-realizes: clamp must engage");
        uint256 keep0 = (25e18 * target) / realizedUsd;
        uint256 keep1 = (25_000e18 * target) / realizedUsd;
        uint256 expectedRefund0 = 25e18 - keep0;
        uint256 expectedRefund1 = 25_000e18 - keep1;

        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 liqWethBefore = weth.balanceOf(liquidator);
        uint256 liqUsdcBefore = usdc.balanceOf(liquidator);

        vm.expectEmit(true, false, false, true, address(liq));
        emit LiquidationOverSeizeRefunded(posId, expectedRefund0, expectedRefund1);

        vm.prank(liquidator);
        liq.liquidate(posId, totalDebt, block.timestamp + 1 hours, 0, 0);

        // Debt fully cleared → solvent full close → excess refunded to the borrower (not the liquidator).
        assertEq(
            weth.balanceOf(alice) - aliceWethBefore, expectedRefund0, "borrower refunded excess WETH on full seize"
        );
        assertEq(
            usdc.balanceOf(alice) - aliceUsdcBefore, expectedRefund1, "borrower refunded excess USDC on full seize"
        );

        // The liquidator's take is capped at the kept share (minus protocol fee, never more), and its
        // Chainlink value never exceeds the repay+bonus target — the whole point of the clamp.
        uint256 liqWeth = weth.balanceOf(liquidator) - liqWethBefore;
        uint256 liqUsdc = usdc.balanceOf(liquidator) + totalDebt - liqUsdcBefore;
        assertLe(liqWeth, keep0, "liquidator WETH take capped at kept share");
        assertLe(liqUsdc, keep1, "liquidator USDC take capped at kept share");
        assertLe(liqWeth * 400 + liqUsdc, target, "liquidator realized value capped at repay+bonus");
    }

    /// @dev The bad-debt routing (Liquidation M-1). When a full seize both over-realizes AND leaves the
    ///      position underwater (debt not cleared, residual value below dust → writeoff), the excess is
    ///      NOT refunded to the defaulting borrower — it is routed to the protocol/FeeCollector to offset
    ///      the lenders' loss (mirrors the swept-fee bad-debt policy, and Revert Lend / Gearbox: surplus
    ///      to the borrower only when solvent, socialized when underwater). Here the position value is
    ///      pushed below dust while WETH is marked to $400, so a partial repay triggers a full seize that
    ///      over-realizes; the writeoff sends the surplus to the collector, and the borrower gets nothing.
    function test_liquidate_fullSeize_badDebt_refundsToProtocol() public {
        uint256 posId = _createLiquidatablePosition(); // debt $30k

        // Collapse the position value below the dust threshold ($1). getPositionValue stays here through
        // the seize (mock oracle is amount-independent), so after a full unwind remainingValue <= dust
        // → the debt that repay didn't cover is written off as bad debt.
        vm.prank(owner);
        oracle.setPrice(0.5e18);

        vm.prank(owner);
        TestPricing.feedFor(priceRegistry, address(weth)).setAnswer(400e18);

        // Partial repay leaves debt outstanding → not a solvent close. collateralToSeize (5_250) >>
        // positionValue (0.5) → full seize → unwind 25 WETH + 25_000 USDC, realized @ Chainlink 35_000.
        uint256 repayAmount = 5000e18;
        usdc.mint(liquidator, repayAmount);
        vm.prank(liquidator);
        usdc.approve(address(liq), repayAmount);

        uint256 target = repayAmount + (repayAmount * 500) / 10_000; // 5_250
        uint256 realizedUsd = 35_000e18;
        uint256 keep0 = (25e18 * target) / realizedUsd; // 3.75 WETH
        uint256 keep1 = (25_000e18 * target) / realizedUsd; // 3_750 USDC
        uint256 expectedRefund0 = 25e18 - keep0; // 21.25 WETH
        uint256 expectedRefund1 = 25_000e18 - keep1; // 21_250 USDC

        address collector = address(liq.feeCollector());
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 colWethBefore = weth.balanceOf(collector);
        uint256 colUsdcBefore = usdc.balanceOf(collector);

        vm.expectEmit(true, false, false, true, address(liq));
        emit LiquidationOverSeizeRefunded(posId, expectedRefund0, expectedRefund1);

        vm.prank(liquidator);
        liq.liquidate(posId, repayAmount, block.timestamp + 1 hours, 0, 0);

        // The defaulting borrower is paid nothing — the surplus offsets the lenders' loss instead.
        assertEq(weth.balanceOf(alice), aliceWethBefore, "defaulting borrower gets no WETH refund");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore, "defaulting borrower gets no USDC refund");

        // The excess lands in the protocol's FeeCollector (>= refund; the Step 8 protocol fee also routes
        // here, so the delta is at least the refund).
        assertGe(weth.balanceOf(collector) - colWethBefore, expectedRefund0, "over-seize WETH routed to protocol");
        assertGe(usdc.balanceOf(collector) - colUsdcBefore, expectedRefund1, "over-seize USDC routed to protocol");
    }

    /// @dev The clamp values the seized underlying through the same registry as the debt leg, so a
    ///      collateral feed that stops updating must stop the liquidation, not be waved through with a
    ///      stale price. In the mock harness getPositionValue is oracle-driven and never touches the
    ///      registry, so the clamp's _valueUsd is the sole registry read of WETH here — isolating the
    ///      new collateral-side dependency this fix introduces. Fails closed, per protocol rule.
    function test_liquidate_overSeize_staleCollateralFeed_reverts() public {
        uint256 posId = _createLiquidatablePosition(); // oracle $30k, HF 0.75

        uint256 repayAmount = 10_000e18; // partial → reaches the clamp
        usdc.mint(liquidator, repayAmount);
        vm.prank(liquidator);
        usdc.approve(address(liq), repayAmount);

        // Freeze the WETH feed at an early timestamp and move past maxStaleness (1h). getPrice() in
        // _valueUsd(WETH, amount0) must reject it. The borrow (USDC) leg is left live, so the revert
        // can only originate from the clamp's collateral valuation.
        uint256 answeredAt = 1000;
        vm.warp(answeredAt + 2 hours);
        vm.mockCall(
            address(TestPricing.feedFor(priceRegistry, address(weth))),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(400e18), answeredAt, answeredAt, uint80(1))
        );

        vm.prank(liquidator);
        vm.expectRevert("STALE_PRICE");
        liq.liquidate(posId, repayAmount, block.timestamp + 1 hours, 0, 0);

        vm.clearMockedCalls();
    }

    // ========== Token Transfer Coverage ==========

    function test_liquidate_bothTokensSameType() public {
        // Both tokens are WETH — liquidator receives WETH from both sides
        adapter.setTokenReturns(address(weth), address(weth));
        adapter.setUnwindAmounts(25e18, 25e18);

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.prank(alice);
        le.borrow(posId, 30_000e18);
        oracle.setPrice(30_000e18);

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        usdc.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc.approve(address(liq), maxRepay);

        weth.mint(address(adapter), 1_000_000e18);

        uint256 wethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours, 0, 0);

        // Liquidator should have received WETH (token0 + token1)
        uint256 wethAfter = weth.balanceOf(liquidator);
        assertGt(wethAfter, wethBefore, "Liquidator must receive WETH from unwind");
    }

    function test_liquidate_token0IsBorrowAsset() public {
        // token0 = USDC (borrow asset), token1 = WETH
        // Liquidator receives both USDC + WETH from unwind
        adapter.setTokenReturns(address(usdc), address(weth));
        adapter.setUnwindAmounts(25_000e18, 25e18); // 25K USDC + 25 WETH per 100 units

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, borrowAsset);
        vm.roll(block.number + 2);
        vm.prank(alice);
        le.borrow(posId, 30_000e18);
        oracle.setPrice(30_000e18);

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        usdc.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc.approve(address(liq), maxRepay);

        usdc.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);

        uint256 usdcBefore = usdc.balanceOf(liquidator);
        uint256 wethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours, 0, 0);

        // Liquidator receives underlying tokens directly
        uint256 usdcAfter = usdc.balanceOf(liquidator);
        uint256 wethAfter = weth.balanceOf(liquidator);
        // Liquidator spent maxRepay USDC but received USDC + WETH from unwind
        assertGt(wethAfter, wethBefore, "Liquidator must receive WETH from unwind");
        // Liquidator spent maxRepay USDC but received USDC back from unwind.
        // Net USDC depends on pool ratio. Check total value increased.
        assertGt(usdcAfter + wethAfter, 0, "Liquidator must receive tokens from unwind");
    }

    // ========== Fuzz Tests ==========

    function testFuzz_setMaxLiquidationPortion_withinBounds(uint256 value) public {
        value = bound(value, 1000, 10_000);
        vm.prank(owner);
        liq.setMaxLiquidationPortion(value);
        assertEq(liq.maxLiquidationPortion(), value);
    }

    // ========== Liquidator Receives Underlying Tokens ==========

    function test_liquidate_liquidatorReceivesToken0AndToken1() public {
        uint256 posId = _createLiquidatablePosition();

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        uint256 repayAmount = maxRepay > 1 ? maxRepay : 1;

        usdc.mint(liquidator, repayAmount);
        vm.prank(liquidator);
        usdc.approve(address(liq), repayAmount);

        uint256 wethBefore = weth.balanceOf(liquidator);
        uint256 usdcBefore = usdc.balanceOf(liquidator);

        vm.prank(liquidator);
        liq.liquidate(posId, repayAmount, block.timestamp + 1 hours, 0, 0);

        uint256 wethAfter = weth.balanceOf(liquidator);
        uint256 usdcAfter = usdc.balanceOf(liquidator);

        // Liquidator should receive WETH (token0) from the unwind
        assertGt(wethAfter, wethBefore, "Liquidator must receive token0 (WETH)");
        // Liquidator spent repayAmount USDC but also receives USDC (token1) from unwind
        // Net USDC change = received USDC from unwind - spent repayAmount
        // At least one of the underlying tokens should be received
        assertTrue(wethAfter > wethBefore || usdcAfter > usdcBefore, "Liquidator must receive underlying tokens");
    }

    function test_liquidate_profitIsZero() public {
        uint256 posId = _createLiquidatablePosition();

        (, uint256 maxRepay) = liq.isLiquidatable(posId);

        usdc.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc.approve(address(liq), maxRepay);

        vm.prank(liquidator);
        uint256 profit = liq.liquidate(posId, maxRepay, block.timestamp + 1 hours, 0, 0);

        // Profit is always 0 since liquidator receives raw tokens (not borrow asset)
        assertEq(profit, 0, "Profit must be 0 in no-swap design");
    }

    // ========== Non-blocking fee/refund settlement ==========

    event ProtocolFeeDeferred(address indexed token, uint256 amount, string feeType);
    event ProtocolFeeFlushed(address indexed token, uint256 amount);
    event WithdrawalDeferred(address indexed account, address indexed token, uint256 amount);
    event WithdrawalClaimed(address indexed account, address indexed token, uint256 amount);

    /// @dev The canonical vector is a token that blocklists the FeeCollector so the protocol-fee
    ///      pull reverts (USDC/USDT-style). That must NOT brick the liquidation: the fee is escrowed in
    ///      the engine and the debt is still repaid. We force ONLY the WETH engine→collector transferFrom
    ///      to revert, so the WETH fee leg defers while everything else settles normally.
    function test_liquidate_protocolFeeEscrowed_whenCollectorPushReverts() public {
        uint256 posId = _createLiquidatablePosition();
        (, uint256 maxRepay) = liq.isLiquidatable(posId);

        usdc.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc.approve(address(liq), maxRepay);

        address collector = address(liq.feeCollector());
        // Prefix match: any WETH.transferFrom(engine -> collector, *) reverts. This is exactly the
        // collectFee pull inside Step 8; the repay pull (USDC, from the liquidator) is unaffected.
        vm.mockCallRevert(
            address(weth),
            abi.encodeWithSelector(weth.transferFrom.selector, address(liq), collector),
            abi.encode("BLOCKLISTED")
        );

        uint256 debtBefore = le.getDebt(posId);
        uint256 collectorWethBefore = weth.balanceOf(collector);

        vm.prank(liquidator);
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours, 0, 0);

        vm.clearMockedCalls();

        // Liquidation still cleared debt despite the fee push failing.
        assertLt(le.getDebt(posId), debtBefore, "debt must still be repaid when the fee push reverts");
        // The WETH fee was escrowed in the engine, not silently dropped and not sent to the collector.
        uint256 escrowed = liq.pendingProtocolFees(address(weth));
        assertGt(escrowed, 0, "WETH fee must be escrowed");
        assertEq(weth.balanceOf(collector), collectorWethBefore, "collector received no WETH while blocklisted");
        assertGe(weth.balanceOf(address(liq)), escrowed, "engine holds the escrowed WETH");

        // Once the collector accepts WETH again, anyone can flush the escrow to it.
        vm.expectEmit(true, false, false, true, address(liq));
        emit ProtocolFeeFlushed(address(weth), escrowed);
        liq.flushProtocolFees(address(weth));

        assertEq(liq.pendingProtocolFees(address(weth)), 0, "escrow cleared after flush");
        assertEq(weth.balanceOf(collector) - collectorWethBefore, escrowed, "flush delivered the fee to the collector");
    }

    function test_flushProtocolFees_revertsWhenNothingPending() public {
        vm.expectRevert("NO_PENDING_FEES");
        liq.flushProtocolFees(address(weth));
    }

    /// @dev A borrower on a token blocklist must not be able to brick their own liquidation. The
    ///      over-seize refund to the borrower falls back to pull-payment when the direct transfer fails.
    ///      Reuses the solvent over-seize scenario (WETH marked to $400) and blocks only WETH→alice, so
    ///      the WETH refund is escrowed for claim while the USDC refund still lands directly.
    function test_liquidate_borrowerRefundEscrowed_whenTransferFails() public {
        uint256 posId = _createLiquidatablePosition();

        vm.prank(owner);
        TestPricing.feedFor(priceRegistry, address(weth)).setAnswer(400e18);

        uint256 repayAmount = 10_000e18;
        usdc.mint(liquidator, repayAmount);
        vm.prank(liquidator);
        usdc.approve(address(liq), repayAmount);

        // Same arithmetic as test_liquidate_overSeize_refundsExcessToBorrower: refund0 = 1.25 WETH.
        // Block ONLY the WETH payout to alice; the 1_250 USDC refund still transfers directly.
        vm.mockCallRevert(
            address(weth), abi.encodeWithSelector(weth.transfer.selector, alice), abi.encode("BLOCKLISTED")
        );

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);

        vm.expectEmit(true, true, false, true, address(liq));
        emit WithdrawalDeferred(alice, address(weth), 1.25e18);

        vm.prank(liquidator);
        liq.liquidate(posId, repayAmount, block.timestamp + 1 hours, 0, 0);

        vm.clearMockedCalls();

        // WETH refund escrowed (alice untouched), USDC refund delivered directly.
        assertEq(weth.balanceOf(alice), aliceWethBefore, "blocklisted borrower received no WETH directly");
        assertEq(liq.pendingWithdrawals(alice, address(weth)), 1.25e18, "WETH refund escrowed for claim");
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, 1250e18, "USDC refund still delivered directly");

        // Borrower pulls the escrowed WETH once they can receive it again.
        vm.expectEmit(true, true, false, true, address(liq));
        emit WithdrawalClaimed(alice, address(weth), 1.25e18);
        vm.prank(alice);
        liq.claim(address(weth));

        assertEq(weth.balanceOf(alice) - aliceWethBefore, 1.25e18, "borrower claimed the escrowed WETH");
        assertEq(liq.pendingWithdrawals(alice, address(weth)), 0, "escrow cleared after claim");
    }

    function test_claim_revertsWhenNothingPending() public {
        vm.prank(alice);
        vm.expectRevert("NO_PENDING_WITHDRAWAL");
        liq.claim(address(weth));
    }

    /// @dev rescueTokens must never dip into balances backing a deferred settlement, otherwise a
    ///      well-meaning admin sweep would strand a borrower's claim() or a pending fee flush. We
    ///      escrow a WETH fee (collector blocklisted), then assert only the stray surplus is rescuable
    ///      and the escrowed portion survives to be flushed.
    function test_rescueTokens_cannotDrainEscrow() public {
        uint256 posId = _createLiquidatablePosition();
        (, uint256 maxRepay) = liq.isLiquidatable(posId);

        usdc.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc.approve(address(liq), maxRepay);

        address collector = address(liq.feeCollector());
        vm.mockCallRevert(
            address(weth),
            abi.encodeWithSelector(weth.transferFrom.selector, address(liq), collector),
            abi.encode("BLOCKLISTED")
        );
        vm.prank(liquidator);
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours, 0, 0);
        vm.clearMockedCalls();

        uint256 escrowed = liq.pendingProtocolFees(address(weth));
        assertGt(escrowed, 0, "WETH fee must be escrowed");
        assertEq(liq.escrowedBalance(address(weth)), escrowed, "escrowedBalance tracks the deferred fee");

        // Add a genuinely stray surplus on top of the escrowed balance.
        uint256 stray = 3e18;
        weth.mint(address(liq), stray);
        address recipient = makeAddr("rescueRecipient");

        // Rescuing more than the stray surplus (i.e. dipping into escrow) fails closed.
        vm.prank(owner);
        vm.expectRevert("EXCEEDS_RESCUABLE");
        liq.rescueTokens(address(weth), recipient, stray + 1);

        // Rescuing exactly the stray surplus succeeds and leaves the escrow intact.
        vm.prank(owner);
        liq.rescueTokens(address(weth), recipient, stray);
        assertEq(weth.balanceOf(recipient), stray, "only the stray surplus is rescued");
        assertGe(weth.balanceOf(address(liq)), escrowed, "engine still holds the escrowed WETH");

        // The escrow is still fully flushable to the collector.
        liq.flushProtocolFees(address(weth));
        assertEq(liq.pendingProtocolFees(address(weth)), 0, "escrow cleared after flush");
        assertEq(liq.escrowedBalance(address(weth)), 0, "escrowedBalance cleared after flush");
    }
}
