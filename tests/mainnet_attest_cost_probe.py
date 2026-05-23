#!/usr/bin/env python3
"""Measure mainnet attestHolding cycle cost and print canister receipt JSON.

Run from repo root (WSL):
  .venv-probe/bin/python tests/mainnet_attest_cost_probe.py
"""

from __future__ import annotations

import hashlib
import json
import re
import secrets
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any

MAINNET_CANISTER_ID = "dciac-uaaaa-aaaad-qlzuq-cai"
MAINNET_HOST = "https://icp-api.io"
EIP712_CHAIN_ID = 1
EIP712_VERIFYING_CONTRACT = "0x1c7D4B196Cb0C7B01d743Fbc6116a9023097791A"
ATTEST_CHAIN = "EthMainnet"
ATTEST_TOKEN = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
ATTEST_THRESHOLD = 1

HAVEN_AOL_DID = """type Chain = variant { EthMainnet; EthSepolia; ArbitrumOne; BaseMainnet; OptimismMainnet; };
type AttestRequest = record {
  chain : Chain; tokenAddress : text; threshold : nat; cidHash : text; evmAddress : text;
  nonce : nat; signature : blob; eip712ChainId : nat; eip712VerifyingContract : text;
};
type AttestResult = variant {
  ok : record {
    attestation : record {
      evmAddress : text; chain : Chain; tokenAddress : text; threshold : nat;
      balanceAtCheck : nat; cidHash : text; timestamp : nat;
    };
    signature : blob;
  };
  err : variant {
    InsufficientBalance : record { required : nat; actual : nat };
    InvalidAddress : text; InvalidThreshold; EvmRpcError : text; VetKDError : text;
    InvalidSignature : text; NonceAlreadyUsed;
  };
};
service : { attestHolding : (AttestRequest) -> (AttestResult); }
"""

# From production failure 2026-05-21 (haven-cli) before SCHNORR_CYCLE_BUDGET fix.
OBSERVED_SIGN_WITH_SCHNORR_REQUIRED_CYCLES = 26_153_846_153

# Current forward caps in main.mo (deployed).
FORWARDED_EVM_RPC_CYCLES = 30_000_000_000
FORWARDED_SCHNORR_CYCLES = 35_000_000_000


@dataclass(frozen=True)
class CycleSnapshot:
    cycles: int
    module_hash: str
    memory_size: int


def _parse_cycles_status(text: str) -> CycleSnapshot:
    cycles_match = re.search(r"Cycles:\s*([\d_]+)", text)
    hash_match = re.search(r"Module hash:\s*(0x[0-9a-f]+)", text)
    mem_match = re.search(r"Memory size:\s*([\d_]+)", text)
    if not cycles_match or not hash_match or not mem_match:
        raise RuntimeError(f"Failed to parse canister status:\n{text}")
    return CycleSnapshot(
        cycles=int(cycles_match.group(1).replace("_", "")),
        module_hash=hash_match.group(1),
        memory_size=int(mem_match.group(1).replace("_", "")),
    )


def _canister_status() -> CycleSnapshot:
    proc = subprocess.run(
        [
            "icp",
            "canister",
            "status",
            "backend",
            "-e",
            "ic",
            "--identity",
            "mainnet-validation-20260506",
        ],
        capture_output=True,
        text=True,
        check=True,
        cwd=_repo_root(),
    )
    return _parse_cycles_status(proc.stdout)


def _repo_root() -> str:
    import os

    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _generate_icp_identity() -> Any:
    from icp_identity.identity import Identity

    pem = subprocess.run(
        ["openssl", "genpkey", "-algorithm", "Ed25519", "-outform", "PEM"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return Identity.from_pem(pem)


def _generate_evm_keypair() -> tuple[str, str]:
    from eth_account import Account

    private_key = "0x" + secrets.token_bytes(32).hex()
    return private_key, Account.from_key(private_key).address


def _sign_attest_request(
    *,
    private_key: str,
    evm_address: str,
    cid_hash: str,
    nonce: int,
) -> bytes:
    from eth_account import Account
    from eth_account.messages import encode_typed_data

    full_message = {
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"},
            ],
            "AttestRequest": [
                {"name": "evmAddress", "type": "address"},
                {"name": "cidHash", "type": "bytes32"},
                {"name": "nonce", "type": "uint256"},
            ],
        },
        "primaryType": "AttestRequest",
        "domain": {
            "name": "HavenAOL",
            "chainId": EIP712_CHAIN_ID,
            "verifyingContract": EIP712_VERIFYING_CONTRACT,
        },
        "message": {
            "evmAddress": evm_address,
            "cidHash": bytes.fromhex(cid_hash),
            "nonce": nonce,
        },
    }
    signed = Account.sign_message(
        encode_typed_data(full_message=full_message), private_key
    )
    return signed.signature


def _build_canister(identity: Any) -> Any:
    from icp_agent.agent import Agent
    from icp_agent.client import Client
    from icp_canister.canister import Canister

    return Canister(
        Agent(identity, Client(url=MAINNET_HOST)),
        MAINNET_CANISTER_ID,
        candid_str=HAVEN_AOL_DID,
    )


def _unwrap_first(response: list[Any]) -> Any:
    item = response[0]
    if isinstance(item, dict) and "type" in item and "value" in item:
        return item["value"]
    return item


