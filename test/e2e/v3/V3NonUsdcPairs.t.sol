// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IUniswapV3Factory} from "../../../src/interfaces/external/IUniswapV3.sol";
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title V3NonUsdcPairs
/// @notice End-to-end pricing of a Uniswap V3 position whose token0 is the 18-decimal leg.
/// @dev Uniswap orders a pool's tokens by address, and on mainnet
///      DAI (0x6B17…) < USDC (0xA0b8…) < WETH (0xC02a…) < USDT (0xdAC1…).
///      WETH/USDT is therefore the only whitelisted pool where WETH is token0, and so the only one
///      that reaches the oracle's `dec0 > dec1` path — everywhere else the stablecoin sorts first and
///      the decimal gap runs the other way.
///
///      That asymmetry matters because two independent pieces of arithmetic change shape with it:
///      the decimal correction inside the Chainlink-implied sqrtPrice, and `getAmountsForLiquidity`,
///      which returns token0 below the range and token1 above it. A sign error or a copied branch in
///      either would leave every WETH/USDC position correct and only misprice this one — collateral
///      valued from the wrong side of the range, which is not a failure that announces itself.
///
///      These tests exist as regression insurance, not because anything is known to be wrong: the
///      path measures correct here to under two thousandths of a percent. Their job is to make a
///      later change that breaks it fail loudly instead of silently.
contract V3NonUsdcPairs is E2EBase {
    using SafeERC20 for OZIERC20;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    /// @dev The oracle derives the position's composition from Chainlink, while Uniswap consumed
    ///      tokens at the pool's own price, so the two agree only as far as those prices agree. At
    ///      the pinned fork block that basis measures 0.0017% on WETH/USDC and 0.0018% on WETH/USDT
    ///      — well under a basis point, and the floor this band has to clear.
    ///
    ///      The ceiling is set by how large a real mistake can look, and that is smaller than it
    ///      first appears. An implied price that is wrong by orders of magnitude does not produce a
    ///      value wrong by orders of magnitude: it pushes the position outside its own range, where
    ///      the whole position converts to a single token and the error stops growing. So the
    ///      observable damage is bounded by the width of the range, not by the size of the arithmetic
    ///      error. Inverting the decimal correction — a 10^12 error in the implied price — moves the
    ///      reported value of these ±1000-tick positions by only 2.6%.
    ///
    ///      0.1% sits with roughly fifty times headroom above the honest deviation and twenty-five
    ///      times below the smallest breakage worth catching. Widening it towards a percent would
    ///      start to let that breakage through.
    uint256 internal constant VALUE_TOLERANCE = 1e15; // 0.1%

    /// @dev Grouped so the three mint results travel as one value; returned separately they push
    ///      the calling tests over the stack limit under via-ir.
    struct Position {
        uint256 tokenId;
        uint256 used0;
        uint256 used1;
    }

    // ========== Premise ==========

    /// @notice The pool this file is built around really is the one with the roles swapped, and the
    ///         other whitelisted V3 pools really are not.
    /// @dev Read from the pools rather than restated from the constants, so that if an address in
    ///      Constants is ever repointed at a different pair this fails instead of quietly testing the
    ///      ordinary ordering. Without it the rest of the file could keep passing while covering
    ///      nothing it was written to cover.
    ///
    ///      All three whitelisted V3 pools are checked, which is what makes "the only one" a
    ///      measured statement about the accepted set rather than an inference from four addresses.
    function test_wethUsdtIsTheOnlyWhitelistedV3PoolWithWethFirst() public view {
        IUniswapV3Pool wethUsdt = IUniswapV3Pool(Constants.UNI_V3_WETH_USDT_3000);
        assertEq(wethUsdt.token0(), Constants.WETH, "WETH must be token0 of the WETH/USDT pool");
        assertEq(wethUsdt.token1(), Constants.USDT, "USDT must be token1 of the WETH/USDT pool");

        // The other two, where the stablecoin sorts first and the decimal gap runs the usual way.
        IUniswapV3Pool wethUsdc = IUniswapV3Pool(Constants.UNI_V3_WETH_USDC_3000);
        assertEq(wethUsdc.token0(), Constants.USDC, "USDC must be token0 of the WETH/USDC pool");
        assertEq(wethUsdc.token1(), Constants.WETH, "WETH must be token1 of the WETH/USDC pool");

        IUniswapV3Pool wethDai = IUniswapV3Pool(Constants.UNI_V3_WETH_DAI_3000);
        assertEq(wethDai.token0(), Constants.DAI, "DAI must be token0 of the WETH/DAI pool");
        assertEq(wethDai.token1(), Constants.WETH, "WETH must be token1 of the WETH/DAI pool");
    }

    // ========== Pricing ==========

    /// @notice The case with WETH as token0: `getRawPrice` must match what Uniswap actually took.
    function test_getRawPrice_wethUsdt_matchesTokensConsumed() public {
        Position memory pos = _mintPosition(alice, Constants.USDT, 1 ether, 4000e6);

        uint256 expected = _usdValue(Constants.WETH, 18, pos.used0) + _usdValue(Constants.USDT, 6, pos.used1);
        uint256 reported = v3Oracle.getRawPrice(Constants.UNI_V3_NFT_MANAGER, pos.tokenId, 0);

        assertGt(expected, 0, "mint consumed nothing, so there is nothing to compare against");
        assertApproxEqRel(reported, expected, VALUE_TOLERANCE, "WETH/USDT position mispriced");
    }

    /// @notice The ordinary ordering, priced the same way.
    /// @dev The control half of the pair. The two tests share every line of the oracle except the
    ///      decimal branch and the token roles, so if a regression takes this one down as well the
    ///      cause is somewhere common and not in the swapped-role handling.
    function test_getRawPrice_wethUsdc_matchesTokensConsumed() public {
        Position memory pos = _mintPosition(alice, Constants.USDC, 1 ether, 4000e6);

        uint256 expected = _usdValue(Constants.USDC, 6, pos.used0) + _usdValue(Constants.WETH, 18, pos.used1);
        uint256 reported = v3Oracle.getRawPrice(Constants.UNI_V3_NFT_MANAGER, pos.tokenId, 0);

        assertGt(expected, 0, "mint consumed nothing, so there is nothing to compare against");
        assertApproxEqRel(reported, expected, VALUE_TOLERANCE, "WETH/USDC position mispriced");
    }

    // ========== Protocol path ==========

    /// @notice A WETH/USDT position carries real borrowing capacity against the USDC pool.
    /// @dev Pricing correctly is necessary but not sufficient: the value still has to travel through
    ///      deposit, collateral accounting and the borrow allowance. Neither leg of this collateral
    ///      is the borrowed asset, so capacity here can only come from the LP's USD value.
    function test_wethUsdt_depositAndBorrowUsdc() public {
        Position memory pos = _mintPosition(alice, Constants.USDT, 1 ether, 4000e6);

        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), pos.tokenId);
        uint256 positionId = positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, pos.tokenId, 0, usdcBorrowAsset);
        vm.stopPrank();

        vm.roll(block.number + 2); // clear the deposit cooldown

        uint256 borrowed = lendingEngine.getMaxBorrow(positionId) / 3;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowed);

        assertGt(_getPositionValue(positionId), 0, "WETH/USDT position valued at zero as collateral");
        assertGt(borrowed, 0, "no borrowing capacity against WETH/USDT");
        assertEq(_getDebt(positionId), borrowed, "debt should equal the amount borrowed");
        // Solvent at a third of the allowance, and would not be if one leg were being dropped.
        assertGt(_getHealthFactor(positionId), 1e18, "position unhealthy at one third of max borrow");
    }

    // ========== Helpers ==========

    /// @dev Mint a real in-range 0.3% position pairing WETH with `quote`, and report the amounts
    ///      Uniswap actually pulled. Those consumed amounts are the independent measurement the
    ///      oracle is checked against: they come from the pool's own math, not from ours.
    ///
    ///      forceApprove rather than approve because USDT's approve returns no data, so a plain call
    ///      through a `returns (bool)` interface reverts while decoding the empty return.
    function _mintPosition(
        address user,
        address quote,
        uint256 wethAmount,
        uint256 quoteAmount
    )
        internal
        returns (Position memory pos)
    {
        _fundWeth(user, wethAmount);
        deal(quote, user, quoteAmount);

        address pool = IUniswapV3Factory(Constants.UNI_V3_FACTORY).getPool(Constants.WETH, quote, FEE);
        require(pool != address(0), "pool missing from the fork");
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        // Both tokens must be held at the current price: a position sitting entirely in one token
        // exercises only one leg, and a mistake in the other one would not reach the total at all.
        // The width is also what bounds how large a mispricing can look — outside the range the
        // position converts fully to one token and any further error is absorbed — so it is what
        // VALUE_TOLERANCE is calibrated against.
        int24 tickLower = ((currentTick - 1000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = ((currentTick + 1000) / TICK_SPACING) * TICK_SPACING;

        bool wethIsToken0 = Constants.WETH < quote;

        vm.startPrank(user);
        OZIERC20(Constants.WETH).forceApprove(Constants.UNI_V3_NFT_MANAGER, wethAmount);
        OZIERC20(quote).forceApprove(Constants.UNI_V3_NFT_MANAGER, quoteAmount);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: wethIsToken0 ? Constants.WETH : quote,
            token1: wethIsToken0 ? quote : Constants.WETH,
            fee: FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: wethIsToken0 ? wethAmount : quoteAmount,
            amount1Desired: wethIsToken0 ? quoteAmount : wethAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: user,
            deadline: block.timestamp + 300
        });
        (pos.tokenId,, pos.used0, pos.used1) = nftManager.mint(params);
        vm.stopPrank();

        assertGt(pos.used0, 0, "position holds no token0, so it exercises only one leg");
        assertGt(pos.used1, 0, "position holds no token1, so it exercises only one leg");
    }

    /// @dev USD value of a raw token amount, at the same Chainlink feed the oracle reads.
    ///      Decimals are passed in rather than read from the token: they are the premise of these
    ///      tests, and USDT declares `decimals` as a uint256, which is exactly the kind of detail a
    ///      helper should not be quietly absorbing on the checking side of a comparison.
    function _usdValue(address token, uint8 tokenDecimals, uint256 amount) internal view returns (uint256) {
        uint256 amount18 = amount * (10 ** (18 - tokenDecimals));
        return Math.mulDiv(amount18, priceFeedRegistry.getPrice(token), 1e18);
    }
}
