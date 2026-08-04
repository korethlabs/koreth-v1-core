// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployBase} from "../DeployBase.s.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockFreshAggregator} from "../local/MockFreshAggregator.sol";

/// @notice Minimal Chainlink AggregatorV3 read surface (to snapshot the real feed at deploy).
interface IAggregatorRead {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title DeployLocal
/// @notice Deploy Koreth on a local anvil MAINNET FORK (Uniswap V2 + V3), with one shared lending
///         pool per stablecoin (USDC, USDT, DAI) and V2 + V3 collateral enabled against all of them.
/// @dev Run via script/local/run.sh, which loads SEED_MNEMONIC from the local .env (gitignored)
///      and derives DEPLOYER_PRIVATE_KEY. Never hardcode private keys in tracked files.
///      Writes deployments/local.json (named addresses + deploy block) for seeding + subgraph tooling.
contract DeployLocal is DeployBase {
    // Anvil default account #0 ADDRESS (public — the deployer must be this on the local fork)
    address internal constant ANVIL_ACCT0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    /// @dev Start anvil with `--chain-id 1337`. A mainnet fork otherwise inherits chainid 1, and
    ///      every address in this profile is a real mainnet address, so nothing about the script
    ///      itself says "local".
    uint256 internal constant LOCAL_CHAIN_ID = 1337;

    // Extra borrow-asset stablecoins + their Chainlink USD feeds (mainnet)
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant CL_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address internal constant CL_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;

    function _config() internal override returns (ChainConfig memory) {
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(deployer == ANVIL_ACCT0, "USE_ANVIL_ACCT0");
        // This profile installs price feeds frozen at deploy time and leaves the deployer holding
        // every role. Until now the only thing between a mistyped RPC
        // and shipping that to mainnet was the anvil key holding no real ETH — an accident, not a
        // safeguard.
        require(block.chainid == LOCAL_CHAIN_ID, "NOT_A_LOCAL_CHAIN");

        return ChainConfig({
            // Roles — deployer wears every hat on a local fork
            deployer: deployer,
            guardian: deployer,
            riskAdmin: deployer,
            // Uniswap V2 (mainnet)
            v2Factory: 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f,
            v2Router: 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D,
            // Uniswap V3 (mainnet)
            v3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
            v3NftManager: 0xC36442b4a4522E871399CD717aBDD847Ab11FE88,
            // Tokens (mainnet)
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            stablecoin: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            // Chainlink feeds (mainnet)
            clNativeUsd: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, // ETH/USD
            clStablecoinUsd: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6, // USDC/USD
            // No sequencer on this chain — L1 and its testnets order their own blocks.
            clSequencerUptime: address(0),
            // Pools to whitelist (mainnet WETH/USDC)
            v2Pool: 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc, // V2 WETH/USDC pair
            v3Pool: 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8, // V3 WETH/USDC 0.3%
            // Market params (conservative)
            maxLtv: 6500, // 65%
            liquidationThreshold: 7500, // 75%
            liquidationBonus: 500, // 5%
            haircut: 500, // 5% discount on collateral value
            borrowCap: 100_000e18 // $100K (18-dec USD, not borrow-asset decimals)
        });
    }

    /// @notice Replace every price feed with a fresh-timestamp mock (fork-only). The forked real
    ///         Chainlink feeds freeze in time, so as anvil's clock drifts they trip STALE_PRICE.
    ///         Each mock captures the real price NOW and reports it with a live timestamp forever,
    ///         so deposits/borrows keep working no matter how long the fork stays up.
    function _afterOracles(ChainConfig memory cfg) internal override {
        _wireMockFeed(cfg.weth, cfg.clNativeUsd);
        _wireMockFeed(cfg.stablecoin, cfg.clStablecoinUsd); // USDC
        _wireMockFeed(USDT, CL_USDT_USD);
        _wireMockFeed(DAI, CL_DAI_USD);
    }

    function _wireMockFeed(address token, address realFeed) internal {
        uint8 dec = IAggregatorRead(realFeed).decimals();
        (, int256 answer,,,) = IAggregatorRead(realFeed).latestRoundData();
        MockFreshAggregator mock = new MockFreshAggregator(dec, answer);
        priceFeedRegistry.setPriceFeed(token, address(mock));
    }

    /// @notice Create the extra shared lending pools (USDT, DAI); the base already made USDC.
    /// @dev No collateral re-whitelisting: CollateralConfig is keyed by LPType only, so the V2/V3
    ///      types the base enabled are already borrowable against these pools too.
    function _afterPools(ChainConfig memory) internal override {
        _ensurePool(USDT);
        _ensurePool(DAI);
    }

    /// @notice Fork tweak: real Chainlink feeds can lag the 1h default (e.g. USDC/USD updates
    ///         ~daily), so anvil's live block.timestamp trips STALE_PRICE. Raise to the 24h max.
    function _beforeGovernance(ChainConfig memory) internal override {
        priceFeedRegistry.setMaxStaleness(86_400);
    }

    /// @notice Persist deployed addresses + deploy block to deployments/local.json.
    ///         Consumed by SeedLocal.s.sol and the subgraph tooling.
    function _afterRun(ChainConfig memory) internal override {
        string memory obj = "local";
        vm.serializeAddress(obj, "aclManager", address(aclManager));
        vm.serializeAddress(obj, "core", address(core));
        vm.serializeAddress(obj, "oracleHub", address(oracleHub));
        vm.serializeAddress(obj, "positionManager", address(positionManager));
        vm.serializeAddress(obj, "lendingEngine", address(lendingEngine));
        vm.serializeAddress(obj, "liquidationEngine", address(liquidationEngine));
        vm.serializeAddress(obj, "feeCollector", address(feeCollector));
        vm.serializeAddress(obj, "riskManager", address(riskManager));
        vm.serializeAddress(obj, "poolFactory", address(poolFactory));
        vm.serializeAddress(obj, "priceFeedRegistry", address(priceFeedRegistry));
        // Adapters (frontend needs these to approve LP before deposit)
        vm.serializeAddress(obj, "v2Adapter", core.adapters(ILPAdapter.LPType.UniswapV2));
        vm.serializeAddress(obj, "v3Adapter", core.adapters(ILPAdapter.LPType.UniswapV3));
        // Tokens + collateral pair (for the frontend)
        vm.serializeAddress(obj, "weth", 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        vm.serializeAddress(obj, "usdc", 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        vm.serializeAddress(obj, "usdt", USDT);
        vm.serializeAddress(obj, "dai", DAI);
        vm.serializeAddress(obj, "v2Pair", 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc);
        vm.serializeUint(obj, "chainId", block.chainid);
        string memory json = vm.serializeUint(obj, "deployBlock", block.number);

        vm.writeJson(json, "./deployments/local.json");
    }
}
