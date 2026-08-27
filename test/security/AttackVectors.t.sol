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
import {MockLendingPool} from "../mocks/MockLendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {RiskConfig} from "../helpers/RiskConfig.sol";
import {TestPricing} from "../helpers/TestPricing.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {TestPools} from "../helpers/TestPools.sol";
import {TestSecurity} from "../helpers/TestSecurity.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @notice Stands in for an attacker-deployed contract named as the protocol-fee recipient.
/// @dev Shares FeeCollector's collectFee signature, because that is what PositionManager calls on
///      whatever address the parameter names. It pulls the approval it was just granted, which is
///      the whole point: naming this address turns a compound into an approve plus an external call
///      made by PositionManager to a target the caller picked.
contract FeeSiphon {
    uint256 public callCount;

    function collectFee(address token, uint256 amount, address from, string calldata) external {
        callCount++;
        // Checked, like the real FeeCollector's SafeERC20 pull. A transferFrom that returned false
        // instead of reverting would leave this call looking successful while moving nothing, so the
        // balances the test logs would understate the drain rather than measure it.
        require(IERC20(token).transferFrom(from, address(this), amount), "TRANSFER_FROM_FAILED");
    }
}

/// @notice Shaped like the periphery CompoundSwapRouter: compounds a position and takes the dust
///         itself so it can swap it before returning the proceeds to the owner.
/// @dev Deliberately without CompoundSwapRouter's `msg.sender == positionManager` guard, so the same
///      contract can also be pointed at a position outside a transform — which is what proves the
///      transformer branch is scoped to a live transform rather than to the contract's role.
contract CompoundingTransformer {
    PositionManager public immutable pm;

    constructor(address _pm) {
        pm = PositionManager(_pm);
    }

    function compound(uint256 positionId, address feeCollector, address rewardRecipient) external {
        pm.compoundFees(
            IPositionManager.CompoundFeesParams({
                positionId: positionId,
                protocolFeeRecipient: feeCollector,
                protocolFeeBps: 200,
                callerRewardRecipient: rewardRecipient,
                callerRewardBps: 50,
                minFeeThreshold: 0,
                dustRefundTo: address(this), // dust lands here so it can be swapped
                maxSlippageBps: 0
            })
        );
    }
}

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
    MockLendingPool public market;
    RiskManager public riskManager;
    FeeCollector public feeCollector;
    MockERC20 public usdc;
    MockERC20 public weth;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public liquidator = makeAddr("liquidator");
    address public lpToken = makeAddr("lpToken");

    address public borrowAsset;

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
        market = new MockLendingPool(address(usdc), address(irm));
        borrowAsset = address(usdc);
        circuitBreaker = new CircuitBreaker(address(core));
        riskManager = new RiskManager(address(core));

        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(address(le));
        aclManager.addLiquidationEngine(address(liq));
        aclManager.addPositionManager(address(pm));
        aclManager.addRiskAdmin(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistLpPool(TestPools.asContract(lpToken), ILPAdapter.LPType.UniswapV3);
        // Price token0 (WETH) too: the over-seize clamp re-values the seized underlying at
        // Chainlink, so any nonzero WETH seize needs a WETH feed. These attack tests assert debt
        // reduction / status, not exact balances, so the exact price only needs to be a live feed.
        PriceFeedRegistry priceRegistry = TestPricing.wireStable(core, address(usdc));
        TestPricing.priceAsset(priceRegistry, address(weth), 200e18);
        core.registerLendingPool(address(usdc), address(market));
        core.setRiskManager(address(riskManager));
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.defaultConfig());
        pm.setLendingEngine(address(le));
        pm.setCircuitBreaker(address(circuitBreaker));
        feeCollector = TestSecurity.wireFeeCollector(core, liq, makeAddr("treasury"));
        // compoundFees pins the protocol-fee leg to this address, mirroring the deploy script.
        pm.setFeeCollector(address(feeCollector));
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
        posId = pm.deposit(lpToken, 1, 100e18, borrowAsset);
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
        uint256 posId1 = pm.deposit(lpToken, 42, 100e18, borrowAsset);

        // Second deposit of same tokenId — mock adapter allows it (no NFT custody check)
        // Real V3 adapter would revert with TRANSFER_FAILED (NFT already transferred)
        // With mock, we verify positions are tracked separately
        vm.prank(alice);
        uint256 posId2 = pm.deposit(lpToken, 42, 100e18, borrowAsset);

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

    // ========== 10. Frozen Collateral State ==========

    function test_attack_frozenMarket_depositsBlocked() public {
        // Guardian freezes market
        vm.prank(guardian);
        circuitBreaker.freezeCollateral(ILPAdapter.LPType.UniswapV3, "USDC depeg detected");

        assertTrue(circuitBreaker.collateralFrozen(ILPAdapter.LPType.UniswapV3), "Market should be frozen");

        // Deposit should fail
        vm.prank(alice);
        vm.expectRevert("COLLATERAL_FROZEN");
        pm.deposit(lpToken, 1, 0, borrowAsset);
    }

    function test_attack_frozenMarket_borrowsBlocked() public {
        uint256 posId = _deposit(alice);
        vm.roll(block.number + 2);

        // Freeze market
        vm.prank(guardian);
        circuitBreaker.freezeCollateral(ILPAdapter.LPType.UniswapV3, "Oracle anomaly");

        // Borrow should fail
        vm.prank(alice);
        vm.expectRevert("COLLATERAL_FROZEN");
        le.borrow(posId, 10_000e18);
    }

    function test_attack_frozenMarket_withdrawStillWorks() public {
        uint256 posId = _deposit(alice);

        // Freeze market
        vm.prank(guardian);
        circuitBreaker.freezeCollateral(ILPAdapter.LPType.UniswapV3, "Emergency");

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
        circuitBreaker.freezeCollateral(ILPAdapter.LPType.UniswapV3, "Emergency");

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
        circuitBreaker.freezeCollateral(ILPAdapter.LPType.UniswapV3, "Depeg response");

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
        circuitBreaker.freezeCollateral(ILPAdapter.LPType.UniswapV3, "Test");

        // Guardian cannot unfreeze
        vm.prank(guardian);
        vm.expectRevert("NOT_POOL_ADMIN");
        circuitBreaker.unfreezeCollateral(ILPAdapter.LPType.UniswapV3);

        // Only PoolAdmin can unfreeze
        vm.prank(owner);
        circuitBreaker.unfreezeCollateral(ILPAdapter.LPType.UniswapV3);
        assertFalse(circuitBreaker.collateralFrozen(ILPAdapter.LPType.UniswapV3));
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

    // ========== compoundFees: value destinations named by the caller ==========
    //
    // compoundFees takes its whole parameter struct from the caller. Three fields name a place value
    // goes, and they are not the same kind of thing:
    //   - callerRewardRecipient is the caller's own compensation, bounded by MAX_COMPOUND_FEE_BPS —
    //     the caller is meant to choose it, and these tests check it still can;
    //   - protocolFeeRecipient is protocol revenue, and PositionManager approves and calls it;
    //   - dustRefundTo receives whatever of the position's own share could not be redeposited, which
    //     is bounded by nothing at all when the pool ratio is skewed.

    uint256 internal constant COMPOUND_FEE0 = 10e18; // WETH fees collected
    uint256 internal constant COMPOUND_FEE1 = 10_000e18; // USDC fees collected
    uint256 internal constant PROTOCOL_FEE_BPS = 200;
    uint256 internal constant CALLER_REWARD_BPS = 50;
    uint256 internal constant ABSORBED_BPS = 1000; // position takes 10% — the rest is dust

    /// @dev Arm the adapter so a compound collects real fees and leaves most of the reinvestment
    ///      unplaceable, the way an out-of-range V3 position does.
    function _armCompound() internal {
        adapter.setMockFees(COMPOUND_FEE0, COMPOUND_FEE1);
        adapter.setAddLiquidityUsedBps(ABSORBED_BPS);
    }

    function _reinvested(uint256 fees) internal pure returns (uint256) {
        return fees - (fees * PROTOCOL_FEE_BPS) / 10_000 - (fees * CALLER_REWARD_BPS) / 10_000;
    }

    function _expectedDust(uint256 fees) internal pure returns (uint256) {
        uint256 reinvest = _reinvested(fees);
        return reinvest - (reinvest * ABSORBED_BPS) / 10_000;
    }

    function _compoundParams(
        uint256 positionId,
        address protocolFeeRecipient,
        address callerRewardRecipient,
        address dustRefundTo
    )
        internal
        pure
        returns (IPositionManager.CompoundFeesParams memory)
    {
        return IPositionManager.CompoundFeesParams({
            positionId: positionId,
            protocolFeeRecipient: protocolFeeRecipient,
            protocolFeeBps: PROTOCOL_FEE_BPS,
            callerRewardRecipient: callerRewardRecipient,
            callerRewardBps: CALLER_REWARD_BPS,
            minFeeThreshold: 0,
            dustRefundTo: dustRefundTo,
            // Zero disables the reinvestment slippage guard entirely, so nothing downstream limits
            // how little of the reinvestment has to be placed.
            maxSlippageBps: 0
        });
    }

    /// @dev Decode an `Error(string)` revert payload. Returndata that is not one — an empty revert, a
    ///      Panic, a custom error, or the return values of a call that unexpectedly succeeded — is
    ///      reported as a marker instead of being decoded anyway, so a test that fails for a reason
    ///      other than the expected require says which reason rather than showing a decoded-garbage
    ///      string or reverting inside this helper.
    function _revertReason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "<no Error(string) payload>";
        if (bytes4(bytes.concat(ret[0], ret[1], ret[2], ret[3])) != bytes4(keccak256("Error(string)"))) {
            return "<not an Error(string) revert>";
        }
        bytes memory trimmed = new bytes(ret.length - 4);
        for (uint256 i = 0; i < trimmed.length; i++) {
            trimmed[i] = ret[i + 4];
        }
        return abi.decode(trimmed, (string));
    }

    function _makeKeeper(string memory name) internal returns (address keeper) {
        keeper = makeAddr(name);
        vm.prank(owner);
        aclManager.addKeeper(keeper);
    }

    /// @notice A keeper cannot name itself as the dust recipient of somebody else's position.
    /// @dev The fee legs are capped at MAX_COMPOUND_FEE_BPS, but dust is the remainder of the
    ///      position's own share after those legs are paid. Whenever the pool ratio leaves most of
    ///      the reinvestment unplaceable, that remainder dwarfs the bounded reward — which is the
    ///      whole gap this closes.
    function test_attack_compoundFees_keeperCannotRedirectDustToItself() public {
        uint256 posId = _deposit(alice);
        address attacker = _makeKeeper("dustKeeper");
        _armCompound();

        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(pm)
            .call(
                abi.encodeCall(
                    PositionManager.compoundFees, (_compoundParams(posId, address(feeCollector), attacker, attacker))
                )
            );

        console.log("compound accepted:              ", ok);
        console.log("attacker WETH taken as dust:    ", weth.balanceOf(attacker));
        console.log("attacker USDC taken as dust:    ", usdc.balanceOf(attacker));
        console.log("bounded caller reward, WETH:    ", (COMPOUND_FEE0 * CALLER_REWARD_BPS) / 10_000);
        console.log("bounded caller reward, USDC:    ", (COMPOUND_FEE1 * CALLER_REWARD_BPS) / 10_000);
        console.log("dust reachable this way, WETH:  ", _expectedDust(COMPOUND_FEE0));
        console.log("dust reachable this way, USDC:  ", _expectedDust(COMPOUND_FEE1));

        assertFalse(ok, "dust may not be sent outside the position");
        assertEq(_revertReason(ret), "INVALID_DUST_RECIPIENT", "wrong revert reason");
        assertEq(weth.balanceOf(attacker), 0, "attacker must receive no token0");
        assertEq(usdc.balanceOf(attacker), 0, "attacker must receive no token1");
    }

    /// @notice A keeper cannot point the protocol-fee leg at a contract of its own.
    /// @dev That leg is protocol revenue by definition, and paying it means PositionManager approves
    ///      the named address and then calls it — an approve and an external call to a caller-chosen
    ///      target. The caller's compensation is the reward leg, not this one.
    function test_attack_compoundFees_keeperCannotNameArbitraryFeeRecipient() public {
        uint256 posId = _deposit(alice);
        address attacker = _makeKeeper("feeKeeper");
        FeeSiphon siphon = new FeeSiphon();
        _armCompound();

        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(pm)
            .call(
                abi.encodeCall(PositionManager.compoundFees, (_compoundParams(posId, address(siphon), attacker, alice)))
            );

        console.log("compound accepted:              ", ok);
        console.log("calls made into the siphon:     ", siphon.callCount());
        console.log("siphon WETH balance:            ", weth.balanceOf(address(siphon)));
        console.log("siphon USDC balance:            ", usdc.balanceOf(address(siphon)));

        assertFalse(ok, "protocol fee may only go to the configured collector");
        assertEq(_revertReason(ret), "INVALID_FEE_RECIPIENT", "wrong revert reason");
        assertEq(siphon.callCount(), 0, "PositionManager must not call a caller-chosen contract");
        assertEq(weth.balanceOf(address(siphon)), 0, "siphon must receive no token0");
        assertEq(usdc.balanceOf(address(siphon)), 0, "siphon must receive no token1");
        assertEq(weth.allowance(address(pm), address(siphon)), 0, "no approval to a caller-chosen target");
    }

    /// @notice The honest keeper path is unaffected: dust to the owner, reward to the keeper's own
    ///         address, protocol fee to the configured collector.
    function test_compoundFees_ownerDustPath_stillWorks() public {
        uint256 posId = _deposit(alice);
        address keeper = _makeKeeper("honestKeeper");
        // The reward recipient is still free-form — a bot routinely banks it somewhere else.
        address rewardSink = makeAddr("keeperRewardSink");
        _armCompound();

        vm.prank(keeper);
        pm.compoundFees(_compoundParams(posId, address(feeCollector), rewardSink, alice));

        console.log("owner WETH dust:                ", weth.balanceOf(alice));
        console.log("owner USDC dust:                ", usdc.balanceOf(alice));
        console.log("keeper reward WETH:             ", weth.balanceOf(rewardSink));
        console.log("keeper reward USDC:             ", usdc.balanceOf(rewardSink));

        assertEq(weth.balanceOf(alice), _expectedDust(COMPOUND_FEE0), "owner must receive the token0 dust");
        assertEq(usdc.balanceOf(alice), _expectedDust(COMPOUND_FEE1), "owner must receive the token1 dust");
        assertEq(
            weth.balanceOf(rewardSink),
            (COMPOUND_FEE0 * CALLER_REWARD_BPS) / 10_000,
            "caller reward in token0 must be untouched"
        );
        assertEq(
            usdc.balanceOf(rewardSink),
            (COMPOUND_FEE1 * CALLER_REWARD_BPS) / 10_000,
            "caller reward in token1 must be untouched"
        );
        assertEq(
            weth.balanceOf(address(feeCollector)),
            (COMPOUND_FEE0 * PROTOCOL_FEE_BPS) / 10_000,
            "protocol fee in token0 must reach the collector"
        );
        assertEq(
            usdc.balanceOf(address(feeCollector)),
            (COMPOUND_FEE1 * PROTOCOL_FEE_BPS) / 10_000,
            "protocol fee in token1 must reach the collector"
        );
    }

    /// @notice The transformer the owner authorized may still take the dust, which is how the
    ///         periphery swap router reaches out-of-range dust before returning it to the owner.
    function test_compoundFees_activeTransformerDustPath_stillWorks() public {
        uint256 posId = _deposit(alice);
        CompoundingTransformer transformer = new CompoundingTransformer(address(pm));
        vm.startPrank(owner);
        aclManager.addTransformer(address(transformer));
        aclManager.addKeeper(address(transformer));
        vm.stopPrank();
        _armCompound();

        address rewardSink = makeAddr("transformerRewardSink");
        vm.prank(alice);
        pm.transform(
            posId,
            address(transformer),
            abi.encodeCall(CompoundingTransformer.compound, (posId, address(feeCollector), rewardSink))
        );

        console.log("transformer WETH dust:          ", weth.balanceOf(address(transformer)));
        console.log("transformer USDC dust:          ", usdc.balanceOf(address(transformer)));

        assertEq(
            weth.balanceOf(address(transformer)),
            _expectedDust(COMPOUND_FEE0),
            "authorized transformer must receive the token0 dust"
        );
        assertEq(
            usdc.balanceOf(address(transformer)),
            _expectedDust(COMPOUND_FEE1),
            "authorized transformer must receive the token1 dust"
        );
    }

    /// @notice Holding the transformer role is not enough — the owner's transform must be running.
    /// @dev Otherwise a whitelisted transformer with KEEPER could drain dust from any position on
    ///      its own initiative, which is the same hole under a different address.
    function test_attack_compoundFees_transformerCannotTakeDustOutsideTransform() public {
        uint256 posId = _deposit(alice);
        CompoundingTransformer transformer = new CompoundingTransformer(address(pm));
        vm.startPrank(owner);
        aclManager.addTransformer(address(transformer));
        aclManager.addKeeper(address(transformer));
        vm.stopPrank();
        _armCompound();

        // Called directly rather than through transform(): transformedPositionId is 0, so the
        // contract is nobody's active transformer.
        vm.expectRevert("INVALID_DUST_RECIPIENT");
        transformer.compound(posId, address(feeCollector), makeAddr("outsideRewardSink"));

        assertEq(weth.balanceOf(address(transformer)), 0, "no token0 dust outside a transform");
        assertEq(usdc.balanceOf(address(transformer)), 0, "no token1 dust outside a transform");
    }
}
