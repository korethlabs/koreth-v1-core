// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Pair, IUniswapV2Router} from "../src/interfaces/external/IUniswapV2.sol";
import {IWETH, IUniswapV2SwapRouter} from "./local/ISeedExternal.sol";

/// @title SeedFaucet
/// @notice Leaves Uniswap V2 WETH/USDC LP tokens in anvil account #4 WITHOUT depositing them, so a
///         MetaMask user can import that account and test the /borrow deposit flow from the UI.
/// @dev    forge script script/SeedFaucet.s.sol --rpc-url http://localhost:8545 --broadcast
contract SeedFaucet is Script {
    using SafeERC20 for IERC20;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant V2_PAIR = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;

    function run() external {
        // Anvil account #4, key derived from SEED_MNEMONIC (env, from local .env — never hardcode).
        uint256 acct4Key = vm.deriveKey(vm.envString("SEED_MNEMONIC"), 4);
        address user = vm.addr(acct4Key);
        uint256 deadline = block.timestamp + 3600;

        vm.startBroadcast(acct4Key);

        IWETH(WETH).deposit{value: 20 ether}();

        // Swap 10 WETH -> USDC to pair against the other 10 WETH.
        IERC20(WETH).forceApprove(V2_ROUTER, 10 ether);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        IUniswapV2SwapRouter(V2_ROUTER).swapExactTokensForTokens(10 ether, 0, path, user, deadline);

        uint256 usdc = IERC20(USDC).balanceOf(user);
        IERC20(WETH).forceApprove(V2_ROUTER, 10 ether);
        IERC20(USDC).forceApprove(V2_ROUTER, usdc);
        IUniswapV2Router(V2_ROUTER).addLiquidity(WETH, USDC, 10 ether, usdc, 0, 0, user, deadline);

        vm.stopBroadcast();

        console.log("Faucet: LP left in account #4:", user);
        console.log("  LP balance:", IUniswapV2Pair(V2_PAIR).balanceOf(user));
    }
}
