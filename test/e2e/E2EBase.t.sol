// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../helpers/ForkTestBase.sol";
import {INonfungiblePositionManager, IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3.sol";
import {IUniswapV2Pair, IUniswapV2Router} from "../../src/interfaces/external/IUniswapV2.sol";
import {ILPOracleHub} from "../../src/interfaces/ILPOracleHub.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Minimal WETH deposit interface
interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Uniswap V3 SwapRouter exactInputSingle interface (for whale dumps)
interface ISwapRouterSingle {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title E2EBase
/// @notice Base for end-to-end fork tests. Deploys full protocol + creates real LP positions.
/// @dev Inherits ForkTestBase (deploys all contracts). Adds helpers to create real V2/V3 positions.
///
///      Test accounts:
///        alice    — borrower (deposits LP, borrows)
///        bob      — lender (supplies USDC to market)
///        liquidator — liquidates underwater positions
///
///      LP positions are created against real Uniswap on forked mainnet.
abstract contract E2EBase is ForkTestBase {
    // V3 position helpers
    INonfungiblePositionManager public nftManager;

    // Funded test amounts
    uint256 constant ALICE_ETH = 10 ether;
    uint256 constant ALICE_USDC = 50_000e6;
    uint256 constant BOB_USDC = 100_000e6;
    uint256 constant LIQUIDATOR_USDC = 50_000e6;

    function setUp() public virtual override {
        super.setUp();
        nftManager = INonfungiblePositionManager(Constants.UNI_V3_NFT_MANAGER);

        // Fork may have stale Chainlink data — increase registry staleness tolerance
        vm.startPrank(deployer);
        priceFeedRegistry.setMaxStaleness(86_400); // 24h for fork testing
        vm.stopPrank();

        // Fund test accounts
        _fundWeth(alice, ALICE_ETH);
        _fundUsdc(alice, ALICE_USDC);
        _fundUsdc(bob, BOB_USDC);
        _fundUsdc(liquidator, LIQUIDATOR_USDC);

        // Bob supplies USDC to the market (provides borrowable liquidity)
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(marketAddr, BOB_USDC);
        IMarket(marketAddr).supply(BOB_USDC);
        vm.stopPrank();
    }

    // ========== V3 Position Helpers ==========

    /// @notice Create a real V3 WETH/USDC position on Uniswap
    /// @param user The user who will own the position
    /// @param wethAmount Amount of WETH to provide
    /// @param usdcAmount Amount of USDC to provide
    /// @return tokenId The V3 NFT position ID
    function _createV3Position(address user, uint256 wethAmount, uint256 usdcAmount)
        internal
        returns (uint256 tokenId)
    {
        vm.startPrank(user);

        IERC20(Constants.WETH).approve(address(nftManager), wethAmount);
        IERC20(Constants.USDC).approve(address(nftManager), usdcAmount);

        // Get current tick to create an in-range position
        IUniswapV3Pool pool = IUniswapV3Pool(Constants.UNI_V3_WETH_USDC_3000);
        (, int24 currentTick,,,,,) = pool.slot0();

        // Round tick to spacing (60 for 0.3% fee tier)
        int24 spacing = 60;
        int24 tickLower = ((currentTick - 1000) / spacing) * spacing;
        int24 tickUpper = ((currentTick + 1000) / spacing) * spacing;

        // Determine token ordering (USDC is token0 in WETH/USDC pool)
        address token0 = Constants.USDC < Constants.WETH ? Constants.USDC : Constants.WETH;
        address token1 = Constants.USDC < Constants.WETH ? Constants.WETH : Constants.USDC;
        uint256 amount0 = token0 == Constants.USDC ? usdcAmount : wethAmount;
        uint256 amount1 = token0 == Constants.USDC ? wethAmount : usdcAmount;

        (tokenId,,,) = nftManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: user,
                deadline: block.timestamp + 300
            })
        );

        vm.stopPrank();
    }

    /// @notice Deposit a V3 position into the protocol
    /// @return positionId The protocol position ID
    function _depositV3(address user, uint256 tokenId) internal returns (uint256 positionId) {
        vm.startPrank(user);

        // Approve NFT transfer to PositionManager (via adapter)
        nftManager.approve(address(v3Adapter), tokenId);

        // Deposit into protocol
        positionId = positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);

        vm.stopPrank();
    }

    // ========== V2 Position Helpers ==========

    /// @notice Create a real V2 WETH/USDC LP position
    /// @return lpAmount Amount of LP tokens received
    function _createV2Position(
        address user,
        uint256 wethAmount,
        uint256 usdcAmount
    )
        internal
        returns (uint256 lpAmount)
    {
        vm.startPrank(user);

        IUniswapV2Router router = IUniswapV2Router(Constants.UNI_V2_ROUTER);
        IERC20(Constants.WETH).approve(address(router), wethAmount);
        IERC20(Constants.USDC).approve(address(router), usdcAmount);

        (,, lpAmount) = router.addLiquidity(
            Constants.WETH, Constants.USDC, wethAmount, usdcAmount, 0, 0, user, block.timestamp + 300
        );

        vm.stopPrank();
    }

    /// @notice Deposit V2 LP tokens into the protocol
    /// @param marketId The market to deposit into (caller must pass the correct V2 market)
    function _depositV2(address user, uint256 lpAmount, uint256 marketId) internal returns (uint256 positionId) {
        vm.startPrank(user);

        IUniswapV2Pair pair = IUniswapV2Pair(Constants.UNI_V2_WETH_USDC);
        pair.approve(address(v2Adapter), lpAmount);

        positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, marketId);

        vm.stopPrank();
    }

    // ========== Price Manipulation Helpers ==========

    /// @notice Mock oracleHub.getPrice to return a specific USD value
    /// @dev Bypasses TWAP/Chainlink deviation checks — use for liquidation tests
    function _mockOraclePrice(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        ILPAdapter.LPType lpType,
        uint256 valueUsd
    )
        internal
    {
        vm.mockCall(
            address(oracleHub),
            abi.encodeWithSelector(ILPOracleHub.getPrice.selector, lpToken, tokenId, amount, lpType),
            abi.encode(
                ILPOracleHub.PriceResult({
                    totalValue: valueUsd,
                    principalValue: valueUsd,
                    feeValue: 0,
                    confidence: 9500,
                    timestamp: block.timestamp
                })
            )
        );
    }

    // ========== View Helpers ==========

    function _getDebt(uint256 positionId) internal view returns (uint256) {
        return lendingEngine.getDebt(positionId);
    }

    function _getPositionValue(uint256 positionId) internal view returns (uint256) {
        return positionManager.getPositionValue(positionId);
    }

    function _getHealthFactor(uint256 positionId) internal view returns (uint256) {
        return positionManager.getHealthFactor(positionId);
    }

    // ========== Real Price Crash Helper ==========

    /// @notice Crash ETH price by dumping WETH into the real Uniswap V3 pool, then mock Chainlink to match.
    /// @dev Steps:
    ///   1. Create a whale address, deal ETH, wrap to WETH
    ///   2. Swap WETH → USDC in the real 0.3% pool (crashes the pool price)
    ///   3. Advance time 35 min so 30-min TWAP fully absorbs the new price
    ///   4. Read the post-crash tick from pool.slot0()
    ///   5. Convert tick → ETH/USD price using TickMath
    ///   6. Mock Chainlink ETH/USD to return that exact price (USDC/USD stays ~$1)
    ///   This ensures TWAP ≈ Chainlink within the 3% deviation tolerance.
    /// @param dumpAmountEth Amount of ETH to dump (e.g. 5000 ether for a big crash)
    /// @return crashedEthPrice The ETH/USD price (8 decimals) that Chainlink now returns
    function _crashEthPrice(uint256 dumpAmountEth) internal returns (int256 crashedEthPrice) {
        // Step 1-2: Dump WETH into the pool (separate function to reduce stack)
        _dumpWethIntoPool(dumpAmountEth);

        // Step 3: Advance time so TWAP absorbs the crash
        _advanceTime(35 minutes);

        // Step 4-5: Read pool price and convert to Chainlink format
        crashedEthPrice = _readPoolPriceAsChainlink();

        // Step 6: Mock Chainlink feeds
        _mockChainlinkFeeds(crashedEthPrice);

        console.log("=== ETH Price Crash ===");
        console.log("  Dump amount:    %s ETH", dumpAmountEth / 1e18);
        console.log("  Chainlink mock:  $%s (8 dec)", uint256(crashedEthPrice));
    }

    /// @dev Dump WETH into the WETH/USDC 0.3% pool to crash the price
    function _dumpWethIntoPool(uint256 dumpAmountEth) internal {
        address whale = makeAddr("ethDumpWhale");
        vm.deal(whale, dumpAmountEth + 1 ether);
        vm.startPrank(whale);
        IWETH(Constants.WETH).deposit{value: dumpAmountEth}();
        IWETH(Constants.WETH).approve(Constants.UNI_V3_SWAP_ROUTER, dumpAmountEth);
        _swapExactSingle(Constants.WETH, Constants.USDC, 3000, dumpAmountEth, whale);
        vm.stopPrank();
    }

    /// @dev Single-hop exact input swap via Uniswap V3 SwapRouter
    function _swapExactSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        address recipient
    )
        internal
        returns (uint256)
    {
        return ISwapRouterSingle(Constants.UNI_V3_SWAP_ROUTER)
            .exactInputSingle(
                ISwapRouterSingle.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                deadline: block.timestamp + 300,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
            );
    }

    /// @dev Read current pool sqrtPriceX96 and convert to Chainlink 8-decimal ETH/USD
    function _readPoolPriceAsChainlink() internal view returns (int256) {
        IUniswapV3Pool pool = IUniswapV3Pool(Constants.UNI_V3_WETH_USDC_3000);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 priceX96 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), uint256(1) << 96);
        uint256 ethPriceUsd8 = Math.mulDiv(uint256(1) << 96, 1e20, priceX96);
        require(ethPriceUsd8 > 0, "Crashed price must be positive");
        return int256(ethPriceUsd8);
    }

    /// @dev Mock Chainlink feeds for ETH/USD and USDC/USD
    function _mockChainlinkFeeds(int256 ethPrice) internal {
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
