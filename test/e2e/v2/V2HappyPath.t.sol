// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";

/// @title V2HappyPath
/// @notice Full lifecycle test with real Uniswap V2 on forked mainnet
contract V2HappyPath is E2EBase {
    uint256 public v2MarketId;

    function setUp() public override {
        super.setUp();

        // Create a V2 market (the default ethUsdcMarketId is V3)
        vm.startPrank(deployer);
        (v2MarketId,) = marketFactory.createMarket(
            ILPAdapter.LPType.UniswapV2, Constants.USDC, 6500, 7500, 500, 10_000_000e6, 0, 0, "volatile"
        );
        vm.stopPrank();

        // Fund Bob with extra USDC for V2 market (E2EBase already spent his allocation on V3)
        _fundUsdc(bob, 50_000e6);
        address v2MarketAddr = core.markets(v2MarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(v2MarketAddr, 50_000e6);
        IMarket(v2MarketAddr).supply(50_000e6);
        vm.stopPrank();
    }

    function test_fullLifecycle_V2() public {
        // 1. Alice creates V2 LP position
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);
        assertGt(lpAmount, 0, "Should get LP tokens");
        console.log("V2 LP tokens: %s", lpAmount);

        // 2. Deposit into protocol
        vm.startPrank(alice);
        IUniswapV2Pair pair = IUniswapV2Pair(Constants.UNI_V2_WETH_USDC);
        pair.approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        // Position has value
        uint256 value = _getPositionValue(positionId);
        assertGt(value, 0, "Position should have value");
        console.log("V2 Position value: $%s", value / 1e18);

        // 3. Borrow
        vm.roll(block.number + 2);
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = maxBorrow / 3;

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);
        console.log("Borrowed: %s USDC", borrowAmount / 1e6);

        // 4. Repay
        _fundUsdc(alice, borrowAmount);
        address v2MarketAddr = core.markets(v2MarketId);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(v2MarketAddr, type(uint256).max);
        lendingEngine.repay(positionId, type(uint256).max);
        vm.stopPrank();

        assertEq(_getDebt(positionId), 0, "Debt should be zero");

        // 5. Withdraw LP tokens
        vm.prank(alice);
        positionManager.withdraw(positionId);

        uint256 lpBalance = pair.balanceOf(alice);
        assertGt(lpBalance, 0, "Alice should have LP tokens back");
        console.log("=== V2 Happy Path Complete ===");
    }

    function test_v2_deposit_withdraw_noDebt() public {
        uint256 lpAmount = _createV2Position(alice, 0.3 ether, 600e6);

        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        assertGt(_getPositionValue(positionId), 0);

        vm.prank(alice);
        positionManager.withdraw(positionId);

        assertGt(IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).balanceOf(alice), 0);
    }

    function test_v2_oracle_pricing() public {
        uint256 lpAmount = _createV2Position(alice, 1 ether, 2000e6);

        // Price via oracle
        uint256 rawPrice = v2Oracle.getRawPrice(Constants.UNI_V2_WETH_USDC, 0, lpAmount);
        assertGt(rawPrice, 0, "V2 oracle should return non-zero price");

        // Sanity: value should be in the right ballpark ($2K-$10K for 1 ETH + 2K USDC of LP)
        assertGt(rawPrice, 1000e18, "Price too low");
        assertLt(rawPrice, 100_000e18, "Price too high");
        console.log("V2 LP value: $%s", rawPrice / 1e18);
    }
}