def _normalize_receipt(result: Any) -> dict[str, Any]:
    """Turn Candid AttestResult into JSON-serializable receipt."""
    if not isinstance(result, dict):
        raise RuntimeError(f"Unexpected result type: {type(result)}")

    if "ok" in result:
        ok = result["ok"]
        att = ok["attestation"]
        chain = att.get("chain")
        chain_name = next(iter(chain)) if isinstance(chain, dict) and chain else str(chain)
        sig = ok["signature"]
        if isinstance(sig, dict) and "value" in sig:
            sig_bytes = bytes(sig["value"])
        elif isinstance(sig, (bytes, bytearray)):
            sig_bytes = bytes(sig)
        elif isinstance(sig, list):
            sig_bytes = bytes(sig)
        else:
            raise RuntimeError(f"Unexpected signature shape: {type(sig)}")

        return {
            "status": "ok",
            "canisterId": MAINNET_CANISTER_ID,
            "attestation": {
                "evmAddress": att["evmAddress"],
                "chain": chain_name,
                "tokenAddress": att["tokenAddress"],
                "threshold": int(att["threshold"]),
                "balanceAtCheck": int(att["balanceAtCheck"]),
                "cidHash": att["cidHash"],
                "timestamp": int(att["timestamp"]),
            },
            "signatureHex": sig_bytes.hex(),
            "signatureBytes": len(sig_bytes),
        }

    if "err" in result:
        err = result["err"]
        if isinstance(err, dict) and err:
            variant = next(iter(err))
            detail = err[variant]
            if isinstance(detail, dict) and "value" in detail:
                detail = detail["value"]
            return {
                "status": "err",
                "canisterId": MAINNET_CANISTER_ID,
                "error": {variant: detail},
            }
        return {"status": "err", "canisterId": MAINNET_CANISTER_ID, "error": str(err)}

    raise RuntimeError(f"Unexpected AttestResult: {result!r}")


def main() -> int:
    before = _canister_status()
    print(f"Cycles before: {before.cycles:,}  module={before.module_hash}")

    identity = _generate_icp_identity()
    canister = _build_canister(identity)
    private_key, address = _generate_evm_keypair()
    nonce = (int(time.time_ns()) << 64) | int.from_bytes(secrets.token_bytes(8), "big")
    cid_hash = hashlib.sha256(f"cost-probe-{nonce}".encode()).hexdigest()
    signature = _sign_attest_request(
        private_key=private_key,
        evm_address=address,
        cid_hash=cid_hash,
        nonce=nonce,
    )

    req = {
        "chain": {ATTEST_CHAIN: None},
        "tokenAddress": ATTEST_TOKEN,
        "threshold": ATTEST_THRESHOLD,
        "cidHash": cid_hash,
        "evmAddress": address,
        "nonce": nonce,
        "signature": signature,
        "eip712ChainId": EIP712_CHAIN_ID,
        "eip712VerifyingContract": EIP712_VERIFYING_CONTRACT,
    }

    t0 = time.perf_counter()
    raw = canister.attestHolding(req, verify_certificate=False)
    elapsed_s = time.perf_counter() - t0
    result = _unwrap_first(raw)
    receipt = _normalize_receipt(result)

    after = _canister_status()
    consumed = before.cycles - after.cycles

    analysis = {
        "measurement": {
            "wallClockSeconds": round(elapsed_s, 3),
            "cyclesBefore": before.cycles,
            "cyclesAfter": after.cycles,
            "cyclesConsumedByCanister": consumed,
            "note": (
                "cyclesConsumedByCanister is balance delta on the backend canister; "
                "includes ingress/execution and net inter-canister charges (forwards minus refunds)."
            ),
        },
        "forwardBudgetsInWasm": {
            "eth_call_via_evm_rpc": FORWARDED_EVM_RPC_CYCLES,
            "sign_with_schnorr": FORWARDED_SCHNORR_CYCLES,
            "schnorr_public_key_warmup": FORWARDED_SCHNORR_CYCLES,
        },
        "historicalObservation": {
            "date": "2026-05-21",
            "source": "haven-cli production attestHolding failure (pre-35B cap)",
            "sign_with_schnorr_required_cycles": OBSERVED_SIGN_WITH_SCHNORR_REQUIRED_CYCLES,
        },
        "estimatedFullSuccessPathCycles": {
            "ecrecover_and_validation": "negligible (<100M instructions, no IC outcall)",
            "eth_call_balanceOf_consensus": "typically 100M–3B net (forward cap 30B)",
            "sign_with_schnorr": f"~{OBSERVED_SIGN_WITH_SCHNORR_REQUIRED_CYCLES:,} required (forward cap {FORWARDED_SCHNORR_CYCLES:,})",
            "totalOrderOfMagnitude": f"~{OBSERVED_SIGN_WITH_SCHNORR_REQUIRED_CYCLES + 3_000_000_000:,}–{OBSERVED_SIGN_WITH_SCHNORR_REQUIRED_CYCLES + 10_000_000_000:,} cycles per successful attest",
        },
        "receipt": receipt,
        "request": {
            "evmAddress": address,
            "chain": ATTEST_CHAIN,
            "tokenAddress": ATTEST_TOKEN,
            "threshold": ATTEST_THRESHOLD,
            "cidHash": cid_hash,
            "nonce": str(nonce),
            "eip712ChainId": EIP712_CHAIN_ID,
            "eip712VerifyingContract": EIP712_VERIFYING_CONTRACT,
        },
    }

    print(json.dumps(analysis, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
