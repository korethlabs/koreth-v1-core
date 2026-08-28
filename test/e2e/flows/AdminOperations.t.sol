// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {InterestRateModel} from "../../../src/markets/InterestRateModel.sol";
import {LendingPool} from "../../../src/markets/LendingPool.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../../src/interfaces/ILPAdapter.sol";
import {FeeCollector} from "../../../src/core/FeeCollector.sol";
import {RiskManager} from "../../../src/security/RiskManager.sol";
import {RiskConfig} from "../../helpers/RiskConfig.sol";

/// @title AdminOperations
/// @notice E2E tests for admin/governance operations on forked mainnet.
/// @dev Covers: RiskManager collateral config and caps, LiquidationEngine admin setters,
///      FeeCollector setters and sweepExcess, interest rate model hot-swap, borrow cooldown,
///      bad debt write-off and deficit elimination.
contract AdminOperations is E2EBase {
    event DebtWrittenOff(uint256 indexed positionId, address indexed borrowAsset, uint256 amount, address caller);

    function setUp() public override {
        super.setUp();

        // Grant RISK_ADMIN to deployer for admin tests
        vm.prank(deployer);
        aclManager.addRiskAdmin(deployer);
    }

    // ========== Market.updateConfig ==========

    /// @notice Update LTV/threshold mid-lifecycle with active positions
    function test_updateConfig_midLifecycle() public {
        // Alice deposits and borrows
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 5);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 3);

        uint256 hfBefore = _getHealthFactor(positionId);
        console.log("HF before config change: %s", hfBefore / 1e16);

        // Admin reduces LTV from 65% to 50% and liq threshold 75% -> 60% (via RiskManager).
        // An enabled type must state a cap — 0 means "blocked", so it would revert ZERO_BORROW_CAP.
        // NO_BORROW_CAP() is read before the prank on purpose: as an argument it is itself an
        // external call, and it would consume the prank so setCollateralConfig arrived from the
        // test contract instead of the admin.
        uint256 noCap = riskManager.NO_BORROW_CAP();
        vm.prank(deployer);
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.config(5000, 6000, 500, 0, noCap, true));

        // HF should change (liquidation threshold changed from 75% to 60%)
        uint256 hfAfter = _getHealthFactor(positionId);
        console.log("HF after config change: %s", hfAfter / 1e16);
        assertLt(hfAfter, hfBefore, "HF should decrease with lower liq threshold");

        // Max borrow should be lower now
        uint256 maxBorrowAfter = lendingEngine.getMaxBorrow(positionId);
        console.log("Max borrow before: %s, after: %s", maxBorrow / 1e6, maxBorrowAfter / 1e6);
        assertLt(maxBorrowAfter, maxBorrow, "Max borrow should decrease with lower LTV");
    }

    /// @notice setCollateralConfig reverts with invalid params
    function test_revert_updateConfig_invalidParams() public {
        // Each case passes NO_BORROW_CAP so the only invalid field is the one under test —
        // a 0 cap would trip ZERO_BORROW_CAP and mask the check we care about.
        uint256 noCap = riskManager.NO_BORROW_CAP();

        // LTV >= liquidation threshold
        vm.prank(deployer);
        vm.expectRevert("LTV_GE_THRESHOLD");
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.config(8000, 7500, 500, 0, noCap, true));

        // Liquidation threshold above the allowed maximum. maxLtv stays within MAX_LTV_BPS (9500)
        // deliberately: at 9600 the LTV_TOO_HIGH check fires first, the threshold bound is never
        // reached, and the case this line exists to cover goes untested.
        vm.prank(deployer);
        vm.expectRevert("THRESHOLD_TOO_HIGH");
        riskManager.setCollateralConfig(
            ILPAdapter.LPType.UniswapV3, RiskConfig.config(9000, 10_001, 500, 0, noCap, true)
        );

        // Non-admin blocked
        vm.prank(alice);
        vm.expectRevert("NOT_RISK_ADMIN");
        riskManager.setCollateralConfig(ILPAdapter.LPType.UniswapV3, RiskConfig.config(5000, 6000, 500, 0, noCap, true));
    }

    // ========== Market.eliminateDeficit ==========

    /// @notice eliminateDeficit when no deficit reverts
    function test_revert_eliminateDeficit_noDeficit() public {
        address poolAddr = address(usdcPool);

        vm.prank(deployer);
        vm.expectRevert("NO_DEFICIT");
        LendingPool(poolAddr).eliminateDeficit();
    }

    // ========== RiskManager supply cap ==========

    /// @notice Market supply cap blocks new deposits when reached
    function test_riskManager_supplyCap_enforced() public {
        // Set a tight supply cap on the market ($5K)
        vm.prank(deployer);
        riskManager.setPoolSupplyCap(usdcBorrowAsset, 5000e18); // $5K in 18-dec USD

        // Alice deposits a $7K+ position -- should fail
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);

        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        vm.expectRevert("SUPPLY_CAP_REACHED");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, usdcBorrowAsset);
        vm.stopPrank();

        // Raise cap -- deposit succeeds
        vm.prank(deployer);
        riskManager.setPoolSupplyCap(usdcBorrowAsset, 100_000e18);

        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        uint256 posId = positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, usdcBorrowAsset);
        vm.stopPrank();

        assertGt(_getPositionValue(posId), 0);
        console.log("Deposit succeeded after raising cap");
    }

    // ========== LiquidationEngine admin ==========

    /// @notice setMaxLiquidationPortion limits seizure amount
    function test_setMaxLiquidationPortion() public {
        // Default is usually 5000 (50%). Set to 2500 (25%)
        vm.prank(deployer);
        liquidationEngine.setMaxLiquidationPortion(2500);

        // Create leveraged position
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 5);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 85) / 100);

        // Mock oracle so HF is ~0.97 (below 1.0 but above CRITICAL_HF 0.95)
        // This ensures the maxLiquidationPortion cap applies (not full-debt mode)
        // HF = (value * liqThreshold) / debtUsd → value = HF * debtUsd * 10000 / liqThreshold
        uint256 debt = _getDebt(positionId);
        uint256 debtUsd = uint256(debt) * 1e12; // 6-dec USDC to 18-dec USD
        uint256 crashedValue = (debtUsd * 9700 * 10_000) / (7500 * 10_000); // HF ~0.97
        _mockOraclePrice(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ILPAdapter.LPType.UniswapV3, crashedValue);

        (bool isLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(isLiq, "Position must be liquidatable");

        // maxRepay should be limited to 25% of debt (2500 bps)
        uint256 expectedMax = (debt * 2500) / 10_000;
        console.log("Debt: %s, maxRepay: %s, expected max ~%s", debt / 1e6, maxRepay / 1e6, expectedMax / 1e6);
        assertLe(maxRepay, expectedMax + expectedMax / 100, "maxRepay should be capped at 25%");
    }

    /// @notice setMaxLiquidationPortion bounds enforcement
    function test_revert_setMaxLiquidationPortion_bounds() public {
        // Below min
        vm.prank(deployer);
        vm.expectRevert("BELOW_MIN");
        liquidationEngine.setMaxLiquidationPortion(0);

        // Above max
        vm.prank(deployer);
        vm.expectRevert("ABOVE_MAX");
        liquidationEngine.setMaxLiquidationPortion(10_001);
    }

    /// @notice rescueTokens recovers stuck tokens
    function test_rescueTokens() public {
        // Send some USDC directly to LiquidationEngine (simulating stuck tokens)
        _fundUsdc(address(liquidationEngine), 1000e6);

        uint256 balBefore = IERC20(Constants.USDC).balanceOf(deployer);

        vm.prank(deployer);
        liquidationEngine.rescueTokens(Constants.USDC, deployer, 1000e6);

        uint256 balAfter = IERC20(Constants.USDC).balanceOf(deployer);
        assertEq(balAfter - balBefore, 1000e6, "Should recover 1000 USDC");
    }

    // ========== FeeCollector.sweepExcess ==========

    /// @notice sweepExcess recovers accidentally sent tokens
    function test_sweepExcess() public {
        // Send USDC directly to FeeCollector (not via collectFee)
        _fundUsdc(address(feeCollector), 500e6);

        uint256 excess =
            IERC20(Constants.USDC).balanceOf(address(feeCollector)) - feeCollector.accumulatedFees(Constants.USDC);
        assertGt(excess, 0, "Should have excess");

        vm.prank(deployer);
        feeCollector.sweepExcess(Constants.USDC, deployer);

        uint256 newExcess =
            IERC20(Constants.USDC).balanceOf(address(feeCollector)) - feeCollector.accumulatedFees(Constants.USDC);
        assertEq(newExcess, 0, "Excess should be swept");
    }

    /// @notice sweepExcess reverts when no excess
    function test_revert_sweepExcess_noExcess() public {
        vm.prank(deployer);
        vm.expectRevert("NO_EXCESS");
        feeCollector.sweepExcess(Constants.USDC, deployer);
    }

    // ========== PositionManager.getActivePositionsByOwner ==========

    /// @notice getActivePositionsByOwner filters closed/liquidated positions
    function test_getActivePositionsByOwner_filters() public {
        // Create 3 positions
        uint256 tokenId1 = _createV3Position(alice, 1 ether, 2000e6);
        _depositV3(alice, tokenId1);

        _fundWeth(alice, 1 ether);
        _fundUsdc(alice, 2000e6);
        uint256 tokenId2 = _createV3Position(alice, 1 ether, 2000e6);
        uint256 posId2 = _depositV3(alice, tokenId2);

        _fundWeth(alice, 1 ether);
        _fundUsdc(alice, 2000e6);
        uint256 tokenId3 = _createV3Position(alice, 1 ether, 2000e6);
        _depositV3(alice, tokenId3);

        // All 3 should be active
        uint256[] memory active = positionManager.getActivePositionsByOwner(alice);
        assertEq(active.length, 3, "Should have 3 active positions");

        // Close position 2
        vm.prank(alice);
        positionManager.withdraw(posId2);

        // Now only 2 active
        active = positionManager.getActivePositionsByOwner(alice);
        assertEq(active.length, 2, "Should have 2 active positions after closing 1");
        console.log("Active positions after closing 1: %s", active.length);
    }

    // ========== compoundFees ACL ==========

    /// @notice Non-keeper/non-admin cannot call compoundFees
    function test_revert_compoundFees_unauthorized() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        vm.prank(alice); // alice is not keeper or pool admin
        vm.expectRevert("NOT_AUTHORIZED");
        positionManager.compoundFees(
            IPositionManager.CompoundFeesParams({
                positionId: positionId,
                protocolFeeRecipient: address(feeCollector),
                protocolFeeBps: 200,
                callerRewardRecipient: alice,
                callerRewardBps: 50,
                minFeeThreshold: 0,
                dustRefundTo: alice,
                maxSlippageBps: 0
            })
        );
    }

    // ========== setInterestRateModel hot-swap ==========

    /// @notice Deploy a new IRM with higher rates, swap it on the market with active borrows,
    ///         and verify the new rates apply after accrual.
    function test_setInterestRateModel_hotSwap() public {
        // Alice deposits and borrows to create active debt
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 3);

        uint256 debtAfterBorrow = _getDebt(positionId);
        assertGt(debtAfterBorrow, 0, "Should have debt");

        // Record the current borrow rate from the original model
        address poolAddr = address(usdcPool);
        uint256 oldRate = volatileModel.getBorrowRate(5000); // at 50% utilization

        // Deploy new IRM with much higher base rate and slopes
        // Original: baseRate=200bps, slope1=600bps, slope2=10000bps, kink=8000
        // New:      baseRate=1000bps, slope1=2000bps, slope2=20000bps, kink=7000
        InterestRateModel newModel = new InterestRateModel(1000, 2000, 20_000, 7000);
        uint256 newRate = newModel.getBorrowRate(5000);
        assertGt(newRate, oldRate, "New model should have higher rate at same utilization");

        // Hot-swap the interest rate model
        vm.prank(deployer);
        LendingPool(poolAddr).setInterestRateModel(address(newModel));

        // Advance time to accumulate interest under the new model
        _advanceTime(1 hours);
        lendingEngine.accrueInterest(usdcBorrowAsset);

        uint256 debtAfterAccrual = _getDebt(positionId);
        assertGt(debtAfterAccrual, debtAfterBorrow, "Debt should increase after accrual with new model");

        console.log("Old rate (per sec): %s", oldRate);
        console.log("New rate (per sec): %s", newRate);
        console.log("Debt before accrual: %s USDC", debtAfterBorrow / 1e6);
        console.log("Debt after accrual:  %s USDC", debtAfterAccrual / 1e6);
        console.log("=== IRM Hot-Swap Test Passed ===");
    }

    // ========== setBorrowCooldown ==========

    /// @notice Set cooldown to 5 blocks, verify borrow reverts before cooldown, succeeds after.
    function test_setBorrowCooldown() public {
        // Set cooldown to 5 blocks
        vm.prank(deployer);
        lendingEngine.setBorrowCooldown(5);

        // Deposit position
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        // Try borrow immediately (same block as deposit) -- should revert
        vm.prank(alice);
        vm.expectRevert("BORROW_COOLDOWN");
        lendingEngine.borrow(positionId, 100e6);

        // Advance 3 blocks (still within 5-block cooldown) -- should revert
        vm.roll(block.number + 3);
        vm.prank(alice);
        vm.expectRevert("BORROW_COOLDOWN");
        lendingEngine.borrow(positionId, 100e6);

        // Advance past cooldown (total > 5 blocks from deposit)
        vm.roll(block.number + 5);
        vm.prank(alice);
        lendingEngine.borrow(positionId, 100e6);

        assertGt(_getDebt(positionId), 0, "Borrow should succeed after cooldown");

        console.log("=== Borrow Cooldown (5 blocks) Test Passed ===");
    }

    // ========== bad debt write-off and deficit elimination ==========

    /// @dev Drives a position into genuine bad debt and liquidates it.
    ///
    ///      Two conditions have to hold at once, and both are asserted here rather than logged:
    ///      the liquidator must stop short of the outstanding debt, and the collateral left
    ///      behind must sit at or under the engine's dust threshold. Only then does liquidate()
    ///      reach its write-off branch. Repaying the full `maxRepay` — which equals the entire
    ///      debt once the position is below the critical health factor — settles the loan out of
    ///      the liquidator's own pocket and leaves nothing to write off.
    ///
    ///      A V3 position is used deliberately: its `amount` stays 0, so the mocked collateral
    ///      price still applies after the seizure and the residual value the engine re-reads is
    ///      the crashed one.
    /// @return positionId The position that was liquidated into bad debt
    function _liquidateIntoBadDebt() private returns (uint256 positionId) {
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        uint256 debt = _getDebt(positionId);
        assertGt(debt, 0, "Position must carry debt");

        // Price the collateral down to the dust threshold: whatever debt survives the repayment
        // has no collateral behind it.
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, liquidationEngine.DUST_THRESHOLD_USD());

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable");

        uint256 repayAmount = debt / 2;
        assertLt(repayAmount, debt, "Repayment must leave debt outstanding");
        assertLe(repayAmount, maxRepay, "Repayment must stay within the close factor");

        _fundUsdc(liquidator, repayAmount);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), repayAmount);
        // Topics only: the written-off amount includes the interest liquidate() accrues on entry,
        // and its size is asserted through the pool's deficit by the callers.
        vm.expectEmit(true, true, false, false, address(lendingEngine));
        emit DebtWrittenOff(positionId, usdcBorrowAsset, 0, address(0));
        liquidationEngine.liquidate(positionId, repayAmount, block.timestamp + 300, 0, 0);
        vm.stopPrank();
    }

    /// @notice A liquidation that leaves debt behind on worthless collateral writes that debt off
    ///         and books it as pool deficit, socialized onto the suppliers.
    function test_badDebtWriteoff_deficitRecorded() public {
        LendingPool market = LendingPool(address(usdcPool));

        uint256 deficitBefore = market.deficit();
        uint256 supplyBefore = market.getPoolState().totalSupply;

        uint256 positionId = _liquidateIntoBadDebt();

        uint256 deficitRecorded = market.deficit() - deficitBefore;
        assertGt(deficitRecorded, 0, "Write-off must record a deficit");
        assertEq(_getDebt(positionId), 0, "Write-off must clear the position's debt");
        assertEq(
            uint256(positionManager.getPosition(positionId).status),
            uint256(IPositionManager.PositionStatus.Liquidated),
            "Position must end up liquidated"
        );

        // recordDeficit socializes whatever reserves could not absorb by cutting totalSupply, and
        // tracks exactly that cut as the deficit — the two move by the same amount.
        assertEq(
            supplyBefore - market.getPoolState().totalSupply,
            deficitRecorded,
            "Supplier loss must equal the recorded deficit"
        );

        console.log("Deficit recorded: %s USDC", deficitRecorded / 1e6);
    }

    /// @notice Reserves accrued after a write-off refund the socialized loss: eliminateDeficit
    ///         draws the reserves down, shrinks the deficit and credits the suppliers back.
    function test_eliminateDeficit() public {
        LendingPool market = LendingPool(address(usdcPool));

        _liquidateIntoBadDebt();

        uint256 deficitBefore = market.deficit();
        assertGt(deficitBefore, 0, "Scenario must leave a deficit to eliminate");

        // Reserves have to be rebuilt after the write-off, not before: recordDeficit spends them
        // first and only socializes what they could not absorb. The deployed pool runs a 0 reserve
        // factor, so state the factor here instead of relying on the deployment.
        vm.prank(deployer);
        market.setReserveFactor(2000); // 20% of interest kept by the protocol

        // A second borrower pays the interest that refills the reserves.
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        _advanceTime(180 days);
        market.accrueInterest();

        uint256 reservesBefore = market.protocolReserves();
        assertGt(reservesBefore, 0, "Reserves must be funded before elimination");

        uint256 supplyBefore = market.getPoolState().totalSupply;

        vm.prank(deployer);
        market.eliminateDeficit();

        uint256 covered = reservesBefore - market.protocolReserves();
        assertGt(covered, 0, "Elimination must draw reserves down");
        assertLt(market.deficit(), deficitBefore, "Deficit must shrink");
        assertEq(market.deficit(), deficitBefore - covered, "Deficit reduced by exactly what reserves covered");
        assertEq(market.getPoolState().totalSupply, supplyBefore + covered, "Suppliers credited back the coverage");

        console.log("Deficit: %s -> %s USDC", deficitBefore / 1e6, market.deficit() / 1e6);
        console.log("Reserves spent on the refund: %s USDC", covered / 1e6);
    }

    // ========== setLPTypeBorrowCap ==========

    /// @notice Set a per-LP-type borrow cap. Borrow within cap succeeds. Borrow exceeding cap reverts.
    function test_setLPTypeBorrowCap() public {
        // Set a tight V3 borrow cap (small enough that a normal borrow will exceed it)
        uint256 capAmount = 50e18; // $50 in 18-dec USD — very tight
        vm.prank(deployer);
        riskManager.setLPTypeBorrowCap(ILPAdapter.LPType.UniswapV3, capAmount);

        assertEq(
            riskManager.lpTypeBorrowCap(ILPAdapter.LPType.UniswapV3), capAmount, "LP type borrow cap should be set"
        );

        // Alice deposits a V3 position
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Borrow a large amount that exceeds the cap — should revert with the bubbled RiskManager reason
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        vm.expectRevert("LP_TYPE_CAP_REACHED");
        lendingEngine.borrow(positionId, maxBorrow / 2);

        // Raise the cap so borrowing succeeds
        vm.prank(deployer);
        riskManager.setLPTypeBorrowCap(ILPAdapter.LPType.UniswapV3, 100_000_000e18); // $100M

        vm.prank(alice);
        lendingEngine.borrow(positionId, 100e6); // small borrow within cap

        assertGt(_getDebt(positionId), 0, "Borrow should succeed within cap");

        console.log("=== setLPTypeBorrowCap Test Passed ===");
    }

    // ========== getLiquidationBonus ==========

    /// @notice Deposit, borrow, verify getLiquidationBonus returns the configured bonus (500 bps = 5%).
    function test_getLiquidationBonus() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        uint256 bonus = liquidationEngine.getLiquidationBonus(positionId);
        assertEq(bonus, 500, "Liquidation bonus should be 500 bps (5%)");

        console.log("Liquidation bonus: %s bps", bonus);
        console.log("=== getLiquidationBonus Test Passed ===");
    }

    // ========== feeCollector.setInsuranceFundShare ==========

    /// @notice Set insurance fund share, verify getter.
    function test_feeCollector_setInsuranceFundShare() public {
        // Default is 1000 bps (10%)
        assertEq(feeCollector.insuranceFundShareBps(), 1000, "Default insurance share should be 1000 bps");

        // Set new value
        vm.prank(deployer);
        feeCollector.setInsuranceFundShare(2000); // 20%

        assertEq(feeCollector.insuranceFundShareBps(), 2000, "Insurance share should be updated to 2000 bps");

        console.log("=== feeCollector setInsuranceFundShare Test Passed ===");
    }

    // ========== feeCollector.setLiquidationFee ==========

    /// @notice Set liquidation fee, verify getter.
    function test_feeCollector_setLiquidationFee() public {
        // Default is 7000 bps (70% of bonus -> protocol)
        assertEq(feeCollector.liquidationFeeBps(), 7000, "Default liquidation fee should be 7000 bps");

        // Set new value
        vm.prank(deployer);
        feeCollector.setLiquidationFee(5000); // 50%

        assertEq(feeCollector.liquidationFeeBps(), 5000, "Liquidation fee should be updated to 5000 bps");

        console.log("=== feeCollector setLiquidationFee Test Passed ===");
    }

    // ========== feeCollector.setDefaultReserveFactor ==========

    /// @notice Set default reserve factor, verify getter.
    function test_feeCollector_setDefaultReserveFactor() public {
        // Default is 2000 bps (20%)
        assertEq(feeCollector.defaultReserveFactorBps(), 2000, "Default reserve factor should be 2000 bps");

        // Set new value
        vm.prank(deployer);
        feeCollector.setDefaultReserveFactor(3000); // 30%

        assertEq(feeCollector.defaultReserveFactorBps(), 3000, "Default reserve factor should be updated to 3000 bps");

        console.log("=== feeCollector setDefaultReserveFactor Test Passed ===");
    }
}
