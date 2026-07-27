// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ILPOracle} from "../interfaces/ILPOracle.sol";
import {ILPOracleHub} from "../interfaces/ILPOracleHub.sol";
import {IUniswapV2Pair} from "../interfaces/external/IUniswapV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LPMath} from "../libraries/LPMath.sol";
import {PriceFeedRegistry} from "./PriceFeedRegistry.sol";

/// @title UniswapV2Oracle
/// @notice Prices Uniswap V2 LP tokens using sqrt(k) fair pricing + Chainlink
/// @dev Fair pricing formula (manipulation-resistant):
///      value = 2 * sqrt(reserve0 * reserve1) * sqrt(price0 * price1) * amount / (totalSupply * 1e18)
///      This is resistant to reserve manipulation because it uses the geometric mean
///      of reserves, not spot reserves directly.
///      See: https://blog.alphaventuredao.io/fair-lp-token-pricing/
///
///      Reserves are normalized to 18 decimals before sqrt(k) computation.
///      Chainlink prices are normalized to 18 decimals.
///      Result is in 18-decimal USD.
contract UniswapV2Oracle is ILPOracle {
    ProtocolCore public immutable core;
    PriceFeedRegistry public immutable priceFeedRegistry;

    constructor(address _core, address _priceFeedRegistry) {
        require(_core != address(0), "ZERO_CORE");
        require(_core.code.length > 0, "NOT_CONTRACT");
        require(_priceFeedRegistry != address(0), "ZERO_REGISTRY");
        require(_priceFeedRegistry.code.length > 0, "NOT_CONTRACT");
        core = ProtocolCore(_core);
        priceFeedRegistry = PriceFeedRegistry(_priceFeedRegistry);
    }

    // --- ILPOracle Implementation ---

    /// @inheritdoc ILPOracle
    /// @dev lpToken = V2 pair address, tokenId unused (0), amount = LP token amount
    function getPrice(
        address lpToken,
        uint256,
        uint256 amount
    )
        external
        view
        returns (ILPOracleHub.PriceResult memory result)
    {
        uint256 rawValue = _computePrice(lpToken, amount);

        // Return real market value (matches Aave/Revert approach)
        result = ILPOracleHub.PriceResult({
            totalValue: rawValue,
            principalValue: rawValue,
            feeValue: 0, // V2 fees auto-compound into reserves
            confidence: 10_000,
            timestamp: block.timestamp
        });
    }

    /// @inheritdoc ILPOracle
    function getRawPrice(address lpToken, uint256, uint256 amount) external view returns (uint256) {
        return _computePrice(lpToken, amount);
    }

    /// @inheritdoc ILPOracle
    /// @dev Always returns true — staleness is checked reactively inside priceFeedRegistry.getPrice()
    ///      on every getPrice() call (reverts if feed is stale). A proactive check here would
    ///      require on-chain Chainlink reads, adding gas to every deposit. Same pattern as Aave V3
    ///      which has no proactive oracle health gate.
    function isHealthy() external pure returns (bool) {
        return true;
    }

    // --- Internal ---

    /// @notice Compute fair LP value using sqrt(k) method
    /// @dev Normalizes reserves to 18 decimals before computation.
    ///      Uses Chainlink for token prices. All results in 18-decimal USD.
    function _computePrice(address lpToken, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        require(lpToken.code.length > 0, "NOT_CONTRACT");
        // Pool whitelist is enforced at deposit time (PositionManager), not here.
        // Oracle must price any position — including delisted pools — to enable liquidation.

        IUniswapV2Pair pair = IUniswapV2Pair(lpToken);
        (uint112 reserve0Raw, uint112 reserve1Raw,) = pair.getReserves();
        uint256 totalSupply = pair.totalSupply();

        if (totalSupply == 0) return 0;

        address token0 = pair.token0();
        address token1 = pair.token1();
        require(token0 != token1, "IDENTICAL_TOKENS");

        // Normalize reserves to 18 decimals
        // Note: totalSupply is passed raw — Uniswap V2 LP tokens are always 18 decimals,
        // matching the 18-dec normalized reserves. LPMath.fairLPValueV2 expects this.
        uint8 dec0 = IERC20(token0).decimals();
        uint8 dec1 = IERC20(token1).decimals();
        uint256 reserve0 = _normalizeTo18(uint256(reserve0Raw), dec0);
        uint256 reserve1 = _normalizeTo18(uint256(reserve1Raw), dec1);

        // Get prices from PriceFeedRegistry (18-decimal USD)
        uint256 price0 = priceFeedRegistry.getPrice(token0);
        uint256 price1 = priceFeedRegistry.getPrice(token1);

        // Fair LP value via sqrt(k) formula
        return LPMath.fairLPValueV2(reserve0, reserve1, totalSupply, price0, price1, amount);
    }

    /// @notice Normalize token amount to 18 decimals (overflow-safe)
    function _normalizeTo18(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        require(decimals <= 36, "INVALID_DECIMALS");
        if (decimals == 18) return amount;
        if (decimals < 18) return Math.mulDiv(amount, 10 ** (18 - decimals), 1);
        return amount / (10 ** (decimals - 18));
    }
}
