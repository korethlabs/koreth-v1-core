// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {InterestRateModel} from "../../../src/markets/InterestRateModel.sol";
import {LendingPool} from "../../../src/markets/LendingPool.sol";
import {ILPAdapter} from "../../../src/interfaces/ILPAdapter.sol";
import {FeeCollector} from "../../../src/core/FeeCollector.sol";
import {RiskManager} from "../../../src/security/RiskManager.sol";

/// @title AdminOpsExtended
/// @notice E2E fork tests for admin operations not covered in AdminOperations.t.sol.
/// @dev Covers: interest rate model hot-swap, borrow cooldown, bad debt write-off, deficit elimination.
contract AdminOpsExtended is E2EBase {
    event DebtWrittenOff(uint256 indexed positionId, address indexed borrowAsset, uint256 amount, address caller);

    function setUp() public override {
        super.setUp();

        // Grant RISK_ADMIN to deployer for admin tests (eliminateDeficit, setReserveFactor)
        vm.prank(deployer);
        aclManager.addRiskAdmin(deployer);
    }

    // ========== 1. setInterestRateModel hot-swap ==========

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
        address marketAddr = address(usdcPool);
        uint256 oldRate = volatileModel.getBorrowRate(5000); // at 50% utilization

        // Deploy new IRM with much higher base rate and slopes
        // Original: baseRate=200bps, slope1=600bps, slope2=10000bps, kink=8000
        // New:      baseRate=1000bps, slope1=2000bps, slope2=20000bps, kink=7000
        InterestRateModel newModel = new InterestRateModel(1000, 2000, 20_000, 7000);
        uint256 newRate = newModel.getBorrowRate(5000);
        assertGt(newRate, oldRate, "New model should have higher rate at same utilization");

        // Hot-swap the interest rate model
        vm.prank(deployer);
        LendingPool(marketAddr).setInterestRateModel(address(newModel));

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

    // ========== 2. setBorrowCooldown ==========

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

    // ========== 3. writeOffDebt bad debt flow ==========

    /// @notice Create underwater position, liquidate partially, write off remaining bad debt.
    function test_writeOffDebt_badDebtFlow() public {
        // Alice deposits and borrows aggressively
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        uint256 debtBefore = _getDebt(positionId);
        assertGt(debtBefore, 0, "Should have debt");

        // Crash ETH price severely to make position deeply underwater
        _crashEthPrice(8000 ether);

        // Verify position is liquidatable
        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable");

        // Liquidate what we can
        if (maxRepay > 0) {
            address marketAddr = address(usdcPool);
            vm.startPrank(liquidator);
            IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
            IERC20(Constants.USDC).approve(marketAddr, maxRepay);
            liquidationEngine.liquidate(positionId, maxRepay, block.timestamp + 300, 0, 0);
            vm.stopPrank();
        }

        // Check if there's remaining debt (bad debt)
        uint256 remainingDebt = _getDebt(positionId);

        // Write off bad debt via LendingEngine (onlyLiquidationEngine)
        if (remainingDebt > 0) {
            // Assert DebtWrittenOff fires with the position, market, debt amount, and caller.
            vm.expectEmit(true, true, false, true, address(lendingEngine));
            emit DebtWrittenOff(positionId, usdcBorrowAsset, remainingDebt, address(liquidationEngine));

            vm.prank(address(liquidationEngine));
            lendingEngine.writeOffDebt(positionId);

            uint256 debtAfterWriteOff = _getDebt(positionId);
            assertEq(debtAfterWriteOff, 0, "Debt should be zero after write-off");

            // Market should have recorded deficit
            address marketAddr = address(usdcPool);
            uint256 marketDeficit = LendingPool(marketAddr).deficit();
            assertGt(marketDeficit, 0, "Market should have deficit after write-off");

            console.log("Remaining debt written off: %s USDC", remainingDebt / 1e6);
            console.log("Market deficit: %s USDC", marketDeficit / 1e6);
        }

        console.log("=== Bad Debt Write-Off Test Passed ===");
    }

    // ========== 4. eliminateDeficit ==========

    /// @notice After writeOffDebt creates a deficit, build reserves via interest, then eliminate deficit.
    function test_eliminateDeficit() public {
        address marketAddr = address(usdcPool);

        // Step 1: Set reserve factor so protocol accumulates reserves from interest
        vm.prank(deployer);
        LendingPool(marketAddr).setReserveFactor(2000); // 20%

        // Step 2: Create a position with active debt to generate interest
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        // Step 3: Advance time to accumulate interest (and thus reserves)
        _advanceTime(30 days);
        lendingEngine.accrueInterest(usdcBorrowAsset);

        uint256 reservesBefore = LendingPool(marketAddr).protocolReserves();
        console.log("Protocol reserves after 30 days: %s USDC", reservesBefore / 1e6);
        assertGt(reservesBefore, 0, "Should have accumulated reserves");

        // Step 4: Crash price and create bad debt
        _crashEthPrice(8000 ether);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable after crash");

        // Liquidate
        if (maxRepay > 0) {
            _fundUsdc(liquidator, maxRepay);
            vm.startPrank(liquidator);
            IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
            IERC20(Constants.USDC).approve(marketAddr, maxRepay);
            liquidationEngine.liquidate(positionId, maxRepay, block.timestamp + 300, 0, 0);
            vm.stopPrank();
        }

        // Write off remaining bad debt
        uint256 remainingDebt = _getDebt(positionId);
        if (remainingDebt > 0) {
            vm.prank(address(liquidationEngine));
            lendingEngine.writeOffDebt(positionId);
        }

        uint256 deficitBefore = LendingPool(marketAddr).deficit();
        console.log("Deficit after write-off: %s USDC", deficitBefore / 1e6);

        // Step 5: Eliminate deficit using reserves
        if (deficitBefore > 0) {
            uint256 reservesNow = LendingPool(marketAddr).protocolReserves();
            vm.prank(deployer);
            LendingPool(marketAddr).eliminateDeficit();

            uint256 deficitAfter = LendingPool(marketAddr).deficit();
            uint256 reservesAfter = LendingPool(marketAddr).protocolReserves();

            // Deficit should be reduced (fully if reserves >= deficit, partially otherwise)
            assertLt(deficitAfter, deficitBefore, "Deficit should decrease");
            assertLt(reservesAfter, reservesNow, "Reserves should decrease");

            console.log("Deficit before: %s, after: %s USDC", deficitBefore / 1e6, deficitAfter / 1e6);
            console.log("Reserves before: %s, after: %s USDC", reservesNow / 1e6, reservesAfter / 1e6);
        } else {
            // If no deficit (liquidation covered everything), verify eliminateDeficit reverts
            vm.prank(deployer);
            vm.expectRevert("NO_DEFICIT");
            LendingPool(marketAddr).eliminateDeficit();
            console.log("No deficit to eliminate (liquidation covered all debt)");
        }

        console.log("=== Deficit Elimination Test Passed ===");
    }

    // ========== 5. setLPTypeBorrowCap ==========

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

    // ========== 6. getLiquidationBonus ==========

    /// @notice Deposit, borrow, verify getLiquidationBonus returns the configured bonus (500 bps = 5%).
    function test_getLiquidationBonus() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        uint256 bonus = liquidationEngine.getLiquidationBonus(positionId);
        assertEq(bonus, 500, "Liquidation bonus should be 500 bps (5%)");

        console.log("Liquidation bonus: %s bps", bonus);
        console.log("=== getLiquidationBonus Test Passed ===");
    }

    // ========== 7. feeCollector_setInsuranceFundShare ==========

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

    // ========== 8. feeCollector_setLiquidationFee ==========

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

    // ========== 9. feeCollector_setDefaultReserveFactor ==========

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
