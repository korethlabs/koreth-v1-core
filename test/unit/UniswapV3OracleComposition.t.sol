// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {UniswapV3Oracle} from "../../src/oracle/UniswapV3Oracle.sol";
import {PriceFeedRegistry} from "../../src/oracle/PriceFeedRegistry.sol";
import {ILPOracleHub} from "../../src/interfaces/ILPOracleHub.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockConstantFeed} from "../mocks/MockConstantFeed.sol";

/// @notice Mock Uniswap V3 NFT manager with a single configurable position.
/// @dev The oracle only reads token0/token1/ticks/liquidity from positions(); everything else is 0.
contract MockNFTManagerV3 {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;

    function setPosition(
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity
    )
        external
    {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        liquidity = _liquidity;
    }

    function positions(uint256)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        return (0, address(0), token0, token1, fee, tickLower, tickUpper, liquidity, 0, 0, 0, 0);
    }
}

/// @notice Harness exposing the internal Chainlink-implied sqrtPrice helper.
contract UniswapV3OracleHarness is UniswapV3Oracle {
    constructor(
        address _core,
        address _positionManager,
        address _priceFeedRegistry
    )
        UniswapV3Oracle(_core, _positionManager, _priceFeedRegistry)
    {}

    function exposed_chainlinkSqrtPriceX96(
        uint256 price0,
        uint256 price1,
        uint8 dec0,
        uint8 dec1
    )
        external
        pure
        returns (uint160)
    {
        return _chainlinkSqrtPriceX96(price0, price1, dec0, dec1);
    }
}

