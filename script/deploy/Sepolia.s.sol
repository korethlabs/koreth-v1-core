// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployBase} from "../DeployBase.s.sol";

/// @title DeploySepolia
/// @notice Deploy Koreth on Sepolia testnet (Uniswap V3 only)
/// @dev Run: forge script script/deploy/Sepolia.s.sol --rpc-url $SEPOLIA_RPC --broadcast --verify
contract DeploySepolia is DeployBase {
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
            guardian: deployer, // same as deployer on testnet
            riskAdmin: deployer,
            treasury: treasury,
            insuranceFund: insuranceFund,
            // V2 — not available on Sepolia
            v2Factory: address(0),
            v2Router: address(0),
            // V3 — Uniswap V3 on Sepolia
            v3Factory: 0x0227628f3F023bb0B980b67D528571c95c6DaC1c,
            v3NftManager: 0x1238536071E1c677A632429e3655c799b22cDA52,
            // Tokens
            weth: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14, // Sepolia WETH
            stablecoin: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, // Sepolia USDC
            // Chainlink feeds (Sepolia)
            clNativeUsd: 0x694AA1769357215DE4FAC081bf1f309aDC325306, // ETH/USD
            clStablecoinUsd: 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E, // USDC/USD
            // No sequencer on this chain — L1 and its testnets order their own blocks.
            clSequencerUptime: address(0),
            // Pools — use a real Sepolia V3 pool (WETH/USDC 0.3%)
            v2Pools: new address[](0), // no V2 on Sepolia
            v3Pools: _pools(0x6cE0896Ee9f20e55E1CDaF1cc234A36e27e8f42e), // WETH/USDC Sepolia
            // Market params (conservative for testnet)
            maxLtv: 6500, // 65%
            liquidationThreshold: 7500, // 75%
            liquidationBonus: 500, // 5%
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
