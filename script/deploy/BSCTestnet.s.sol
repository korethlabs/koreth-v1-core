// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployBase} from "../DeployBase.s.sol";

/// @title DeployBSCTestnet
/// @notice Deploy Koreth on BSC Testnet (PancakeSwap V2 — same interface as Uniswap V2)
/// @dev Run: forge script script/deploy/BSCTestnet.s.sol --rpc-url $BSC_TESTNET_RPC --broadcast --verify
contract DeployBSCTestnet is DeployBase {
    function _config() internal override returns (ChainConfig memory) {
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        return ChainConfig({
            // Roles
            deployer: deployer,
            guardian: deployer,
            riskAdmin: deployer,
            // V2 — PancakeSwap V2 on BSC Testnet
            v2Factory: 0x6725F303b657a9451d8BA641348b6761A6CC7a17,
            v2Router: 0xD99D1c33F9fC3444f8101754aBC46c52416550D1,
            // V3 — not deploying V3 on BSC testnet
            v3Factory: address(0),
            v3NftManager: address(0),
            // Tokens
            weth: 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd, // BSC Testnet WBNB
            stablecoin: 0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7, // BSC Testnet BUSD
            // Chainlink feeds (BSC Testnet)
            clNativeUsd: 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526, // BNB/USD
            clStablecoinUsd: 0x9331b55D9830EF609A2aBCfAc0FBCE050A52fdEa, // BUSD/USD
            // Pools — PancakeSwap V2 WBNB/BUSD pair
            v2Pool: 0xe0e92035077c39594793e61802a350347c320cf2, // WBNB/BUSD testnet
            v3Pool: address(0),
            // Market params
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            haircut: 500, // 5% discount on collateral value
            borrowCap: 100_000e18, // $100K (18-dec USD, not borrow-asset decimals)
            multisig: deployer,
            timelockDelay: 60 // 1 minute for testnet
        });
    }
}
