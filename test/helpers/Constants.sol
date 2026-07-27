// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Constants
/// @notice Mainnet addresses for fork testing
/// @dev These are real deployed contract addresses on Ethereum mainnet.
///      Update if testing against a different chain.
library Constants {
    // --- Tokens ---
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    // --- Uniswap V3 ---
    address constant UNI_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant UNI_V3_NFT_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNI_V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // --- Uniswap V2 ---
    address constant UNI_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // --- Curve ---
    address constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address constant CURVE_3POOL_LP = 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;
    address constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address constant CURVE_REGISTRY = 0x90E00ACe148ca3b23Ac1bC8C240C2a7Dd9c2d7f5;

    // --- Chainlink Price Feeds (ETH mainnet) ---
    address constant CL_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant CL_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CL_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant CL_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address constant CL_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;

    // --- Uniswap V3 Pools (high liquidity) ---
    address constant UNI_V3_WETH_USDC_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // 0.05% fee
    address constant UNI_V3_WETH_USDC_3000 = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8; // 0.3% fee
    address constant UNI_V3_WBTC_WETH_3000 = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD;

    // --- Uniswap V2 Pairs ---
    address constant UNI_V2_WETH_USDC = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
    address constant UNI_V2_WETH_DAI = 0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11;

    // --- Whales (for impersonation in tests) ---
    address constant WETH_WHALE = 0xF04a5cC80B1E94C69B48f5ee68a08CD2F09A7c3E;
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    address constant DAI_WHALE = 0x60FaAe176336dAb62e284Fe19B885B095d29fB7F;
}
