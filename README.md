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
├── markets/     LendingPool, PoolFactory, InterestRateModel
├── oracle/      LPOracleHub, PriceFeedRegistry, PoolLiquidityMonitor, UniswapV2Oracle, UniswapV3Oracle,
│                CurveOracle, AerodromeOracle
├── adapters/    UniswapV2Adapter, UniswapV3Adapter (+ fail-closed stubs)
├── security/    RiskManager, CircuitBreaker
├── libraries/   LPMath, TokenUtils
└── interfaces/  (MIT-licensed — build against these freely)
```

Design highlights:
- **LP-as-collateral**: deposit V2 LP tokens or V3 position NFTs; borrow any asset the protocol
  has a pool for.
- **Manipulation-resistant pricing**: both LP types are valued from Chainlink — V2 by sqrt-k fair
  value, V3 by deriving the position's token composition from a Chainlink-implied price rather than
  reading the pool's own tick; principal-only valuation (uncollected fees are not collateral).
- **UUPS upgradeable** engines behind a timelocked governance handoff.
- **Shared liquidity, isolated risk**: one `LendingPool` per borrow asset, open to every
  collateral type, with Aave-style risk parameters and a hard borrow cap held per LP type in
  `RiskManager`.

### Liquidity and risk are separate axes

Liquidity lives in a **`LendingPool`, one per borrow asset** (USDC, USDT, …), registered through
`ProtocolCore.registerLendingPool()`. Every collateral type draws on the same pool, so a lender's
deposit is never stranded behind an LP type nobody borrows against.

Risk lives in **`RiskManager`, keyed per `ILPAdapter.LPType`** — LTV, liquidation threshold and
bonus, haircut, and a `borrowCap` denominated in USD. The cap is what keeps shared liquidity from
turning one bad collateral type into a protocol-wide loss: exposure to that type simply stops at
its cap. `borrowCap == 0` blocks borrowing (fail-closed); `type(uint256).max` means uncapped.

## Build & test

```bash
forge install        # fetch pinned deps (OZ 5.6.1, solmate, forge-std)
forge build
forge test            # unit tests (no fork)

# Fork tests (real Uniswap / Chainlink on mainnet fork):
forge test --fork-url "$ETH_RPC_URL" --match-path "test/e2e/**"
```

Secrets (RPC key, deploy mnemonic) live in a local `.env` (gitignored) — never commit keys.

## Enum ordinals for consumers

`exports/enums.json` publishes the members of core's Solidity enums in declaration order,
so the index of a member is its on-chain value. The SDK, subgraph and interface all branch
on `ILPAdapter.LPType` and `IPositionManager.PositionStatus`; read them from here rather
than re-typing them.

An ABI cannot carry this. Solidity encodes an enum parameter as `uint8` and drops the
member names entirely, so an ABI regenerate-and-diff check passes while every label is
wrong. That is not a gap in how those checks are written — it is a property of what an ABI
contains. The file is generated from solc's AST, which is the compiler's own record of
what it compiled and so cannot disagree with the source.

```bash
python3 script/tools/gen_enums.py           # regenerate after changing an enum
python3 script/tools/gen_enums.py --check   # what CI runs
```

Adding, removing or reordering a member changes the file, and CI fails until it is
regenerated and committed. Reordering is a breaking change for every consumer even when
the member names are unchanged.

## Deployment

`script/deploy/` — chain-specific deploys (`Sepolia`, `EthMainnet`, `BSCTestnet`) on top of
`DeployBase`. `script/local/` — forked-anvil deploy + seed for local development.

## License

`BUSL-1.1` (see [LICENSE](./LICENSE)) — converts to `GPL-2.0-or-later` on the Change Date.
`src/interfaces/` is MIT so integrators can build freely.

## Security

Unaudited / pre-launch. Do not use in production. Report vulnerabilities to security@koreth.finance.
