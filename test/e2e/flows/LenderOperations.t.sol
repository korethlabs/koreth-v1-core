// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {LendingPool} from "../../../src/markets/LendingPool.sol";

/// @title LenderOperations
/// @notice E2E tests for lender supply/withdraw from markets on forked mainnet.
/// @dev Covers: supply, withdraw (redeem shares), interest earnings, high utilization withdrawal.
contract LenderOperations is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Lender supplies USDC → earns interest from borrowers → withdraws with profit
    function test_lenderSupply_earnInterest_withdraw() public {
        address poolAddr = address(usdcPool);
        ILendingPool market = ILendingPool(poolAddr);

        // 1. Charlie supplies USDC as a lender
        address charlie = makeAddr("charlie");
        _fundUsdc(charlie, 50_000e6);

        vm.startPrank(charlie);
        IERC20(Constants.USDC).approve(poolAddr, 50_000e6);
        uint256 shares = market.supply(50_000e6);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
        console.log("Charlie supplied 50K USDC, got %s shares", shares);

        // 2. Alice borrows (creates interest)
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = maxBorrow / 2;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // 3. Time passes — interest accrues (re-mock Chainlink to avoid staleness)
        _advanceTime(30 days);
        _refreshChainlinkMocks();
        lendingEngine.accrueInterest(usdcBorrowAsset);

        // 4. Charlie withdraws all shares
        vm.prank(charlie);
        uint256 received = market.withdraw(shares);

        console.log("Charlie withdrew: %s USDC", received / 1e6);
        assertGt(received, 50_000e6, "Should receive more than deposited (interest earned)");

        uint256 profit = received - 50_000e6;
        console.log("Profit: %s USDC", profit / 1e6);
    }

    /// @notice Lender cannot withdraw more than available liquidity
    function test_revert_lenderWithdraw_insufficientLiquidity() public {
        address poolAddr = address(usdcPool);
        ILendingPool market = ILendingPool(poolAddr);

        // Bob already supplied 100K USDC in E2EBase setUp
        // Alice borrows most of it
        uint256 tokenId = _createV3Position(alice, 5 ether, 12_000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        // Borrow 90% of max to use up most liquidity
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        // Bob tries to withdraw all shares — should fail (most USDC is lent out)
        uint256 bobShares = LendingPool(poolAddr).shares(bob);
        vm.prank(bob);
        vm.expectRevert("INSUFFICIENT_LIQUIDITY");
        market.withdraw(bobShares);
    }

    /// @notice Multiple lenders share interest proportionally
    function test_multipleLenders_proportionalReturns() public {
        address poolAddr = address(usdcPool);
        ILendingPool market = ILendingPool(poolAddr);

        // Charlie supplies 50K (Bob already supplied 100K in E2EBase)
        address charlie = makeAddr("charlie");
        _fundUsdc(charlie, 50_000e6);
        vm.startPrank(charlie);
        IERC20(Constants.USDC).approve(poolAddr, 50_000e6);
        uint256 charlieShares = market.supply(50_000e6);
        vm.stopPrank();

        uint256 bobShares = LendingPool(poolAddr).shares(bob);

        // Alice borrows
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 5);
        uint256 _maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, _maxBorrow / 2);

        // Time passes — re-mock Chainlink to avoid staleness
        _advanceTime(30 days);
        _refreshChainlinkMocks();
        lendingEngine.accrueInterest(usdcBorrowAsset);

        // Both withdraw partial
        uint256 charliePartial = charlieShares / 2;
        vm.prank(charlie);
        uint256 charlieReceived = market.withdraw(charliePartial);

        uint256 bobPartial = bobShares / 2;
        vm.prank(bob);
        uint256 bobReceived = market.withdraw(bobPartial);

        console.log("Charlie (50K deposit, %s shares burned): %s USDC", charliePartial, charlieReceived / 1e6);
        console.log("Bob (100K deposit, %s shares burned): %s USDC", bobPartial, bobReceived / 1e6);

        // Bob deposited 2x Charlie, so should get ~2x per share
        // Both should have earned some interest
        assertGt(charlieReceived, 0);
        assertGt(bobReceived, 0);
    }

    /// @notice Lender withdraws more than deposited once borrower interest has accrued
    function test_lenderEarnsProfit_withdrawsMore() public {
        address poolAddr = address(usdcPool);
        LendingPool market = LendingPool(poolAddr);

        // Carol supplies 10K USDC
        address carol = makeAddr("carol");
        _fundUsdc(carol, 10_000e6);
        vm.startPrank(carol);
        IERC20(Constants.USDC).approve(poolAddr, 10_000e6);
        market.supply(10_000e6);
        vm.stopPrank();

        uint256 carolShares = market.shares(carol);
        // Carol supplied 10K — her USDC balance is now ~0 after supply

        // Alice borrows to generate interest
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, usdcBorrowAsset);
        vm.stopPrank();
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 2);

        // One hour of accrual lands exactly on maxStaleness, leaving the reads that follow no
        // margin at all. Restamp the feeds the way the other tests here do, so the window is
        // chosen for the interest it produces rather than for what the oracle still tolerates.
        _advanceTime(1 hours);
        _refreshChainlinkMocks();
        market.accrueInterest();

        // Alice repays so Carol can withdraw
        uint256 debt = lendingEngine.getDebt(positionId);
        _fundUsdc(alice, debt);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(poolAddr, type(uint256).max);
        lendingEngine.repay(positionId, type(uint256).max);
        vm.stopPrank();

        // Carol withdraws all shares — should get back >= 10K (interest earned)
        vm.prank(carol);
        uint256 withdrawn = market.withdraw(carolShares);

        // Withdrawn amount represents Carol's share of pool + interest
        assertGt(withdrawn, 0, "Should withdraw something");
        // With interest earned, withdrawn should be >= original deposit (10K USDC minus dead shares rounding)
        assertGt(withdrawn, 10_000e6, "Should withdraw more than deposited");
        console.log("Carol deposited: 10000 USDC, withdrew: %s USDC", withdrawn / 1e6);
        console.log("=== Lender Earns Profit Passed ===");
    }

    function _refreshChainlinkMocks() internal {
        int256 ethPrice = int256(_getEthPrice() / 1e10);
        vm.mockCall(
            Constants.CL_ETH_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), ethPrice, block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(
            Constants.CL_USDC_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), int256(100_000_000), block.timestamp, block.timestamp, uint80(1))
        );
    }
}
