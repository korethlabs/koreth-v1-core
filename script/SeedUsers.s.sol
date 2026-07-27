// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProtocolCore} from "../src/core/ProtocolCore.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IPositionManager} from "../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../src/interfaces/ILPAdapter.sol";
import {IUniswapV2Pair, IUniswapV2Router} from "../src/interfaces/external/IUniswapV2.sol";
import {IWETH, IUniswapV2SwapRouter} from "./local/ISeedExternal.sol";

/// @title SeedUsers
/// @notice Seeds collateral deposits for several distinct users (anvil accounts #1..#3) so the
///         subgraph/dashboard shows multiple positions with varied sizes. Each user acquires its
///         own LP (wrap ETH -> swap -> addLiquidity) and deposits it in its own broadcast.
/// @dev    Borrows are done separately (SeedBorrow) due to the deposit->borrow cooldown.
///           forge script script/SeedUsers.s.sol --rpc-url http://localhost:8545 --broadcast
contract SeedUsers is Script {
    using stdJson for string;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant V2_PAIR = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;

    function run() external {
        string memory json = vm.readFile("./deployments/local.json");
        ProtocolCore core = ProtocolCore(json.readAddress(".core"));
        address positionManager = json.readAddress(".positionManager");
        (uint256 marketId,) = _findV2Market(core);
        address adapter = core.adapters(ILPAdapter.LPType.UniswapV2);
        require(adapter != address(0), "NO_V2_ADAPTER");

        // Anvil accounts #1..#3, keys derived from SEED_MNEMONIC (env, from local .env —
        // never hardcode keys in tracked files).
        string memory mnemonic = vm.envString("SEED_MNEMONIC");
        uint256[3] memory keys = [vm.deriveKey(mnemonic, 1), vm.deriveKey(mnemonic, 2), vm.deriveKey(mnemonic, 3)];
        // Varied LP sizes so positions differ on the dashboard.
        uint256[3] memory lpWeth = [uint256(5 ether), 20 ether, 3 ether];
        uint256[3] memory swapWeth = [uint256(10 ether), 25 ether, 6 ether];
        uint256[3] memory wrapWeth = [uint256(16 ether), 46 ether, 10 ether];

        for (uint256 i = 0; i < keys.length; i++) {
            _seedUser(keys[i], wrapWeth[i], swapWeth[i], lpWeth[i], positionManager, adapter, marketId);
        }
    }

    function _seedUser(
        uint256 key,
        uint256 wrapEth,
        uint256 swapWethAmt,
        uint256 lpWethAmt,
        address positionManager,
        address adapter,
        uint256 marketId
    )
        internal
    {
        address user = vm.addr(key);
        uint256 deadline = block.timestamp + 3600;

        vm.startBroadcast(key);

        IWETH(WETH).deposit{value: wrapEth}();

        // WETH -> USDC
        IERC20(WETH).approve(V2_ROUTER, swapWethAmt);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        IUniswapV2SwapRouter(V2_ROUTER).swapExactTokensForTokens(swapWethAmt, 0, path, user, deadline);

        // Add liquidity (router pulls the ratio-optimal USDC <= balance)
        uint256 usdcBal = IERC20(USDC).balanceOf(user);
        IERC20(WETH).approve(V2_ROUTER, lpWethAmt);
        IERC20(USDC).approve(V2_ROUTER, usdcBal);
        IUniswapV2Router(V2_ROUTER).addLiquidity(WETH, USDC, lpWethAmt, usdcBal, 0, 0, user, deadline);

        // Deposit LP as collateral
        uint256 lpBal = IUniswapV2Pair(V2_PAIR).balanceOf(user);
        require(lpBal > 0, "NO_LP");
        IUniswapV2Pair(V2_PAIR).approve(adapter, lpBal);
        uint256 positionId = IPositionManager(positionManager).deposit(V2_PAIR, 0, lpBal, marketId);

        vm.stopBroadcast();

        console.log("user", user);
        console.log("  positionId", positionId);
        console.log("  LP", lpBal);
    }

    function _findV2Market(ProtocolCore core) internal view returns (uint256 id, address addr) {
        uint256 count = core.nextMarketId();
        for (uint256 i = 0; i < count; i++) {
            address m = core.markets(i);
            if (m == address(0)) continue;
            IMarket.MarketConfig memory cfg = IMarket(m).getConfig();
            if (cfg.lpType == ILPAdapter.LPType.UniswapV2 && cfg.borrowAsset == USDC) {
                return (i, m);
            }
        }
        revert("V2_MARKET_NOT_FOUND");
    }
}
