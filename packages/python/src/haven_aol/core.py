"""Core functions for Haven-AOL upload-side encryption."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
from typing import Optional

import haven_aol_vetkeys
from icp_principal import Principal

# Valid chain variant names (must match Candid Chain type exactly)
VALID_CHAINS = frozenset({
    "EthMainnet",
    "EthSepolia",
    "ArbitrumOne",
    "BaseMainnet",
    "OptimismMainnet",
})

# Default VetKD context — must match canister and TypeScript package (protocol v1).
DEFAULT_CONTEXT = b"accessol_v1"

# Token address regex: 0x followed by exactly 40 hex chars
_TOKEN_ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")


def compute_derivation_input(
    chain: str,
    token_address: str,
    threshold: int,
    cid: str,
) -> bytes:
    """Compute the derivation input hash per docs/derivation-spec.md.

    Returns 32 raw bytes (SHA-256 digest).
    """
    if chain not in VALID_CHAINS:
        raise ValueError(f"Invalid chain: {chain!r}")
    if not _TOKEN_ADDR_RE.match(token_address):
        raise ValueError(f"Invalid token address: {token_address!r}")
    if not isinstance(threshold, int) or threshold < 0:
        raise ValueError(f"Threshold must be a non-negative integer, got {threshold!r}")
    if not cid:
        raise ValueError("CID must be a non-empty string")

    preimage = f"accessol:{chain}:{token_address}:{threshold}:{cid}"
    return hashlib.sha256(preimage.encode("utf-8")).digest()


def encrypt_file(
    plaintext: bytes,
    aes_key: Optional[bytes] = None,
) -> tuple[bytes, bytes, bytes]:
    """AES-256-GCM encrypt plaintext.

    Args:
        plaintext: Data to encrypt.
        aes_key: Optional 32-byte key. Generated randomly if not provided.

    Returns:
        (ciphertext, aes_key, iv) where ciphertext = [12-byte IV || ciphertext+tag].
    """
    if aes_key is None:
        aes_key = os.urandom(32)
    if len(aes_key) != 32:
        raise ValueError(f"AES key must be 32 bytes, got {len(aes_key)}")

    iv = os.urandom(12)

    # Use cryptography library's AES-GCM if available, otherwise fall back
    # to a minimal implementation using the standard library
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        aesgcm = AESGCM(aes_key)
        ct_and_tag = aesgcm.encrypt(iv, plaintext, None)
    except ImportError:
        # Fallback: use OpenSSL via ctypes or raise
        raise ImportError(
            "The 'cryptography' package is required for AES-256-GCM. "
            "Install it with: pip install cryptography"
        )

    # Output format: [12-byte IV][ciphertext + 16-byte auth tag]
    ciphertext = iv + ct_and_tag
    return ciphertext, aes_key, iv


def derive_verification_key(
    canister_id: bytes | str,
    context: bytes = DEFAULT_CONTEXT,
    key_name: str = "key_1",
    verification_key_bytes: Optional[bytes] = None,
) -> bytes:
    """Derive the VetKD verification key offline from the mainnet master key.

    Args:
        canister_id: Canister principal as raw bytes or text (e.g. "bkyz2-fmaaa-aaaaa-qaaaq-cai").
        context: Domain separator bytes. Default: b"accessol_v1" (protocol v1).
        key_name: Master key name. Default: "key_1".
        verification_key_bytes: If provided, skip offline derivation and validate
            these bytes as a DerivedPublicKey instead. Use for local dev where
            the mainnet master key doesn't match.

    Returns:
        Serialized DerivedPublicKey bytes (96 bytes, compressed G2 point).
    """
    if verification_key_bytes is not None:
        # Validate and return — useful for local dev mode
        return haven_aol_vetkeys.deserialize_derived_public_key(verification_key_bytes)

    if isinstance(canister_id, str):
        canister_id = _principal_text_to_bytes(canister_id)

    return haven_aol_vetkeys.derive_verification_key(key_name, canister_id, context)


def ibe_encrypt_aes_key(
    aes_key: bytes,
    derived_public_key: bytes,
    derivation_input: bytes,
) -> bytes:
    """IBE-encrypt the AES key using the derived public key and derivation input as identity.

    Args:
        aes_key: 32-byte AES key to encrypt.
        derived_public_key: Serialized DerivedPublicKey (96 bytes).
        derivation_input: Raw hash bytes used as IBE identity (32 bytes).

    Returns:
        Serialized IbeCiphertext bytes.
    """
    return haven_aol_vetkeys.ibe_encrypt(derived_public_key, derivation_input, aes_key)


def build_gate_metadata(
    cid: str,
    chain: str,
    token_address: str,
    threshold: int,
    encrypted_aes_key: bytes,
) -> dict:
    """Build the gate metadata dict.

    Args:
        cid: IPFS CID string.
        chain: Chain variant name (e.g. "EthMainnet").
        token_address: 0x-prefixed checksummed ERC-20 address.
        threshold: Minimum token balance in smallest units.
        encrypted_aes_key: Serialized IbeCiphertext bytes.

    Returns:
        Gate metadata dict matching the schema.
    """
    if chain not in VALID_CHAINS:
        raise ValueError(f"Invalid chain: {chain!r}")
    if not _TOKEN_ADDR_RE.match(token_address):
        raise ValueError(f"Invalid token address: {token_address!r}")
    if not isinstance(threshold, int) or threshold < 0:
        raise ValueError(f"Threshold must be a non-negative integer, got {threshold!r}")
    if not cid:
        raise ValueError("CID must be a non-empty string")

    return {
        "version": 1,
        "cid": cid,
        "chain": chain,
        "tokenAddress": token_address,
        "threshold": str(threshold),
        "encryptedAesKey": base64.b64encode(encrypted_aes_key).decode("ascii"),
    }


def serialize_gate_metadata(metadata: dict) -> str:
    """Serialize gate metadata to JSON string.

    Args:
        metadata: Gate metadata dict (from build_gate_metadata).

    Returns:
        JSON string.
    """
    return json.dumps(metadata, separators=(",", ":"))


def _principal_text_to_bytes(text: str) -> bytes:
    """Convert a textual principal (e.g. 'bkyz2-fmaaa-aaaaa-qaaaq-cai') to raw bytes.

    Uses ``Principal.from_str`` from the ``icp-py-core`` distribution on PyPI
    (``icp_principal``), matching the IC interface spec checksum and base32 rules.
    """
    return Principal.from_str(text).bytes