/// @title UniswapV3OracleCompositionTest
/// @notice Unit tests for the Chainlink-derived composition oracle (H-1 fix).
/// @dev The oracle derives a V3 position's token split from TRUSTED Chainlink prices, never from
///      the pool tick. Consequences these tests pin down:
///        - there is no pool read, so no manipulation surface and no consistency guard that can
///          revert during a crash (the H-1 failure mode);
///        - a below-range position is pure token0 (price1-independent), an above-range position is
///          pure token1 (price0-independent);
///        - the implied sqrtPrice mirrors MakerDAO's GUniLPOracle arithmetic and fails closed
///          outside Uniswap's representable range.
contract UniswapV3OracleCompositionTest is Test {
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2^96

    ProtocolCore internal core;
    PriceFeedRegistry internal registry;
    UniswapV3OracleHarness internal oracle;
    MockNFTManagerV3 internal nft;

    MockERC20 internal token0; // 6 dec (USDC-like)
    MockERC20 internal token1; // 18 dec (WETH-like)
    MockConstantFeed internal feed0;
    MockConstantFeed internal feed1;

    address internal owner = makeAddr("owner");

    function setUp() public {
        ACLManager acl = new ACLManager(owner);
        core = new ProtocolCore(owner, address(acl));

        token0 = new MockERC20("USD Coin", "USDC", 6);
        token1 = new MockERC20("Wrapped Ether", "WETH", 18);

        // Chainlink-shaped feeds report 18-dec USD prices: $1 and $2000.
        feed0 = new MockConstantFeed(1e18);
        feed1 = new MockConstantFeed(2000e18);

        vm.startPrank(owner);
        registry = new PriceFeedRegistry(address(core));
        registry.setPriceFeed(address(token0), address(feed0));
        registry.setPriceFeed(address(token1), address(feed1));
        vm.stopPrank();

        nft = new MockNFTManagerV3();
        oracle = new UniswapV3OracleHarness(address(core), address(nft), address(registry));
    }

    function _price(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    )
        internal
        returns (ILPOracleHub.PriceResult memory)
    {
        nft.setPosition(address(token0), address(token1), 500, tickLower, tickUpper, liquidity);
        return oracle.getPrice(address(nft), 1, 0);
    }

    // ===================== _chainlinkSqrtPriceX96 arithmetic =====================

    /// @dev Equal 18-dec prices ⇒ P = 1 ⇒ sqrtPriceX96 = 2^96, exactly.
    function test_sqrtPrice_equalPrices_is2pow96() public view {
        uint160 s = oracle.exposed_chainlinkSqrtPriceX96(1e18, 1e18, 18, 18);
        assertEq(uint256(s), Q96, "P=1 must give sqrtPriceX96 = 2^96");
    }

    /// @dev Equal USD prices but a 6/18 decimal gap ⇒ P = 10^12 ⇒ sqrtPriceX96 = 10^6 * 2^96, exactly.
    function test_sqrtPrice_decimalGap_exact() public view {
        uint160 s = oracle.exposed_chainlinkSqrtPriceX96(1e18, 1e18, 6, 18);
        assertEq(uint256(s), 1e6 * Q96, "10^12 price ratio must give 10^6 * 2^96");
    }

    /// @dev Squaring the implied sqrtPrice recovers P = (price0*10^dec1)/(price1*10^dec0).
    function test_sqrtPrice_squaresBackToRatio() public view {
        // token0=USDC(6,$1), token1=WETH(18,$2000): P = (1e18 * 1e18)/(2000e18 * 1e6) = 5e8.
        uint160 s = oracle.exposed_chainlinkSqrtPriceX96(1e18, 2000e18, 6, 18);
        uint256 pRecovered = Math_mulDiv(uint256(s), uint256(s), Q96 * Q96);
        assertApproxEqRel(pRecovered, 5e8, 1e12, "recovered pool price should be ~5e8"); // 1e-6 tol
    }

    function test_sqrtPrice_zeroPrice0_reverts() public {
        vm.expectRevert("ZERO_REF_PRICE");
        oracle.exposed_chainlinkSqrtPriceX96(0, 1e18, 18, 18);
    }

    function test_sqrtPrice_zeroPrice1_reverts() public {
        vm.expectRevert("ZERO_REF_PRICE");
        oracle.exposed_chainlinkSqrtPriceX96(1e18, 0, 18, 18);
    }

    /// @dev An absurdly high implied price lands above MAX_SQRT_RATIO ⇒ fail closed.
    function test_sqrtPrice_aboveMax_reverts() public {
        vm.expectRevert("SQRT_PRICE_OUT_OF_RANGE");
        oracle.exposed_chainlinkSqrtPriceX96(126e39, 1, 18, 18);
    }

    /// @dev An absurdly low implied price underflows to 0 (< MIN_SQRT_RATIO) ⇒ fail closed.
    function test_sqrtPrice_belowMin_reverts() public {
        vm.expectRevert("SQRT_PRICE_OUT_OF_RANGE");
        oracle.exposed_chainlinkSqrtPriceX96(1, 1e30, 18, 18);
    }

    // ===================== Composition & valuation =====================

    /// @dev In-range position (implied tick ~200330 for USDC/WETH at $1/$2000) prices to a positive
    ///      value with high confidence.
    function test_inRange_pricesPositive() public {
        ILPOracleHub.PriceResult memory r = _price(190_000, 210_000, 1e12);
        assertGt(r.totalValue, 0, "in-range value must be positive");
        assertEq(r.principalValue, r.totalValue, "totalValue == principalValue");
        assertEq(r.feeValue, 0, "fees are never collateral");
        assertGe(r.confidence, 8000, "in-range confidence >= 80%");
    }

    /// @dev Below range ⇒ all token0. Value must NOT depend on token1's price at all.
    function test_belowRange_independentOfToken1Price() public {
        // Implied tick ~200311 for USDC/WETH at $1/$2000. A range far ABOVE that (tickLower=300000)
        // puts the current price below the range ⇒ the position holds only token0 (USDC).
        nft.setPosition(address(token0), address(token1), 500, 300_000, 320_000, 1e12);
        uint256 vA = oracle.getPrice(address(nft), 1, 0).totalValue;

        // Halve token1 price; a below-range (all token0) position must be unaffected.
        feed1.setAnswer(1000e18);
        uint256 vB = oracle.getPrice(address(nft), 1, 0).totalValue;

        assertEq(vA, vB, "below-range value must be independent of token1 price");
        assertGt(vA, 0, "value must be positive");
    }

    /// @dev Above range ⇒ all token1. Value must NOT depend on token0's price at all.
    function test_aboveRange_independentOfToken0Price() public {
        // Range far BELOW the implied tick (~200330) ⇒ price above range ⇒ all token1.
        nft.setPosition(address(token0), address(token1), 500, 100_000, 120_000, 1e12);
        uint256 vA = oracle.getPrice(address(nft), 1, 0).totalValue;

        // Move token0 (USDC) price; an all-token1 position must be unaffected.
        feed0.setAnswer(2e18);
        uint256 vB = oracle.getPrice(address(nft), 1, 0).totalValue;

        assertEq(vA, vB, "above-range value must be independent of token0 price");
        assertGt(vA, 0, "value must be positive");
    }

    /// @dev H-1 liveness: a large Chainlink move (crash or spike) must never revert pricing. There
    ///      is no pool cross-check left to trip — liquidation stays live.
    function test_crashDoesNotRevert() public {
        nft.setPosition(address(token0), address(token1), 500, 190_000, 210_000, 1e12);
        uint256 vBase = oracle.getPrice(address(nft), 1, 0).totalValue;

        feed1.setAnswer(200e18); // WETH crashes 10x
        uint256 vCrash = oracle.getPrice(address(nft), 1, 0).totalValue;
        assertGt(vCrash, 0, "must still price after a crash");

        feed1.setAnswer(20_000e18); // WETH spikes 10x
        uint256 vSpike = oracle.getPrice(address(nft), 1, 0).totalValue;
        assertGt(vSpike, 0, "must still price after a spike");

        // Sanity: the position is monotone in the WETH price it holds.
        assertLt(vCrash, vBase, "crash lowers value");
        assertGt(vSpike, vBase, "spike raises value");
    }

    /// @dev The oracle reads NO pool state, so composition is a pure function of Chainlink + NFT
    ///      data. Demonstrated by: value changes only when a feed changes, deterministically.
    function test_valueIsPureFunctionOfFeedsAndNft() public {
        nft.setPosition(address(token0), address(token1), 500, 190_000, 210_000, 1e12);
        uint256 v1 = oracle.getPrice(address(nft), 1, 0).totalValue;
        uint256 v2 = oracle.getPrice(address(nft), 1, 0).totalValue;
        assertEq(v1, v2, "same inputs give same value (no external pool state)");
    }

    /// @dev Larger liquidity ⇒ proportionally larger value at a fixed price.
    function test_valueScalesWithLiquidity() public {
        uint256 vSmall = _price(190_000, 210_000, 1e12).totalValue;
        uint256 vLarge = _price(190_000, 210_000, 2e12).totalValue;
        assertApproxEqRel(vLarge, vSmall * 2, 1e12, "value should roughly double with 2x liquidity");
    }

    // ===================== helpers =====================

    /// @dev Local mulDiv to recover P from sqrtPriceX96 without importing OZ into the test.
    function Math_mulDiv(uint256 a, uint256 b, uint256 denom) internal pure returns (uint256) {
        // Small operands here (sqrtPriceX96 ~ 1e33, product ~ 1e66 < 2^256), so a plain path is safe.
        return (a * b) / denom;
    }
}
