// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployBase} from "../DeployBase.s.sol";

/// @title DeployBSCTestnet
/// @notice Deploy Koreth on BSC Testnet (PancakeSwap V2 — same interface as Uniswap V2)
/// @dev Run: forge script script/deploy/BSCTestnet.s.sol --rpc-url $BSC_TESTNET_RPC --broadcast --verify
contract DeployBSCTestnet is DeployBase {
    function _config() internal override returns (ChainConfig memory) {
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        // Required even on a testnet, where guardian is allowed to fall back to the deployer. A
        // role can be regranted once someone notices; a fee destination is where the money already
        // went. Naming them here is also what keeps the testnet exercising the same two-recipient
        // split production runs on, instead of a degenerate one that always passes.
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address insuranceFund = vm.envAddress("INSURANCE_FUND_ADDRESS");

        return ChainConfig({
            // Roles
            deployer: deployer,
            guardian: deployer,
            riskAdmin: deployer,
            treasury: treasury,
            insuranceFund: insuranceFund,
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
            // No sequencer on this chain — L1 and its testnets order their own blocks.
            clSequencerUptime: address(0),
            // Pools — PancakeSwap V2 WBNB/BUSD pair
            v2Pools: _pools(0xe0e92035077c39594793e61802a350347c320cf2), // WBNB/BUSD testnet
            v3Pools: new address[](0), // no V3 on BSC testnet
            // Market params
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            haircut: 500, // 5% discount on collateral value
            borrowCap: 100_000e18, // $100K (18-dec USD, not borrow-asset decimals)
            // $100 floor rather than mainnet's $10K. Testnet balances are faucet-sized, and the
            // floor binds repayment as much as borrowing, so a production-sized floor would leave
            // ordinary test positions unable to part-repay.
            minBorrowUsd: 100e18,
            // Same $10M window as mainnet, so the testnet exercises the production throttle rather
            // than a permissive stand-in that could never trip.
            dailyBorrowIncreaseLimit: 10_000_000e18
        });
    }
}
