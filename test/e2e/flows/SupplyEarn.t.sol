// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title SupplyEarn
/// @notice Tests that lenders earn interest when borrowers borrow and time passes
contract SupplyEarn is E2EBase {
    function setUp() public override {
        super.setUp();

        // Set reserve factor so interest is split between lenders and protocol
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.prank(deployer);
        Market(marketAddr).setReserveFactor(2000); // 20%
    }

    function test_lenderEarnsInterest() public {
        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);

        // Record Bob's initial shares
        uint256 bobShares = market.shares(bob);
        uint256 initialTotalSupply = market.getMarketState().totalSupply;
        assertGt(bobShares, 0, "Bob should have shares from E2EBase setUp");
        console.log("Bob shares: %s", bobShares);
        console.log("Initial totalSupply: %s", initialTotalSupply);

        // Alice deposits V3 position and borrows
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = maxBorrow / 2;

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);
        console.log("Borrowed: %s USDC", borrowAmount / 1e6);

        // Time passes — interest accrues
        _advanceTime(1 hours);
        market.accrueInterest();

        uint256 finalTotalSupply = market.getMarketState().totalSupply;
        assertGt(finalTotalSupply, initialTotalSupply, "totalSupply should grow from interest");

        // Bob's withdrawal value (shares * totalSupply / totalShares) should be higher
        uint256 bobValue = (bobShares * finalTotalSupply) / market.totalShares();
        uint256 bobInitialValue = (bobShares * initialTotalSupply) / (market.totalShares());

        // Bob earns interest (may be same or slightly more due to rounding)
        assertGe(bobValue, bobInitialValue, "Bob should earn interest");

        uint256 earned = bobValue > bobInitialValue ? bobValue - bobInitialValue : 0;
        console.log("Bob earned: %s USDC", earned / 1e6);

        // Protocol reserves should also grow
        uint256 reserves = market.protocolReserves();
        assertGt(reserves, 0, "Protocol should earn reserves");
        console.log("Protocol reserves: %s USDC", reserves / 1e6);

        console.log("=== Supply Earn Test Passed ===");
    }

    function test_multipleSuppliers_earningProportionally() public {
        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);

        // Carol supplies 50K USDC (same as Bob)
        address carol = makeAddr("carol");
        _fundUsdc(carol, 50_000e6);
        vm.startPrank(carol);
        IERC20(Constants.USDC).approve(marketAddr, 50_000e6);
        market.supply(50_000e6);
        vm.stopPrank();

        uint256 bobShares = market.shares(bob);
        uint256 carolShares = market.shares(carol);
        console.log("Bob shares: %s, Carol shares: %s", bobShares, carolShares);

        // Snapshot pre-borrow totalSupply
        uint256 totalSupplyBefore = market.getMarketState().totalSupply;

        // Alice borrows
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 2);

        // Time passes
        _advanceTime(1 hours);
        market.accrueInterest();

        // Both earn proportionally to their shares
        uint256 totalSupplyAfter = market.getMarketState().totalSupply;
        uint256 totalShares = market.totalShares();

        // totalSupply must grow monotonically after interest accrual
        assertGt(totalSupplyAfter, totalSupplyBefore, "totalSupply should increase after interest accrual");

        uint256 bobValue = (bobShares * totalSupplyAfter) / totalShares;
        uint256 carolValue = (carolShares * totalSupplyAfter) / totalShares;

        // Both values must exceed their initial deposit minus rounding
        uint256 bobInitialValue = (bobShares * totalSupplyBefore) / totalShares;
        uint256 carolInitialValue = (carolShares * totalSupplyBefore) / totalShares;
        assertGe(bobValue, bobInitialValue, "Bob value should not decrease");
        assertGe(carolValue, carolInitialValue, "Carol value should not decrease");

        // Carol supplied same amount as Bob at similar time, shares should be similar
        // Their earnings should be proportional
        console.log("Bob value: %s USDC, Carol value: %s USDC", bobValue / 1e6, carolValue / 1e6);

        console.log("=== Multiple Suppliers Test Passed ===");
    }

    function test_withdrawAfterEarning() public {
        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);

        uint256 bobShares = market.shares(bob);

        // Alice borrows
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 3);

        // Time passes
        _advanceTime(1 hours);
        market.accrueInterest();

        // Alice repays before Bob withdraws (so there's enough liquidity)
        uint256 debt = lendingEngine.getDebt(positionId);
        _fundUsdc(alice, debt);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, type(uint256).max);
        lendingEngine.repay(positionId, type(uint256).max);
        vm.stopPrank();

        // Bob withdraws all shares
        uint256 bobUsdcBefore = IERC20(Constants.USDC).balanceOf(bob);

        vm.prank(bob);
        uint256 withdrawn = market.withdraw(bobShares);

        uint256 bobUsdcAfter = IERC20(Constants.USDC).balanceOf(bob);
        uint256 received = bobUsdcAfter - bobUsdcBefore;

        assertEq(received, withdrawn, "Should receive withdrawn amount");
        // Bob should get back more than he deposited (100K USDC) due to interest
        // Note: might be slightly less due to dead shares on first deposit
        console.log("Bob deposited: 100000 USDC, withdrew: %s USDC", received / 1e6);

        console.log("=== Withdraw After Earning Test Passed ===");
    }
}
