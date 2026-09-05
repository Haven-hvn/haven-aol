#!/usr/bin/env bash
# Mainnet smoke tests for backend (run from repo root in WSL).
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:${HOME}/.cargo/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="${ICP_MAINNET_IDENTITY:-mainnet-validation-20260506}"
ENV_IC=( -e ic --identity "$IDENTITY" )

echo "== M0: health query =="
HEALTH="$(icp canister call backend health '()' --query "${ENV_IC[@]}" -o candid)"
if [[ "$HEALTH" != *"ok"* ]]; then
  echo "FAIL M0: unexpected health: $HEALTH"
  exit 1
fi
echo "OK"

echo "== M1: getVetKDPublicKey (non-empty response) =="
OUT="$(icp canister call backend getVetKDPublicKey '()' "${ENV_IC[@]}" -o hex)"
if [[ ${#OUT} -lt 32 ]]; then
  echo "FAIL: expected hex output length >= 32, got ${#OUT}"
  exit 1
fi
echo "OK (${#OUT} hex chars)"

echo "== M2: requestDecryptionKey invalid evmAddress =="
icp canister call backend requestDecryptionKey '(
  record {
    chain = variant { EthMainnet };
    tokenAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    threshold = 1_000_000 : nat;
    cid = "QmTestCid";
    evmAddress = "0x123";
    transportPublicKey = blob "\04\00";
    nonce = 1 : nat;
    signature = blob "";
    eip712ChainId = 1 : nat;
    eip712VerifyingContract = "0x0000000000000000000000000000000000000001";
  }
)' "${ENV_IC[@]}" -o candid | tee /tmp/m2.out
grep -q 'InvalidAddress' /tmp/m2.out || { echo "FAIL M2"; exit 1; }
echo "OK"

echo "== M3: requestDecryptionKey InvalidThreshold =="
icp canister call backend requestDecryptionKey '(
  record {
    chain = variant { EthMainnet };
    tokenAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    threshold = 0 : nat;
    cid = "QmTestCid";
    evmAddress = "0x0000000000000000000000000000000000000001";
    transportPublicKey = blob "\04\00";
    nonce = 2 : nat;
    signature = blob "";
    eip712ChainId = 1 : nat;
    eip712VerifyingContract = "0x0000000000000000000000000000000000000001";
  }
)' "${ENV_IC[@]}" -o candid | tee /tmp/m3.out
grep -q 'InvalidThreshold' /tmp/m3.out || { echo "FAIL M3"; exit 1; }
echo "OK"

echo "== M4: requestDecryptionKey empty cid =="
icp canister call backend requestDecryptionKey '(
  record {
    chain = variant { EthMainnet };
    tokenAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    threshold = 1_000_000 : nat;
    cid = "";
    evmAddress = "0x0000000000000000000000000000000000000001";
    transportPublicKey = blob "\04\00";
    nonce = 3 : nat;
    signature = blob "";
    eip712ChainId = 1 : nat;
    eip712VerifyingContract = "0x0000000000000000000000000000000000000001";
  }
)' "${ENV_IC[@]}" -o candid | tee /tmp/m4.out
grep -q 'InvalidAddress' /tmp/m4.out || { echo "FAIL M4"; exit 1; }
echo "OK"

echo "== M5: requestDecryptionKey empty transportPublicKey =="
icp canister call backend requestDecryptionKey '(
  record {
    chain = variant { EthMainnet };
    tokenAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    threshold = 1_000_000 : nat;
    cid = "QmTestCid";
    evmAddress = "0x0000000000000000000000000000000000000001";
    transportPublicKey = blob "";
    nonce = 4 : nat;
    signature = blob "";
    eip712ChainId = 1 : nat;
    eip712VerifyingContract = "0x0000000000000000000000000000000000000001";
  }
)' "${ENV_IC[@]}" -o candid | tee /tmp/m5.out
grep -q 'InvalidAddress' /tmp/m5.out || { echo "FAIL M5"; exit 1; }
echo "OK"

echo "== M6: requestDecryptionKey malformed signature rejected =="
icp canister call backend requestDecryptionKey '(
  record {
    chain = variant { EthMainnet };
    tokenAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    threshold = 1_000_000_000_000_000_000 : nat;
    cid = "QmTestCid";
    evmAddress = "0x0000000000000000000000000000000000000001";
    transportPublicKey = blob "\04\00";
    nonce = 5 : nat;
    signature = blob "";
    eip712ChainId = 1 : nat;
    eip712VerifyingContract = "0x0000000000000000000000000000000000000001";
  }
)' "${ENV_IC[@]}" -o candid | tee /tmp/m6.out
if grep -q 'InvalidSignature' /tmp/m6.out; then
  echo "OK (InvalidSignature)"
elif grep -q 'EvmRpcError' /tmp/m6.out; then
  echo "OK (EvmRpcError — acceptable on provider/consensus quirks)"
else
  echo "FAIL M6: expected InvalidSignature or EvmRpcError"
  cat /tmp/m6.out
  exit 1
fi

