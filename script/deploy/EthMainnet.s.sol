// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployBase} from "../DeployBase.s.sol";

/// @title DeployEthMainnet
/// @notice Deploy Koreth on Ethereum Mainnet (Uniswap V2 + V3)
/// @dev Run: forge script script/deploy/EthMainnet.s.sol --rpc-url $ETH_RPC --broadcast --verify
///      IMPORTANT: Use multisig addresses for guardian/riskAdmin in production!
contract DeployEthMainnet is DeployBase {
    function _config() internal override returns (ChainConfig memory) {
        // The deployer EOA becomes the initial owner and pool admin of all contracts.
        // After deployment, transfer ownership of ACLManager, ProtocolCore, and all admin
        // roles to a multisig. The deployer should hold no privileged roles post-deploy.
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        // TODO: Replace with actual multisig addresses before mainnet deployment
        address guardian = vm.envOr("GUARDIAN_ADDRESS", deployer);
        address riskAdmin = vm.envOr("RISK_ADMIN_ADDRESS", deployer);

        return ChainConfig({
            // Roles
            deployer: deployer,
            guardian: guardian,
            riskAdmin: riskAdmin,
            // V2 — Uniswap V2
            v2Factory: 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f,
            v2Router: 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D,
            // V3 — Uniswap V3
            v3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
            v3NftManager: 0xC36442b4a4522E871399CD717aBDD847Ab11FE88,
            // Tokens
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            stablecoin: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            // Chainlink feeds
            clNativeUsd: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, // ETH/USD
            clStablecoinUsd: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6, // USDC/USD
            // Pools
            v2Pool: 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc, // WETH/USDC V2
            v3Pool: 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8, // WETH/USDC 0.3% V3
            // Market params (production — conservative)
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            haircut: 500, // 5% discount on collateral value
            borrowCap: 10_000_000e18, // $10M (18-dec USD, not borrow-asset decimals)
            // Governance — multisig required for mainnet (no fallback to deployer)
            multisig: vm.envAddress("MULTISIG_ADDRESS"),
            timelockDelay: 48 hours
        });
    }
}
