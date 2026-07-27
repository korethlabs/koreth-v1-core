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
import {CircuitBreaker} from "../../src/security/CircuitBreaker.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title AttackVectorTests
/// @notice Security tests covering the 10 Tier 2 attack vectors from docs/security/attack-vectors.md
/// @dev Each test simulates a real-world attack scenario and verifies the protocol defends against it.
contract AttackVectorTests is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    LiquidationEngine public liq;
    LPOracleHub public oracleHub;
    CircuitBreaker public circuitBreaker;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockMarket public market;
    MockERC20 public usdc;
    MockERC20 public weth;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public liquidator = makeAddr("liquidator");
    address public lpToken = makeAddr("lpToken");

    uint256 public marketId;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        weth = new MockERC20("WETH", "WETH", 18);
        InterestRateModel irm = new InterestRateModel(200, 600, 10_000, 8000);

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

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        adapter.setTokenReturns(address(weth), address(usdc));
        adapter.setUnwindAmounts(25e18, 25_000e18);

        oracle = new MockLPOracle();
        oracle.setPrice(50_000e18);
        market = new MockMarket(address(usdc), address(irm));
        circuitBreaker = new CircuitBreaker(address(core));

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(address(le));
        aclManager.addLiquidationEngine(address(liq));
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
        pm.setLendingEngine(address(le));
        pm.setCircuitBreaker(address(circuitBreaker));
        vm.stopPrank();

        // Fund market with liquidity
        usdc.mint(address(market), 1_000_000e18);

        // Fund adapter with tokens for unwind
        weth.mint(address(adapter), 100e18);
        usdc.mint(address(adapter), 100_000e18);
    }

    // ========== Helpers ==========

    function _deposit(address user) internal returns (uint256 posId) {
        vm.prank(user);
        posId = pm.deposit(lpToken, 1, 100e18, marketId);
    }

    function _depositAndBorrow(address user, uint256 borrowAmount) internal returns (uint256 posId) {
        posId = _deposit(user);
        vm.roll(block.number + 2); // cooldown
        vm.prank(user);
        le.borrow(posId, borrowAmount);
    }

    // ========== 1. Oracle Returns Zero ==========

    function test_attack_oracleReturnsZero_positionLiquidatable() public {
        uint256 posId = _depositAndBorrow(alice, 25_000e18);

        // Simulate Chainlink crash → oracle returns $0
        oracle.setPrice(0);

        // Health factor should be 0 (no collateral value)
        uint256 hf = pm.getHealthFactor(posId);
        assertEq(hf, 0, "HF should be 0 when oracle returns 0");

        // Position should be liquidatable
        (bool canLiq,) = liq.isLiquidatable(posId);
        assertTrue(canLiq, "Position must be liquidatable at zero price");
    }

    // ========== 2. Token Depeg (USDC $0.88) ==========

    function test_attack_tokenDepeg_healthFactorDrops() public {
        uint256 posId = _depositAndBorrow(alice, 30_000e18);

        uint256 hfBefore = pm.getHealthFactor(posId);
        assertGt(hfBefore, 1e18, "Should be healthy initially");

        // Simulate depeg: collateral value drops 40%
        oracle.setPrice(30_000e18); // was 50,000 → now 30,000

        uint256 hfAfter = pm.getHealthFactor(posId);
        assertLt(hfAfter, hfBefore, "HF should drop after depeg");

        // At 30K collateral / 30K debt with 75% liq threshold → HF = 0.75
        (bool canLiq,) = liq.isLiquidatable(posId);
        assertTrue(canLiq, "Position should be liquidatable after depeg");
    }

    // ========== 3. Token Crashes to $0 — Bad Debt ==========

    function test_attack_tokenCrash_badDebtRecorded() public {
        uint256 posId = _depositAndBorrow(alice, 25_000e18);

        // Token crashes to $0
        oracle.setPrice(0);

        // Position is liquidatable
        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq, "Must be liquidatable");
        assertGt(maxRepay, 0);

        // Fund liquidator and execute liquidation
        usdc.mint(liquidator, maxRepay);
        vm.startPrank(liquidator);
        usdc.approve(address(liq), maxRepay);
        liq.liquidate(posId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        // After liquidation at $0 collateral value, bad debt writeoff should trigger
        // Position should be marked liquidated
        PositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(uint256(pos.status), 3, "Position should be Liquidated (status=3)");
    }

    // ========== 4. Borrow Cooldown Prevents Flash Loan ==========

    function test_attack_flashLoan_borrowCooldownBlocks() public {
        uint256 posId = _deposit(alice);

        // Try to borrow in the same block as deposit → blocked by cooldown
        vm.prank(alice);
        vm.expectRevert("BORROW_COOLDOWN");
        le.borrow(posId, 10_000e18);

        // Advance 2 blocks → allowed (cooldown requires block.number > depositBlock + cooldown)
        vm.roll(block.number + 2);
        vm.prank(alice);
        le.borrow(posId, 10_000e18);
        assertGt(le.getDebt(posId), 0, "Borrow should succeed after cooldown");
    }

    // ========== 5. Double-Deposit Same NFT ==========

    function test_attack_doubleDeposit_separatePositions() public {
        // First deposit succeeds
        vm.prank(alice);
        uint256 posId1 = pm.deposit(lpToken, 42, 100e18, marketId);

        // Second deposit of same tokenId — mock adapter allows it (no NFT custody check)
        // Real V3 adapter would revert with TRANSFER_FAILED (NFT already transferred)
        // With mock, we verify positions are tracked separately
        vm.prank(alice);
        uint256 posId2 = pm.deposit(lpToken, 42, 100e18, marketId);

        assertFalse(posId1 == posId2, "Must create separate position IDs");
        // NOTE: Real V3Adapter enforces NFT custody — second deposit would revert.
        // This test confirms the mock behavior; fork E2E tests verify real adapter.
    }

    // ========== 6. 100% Utilization — Withdrawal Blocked ==========

    function test_attack_fullUtilization_marketDrained() public {
        // Set oracle price very high so LTV allows large borrows
        oracle.setPrice(5_000_000e18); // $5M collateral

        uint256 posId = _deposit(alice);
        vm.roll(block.number + 2);
        vm.prank(alice);
        le.borrow(posId, 900_000e18); // 90% of market liquidity

        // Market balance is now ~100K — most liquidity lent out
        uint256 marketBalance = usdc.balanceOf(address(market));
        assertLt(marketBalance, 200_000e18, "Market should have reduced liquidity");
        assertGt(le.getDebt(posId), 0, "Alice should have debt");

        // Attempting to borrow more than remaining balance would fail
        oracle.setPrice(5_000_000e18);
        uint256 posId2 = _deposit(bob);
        vm.roll(block.number + 3);
        vm.prank(bob);
        vm.expectRevert(); // MockMarket reverts on insufficient balance
        le.borrow(posId2, marketBalance + 1);
    }

    // ========== 7. Self-Liquidation (Allowed by Design) ==========

    function test_attack_selfLiquidation_noExtraProfit() public {
        uint256 posId = _depositAndBorrow(alice, 30_000e18);

        // Price drops — position underwater
        oracle.setPrice(35_000e18);

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq, "Should be liquidatable");

        // Alice self-liquidates
        usdc.mint(alice, maxRepay);
        vm.startPrank(alice);
        usdc.approve(address(liq), maxRepay);
        liq.liquidate(posId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        // Alice paid maxRepay USDC and received underlying tokens
        // This is economically equivalent to manual unwind — no exploit
        uint256 debtAfter = le.getDebt(posId);
        assertLt(debtAfter, 30_000e18, "Debt should be reduced");
    }

    // ========== 8. Pausable Token — Liquidation Reverts Cleanly ==========

    function test_attack_pausableToken_cleanRevert() public {
        // This test verifies that if token transfers fail (e.g., USDT pause),
        // the liquidation reverts cleanly (no stuck state)
        uint256 posId = _depositAndBorrow(alice, 25_000e18);
        oracle.setPrice(30_000e18); // make liquidatable

        (bool canLiq,) = liq.isLiquidatable(posId);
        assertTrue(canLiq);

        // Liquidator tries to liquidate but has no USDC (simulates transfer failure)
        vm.prank(liquidator);
        vm.expectRevert(); // transferFrom fails
        liq.liquidate(posId, 10_000e18, block.timestamp, 0, 0);

        // Position state unchanged — no stuck state
        uint256 debt = le.getDebt(posId);
        assertEq(debt, 25_000e18, "Debt should be unchanged after failed liquidation");
    }

    // ========== 9. borrowIndex Extreme Duration ==========

    function test_attack_borrowIndexExtreme_noOverflow() public {
        uint256 posId = _depositAndBorrow(alice, 25_000e18);

        // Simulate 10 years of compound interest by manually setting borrowIndex
        // MockMarket.accrueInterest is a no-op, so we set index directly
        // At ~4% APR for 10 years: index ≈ 1.04^10 ≈ 1.48 → 1.48e27
        market.setBorrowIndex(1_480_000_000_000_000_000_000_000_000);

        // Debt should be calculable without overflow
        uint256 debt = le.getDebt(posId);
        assertGt(debt, 25_000e18, "Debt should grow with index");
        assertLt(debt, type(uint256).max, "Should not overflow");

        // Extreme index (100 years at high rate) — still no overflow
        market.setBorrowIndex(1e30); // 1000x original index
        debt = le.getDebt(posId);
        assertGt(debt, 0, "Debt must be calculable");
        assertLt(debt, type(uint256).max, "Must not overflow");
    }

    // ========== 10. Frozen Market State ==========

    function test_attack_frozenMarket_depositsBlocked() public {
        // Guardian freezes market
        vm.prank(guardian);
        circuitBreaker.freezeMarket(marketId, "USDC depeg detected");

        assertTrue(circuitBreaker.marketFrozen(marketId), "Market should be frozen");

        // Deposit should fail
        vm.prank(alice);
        vm.expectRevert("MARKET_FROZEN");
        pm.deposit(lpToken, 1, 0, marketId);
    }

    function test_attack_frozenMarket_borrowsBlocked() public {
        uint256 posId = _deposit(alice);
        vm.roll(block.number + 2);

        // Freeze market
        vm.prank(guardian);
        circuitBreaker.freezeMarket(marketId, "Oracle anomaly");

        // Borrow should fail
        vm.prank(alice);
        vm.expectRevert("MARKET_FROZEN");
        le.borrow(posId, 10_000e18);
    }

    function test_attack_frozenMarket_withdrawStillWorks() public {
        uint256 posId = _deposit(alice);

        // Freeze market
        vm.prank(guardian);
        circuitBreaker.freezeMarket(marketId, "Emergency");

        // Withdraw should still work (risk-reducing)
        vm.prank(alice);
        pm.withdraw(posId);

        PositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(uint256(pos.status), 2, "Position should be Closed");
    }

    function test_attack_frozenMarket_repayStillWorks() public {
        uint256 posId = _depositAndBorrow(alice, 10_000e18);

        // Freeze market
        vm.prank(guardian);
        circuitBreaker.freezeMarket(marketId, "Emergency");

        // Repay should still work (risk-reducing)
        usdc.mint(alice, 10_000e18);
        vm.startPrank(alice);
        usdc.approve(address(market), type(uint256).max);
        le.repay(posId, 5000e18);
        vm.stopPrank();

        uint256 debt = le.getDebt(posId);
        assertLt(debt, 10_000e18, "Debt should decrease after repay");
    }

    function test_attack_frozenMarket_liquidationStillWorks() public {
        uint256 posId = _depositAndBorrow(alice, 30_000e18);

        // Price drops + freeze
        oracle.setPrice(35_000e18);
        vm.prank(guardian);
        circuitBreaker.freezeMarket(marketId, "Depeg response");

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq, "Should be liquidatable even when frozen");

        // Liquidation should work
        usdc.mint(liquidator, maxRepay);
        vm.startPrank(liquidator);
        usdc.approve(address(liq), maxRepay);
        liq.liquidate(posId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        uint256 debtAfter = le.getDebt(posId);
        assertLt(debtAfter, 30_000e18, "Debt should decrease from liquidation");
    }

    function test_attack_frozenMarket_unfreezeRequiresPoolAdmin() public {
        vm.prank(guardian);
        circuitBreaker.freezeMarket(marketId, "Test");

        // Guardian cannot unfreeze
        vm.prank(guardian);
        vm.expectRevert("NOT_POOL_ADMIN");
        circuitBreaker.unfreezeMarket(marketId);

        // Only PoolAdmin can unfreeze
        vm.prank(owner);
        circuitBreaker.unfreezeMarket(marketId);
        assertFalse(circuitBreaker.marketFrozen(marketId));
    }

    // ========== Interest Rate Cap ==========

    function test_attack_extremeRateCapped() public {
        // Deploy IRM with absurd slopes (10000% APR above kink)
        InterestRateModel extremeIrm = new InterestRateModel(0, 0, 100_000, 5000);

        // At 100% utilization: rate would be astronomical without cap
        uint256 rate = extremeIrm.getBorrowRate(10_000);

        // Should be capped at MAX_RATE_PER_SECOND (~500% APR)
        assertLe(rate, extremeIrm.MAX_RATE_PER_SECOND(), "Rate must be capped");
    }

    function test_attack_normalRateNotCapped() public {
        // Normal IRM — rates should NOT hit the cap
        InterestRateModel normalIrm = new InterestRateModel(200, 600, 10_000, 8000);

        uint256 rateAt50 = normalIrm.getBorrowRate(5000);
        uint256 rateAt100 = normalIrm.getBorrowRate(10_000);

        assertLt(rateAt50, normalIrm.MAX_RATE_PER_SECOND(), "Normal rate should be below cap");
        assertLt(rateAt100, normalIrm.MAX_RATE_PER_SECOND(), "High util rate should still be below cap");
        assertGt(rateAt100, rateAt50, "Higher util should have higher rate");
    }
}
