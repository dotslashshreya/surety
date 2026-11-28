#!/usr/bin/env bash
# Deploys Surety to a local Anvil chain, registers both curators and runs the first settlement.
# Start Anvil first (`anvil`), then run: script/local.sh
#
# Uses Anvil's default accounts. Their keys are public test keys that only exist on a local chain:
# never send real funds to them or use them on any live network.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=${RPC:-http://127.0.0.1:8545}
ANVIL_MNEMONIC="test test test test test test test test test test test junk" # Anvil's standard test phrase
key() { cast wallet private-key --mnemonic "$ANVIL_MNEMONIC" --mnemonic-index "$1"; }

if [ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" != "31337" ]; then
  echo "No local Anvil chain at $RPC. Start one with: anvil" >&2
  exit 1
fi

DEPLOYER_KEY=$(key 0)
CAREFUL_KEY=$(key 1)
RECKLESS_KEY=$(key 2)
KEEPER_KEY=$(key 3)
CAREFUL=$(cast wallet address --private-key "$CAREFUL_KEY")
RECKLESS=$(cast wallet address --private-key "$RECKLESS_KEY")
export CAREFUL RECKLESS

echo "1/4 Deploying tokens, faucet, hook and pool, and seeding the vault"
forge script script/DeploySurety.s.sol --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast >/dev/null

json() { python3 -c "import json,sys; print(json.load(open('deployments/31337.json'))['$1'])"; }
HOOK=$(json hook)
METH_IS_0=$(json methIsToken0)
# Bonds are in token1: mUSDC when mETH is token0, otherwise mETH at about $3,000.
if [ "$METH_IS_0" = "True" ]; then CAREFUL_BOND=18000000000000000000000; RECKLESS_BOND=9000000000000000000000
else CAREFUL_BOND=6000000000000000000; RECKLESS_BOND=3000000000000000000; fi

echo "2/4 Registering Careful (wide range) and Reckless (narrow range)"
forge script script/RegisterCurator.s.sol --sig "run(uint256,int24)" "$CAREFUL_BOND" 3000 \
  --rpc-url "$RPC" --private-key "$CAREFUL_KEY" --broadcast >/dev/null
forge script script/RegisterCurator.s.sol --sig "run(uint256,int24)" "$RECKLESS_BOND" 300 \
  --rpc-url "$RPC" --private-key "$RECKLESS_KEY" --broadcast >/dev/null

echo "3/4 Ending epoch 1 (fast-forwarding 30 minutes)"
cast rpc evm_increaseTime 1801 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null

echo "4/4 Settling: curators get their capital, the seed deposit becomes shares"
cast send "$HOOK" "settle()" --private-key "$KEEPER_KEY" --rpc-url "$RPC" >/dev/null

echo
echo "Hook:        $HOOK"
echo "Epoch, end time, share price: $(cast call "$HOOK" "epochInfo()(uint64,uint64,uint256)" --rpc-url "$RPC" | tr '\n' ' ')"
echo "Vault value (token1): $(cast call "$HOOK" "totalValue()(uint256)" --rpc-url "$RPC")"
echo "Careful  bond, capital, excess, frozen: $(cast call "$HOOK" "curatorState(address)(uint256,uint256,int256,bool)" "$CAREFUL" --rpc-url "$RPC" | tr '\n' ' ')"
echo "Reckless bond, capital, excess, frozen: $(cast call "$HOOK" "curatorState(address)(uint256,uint256,int256,bool)" "$RECKLESS" --rpc-url "$RPC" | tr '\n' ' ')"
echo "Addresses are in deployments/31337.json"
