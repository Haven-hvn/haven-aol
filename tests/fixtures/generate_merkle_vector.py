#!/usr/bin/env python3
"""
Generate canonical Merkle attestation test vectors for N=1, N=2, N=4, N=20.

Mirrors src/backend/main.mo's batchAttestHolding implementation byte-for-byte:
  • RFC 6962-style domain separation (0x00 leaf, 0x01 node)
  • ZERO_LEAF = SHA-256(0x00 ‖ "HAVEN_MERKLE_ZERO") padding sentinel
  • Heap-indexed binary tree (root=0, children at 2p+1, 2p+2)
  • cidHashes sorted lexicographically AFTER EIP-712 verification
  • Per-leaf proofs emitted in SUBMISSION order
  • side = 'left'  → sibling on left  → sha256(0x01 ‖ sibling ‖ current)
  • side = 'right' → sibling on right → sha256(0x01 ‖ current ‖ sibling)

Run:
    python3 tests/fixtures/generate_merkle_vector.py
"""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

LEAF_PREFIX = b"\x00"
NODE_PREFIX = b"\x01"


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def hash_leaf(preimage: bytes) -> bytes:
    return sha256(LEAF_PREFIX + preimage)


def hash_node(left: bytes, right: bytes) -> bytes:
    return sha256(NODE_PREFIX + left + right)


ZERO_LEAF = hash_leaf(b"HAVEN_MERKLE_ZERO")


def leaf_preimage(
    chain: str,
    token_address: str,
    threshold: int,
    evm_address: str,
    cid_hash: str,
    timestamp: int,
    balance: int,
) -> bytes:
    return (
        f"HAVEN_ATTEST_V1:{chain}:{token_address}:{threshold}:"
        f"{evm_address}:{cid_hash}:{timestamp}:{balance}"
    ).encode("utf-8")


def batch_preimage(
    chain: str,
    token_address: str,
    threshold: int,
    evm_address: str,
    merkle_root_hex: str,
    cid_count: int,
    timestamp: int,
    balance: int,
) -> bytes:
    return (
        f"HAVEN_BATCH_ATTEST_V1:{chain}:{token_address}:{threshold}:"
        f"{evm_address}:{merkle_root_hex}:{cid_count}:{timestamp}:{balance}"
    ).encode("utf-8")


def next_pow2(n: int) -> int:
    if n <= 1:
        return 1
    return 1 << (n - 1).bit_length()


def build_heap(sorted_leaf_hashes: list[bytes], limit: int) -> list[bytes]:
    """Heap layout: nodes[0..2*limit-2]; leaves at [limit-1..2*limit-2]."""
    total = 2 * limit - 1
    nodes = [b"\x00" * 32] * total
    for i in range(limit):
        nodes[limit - 1 + i] = sorted_leaf_hashes[i] if i < len(sorted_leaf_hashes) else ZERO_LEAF
    if limit > 1:
        for p in range(limit - 2, -1, -1):
            nodes[p] = hash_node(nodes[2 * p + 1], nodes[2 * p + 2])
    return nodes


def proof_for_leaf(nodes: list[bytes], leaf_heap_idx: int) -> list[dict]:
    out: list[dict] = []
    p = leaf_heap_idx
    while p > 0:
        if p % 2 == 1:
            sibling_idx, side = p + 1, "right"
        else:
            sibling_idx, side = p - 1, "left"
        out.append({"side": side, "hash": nodes[sibling_idx].hex()})
        p = (p - 1) // 2
    return out


def verify_proof(leaf_hash: bytes, proof: list[dict], expected_root: bytes) -> bool:
    h = leaf_hash
    for step in proof:
        sibling = bytes.fromhex(step["hash"])
        if step["side"] == "left":
            h = hash_node(sibling, h)
        else:
            h = hash_node(h, sibling)
    return h == expected_root


