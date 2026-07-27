#!/usr/bin/env bash
# Deploy + seed Koreth on a local anvil MAINNET FORK, then print addresses for the subgraph.
#
# Prereq: anvil must already be running as a mainnet fork on :8545, e.g. from repo root:
#   docker compose up -d anvil        # uses ETH_RPC_URL + pinned --fork-block-number
#
# Usage (from packages/contracts):
#   ./script/local/run.sh
set -euo pipefail

cd "$(dirname "$0")/../.."  # -> packages/contracts
ROOT="$(cd ../.. && pwd)"   # repo root

# Load local secrets (gitignored). NEVER hardcode private keys / mnemonics in tracked files —
# keep them in $ROOT/.env only. SEED_MNEMONIC is anvil's mnemonic (printed by anvil on startup).
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
: "${SEED_MNEMONIC:?set SEED_MNEMONIC in $ROOT/.env (anvil prints its default mnemonic on startup)}"
export SEED_MNEMONIC
# Deployer = mnemonic account #0 — derived at runtime, never stored in a tracked file.
export DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY:-$(cast wallet derive-private-key "$SEED_MNEMONIC" 0)}"

RPC="${RPC:-http://localhost:8547}"  # our forked anvil (host :8545/:8546 are the SSH-forwarded mainnet RPC)

echo "==> Waiting for anvil at $RPC ..."
for i in $(seq 1 30); do
  if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
  sleep 1
  if [ "$i" -eq 30 ]; then echo "anvil not reachable at $RPC — start it with 'docker compose up -d anvil'"; exit 1; fi
done
echo "    anvil block: $(cast block-number --rpc-url "$RPC")"

mkdir -p deployments  # vm.writeJson needs the dir to exist

echo "==> Deploying protocol (Local.s.sol) ..."
forge script script/deploy/Local.s.sol:DeployLocal --rpc-url "$RPC" --broadcast

echo "==> Seeding lender supply + deployer collateral (SeedLocal.s.sol) ..."
forge script script/SeedLocal.s.sol:SeedLocal --rpc-url "$RPC" --broadcast

echo "==> Seeding extra user deposits (SeedUsers.s.sol) ..."
forge script script/SeedUsers.s.sol:SeedUsers --rpc-url "$RPC" --broadcast

echo "==> Waiting for borrow cooldown (mining blocks) ..."
sleep 8  # block-time is 2s -> mines ~4 blocks > cooldown (1) + 1

echo "==> Borrowing (SeedBorrow.s.sol) ..."
forge script script/SeedBorrow.s.sol:SeedBorrow --rpc-url "$RPC" --broadcast

echo "==> Faucet: leaving LP in account #4 for UI deposit testing (SeedFaucet.s.sol) ..."
forge script script/SeedFaucet.s.sol:SeedFaucet --rpc-url "$RPC" --broadcast

echo "==> Liquidation demo (SeedLiquidate.s.sol) ..."
forge script script/SeedLiquidate.s.sol:SeedLiquidate --rpc-url "$RPC" --broadcast

# Mine a few extra blocks so graph-node can finalize the last seeded events (mine-on-demand fork).
cast rpc anvil_mine 0x8 --rpc-url "$RPC" >/dev/null 2>&1 || true

echo "==> Done. Deployment written to deployments/local.json:"
cat deployments/local.json
echo
echo "Deploy block (use as subgraph startBlock): $(cast --to-dec "$(cast rpc eth_blockNumber --rpc-url "$RPC" | tr -d '\"')" 2>/dev/null || cast block-number --rpc-url "$RPC")"
