// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployBase} from "../DeployBase.s.sol";

/// @title DeployEthMainnet
/// @notice Deploy Koreth on Ethereum Mainnet (Uniswap V2 + V3)
/// @dev Run: forge script script/deploy/EthMainnet.s.sol --rpc-url $ETH_RPC --broadcast --verify
///      The deployer holds every admin role after this runs. Handing the protocol to the DAO is
///      a separate, deliberate step — see script/HandoverToDAO.s.sol.
contract DeployEthMainnet is DeployBase {
    function _config() internal override returns (ChainConfig memory) {
        // The deployer holds DEFAULT_ADMIN, POOL_ADMIN, RISK_ADMIN and ProtocolCore ownership
        // until the handover scripts run. That is the launch posture, stated rather than implied.
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        // Required, not defaulted: the guardian being a separate key is the point, and an env var
        // that silently falls back to the deployer would collapse that separation exactly when
        // nobody is looking. Splitting it costs nothing — EMERGENCY_ADMIN can pause but not
        // unpause, so moving the emergency brake off the deploying key weakens nothing. RISK_ADMIN is deliberately not configurable the same way — pointing
        // it elsewhere would leave the deployer without a role the launch posture says it holds,
        // and HandoverFinalize would then refuse to strip a deployer that never had it. An extra
        // operational risk key can be granted after deploy, and revoked before handover.
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");
        // Required for the same reason, and more sharply: these are not roles that can be regranted
        // later without anyone noticing, they are where the money goes. Defaulting either to the
        // deployer would deploy a protocol whose revenue and whose insurance fund are one EOA, and
        // nothing downstream — not the handover script, not the tests — would report it.
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address insuranceFund = vm.envAddress("INSURANCE_FUND_ADDRESS");

        return ChainConfig({
            // Roles
            deployer: deployer,
            guardian: guardian,
            riskAdmin: deployer,
            treasury: treasury,
            insuranceFund: insuranceFund,
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
            // No sequencer on this chain — L1 and its testnets order their own blocks.
            clSequencerUptime: address(0),
            // Pools — WETH/USDC only. The local profile also lists WETH/DAI and WETH/USDT; they are
            // deliberately not here, because listing a pair on mainnet is a risk decision about its
            // depth and its feeds, not a symmetry to keep with a fork.
            v2Pools: _pools(0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc), // WETH/USDC V2
            v3Pools: _pools(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8), // WETH/USDC 0.3% V3
            // Market params (production — conservative)
            maxLtv: 6500,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            haircut: 500, // 5% discount on collateral value
            borrowCap: 10_000_000e18, // $10M (18-dec USD, not borrow-asset decimals)
            // $10K debt floor. Sized against mainnet gas: a liquidation seizes an LP, unwinds it
            // through the adapter and pays the liquidator in one transaction, so a position much
            // smaller than this is not worth liquidating and would sit as bad debt instead.
            minBorrowUsd: 10_000e18,
            // $10M of new principal per 24h. Clears the $6.5M a single maximum position can draw
            // (RiskManager.maxPositionValue at the 6500 bps maxLtv above) with room to spare, so the
            // throttle bounds an attack's rate without a legitimate large borrower ever meeting it.
            dailyBorrowIncreaseLimit: 10_000_000e18
        });
    }
}