def build_vector(
    *,
    name: str,
    chain: str,
    token_address: str,
    threshold: int,
    evm_address: str,
    cid_hashes: list[str],
    timestamp: int,
    balance: int,
) -> dict:
    """cid_hashes is in *submission* order (lower-case 64-char hex, no 0x)."""
    cid_hashes = [c.lower() for c in cid_hashes]

    # Sort with submission index, derive submission→sorted mapping.
    pairs = sorted(enumerate(cid_hashes), key=lambda kv: kv[1])
    submission_to_sorted = [0] * len(cid_hashes)
    for sorted_idx, (sub_idx, _) in enumerate(pairs):
        submission_to_sorted[sub_idx] = sorted_idx

    sorted_leaf_hashes = [
        hash_leaf(
            leaf_preimage(chain, token_address, threshold, evm_address, h, timestamp, balance)
        )
        for _, h in pairs
    ]

    limit = next_pow2(len(cid_hashes))
    nodes = build_heap(sorted_leaf_hashes, limit)
    merkle_root = nodes[0]

    leaves: list[dict] = []
    for sub_idx, cid_hash in enumerate(cid_hashes):
        sorted_idx = submission_to_sorted[sub_idx]
        leaf_heap_idx = limit - 1 + sorted_idx
        proof = proof_for_leaf(nodes, leaf_heap_idx)
        # Self-verify before emitting.
        own_leaf = hash_leaf(
            leaf_preimage(chain, token_address, threshold, evm_address, cid_hash, timestamp, balance)
        )
        assert verify_proof(own_leaf, proof, merkle_root), f"proof verify failed for {cid_hash}"
        leaves.append({"cidHash": cid_hash, "merkleProof": proof})

    return {
        "name": name,
        "input": {
            "chain": chain,
            "tokenAddress": token_address,
            "threshold": threshold,
            "evmAddress": evm_address,
            "cidHashes_submissionOrder": cid_hashes,
        },
        "expected": {
            "timestamp": timestamp,
            "balanceAtCheck": balance,
            "cidCount": len(cid_hashes),
            "merkleRoot": merkle_root.hex(),
            "batchPreimage_utf8": batch_preimage(
                chain, token_address, threshold, evm_address, merkle_root.hex(),
                len(cid_hashes), timestamp, balance,
            ).decode("utf-8"),
            "leaves_submissionOrder": leaves,
            "padLimit": limit,
            "zeroLeaf": ZERO_LEAF.hex(),
        },
        "constants": {
            "LEAF_PREFIX": "0x00",
            "NODE_PREFIX": "0x01",
            "leafPreimageFormat": (
                "HAVEN_ATTEST_V1:{chain}:{tokenAddress}:{threshold}:"
                "{evmAddress}:{cidHash}:{timestamp}:{balanceAtCheck}"
            ),
            "batchPreimageFormat": (
                "HAVEN_BATCH_ATTEST_V1:{chain}:{tokenAddress}:{threshold}:"
                "{evmAddress}:{merkleRootHex}:{cidCount}:{timestamp}:{balanceAtCheck}"
            ),
        },
    }


# Deterministic 32-byte cidHashes used throughout fixtures (chosen so they
# don't sort into submission order, exercising the submission→sorted mapping).
CID_POOL = [
    "f" * 64,                                                              # cid_FF…
    "a" * 64,                                                              # cid_AA…
    "0" * 63 + "1",                                                        # cid_00…01
    "5" * 64,                                                              # cid_55…
    "deadbeef" * 8,
    "cafebabe" * 8,
    "1234567890abcdef" * 4,
    "fedcba9876543210" * 4,
    "0001020304050607" * 4,
    "0a0b0c0d0e0f1011" * 4,
    "1112131415161718" * 4,
    "20" * 32,
    "30" * 32,
    "40" * 32,
    "50" * 32,
    "60" * 32,
    "70" * 32,
    "80" * 32,
    "90" * 32,
    "a0" * 32,
]


COMMON = dict(
    chain="EthMainnet",
    token_address="0x6982508145454ce325ddbe47a25d4ec3d2311933",
    threshold=1_000_000_000_000_000_000,
    evm_address="0x742d35cc6634c0532925a3b844bc9e7595f0beb1",
    timestamp=1_700_000_000,
    balance=5_000_000_000_000_000_000,
)


def main() -> None:
    out_dir = Path(__file__).parent
    sizes = [1, 2, 4, 20]
    for n in sizes:
        vec = build_vector(name=f"merkle-attest-vector-n{n}", cid_hashes=CID_POOL[:n], **COMMON)
        path = out_dir / f"merkle-attest-vector-n{n}.json"
        path.write_text(json.dumps(vec, indent=2) + "\n")
        print(f"wrote {path}  root={vec['expected']['merkleRoot']}")


if __name__ == "__main__":
    main()
