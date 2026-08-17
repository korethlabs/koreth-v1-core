// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILPOracle} from "../interfaces/ILPOracle.sol";
import {ILPOracleHub} from "../interfaces/ILPOracleHub.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {PriceFeedRegistry} from "./PriceFeedRegistry.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {INonfungiblePositionManager} from "../interfaces/external/IUniswapV3.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TickMathLib
/// @notice Computes sqrt price for ticks of size 1.0001 (Uniswap V3 canonical implementation)
library TickMathLib {
    int24 internal constant MIN_TICK = -887_272;
    int24 internal constant MAX_TICK = 887_272;
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(int256(MAX_TICK)), "T");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}

/// @title LiquidityAmountsLib
/// @notice Computes token amounts from liquidity and sqrt price ranges (Uniswap V3 canonical formulas)
/// @dev Uses OZ Math.mulDiv for overflow-safe 512-bit precision instead of custom assembly.
library LiquidityAmountsLib {
    function getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return Math.mulDiv(uint256(liquidity) << 96, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96) / sqrtRatioAX96;
    }

    function getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return Math.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, 1 << 96);
    }

    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }
}

/// @title UniswapV3Oracle
/// @notice Prices Uniswap V3 NFT positions from trusted Chainlink prices (manipulation-resistant).
/// @dev A V3 position is concentrated liquidity in [tickLower, tickUpper]; its token composition
///      depends on the current price. The manipulation-resistant way to value it is to derive that
///      composition from an EXTERNAL trusted price (Chainlink), NEVER from the pool's own tick
///      (a flash loan can move slot0; a slow attacker can drag a TWAP). This oracle therefore
///      builds the Uniswap sqrtPriceX96 from Chainlink feeds and feeds it to Uniswap's canonical
///      LiquidityAmounts math — the pool is never read for pricing.
///
///      The sqrtPriceX96 derivation mirrors MakerDAO's audited GUniLPOracle (ChainSecurity,
///      live in production). See _chainlinkSqrtPriceX96.
///
///      Why no TWAP + deviation cross-check anymore: a reverting consistency guard on the price
///      path is a liveness hazard — during a crash the pool TWAP lags Chainlink, the deviation
///      trips, and every liquidation reverts precisely when liquidations are needed, converting a
///      market move into avoidable bad debt (audit finding H-1). Battle-tested lenders (Aave,
///      Morpho) trust a single oracle for BOTH borrow and liquidation and never revert on a price
///      disagreement. Deriving composition from Chainlink removes the pool-price attack surface
///      entirely, so there is nothing left to cross-check.
///
/// Pricing flow:
///   1. Read position from NFT manager (token0, token1, tickLower, tickUpper, liquidity)
///   2. Price token0/token1 via Chainlink (18-dec USD, fail-closed in PriceFeedRegistry)
///   3. Derive the Chainlink-implied sqrtPriceX96 (no pool read)
///   4. Convert liquidity → token0/token1 amounts at that price (Uniswap LiquidityAmounts)
///   5. Normalize amounts to 18 decimals and value them in USD
///   6. Return principal-only value (uncollected fees are NOT collateral)
contract UniswapV3Oracle is ILPOracle {
    ProtocolCore public immutable core;
    INonfungiblePositionManager public immutable positionManager;

    constructor(address _core, address _positionManager) {
        require(_core != address(0) && _positionManager != address(0), "ZERO_ADDRESS");
        require(_core.code.length > 0 && _positionManager.code.length > 0, "NOT_CONTRACT");
        core = ProtocolCore(_core);
        positionManager = INonfungiblePositionManager(_positionManager);
    }

    /// @dev Resolve the price registry live from core rather than caching it. core.setPriceFeedRegistry
    ///      can rotate the registry, and every other consumer (LendingEngine, PositionManager,
    ///      LiquidationEngine, PoolLiquidityMonitor) already reads it per-call through the same getter;
    ///      an immutable snapshot here would silently price positions against a stale registry after a
    ///      rotation, diverging from the debt valuation. getPriceFeedRegistry() fails closed
    ///      (PRICE_REGISTRY_UNSET) and setPriceFeedRegistry enforces the registry is bound to this core,
    ///      so the per-call read inherits both guarantees.
    function _registry() internal view returns (PriceFeedRegistry) {
        return PriceFeedRegistry(core.getPriceFeedRegistry());
    }

    // --- ILPOracle Implementation ---

    /// @inheritdoc ILPOracle
    function getPrice(
        address lpToken,
        uint256 tokenId,
        uint256 /* amount */
    )
        external
        view
        returns (ILPOracleHub.PriceResult memory result)
    {
        require(lpToken == address(positionManager), "WRONG_LP_TOKEN");
        result = _computePrice(tokenId);
    }

    /// @inheritdoc ILPOracle
    function getRawPrice(
        address lpToken,
        uint256 tokenId,
        uint256 /* amount */
    )
        external
        view
        returns (uint256)
    {
        require(lpToken == address(positionManager), "WRONG_LP_TOKEN");
        ILPOracleHub.PriceResult memory result = _computePrice(tokenId);
        return result.principalValue + result.feeValue;
    }

    /// @inheritdoc ILPOracle
    /// @dev By design, always returns true. This is NOT a bug.
    ///      Price staleness and feed validity are enforced reactively inside
    ///      PriceFeedRegistry.getPrice() on every pricing call — if a feed is stale or
    ///      invalid, getPrice() reverts. A proactive health check here would duplicate
    ///      that logic, add gas to every deposit, and provide zero additional safety.
    ///      Same pattern as Aave V3 (no proactive oracle health gate).
    function isHealthy() external pure returns (bool) {
        return true;
    }

    // --- Internal: Core Pricing Logic ---

    /// @notice Value a Uniswap V3 NFT position — principal only, manipulation-resistant.
    /// @dev A V3 position is concentrated liquidity in [tickLower, tickUpper]; its token
    ///      composition depends on the current price, so it can't be valued like a fungible LP.
    ///      Methodology:
    ///        1. Read the position's range + liquidity from the NFT (uncollected fees ignored —
    ///           they are not collateral; they are swept to the borrower at liquidation).
    ///        2. Price token0/token1 with Chainlink (18-dec USD, fail-closed).
    ///        3. Derive the Chainlink-implied sqrtPriceX96 — the pool is never read, so there is
    ///           no manipulable pool price and no cross-check that could revert during a crash.
    ///        4. Convert liquidity → underlying token0/token1 amounts AT that price via Uniswap's
    ///           LiquidityAmounts math (below range → all token0; above → all token1; in → a mix).
    ///      Result: totalValue == principalValue (underlying tokens' USD value), feeValue == 0.
    /// @param tokenId The Uniswap V3 position NFT id
    /// @return result Price result with totalValue == principalValue and feeValue == 0
    function _computePrice(uint256 tokenId) internal view returns (ILPOracleHub.PriceResult memory result) {
        // Step 1: Read position data from NFT manager.
        // Uncollected fees (tokensOwed) are intentionally NOT read — they are not collateral.
        // Only the LP principal (liquidity) is valued; fees are the borrower's yield and are
        // swept to them at liquidation. This removes the fee-manipulation surface entirely.
        (,, address token0, address token1,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            positionManager.positions(tokenId);

        // Step 2: Get token decimals and Chainlink prices (both 18-dec USD, fail-closed).
        // safeDecimals wraps decimals() in try/catch (non-standard tokens revert cleanly) and
        // enforces the <= 36 bound, so a separate range check is no longer needed here.
        uint8 dec0 = TokenUtils.safeDecimals(token0);
        uint8 dec1 = TokenUtils.safeDecimals(token1);
        PriceFeedRegistry priceFeedRegistry = _registry();
        uint256 price0 = priceFeedRegistry.getPrice(token0); // 18 decimals USD
        uint256 price1 = priceFeedRegistry.getPrice(token1); // 18 decimals USD

        // Step 3: Derive the position's composition from the CHAINLINK-implied price, NOT the pool
        // tick. This is what makes valuation both manipulation-resistant (no pool state a flash
        // loan can move) and liquidation-safe (no consistency guard that can revert during a
        // crash — audit finding H-1). See _chainlinkSqrtPriceX96.
        uint160 sqrtPriceX96 = _chainlinkSqrtPriceX96(price0, price1, dec0, dec1);
        uint160 sqrtPriceAX96 = TickMathLib.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMathLib.getSqrtRatioAtTick(tickUpper);

        (uint256 amount0, uint256 amount1) =
            LiquidityAmountsLib.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity);

        // Step 4: Calculate principal value in USD (18 decimals).
        // amount0/amount1 are in token's native decimals — normalize to 18 before pricing.
        uint256 principalValue = Math.mulDiv(_normalizeTo18(amount0, dec0), price0, 1e18)
            + Math.mulDiv(_normalizeTo18(amount1, dec1), price1, 1e18);

        // Value = LP principal only. Uncollected fees are deliberately NOT counted as collateral
        // (they are the borrower's yield, swept to them at liquidation). This is conservative
        // (Aave-like: value the collateral asset, not speculative uncollected yield) and removes
        // the tokensOwed manipulation surface. Safety comes from LTV + threshold gap.
        result = ILPOracleHub.PriceResult({
            totalValue: principalValue,
            principalValue: principalValue,
            feeValue: 0,
            confidence: _computeConfidence(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96),
            timestamp: block.timestamp
        });
    }

    // --- Internal: Chainlink-implied price ---

    /// @notice Derive the Uniswap V3 sqrtPriceX96 implied by trusted Chainlink prices.
    /// @dev Manipulation-resistant core of the oracle: the position's composition is computed from
    ///      EXTERNAL prices, never from the pool's own (manipulable) tick. Mirrors MakerDAO's
    ///      audited GUniLPOracle.seek() (ChainSecurity, live in production).
    ///
    ///      The pool price P (token1 native per token0 native) implied by the two USD prices is
    ///        P = (price0 / price1) * 10^(dec1 - dec0)
    ///      and Uniswap encodes it as sqrtPriceX96 = sqrt(P) * 2^96. To preserve precision we take
    ///      the sqrt of a Q96-scaled value and shift the missing 2^48 back in, exactly like Maker:
    ///        sqrt(P * 2^96) * 2^48 == sqrt(P) * 2^96
    ///
    ///      Two deltas vs the Maker code, both hardening for a general-purpose position oracle:
    ///        - overflow-safe mulDiv for the pre-sqrt scaling (Maker uses checked mul on 0.6.12);
    ///        - an explicit [MIN_SQRT_RATIO, MAX_SQRT_RATIO] bound with revert (Maker relies only on
    ///          a uint160 cast). Fails closed: an implied price outside Uniswap's representable
    ///          range — which LiquidityAmounts math assumes — blocks pricing instead of guessing.
    /// @param price0 Chainlink USD price of token0 (18 decimals), must be > 0
    /// @param price1 Chainlink USD price of token1 (18 decimals), must be > 0
    /// @param dec0 token0 ERC20 decimals
    /// @param dec1 token1 ERC20 decimals
    /// @return sqrtPriceX96 The implied Uniswap sqrt price (Q64.96)
    function _chainlinkSqrtPriceX96(
        uint256 price0,
        uint256 price1,
        uint8 dec0,
        uint8 dec1
    )
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
        // Fail closed: a zero reference price is a broken invariant (PriceFeedRegistry reverts on
        // non-positive answers). Never derive a price from a zero input.
        require(price0 > 0 && price1 > 0, "ZERO_REF_PRICE");

        // Step 1: scaledX96 = (price0 / price1) * 2^96 (P scaled by 2^96, before decimals).
        // mulDiv keeps full 512-bit precision for the intermediate product.
        uint256 scaledX96 = Math.mulDiv(price0, 1 << 96, price1);

        // Step 2: apply the decimal factor 10^(dec1 - dec0). mulDiv reverts on 256-bit overflow
        // (fail-closed) for extreme decimal gaps.
        if (dec1 >= dec0) {
            scaledX96 = Math.mulDiv(scaledX96, 10 ** (dec1 - dec0), 1);
        } else {
            scaledX96 = scaledX96 / (10 ** (dec0 - dec1));
        }

        // Step 3: sqrt(P * 2^96) << 48 == sqrt(P) * 2^96 == sqrtPriceX96.
        uint256 result = Math.sqrt(scaledX96) << 48;

        // Fail closed: reject implied prices outside Uniswap's representable range. The downstream
        // LiquidityAmounts / TickMath math assumes the price sits in [MIN_SQRT_RATIO, MAX_SQRT_RATIO].
        require(result >= TickMathLib.MIN_SQRT_RATIO && result <= TickMathLib.MAX_SQRT_RATIO, "SQRT_PRICE_OUT_OF_RANGE");

        sqrtPriceX96 = uint160(result);
    }

    // --- Internal: Confidence ---

    /// @notice Compute oracle confidence based on position state (0-10000 bps).
    /// @dev Analytics only — NOT consumed in the pricing/valuation path. Measures how centered the
    ///      Chainlink-implied price sits within the position's range, in sqrt-price space.
    function _computeConfidence(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96
    )
        internal
        pure
        returns (uint256)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        // Out of range: all liquidity sits in a single token → 70% confidence.
        if (sqrtPriceX96 <= sqrtPriceAX96 || sqrtPriceX96 >= sqrtPriceBX96) {
            return 7000;
        }

        // In range: 80-100% based on how centered the price is within [A, B].
        uint256 span = uint256(sqrtPriceBX96) - uint256(sqrtPriceAX96);
        uint256 center = uint256(sqrtPriceAX96) + span / 2;
        uint256 distFromCenter =
            uint256(sqrtPriceX96) > center ? uint256(sqrtPriceX96) - center : center - uint256(sqrtPriceX96);
        uint256 halfSpan = span / 2;

        if (halfSpan == 0 || distFromCenter >= halfSpan) return 8000;
        uint256 centeredness = (halfSpan - distFromCenter) * 2000 / halfSpan;
        return 8000 + centeredness; // 8000-10000
    }

    // --- Internal: Helpers ---

    /// @notice Normalize a token amount to 18 decimals (overflow-safe)
    function _normalizeTo18(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals == 18) return amount;
        if (tokenDecimals < 18) return Math.mulDiv(amount, 10 ** (18 - tokenDecimals), 1);
        return amount / (10 ** (tokenDecimals - 18));
    }
}
