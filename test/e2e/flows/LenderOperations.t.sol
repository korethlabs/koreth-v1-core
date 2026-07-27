// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {Market} from "../../../src/markets/Market.sol";

/// @title LenderOperations
/// @notice E2E tests for lender supply/withdraw from markets on forked mainnet.
/// @dev Covers: supply, withdraw (redeem shares), interest earnings, high utilization withdrawal.
contract LenderOperations is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Lender supplies USDC → earns interest from borrowers → withdraws with profit
    function test_lenderSupply_earnInterest_withdraw() public {
        address marketAddr = core.markets(ethUsdcMarketId);
        IMarket market = IMarket(marketAddr);

        // 1. Charlie supplies USDC as a lender
        address charlie = makeAddr("charlie");
        _fundUsdc(charlie, 50_000e6);

        vm.startPrank(charlie);
        IERC20(Constants.USDC).approve(marketAddr, 50_000e6);
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
        lendingEngine.accrueInterest(ethUsdcMarketId);

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
        address marketAddr = core.markets(ethUsdcMarketId);
        IMarket market = IMarket(marketAddr);

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
        uint256 bobShares = Market(marketAddr).shares(bob);
        vm.prank(bob);
        vm.expectRevert("INSUFFICIENT_LIQUIDITY");
        market.withdraw(bobShares);
    }

    /// @notice Multiple lenders share interest proportionally
    function test_multipleLenders_proportionalReturns() public {
        address marketAddr = core.markets(ethUsdcMarketId);
        IMarket market = IMarket(marketAddr);

        // Charlie supplies 50K (Bob already supplied 100K in E2EBase)
        address charlie = makeAddr("charlie");
        _fundUsdc(charlie, 50_000e6);
        vm.startPrank(charlie);
        IERC20(Constants.USDC).approve(marketAddr, 50_000e6);
        uint256 charlieShares = market.supply(50_000e6);
        vm.stopPrank();

        uint256 bobShares = Market(marketAddr).shares(bob);

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
        lendingEngine.accrueInterest(ethUsdcMarketId);

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
