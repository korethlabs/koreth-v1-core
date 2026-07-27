// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract PriceConversionTest is Test {
    // WETH/USDC 0.3% pool on Ethereum mainnet
    address constant POOL = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;

    function setUp() public {
        // Fork mainnet
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpcUrl);
    }

    function test_sqrtPriceToEthUsd() public {
        IUniswapV3Pool pool = IUniswapV3Pool(POOL);

        // Verify token ordering
        address t0 = pool.token0();
        address t1 = pool.token1();
        emit log_named_address("token0", t0);
        emit log_named_address("token1", t1);

        // Read sqrtPriceX96
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        emit log_named_uint("sqrtPriceX96", uint256(sqrtPriceX96));

        // Uniswap V3: sqrtPriceX96 = sqrt(token1/token0) * 2^96
        // token0 = USDC (6 dec), token1 = WETH (18 dec)
        // price = sqrtPriceX96^2 / 2^192 = WETH_raw / USDC_raw
        //
        // ETH/USD (human) = USDC_human / WETH_human
        //                  = (USDC_raw * 10^-6) / (WETH_raw * 10^-18)
        //                  = (1 / price) * 10^12
        //                  = 10^12 * 2^192 / sqrtPriceX96^2
        //
        // Chainlink 8-dec: ethPriceUsd8 = 10^20 * 2^192 / sqrtPriceX96^2
        //
        // Split via mulDiv to avoid overflow:
        //   priceX96 = mulDiv(sqrtPriceX96, sqrtPriceX96, 2^96) = sqrtPriceX96^2 / 2^96
        //   ethPriceUsd8 = mulDiv(2^96, 10^20, priceX96) = 2^96 * 10^20 / priceX96

        uint256 priceX96 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), uint256(1) << 96);
        emit log_named_uint("priceX96", priceX96);

        uint256 ethPriceUsd8 = Math.mulDiv(uint256(1) << 96, 1e20, priceX96);
        emit log_named_uint("ethPriceUsd8", ethPriceUsd8);

        // Convert to human-readable for logging
        uint256 ethPriceWhole = ethPriceUsd8 / 1e8;
        uint256 ethPriceFrac = (ethPriceUsd8 % 1e8) / 1e4; // 4 decimal places
        emit log_named_uint("ETH price (whole $)", ethPriceWhole);
        emit log_named_uint("ETH price (frac, 4dp)", ethPriceFrac);

        // Sanity check: ETH should be between $1,000 and $10,000
        assertGt(ethPriceUsd8, 1000 * 1e8, "ETH price too low");
        assertLt(ethPriceUsd8, 10_000 * 1e8, "ETH price too high");
    }
}
