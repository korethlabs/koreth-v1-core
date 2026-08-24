// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IUniswapV2Factory} from "../../../src/interfaces/external/IUniswapV2.sol";
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title V2NonUsdcPairs
/// @notice Deposit and borrow against V2 LP whose quote leg is not the borrow asset.
/// @dev Every other V2 end-to-end test uses WETH/USDC and borrows USDC, so the collateral happens to
///      contain the asset being borrowed. That coincidence hides two things: whether pricing works
///      for a pair the protocol was not first built around, and whether borrowing capacity is really
///      derived from the LP's USD value rather than from a leg that matches the debt. These tests use
///      WETH/DAI and WETH/USDT against the USDC pool, so neither leg is the borrow asset.
contract V2NonUsdcPairs is E2EBase {
    using SafeERC20 for OZIERC20;

    function setUp() public override {
        super.setUp();

        // The shared USDC pool needs depth for two borrows on top of what E2EBase supplies.
        _fundUsdc(bob, 50_000e6);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(address(usdcPool), 50_000e6);
        usdcPool.supply(50_000e6);
        vm.stopPrank();
    }

    /// @dev Mint V2 LP for WETH paired with `quote`. forceApprove rather than approve: USDT's approve
    ///      returns no data, so a plain call through a `returns (bool)` interface reverts on decode.
    function _addLiquidity(
        address user,
        address quote,
        uint256 wethAmount,
        uint256 quoteAmount
    )
        internal
        returns (uint256 lpAmount)
    {
        _fundWeth(user, wethAmount);
        deal(quote, user, quoteAmount);

        vm.startPrank(user);
        OZIERC20(Constants.WETH).forceApprove(Constants.UNI_V2_ROUTER, wethAmount);
        OZIERC20(quote).forceApprove(Constants.UNI_V2_ROUTER, quoteAmount);
        (,, lpAmount) = IUniswapV2Router(Constants.UNI_V2_ROUTER)
            .addLiquidity(Constants.WETH, quote, wethAmount, quoteAmount, 0, 0, user, block.timestamp + 300);
        vm.stopPrank();
    }

    /// @dev Deposit the caller's whole LP balance for `pair` and borrow a third of the allowance.
    function _depositAndBorrow(address user, address pair) internal returns (uint256 positionId, uint256 borrowed) {
        uint256 lpAmount = IUniswapV2Pair(pair).balanceOf(user);
        assertGt(lpAmount, 0, "no LP to deposit");

        vm.startPrank(user);
        IUniswapV2Pair(pair).approve(address(v2Adapter), lpAmount);
        positionId = positionManager.deposit(pair, 0, lpAmount, usdcBorrowAsset);
        vm.stopPrank();

        vm.roll(block.number + 2); // clear the deposit cooldown
        borrowed = lendingEngine.getMaxBorrow(positionId) / 3;
        vm.prank(user);
        lendingEngine.borrow(positionId, borrowed);
    }

    function test_wethDai_depositAndBorrowUsdc() public {
        _addLiquidity(alice, Constants.DAI, 1 ether, 4000e18);

        (uint256 positionId, uint256 borrowed) = _depositAndBorrow(alice, Constants.UNI_V2_WETH_DAI);

        assertGt(_getPositionValue(positionId), 0, "WETH/DAI LP priced at zero");
        assertGt(borrowed, 0, "no borrowing capacity against WETH/DAI");
        assertEq(_getDebt(positionId), borrowed, "debt should equal the amount borrowed");
        // The position is solvent right after borrowing a third of its allowance, and would not be
        // if the LP were being priced as if one leg were worthless.
        assertGt(_getHealthFactor(positionId), 1e18, "position unhealthy at one third of max borrow");
    }

    function test_wethUsdt_depositAndBorrowUsdc() public {
        _addLiquidity(alice, Constants.USDT, 1 ether, 4000e6);

        (uint256 positionId, uint256 borrowed) = _depositAndBorrow(alice, Constants.UNI_V2_WETH_USDT);

        assertGt(_getPositionValue(positionId), 0, "WETH/USDT LP priced at zero");
        assertGt(borrowed, 0, "no borrowing capacity against WETH/USDT");
        assertEq(_getDebt(positionId), borrowed, "debt should equal the amount borrowed");
        assertGt(_getHealthFactor(positionId), 1e18, "position unhealthy at one third of max borrow");
    }

    /// @notice Widening the accepted set did not widen it to every V2 pair.
    /// @dev WETH/WBTC is a real, liquid pair the adapter will happily lock; only the whitelist stands
    ///      between it and a position. Resolved from the factory rather than hardcoded, so this stays
    ///      a statement about the whitelist and not about an address transcribed here.
    function test_unlistedPairStillRefused() public {
        address pair = IUniswapV2Factory(Constants.UNI_V2_FACTORY).getPair(Constants.WETH, Constants.WBTC);
        assertTrue(pair != address(0), "WETH/WBTC pair missing from the fork");
        assertFalse(core.isLpPoolSupported(pair));

        deal(pair, alice, 1e15);
        vm.startPrank(alice);
        IUniswapV2Pair(pair).approve(address(v2Adapter), 1e15);
        vm.expectRevert("LP_POOL_NOT_SUPPORTED");
        positionManager.deposit(pair, 0, 1e15, usdcBorrowAsset);
        vm.stopPrank();
    }
}