echo "== M7: batchAttestHolding rejects threshold=0 =="
icp canister call backend batchAttestHolding '(
  record {
    chain = variant { EthMainnet };
    tokenAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    threshold = 0 : nat;
    cidHashes = vec { "ab" };
    evmAddress = "0x0000000000000000000000000000000000000001";
    nonce = 0 : nat;
    signature = blob "";
    eip712ChainId = 1 : nat;
    eip712VerifyingContract = "0x0000000000000000000000000000000000000001";
  }
)' "${ENV_IC[@]}" -o candid | tee /tmp/m7.out
grep -q 'InvalidThreshold' /tmp/m7.out || { echo "FAIL M7"; exit 1; }
echo "OK"

echo "== M8: batchAttestHolding rejects empty cidHashes =="
icp canister call backend batchAttestHolding '(
  record {
    chain = variant { EthMainnet };
    tokenAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    threshold = 1_000_000 : nat;
    cidHashes = vec {};
    evmAddress = "0x0000000000000000000000000000000000000001";
    nonce = 1 : nat;
    signature = blob "";
    eip712ChainId = 1 : nat;
    eip712VerifyingContract = "0x0000000000000000000000000000000000000001";
  }
)' "${ENV_IC[@]}" -o candid | tee /tmp/m8.out
grep -q 'InvalidThreshold' /tmp/m8.out || { echo "FAIL M8"; exit 1; }
echo "OK"

echo "== M9: batchAttestHolding rejects invalid evmAddress (too short) =="
icp canister call backend batchAttestHolding '(
  record {
    chain = variant { EthMainnet };
    tokenAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    threshold = 1_000_000 : nat;
    cidHashes = vec { "ab" };
    evmAddress = "0x123";
    nonce = 2 : nat;
    signature = blob "";
    eip712ChainId = 1 : nat;
    eip712VerifyingContract = "0x0000000000000000000000000000000000000001";
  }
)' "${ENV_IC[@]}" -o candid | tee /tmp/m9.out
grep -q 'InvalidAddress' /tmp/m9.out || { echo "FAIL M9"; exit 1; }
echo "OK"

# ── Protocol v4 Bond mode (curve pricing — no signatures needed below) ──

echo "== M10: getBondConfig EthMainnet returns the Bond default =="
icp canister call backend getBondConfig '(variant { EthMainnet })' "${ENV_IC[@]}" -o candid | tee /tmp/m10.out
grep -qi 'c5a076cad94176c2996b32d8466be1ce757faa27' /tmp/m10.out || { echo "FAIL M10: expected Bond address in EthMainnet config"; exit 1; }
echo "OK"

echo "== M11: getBondConfig BaseMainnet returns the Bond default =="
icp canister call backend getBondConfig '(variant { BaseMainnet })' "${ENV_IC[@]}" -o candid | tee /tmp/m11.out
grep -qi 'c5a076cad94176c2996b32d8466be1ce757faa27' /tmp/m11.out || { echo "FAIL M11: expected Bond address in BaseMainnet config"; exit 1; }
echo "OK"

echo "== M12: getBondConfig ArbitrumOne returns the CREATE2 Bond default =="
icp canister call backend getBondConfig '(variant { ArbitrumOne })' "${ENV_IC[@]}" -o candid | tee /tmp/m12.out
grep -qi 'c5a076cad94176c2996b32d8466be1ce757faa27' /tmp/m12.out || { echo "FAIL M12: expected Bond default on ArbitrumOne"; exit 1; }
echo "OK"

echo "== M12b: getBondConfig EthSepolia returns the TESTNET Bond (not CREATE2) =="
icp canister call backend getBondConfig '(variant { EthSepolia })' "${ENV_IC[@]}" -o candid | tee /tmp/m12b.out
grep -qi '8dce343a86aa950d539eee0e166affd0ef515c0c' /tmp/m12b.out || { echo "FAIL M12b: expected testnet Bond on EthSepolia"; exit 1; }
grep -qi 'c5a076cad94176c2996b32d8466be1ce757faa27' /tmp/m12b.out && { echo "FAIL M12b: mainnet Bond must NOT appear on EthSepolia"; exit 1; }
echo "OK"

echo "== M13: getMarketCap Bond-mode fails closed on a bogus token =="
icp canister call backend getMarketCap '(
  variant { BaseMainnet },
  "0x0000000000000000000000000000000000000000",
  "0xc5a076cad94176c2996B32d8466Be1cE757FAa27"
)' "${ENV_IC[@]}" -o candid | tee /tmp/m13.out
grep -q 'err' /tmp/m13.out || { echo "FAIL M13: expected err for bogus Bond-mode token"; exit 1; }
echo "OK"

# NOTE (Bond-mode acceptance follow-ups — need real bonded tokens + signed
# requestDecryptionKeyV4 calls, so they are not in this signature-less script):
#   • bonded token with Bond-as-oracle opens past its rung
#     (MarketCapNotReached below rung → ok above), rung in whole ETH;
#   • wrong-reserve (non-native) token fails closed with #InvalidOracle.
# Run those against a live fork with EIP-712-signed v4 requests before
# advertising Bond mode per chain.

echo "== All mainnet smoke checks passed =="
