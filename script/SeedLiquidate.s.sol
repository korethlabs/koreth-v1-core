// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProtocolCore} from "../src/core/ProtocolCore.sol";
import {LiquidationEngine} from "../src/core/LiquidationEngine.sol";
import {Market} from "../src/markets/Market.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {ILPAdapter} from "../src/interfaces/ILPAdapter.sol";
import {IWETH, IUniswapV2SwapRouter} from "./local/ISeedExternal.sol";

/// @title SeedLiquidate
/// @notice Produces a liquidation for the demo: the deployer (still RISK_ADMIN on the local fork)
///         temporarily drops the V2->USDC market threshold so a borrowed position goes underwater,
///         a liquidator (account #5) fully liquidates it, then the config is restored. Result: one
///         LiquidationEvent + a `liquidated` position, with the market config back to normal.
/// @dev    Run last (after SeedBorrow): forge script script/SeedLiquidate.s.sol --broadcast
contract SeedLiquidate is Script {
    using stdJson for string;
    using SafeERC20 for IERC20;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // Seed order makes position #3 the one owned by account #2 (borrowed 8000 USDC).
    uint256 internal constant POSITION_ID = 3;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        // Anvil account #5 acts as the liquidator; key derived from SEED_MNEMONIC (env, from local .env).
        uint256 liquidatorKey = vm.deriveKey(vm.envString("SEED_MNEMONIC"), 5);
        address liquidator = vm.addr(liquidatorKey);

        string memory json = vm.readFile("./deployments/local.json");
        ProtocolCore core = ProtocolCore(json.readAddress(".core"));
        LiquidationEngine liqEngine = LiquidationEngine(json.readAddress(".liquidationEngine"));
        address marketAddr = _findMarket(core, ILPAdapter.LPType.UniswapV2, USDC);

        // 1. Deployer drops the threshold so the position is deeply underwater (full-liquidation zone).
        vm.startBroadcast(deployerKey);
        Market(marketAddr).updateConfig(50, 100, 500, 100_000e6);
        vm.stopBroadcast();

        (bool canLiq, uint256 maxRepay) = liqEngine.isLiquidatable(POSITION_ID);
        require(canLiq, "NOT_LIQUIDATABLE");

        // 2. Liquidator acquires USDC and liquidates the position in full.
        vm.startBroadcast(liquidatorKey);
        IWETH(WETH).deposit{value: 10 ether}();
        IERC20(WETH).forceApprove(V2_ROUTER, 10 ether);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        IUniswapV2SwapRouter(V2_ROUTER).swapExactTokensForTokens(10 ether, 0, path, liquidator, block.timestamp + 3600);
        IERC20(USDC).forceApprove(address(liqEngine), maxRepay);
        liqEngine.liquidate(POSITION_ID, maxRepay, block.timestamp + 3600, 0, 0);
        vm.stopBroadcast();

        // 3. Deployer restores the normal config (protects the other positions).
        vm.startBroadcast(deployerKey);
        Market(marketAddr).updateConfig(6500, 7500, 500, 100_000e6);
        vm.stopBroadcast();

        console.log("=== Liquidation complete ===");
        console.log("Liquidated position:", POSITION_ID);
        console.log("Repaid (USDC):      ", maxRepay);
    }

    function _findMarket(
        ProtocolCore core,
        ILPAdapter.LPType lpType,
        address borrowAsset
    )
        internal
        view
        returns (address addr)
    {
        uint256 count = core.nextMarketId();
        for (uint256 i = 0; i < count; i++) {
            address m = core.markets(i);
            if (m == address(0)) continue;
            IMarket.MarketConfig memory cfg = IMarket(m).getConfig();
            if (cfg.lpType == lpType && cfg.borrowAsset == borrowAsset) return m;
        }
        revert("MARKET_NOT_FOUND");
    }
}
