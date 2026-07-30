// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProtocolCore} from "../src/core/ProtocolCore.sol";
import {ILendingPool} from "../src/interfaces/ILendingPool.sol";
import {IPositionManager} from "../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../src/interfaces/ILPAdapter.sol";
import {IUniswapV2Pair, IUniswapV2Router} from "../src/interfaces/external/IUniswapV2.sol";
import {IWETH, IUniswapV2SwapRouter} from "./local/ISeedExternal.sol";

/// @title SeedLocal
/// @notice Seeds a locally-deployed Koreth (mainnet fork): supplies lender liquidity to every
///         market (USDC/USDT/DAI) and opens the deployer's LP collateral position. Every step is a
///         real tx from the anvil dev EOA (cheatcode balance edits do NOT persist to the node, so
///         we genuinely acquire the tokens by wrapping ETH and swapping on Uniswap V2).
/// @dev    Borrow is a SEPARATE script (SeedBorrow) because the borrow cooldown needs blocks mined
///         after the deposit, and forge simulates a whole script at one block height.
///           forge script script/SeedLocal.s.sol --rpc-url http://localhost:8545 --broadcast
contract SeedLocal is Script {
    using stdJson for string;
    using SafeERC20 for IERC20;

    // Mainnet addresses (must match DeployLocal)
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant V2_PAIR = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc; // WETH/USDC

    // Seed amounts. Swap generously; supply amounts are derived from actual balances so the script
    // is robust to the fork's ETH price instead of hardcoding USD figures.
    uint256 internal constant WRAP_ETH = 95 ether;
    uint256 internal constant SWAP_USDC = 40 ether; // WETH -> USDC (LP + both USDC markets)
    uint256 internal constant SWAP_USDT = 20 ether; // WETH -> USDT
    uint256 internal constant SWAP_DAI = 20 ether; // WETH -> DAI
    uint256 internal constant LP_WETH = 10 ether; // WETH into the collateral LP

    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(key);

        string memory json = vm.readFile("./deployments/local.json");
        ProtocolCore core = ProtocolCore(json.readAddress(".core"));
        IPositionManager positionManager = IPositionManager(json.readAddress(".positionManager"));

        // Shared-pool model: one lending pool per borrow asset (collateral type is not part of the key).
        address usdcPoolAddr = core.getPool(USDC);
        address usdtPoolAddr = core.getPool(USDT);
        address daiPoolAddr = core.getPool(DAI);
        address adapter = core.adapters(ILPAdapter.LPType.UniswapV2);
        require(adapter != address(0), "NO_V2_ADAPTER");

        uint256 deadline = block.timestamp + 3600;

        vm.startBroadcast(key);

        // 1. Wrap ETH -> WETH, then acquire each stablecoin via Uniswap V2 swaps.
        IWETH(WETH).deposit{value: WRAP_ETH}();
        _swap(USDC, SWAP_USDC, me, deadline);
        _swap(USDT, SWAP_USDT, me, deadline);
        _swap(DAI, SWAP_DAI, me, deadline);

        // 2. Add V2 liquidity -> LP tokens (router pulls ratio-optimal USDC <= balance).
        uint256 usdcForLp = IERC20(USDC).balanceOf(me);
        IERC20(WETH).forceApprove(V2_ROUTER, LP_WETH);
        IERC20(USDC).forceApprove(V2_ROUTER, usdcForLp);
        IUniswapV2Router(V2_ROUTER).addLiquidity(WETH, USDC, LP_WETH, usdcForLp, 0, 0, me, deadline);

        // 3. Supply lender liquidity to every pool.
        _supply(usdcPoolAddr, USDC, IERC20(USDC).balanceOf(me));
        _supply(usdtPoolAddr, USDT, IERC20(USDT).balanceOf(me));
        _supply(daiPoolAddr, DAI, IERC20(DAI).balanceOf(me));

        // 4. Deposit LP as collateral, borrowing against the shared USDC pool (adapter pulls the LP).
        uint256 lpBal = IUniswapV2Pair(V2_PAIR).balanceOf(me);
        require(lpBal > 0, "NO_LP");
        IUniswapV2Pair(V2_PAIR).approve(adapter, lpBal);
        uint256 positionId = positionManager.deposit(V2_PAIR, 0, lpBal, USDC);

        vm.stopBroadcast();

        console.log("=== Seed (supply + collateral) complete ===");
        console.log("USDC pool:       ", usdcPoolAddr);
        console.log("LP deposited:    ", lpBal);
        console.log("positionId:      ", positionId);
        console.log("Next: SeedUsers, then SeedBorrow (after cooldown)");
    }

    function _swap(address tokenOut, uint256 amountIn, address to, uint256 deadline) internal {
        IERC20(WETH).forceApprove(V2_ROUTER, amountIn);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = tokenOut;
        IUniswapV2SwapRouter(V2_ROUTER).swapExactTokensForTokens(amountIn, 0, path, to, deadline);
    }

    function _supply(address pool, address asset, uint256 amount) internal {
        require(amount > 0, "NOTHING_TO_SUPPLY");
        IERC20(asset).forceApprove(pool, amount);
        ILendingPool(pool).supply(amount);
    }
}
