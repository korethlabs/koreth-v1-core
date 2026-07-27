# Koreth v1 Core

Core smart contracts for **Koreth** — a lending protocol where **Uniswap LP positions**
(V2 & V3) are used as collateral to borrow stablecoins, priced with manipulation-resistant
LP oracles.

This repository is the security-critical core. Periphery contracts (routers, transformers,
flashloan liquidator) live in [`koreth-v1-periphery`](https://github.com/korethlabs/koreth-v1-periphery)
and depend on this repo. **Core depends on nothing.**

## Architecture

```
src/
├── core/        ProtocolCore, ACLManager, PositionManager, LendingEngine, LiquidationEngine, FeeCollector
├── markets/     Market, MarketFactory, MarketRegistry, InterestRateModel
├── oracle/      LPOracleHub, PriceFeedRegistry, PriceValidator, UniswapV2Oracle, UniswapV3Oracle
├── adapters/    UniswapV2Adapter, UniswapV3Adapter (+ fail-closed stubs)
├── security/    RiskManager, CircuitBreaker, PoolHealthMonitor
├── libraries/   LPMath, TokenUtils
└── interfaces/  (MIT-licensed — build against these freely)
```

Design highlights:
- **LP-as-collateral**: deposit V2 LP tokens or V3 position NFTs; borrow the market's stablecoin.
- **Manipulation-resistant pricing**: V2 fair-value (sqrt-k) and V3 30-min TWAP, cross-checked
  against Chainlink; principal-only valuation (uncollected fees are not collateral).
- **UUPS upgradeable** engines behind a timelocked governance handoff.
- **Isolated markets** per (LP type × borrow asset), Aave-style risk parameters.

## Build & test

```bash
forge install        # fetch pinned deps (OZ 5.6.1, solmate, forge-std)
forge build
forge test            # unit tests (no fork)

# Fork tests (real Uniswap / Chainlink on mainnet fork):
forge test --fork-url "$ETH_RPC_URL" --match-path "test/e2e/**"
```

Secrets (RPC key, deploy mnemonic) live in a local `.env` (gitignored) — never commit keys.

## Deployment

`script/deploy/` — chain-specific deploys (`Sepolia`, `EthMainnet`, `BSCTestnet`) on top of
`DeployBase`. `script/local/` — forked-anvil deploy + seed for local development.

## License

`BUSL-1.1` (see [LICENSE](./LICENSE)) — converts to `GPL-2.0-or-later` on the Change Date.
`src/interfaces/` is MIT so integrators can build freely.

## Security

Unaudited / pre-launch. Do not use in production. Report vulnerabilities to security@koreth.finance.
