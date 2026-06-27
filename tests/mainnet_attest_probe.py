"""Minimal mainnet probe for attestHolding (no haven-cli).

Reproduces the haven-cli / icp-py-core path against dciac-uaaaa-aaaad-qlzuq-cai.
Run from repo root in WSL:

  pip install icp-py-core eth-account pytest
  pytest tests/mainnet_attest_probe.py -v -s

Expectation for an ephemeral wallet with threshold=1 on USDC:
  - #err InsufficientBalance (eth_call + ecrecover succeeded; signing not reached)
  - NOT ReplicaReject IC0406

If IC0406 occurs, the failure is in an uncaught inter-canister call (likely eth_call or sign_with_schnorr).
"""

from __future__ import annotations

import hashlib
import secrets
import subprocess
import time
from typing import Any

import pytest

MAINNET_CANISTER_ID = "dciac-uaaaa-aaaad-qlzuq-cai"
MAINNET_HOST = "https://icp-api.io"

EIP712_CHAIN_ID = 1
EIP712_VERIFYING_CONTRACT = "0x1c7D4B196Cb0C7B01d743Fbc6116a9023097791A"

ATTEST_CHAIN = "EthMainnet"
ATTEST_TOKEN = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
ATTEST_THRESHOLD = 1

HAVEN_AOL_GATE_DID = """type Chain = variant { EthMainnet; EthSepolia; ArbitrumOne; BaseMainnet; OptimismMainnet; };
type GateRequest = record {
  chain : Chain; tokenAddress : text; threshold : nat; cid : text; evmAddress : text;
  transportPublicKey : blob; nonce : nat; signature : blob; eip712ChainId : nat; eip712VerifyingContract : text;
};
type GateResult = variant {
  ok : record { encrypted_key : blob; verification_key : blob };
  err : variant {
    InsufficientBalance : record { required : nat; actual : nat };
    InvalidAddress : text; InvalidThreshold; EvmRpcError : text; VetKDError : text;
    InvalidSignature : text; NonceAlreadyUsed;
  };
};
service : { requestDecryptionKey : (GateRequest) -> (GateResult); }
"""

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
type MerkleSide = variant { left; right };
type MerkleProofEntry = record {
  side : MerkleSide;
  hash : blob;
};
type MerkleAttestLeaf = record {
  cidHash : text;
  merkleProof : vec MerkleProofEntry;
};
type MerkleAttestation = record {
  evmAddress : text; chain : Chain; tokenAddress : text; threshold : nat;
  balanceAtCheck : nat; timestamp : nat; cidCount : nat;
  merkleRoot : blob; leaves : vec MerkleAttestLeaf; rootSignature : blob;
};
type MerkleAttestRequest = record {
  chain : Chain; tokenAddress : text; threshold : nat;
  cidHashes : vec text; evmAddress : text;
  nonce : nat; signature : blob; eip712ChainId : nat; eip712VerifyingContract : text;
};
type MerkleAttestResult = variant {
  ok : MerkleAttestation;
  err : GateError;
};
service : {
  attestHolding : (AttestRequest) -> (AttestResult);
  batchAttestHolding : (MerkleAttestRequest) -> (MerkleAttestResult);
  health : () -> (text) query;
}
"""


def _generate_icp_identity() -> Any:
    from icp_identity.identity import Identity

    result = subprocess.run(
        ["openssl", "genpkey", "-algorithm", "Ed25519", "-outform", "PEM"],
        capture_output=True,
        text=True,
        check=True,
    )
    identity = Identity.from_pem(result.stdout)
    assert not getattr(identity, "anonymous", False)
    return identity


def _generate_evm_keypair() -> tuple[str, str]:
    from eth_account import Account

    private_key = "0x" + secrets.token_bytes(32).hex()
    account = Account.from_key(private_key)
    return private_key, account.address


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
    signable = encode_typed_data(full_message=full_message)
    normalized_key = private_key if private_key.startswith("0x") else f"0x{private_key}"
    signed = Account.sign_message(signable, normalized_key)
    assert len(signed.signature) == 65
    assert signed.signature[-1] in (27, 28)
    return signed.signature


def _sign_batch_attest_request(
    *,
    private_key: str,
    evm_address: str,
    cid_hashes: list[str],
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
            "MerkleAttestRequest": [
                {"name": "evmAddress", "type": "address"},
                {"name": "cidHashes", "type": "bytes32[]"},
                {"name": "nonce", "type": "uint256"},
            ],
        },
        "primaryType": "MerkleAttestRequest",
        "domain": {
            "name": "HavenAOL",
            "chainId": EIP712_CHAIN_ID,
            "verifyingContract": EIP712_VERIFYING_CONTRACT,
        },
        "message": {
            "evmAddress": evm_address,
            "cidHashes": [f"0x{cid_hash}" for cid_hash in cid_hashes],
            "nonce": nonce,
        },
    }
    signable = encode_typed_data(full_message=full_message)
    normalized_key = private_key if private_key.startswith("0x") else f"0x{private_key}"
    signed = Account.sign_message(signable, normalized_key)
    assert len(signed.signature) == 65
    assert signed.signature[-1] in (27, 28)
    return signed.signature


def _build_canister(identity: Any) -> Any:
    from icp_agent.agent import Agent
    from icp_agent.client import Client
    from icp_canister.canister import Canister

    client = Client(url=MAINNET_HOST)
    agent = Agent(identity, client)
    return Canister(agent, MAINNET_CANISTER_ID, candid_str=HAVEN_AOL_DID)


def _unwrap_first(response: list[Any]) -> Any:
    assert isinstance(response, list) and len(response) == 1
    item = response[0]
    if isinstance(item, dict) and "type" in item and "value" in item:
        return item["value"]
    return item


@pytest.fixture(scope="module")
def ic_canister() -> Any:
    return _build_canister(_generate_icp_identity())


@pytest.fixture(scope="module")
def evm_keypair() -> dict[str, str]:
    private_key, address = _generate_evm_keypair()
    return {"private_key": private_key, "address": address}


def test_mainnet_health_query(ic_canister: Any) -> None:
    response = ic_canister.health(verify_certificate=False)
    value = _unwrap_first(response)
    assert value == "ok"


def test_mainnet_attest_invalid_signature(ic_canister: Any) -> None:
    """Pre-flight validation: must return InvalidSignature, not IC0406."""
    nonce = (int(time.time_ns()) << 64) | int.from_bytes(secrets.token_bytes(8), "big")
    cid_hash = hashlib.sha256(b"probe-invalid-sig").hexdigest()
    req = {
        "chain": {ATTEST_CHAIN: None},
        "tokenAddress": ATTEST_TOKEN,
        "threshold": ATTEST_THRESHOLD,
        "cidHash": cid_hash,
        "evmAddress": "0x" + "11" * 20,
        "nonce": nonce,
        "signature": bytes(65),
        "eip712ChainId": EIP712_CHAIN_ID,
        "eip712VerifyingContract": EIP712_VERIFYING_CONTRACT,
    }
    result = _unwrap_first(ic_canister.attestHolding(req, verify_certificate=False))
    assert isinstance(result, dict) and "err" in result
    err = result["err"]
    if isinstance(err, dict) and err:
        err_variant = next(iter(err))
        assert err_variant == "InvalidSignature", err


def test_mainnet_gate_ephemeral_wallet(ic_canister: Any, evm_keypair: dict[str, str]) -> None:
    """Same wallet/token as attest probe but via requestDecryptionKey (shared checkBalance)."""
    from eth_account import Account
    from eth_account.messages import encode_typed_data
    from icp_agent.agent import Agent
    from icp_agent.client import Client
    from icp_canister.canister import Canister

    identity = ic_canister.agent.identity
    gate_canister = Canister(
        Agent(identity, Client(url=MAINNET_HOST)),
        MAINNET_CANISTER_ID,
        candid_str=HAVEN_AOL_GATE_DID,
    )

    nonce = (int(time.time_ns()) << 64) | int.from_bytes(secrets.token_bytes(8), "big")
    transport_public_key = bytes([4] + [0] * 47)
    full_message = {
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"},
            ],
            "GateRequest": [
                {"name": "evmAddress", "type": "address"},
                {"name": "transportPublicKey", "type": "bytes"},
                {"name": "nonce", "type": "uint256"},
            ],
        },
        "primaryType": "GateRequest",
        "domain": {
            "name": "HavenAOL",
            "chainId": EIP712_CHAIN_ID,
            "verifyingContract": EIP712_VERIFYING_CONTRACT,
        },
        "message": {
            "evmAddress": evm_keypair["address"],
            "transportPublicKey": transport_public_key,
            "nonce": nonce,
        },
    }
    sig = Account.sign_message(encode_typed_data(full_message=full_message), evm_keypair["private_key"]).signature
    req = {
        "chain": {ATTEST_CHAIN: None},
        "tokenAddress": ATTEST_TOKEN,
        "threshold": ATTEST_THRESHOLD,
        "cid": "QmProbeGate",
        "evmAddress": evm_keypair["address"],
        "transportPublicKey": transport_public_key,
        "nonce": nonce,
        "signature": sig,
        "eip712ChainId": EIP712_CHAIN_ID,
        "eip712VerifyingContract": EIP712_VERIFYING_CONTRACT,
    }
    result = _unwrap_first(gate_canister.requestDecryptionKey(req, verify_certificate=False))
    assert isinstance(result, dict) and "err" in result, result


def test_mainnet_attest_ephemeral_wallet(ic_canister: Any, evm_keypair: dict[str, str]) -> None:
    """Full path through ecrecover + eth_call; ephemeral wallet should not reach signing."""
    nonce = (int(time.time_ns()) << 64) | int.from_bytes(secrets.token_bytes(8), "big")
    cid_hash = hashlib.sha256(b"probe-ephemeral-wallet").hexdigest()
    signature = _sign_attest_request(
        private_key=evm_keypair["private_key"],
        evm_address=evm_keypair["address"],
        cid_hash=cid_hash,
        nonce=nonce,
    )
    req = {
        "chain": {ATTEST_CHAIN: None},
        "tokenAddress": ATTEST_TOKEN,
        "threshold": ATTEST_THRESHOLD,
        "cidHash": cid_hash,
        "evmAddress": evm_keypair["address"],
        "nonce": nonce,
        "signature": signature,
        "eip712ChainId": EIP712_CHAIN_ID,
        "eip712VerifyingContract": EIP712_VERIFYING_CONTRACT,
    }
    response = ic_canister.attestHolding(req, verify_certificate=False)
    result = _unwrap_first(response)
    assert isinstance(result, dict), result
    if "ok" in result:
        pytest.skip("Ephemeral wallet unexpectedly met threshold; cannot assert InsufficientBalance")
    assert "err" in result, result
    err = result["err"]
    if isinstance(err, dict) and err:
        err_variant = next(iter(err))
        assert err_variant in (
            "InsufficientBalance",
            "EvmRpcError",
        ), f"Unexpected error (wanted InsufficientBalance or EvmRpcError): {err}"
    else:
        pytest.fail(f"Unexpected err shape: {err!r}")


def test_mainnet_batch_attest_invalid_signature(ic_canister: Any) -> None:
    """Pre-flight validation: must return InvalidSignature, not IC0406."""
    nonce = (int(time.time_ns()) << 64) | int.from_bytes(secrets.token_bytes(8), "big")
    cid_hashes = [hashlib.sha256(f"probe-batch-{i}".encode()).hexdigest() for i in range(3)]
    req = {
        "chain": {ATTEST_CHAIN: None},
        "tokenAddress": ATTEST_TOKEN,
        "threshold": ATTEST_THRESHOLD,
        "cidHashes": cid_hashes,
        "evmAddress": "0x" + "11" * 20,
        "nonce": nonce,
        "signature": bytes(65),
        "eip712ChainId": EIP712_CHAIN_ID,
        "eip712VerifyingContract": EIP712_VERIFYING_CONTRACT,
    }
    result = _unwrap_first(ic_canister.batchAttestHolding(req, verify_certificate=False))
    assert isinstance(result, dict) and "err" in result
    err = result["err"]
    if isinstance(err, dict) and err:
        err_variant = next(iter(err))
        assert err_variant == "InvalidSignature", err


def test_mainnet_batch_attest_ephemeral_wallet(ic_canister: Any, evm_keypair: dict[str, str]) -> None:
    """Full ecrecover + single eth_call path; ephemeral wallet should not reach signing."""
    nonce = (int(time.time_ns()) << 64) | int.from_bytes(secrets.token_bytes(8), "big")
    cid_hashes = [hashlib.sha256(f"probe-batch-ephemeral-{i}".encode()).hexdigest() for i in range(3)]
    signature = _sign_batch_attest_request(
        private_key=evm_keypair["private_key"],
        evm_address=evm_keypair["address"],
        cid_hashes=cid_hashes,
        nonce=nonce,
    )
    req = {
        "chain": {ATTEST_CHAIN: None},
        "tokenAddress": ATTEST_TOKEN,
        "threshold": ATTEST_THRESHOLD,
        "cidHashes": cid_hashes,
        "evmAddress": evm_keypair["address"],
        "nonce": nonce,
        "signature": signature,
        "eip712ChainId": EIP712_CHAIN_ID,
        "eip712VerifyingContract": EIP712_VERIFYING_CONTRACT,
    }
    response = ic_canister.batchAttestHolding(req, verify_certificate=False)
    result = _unwrap_first(response)
    assert isinstance(result, dict), result
    if "ok" in result:
        pytest.skip("Ephemeral wallet unexpectedly met threshold; cannot assert InsufficientBalance")
    assert "err" in result, result
    err = result["err"]
    if isinstance(err, dict) and err:
        err_variant = next(iter(err))
        assert err_variant in (
            "InsufficientBalance",
            "EvmRpcError",
        ), f"Unexpected error (wanted InsufficientBalance or EvmRpcError): {err}"
    else:
        pytest.fail(f"Unexpected err shape: {err!r}")
