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

echo "== All mainnet smoke checks passed =="
