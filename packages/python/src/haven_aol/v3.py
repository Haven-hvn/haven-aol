"""Haven-AOL Protocol v3 — Python SDK surface.

This module implements the v3 derivation, gate-metadata, EIP-712
typed-data, and parse/dispatch helpers described in
``docs/derivation-spec.md`` §Protocol v3 and frozen in
``tasking/README.md`` (Interface Contracts).

v3 is purely additive to v1: every v1 symbol in ``haven_aol.core``
keeps its name, signature, and byte-for-byte behaviour. This module
introduces:

  * ``EPOCH_LENGTH_SECONDS``               — protocol constant (30 days)
  * ``GATE_METADATA_VERSION_V3``           — JSON ``version`` discriminator
  * ``EIP712_GATE_REQUEST_V3_TYPE_STRING`` — exact EIP-712 type string
  * ``EIP712_GATE_REQUEST_V3_TYPEHASH``    — keccak256 of the type string
  * ``current_epoch()``                    — local-clock epoch helper
  * ``compute_derivation_input_v3``        — 32-byte SHA-256 derivation
  * ``build_gate_metadata_v3``             — gate-metadata JSON builder
  * ``parse_gate_metadata_v3``             — v3-only parser (returns None
                                             on any non-v3 record)
  * ``parse_gate_metadata``                — dispatching parser (v1 or v3)
  * ``gate_metadata_v3_to_json``           — byte-stable serializer
  * ``build_eip712_gate_request_v3_typed_data``
                                           — EIP-712 typed-data dict suitable
                                             for eth_account to sign

Design notes
------------

* No new dependencies. Only ``hashlib``, ``json``, ``time``, and ``re``
  from the standard library are imported. The keccak256 typehash is
  hard-coded from the spec rather than recomputed at runtime, which
  removes any need for a keccak library at SDK level. (The canister
  and the integration suite verify byte-identity against the type
  string — see ``tests/fixtures/derivation-v3-vectors.json``.)

* The SDK does **not** enforce the canister's threshold-zero collapse.
  It only refuses to *build* v3 metadata where the caller asserts
  ``threshold == 0`` together with ``epoch != 0``. This is the
  uploader-side mitigation called out in ``tasking/README.md`` (Key
  Design Decisions §5). The canister enforces collapse server-side.

* No I/O. All functions are pure. Callers (haven-cli, haven-dapp)
  are responsible for HTTP/Candid transport and IBE primitives.
"""

from __future__ import annotations

import hashlib
import json
import re
import time
from typing import Any, Mapping, Union

# ── Constants ──────────────────────────────────────────────────────

#: Length of a v3 epoch in seconds (30 days). Identical across Motoko,
#: Python, and TypeScript stacks. Changing this is a protocol-version bump.
EPOCH_LENGTH_SECONDS: int = 2_592_000

#: JSON ``version`` discriminator for v3 gate metadata records.
GATE_METADATA_VERSION_V3: int = 3

#: ASCII domain tag prefixed onto the v3 derivation preimage. Includes the
#: trailing colon so the preimage builder can simply concatenate fields.
_V3_DOMAIN_TAG: str = "accessol_v3:"

#: EIP-712 primary-type string for v3 gate requests. Whitespace is exact;
#: keccak256 of this UTF-8 byte string is the typehash.
EIP712_GATE_REQUEST_V3_TYPE_STRING: str = (
    "GateRequestV3(address evmAddress,bytes transportPublicKey,"
    "uint256 epoch,uint256 nonce)"
)

#: keccak256 of ``EIP712_GATE_REQUEST_V3_TYPE_STRING`` encoded UTF-8.
#: Pinned in ``docs/derivation-spec.md`` §v3.6 and
#: ``tests/fixtures/derivation-v3-vectors.json`` (``eip712TypehashHex``).
EIP712_GATE_REQUEST_V3_TYPEHASH: bytes = bytes.fromhex(
    "bf3ae9382ccda27b087c12bfb5fd82fa7ccc60857623462a4c7fec696bc7d7af"
)

# ── Internal validation helpers ────────────────────────────────────

# Chain variant names and token-address shape are duplicated from
# ``haven_aol.core`` rather than imported so this module loads without
# the v1 native crypto extension (``haven_aol_vetkeys``) present. v3
# itself does no IBE / VetKD work — it is pure derivation + metadata —
# so requiring the v1 extension at import time would be wrong. The
# duplication is intentional and is checked by a SDK-internal parity
# test (``TestV3ChainParityWithCore`` in ``tests/test_haven_aol_v3.py``).
VALID_CHAINS = frozenset({
    "EthMainnet",
    "EthSepolia",
    "ArbitrumOne",
    "BaseMainnet",
    "OptimismMainnet",
})
_TOKEN_ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
_BASE64_RE = re.compile(r"^[A-Za-z0-9+/]+={0,2}$")
_THRESHOLD_STR_RE = re.compile(r"^(0|[1-9][0-9]*)$")


def _require_chain(chain: str) -> None:
    if chain not in VALID_CHAINS:
        raise ValueError(f"Invalid chain: {chain!r}")


def _require_token_address(token_address: str) -> None:
    if not isinstance(token_address, str) or not _TOKEN_ADDR_RE.match(token_address):
        raise ValueError(f"Invalid token address: {token_address!r}")


def _require_nat(value: Any, *, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{name} must be a non-negative integer, got {value!r}")
    return value


# ── Epoch helper ───────────────────────────────────────────────────


def current_epoch() -> int:
    """Return the current v3 epoch from the local wall clock.

    ``epoch = floor(unix_seconds / EPOCH_LENGTH_SECONDS)``.

    This MUST be called per-file by uploaders, not once per session.
    See ``tasking/README.md`` (Key Design Decisions §4).
    """
    return int(time.time()) // EPOCH_LENGTH_SECONDS


# ── Derivation input ───────────────────────────────────────────────


def compute_derivation_input_v3(
    chain: str,
    token_address: str,
    threshold: int,
    epoch: int,
) -> bytes:
    """Compute the v3 derivation input.

    Returns the 32-byte SHA-256 digest of the UTF-8 preimage::

        "accessol_v3:" + chain + ":" + tokenAddress + ":"
            + decimal(threshold) + ":" + decimal(epoch)

    No collapse is performed — the SDK reports byte-identical bytes for
    the literal inputs. Canister-side collapse is verified by the
    integration suite, not by the SDK.

    Raises:
        ValueError: on invalid chain, token address, or negative threshold/epoch.
    """
    _require_chain(chain)
    _require_token_address(token_address)
    _require_nat(threshold, name="threshold")
    _require_nat(epoch, name="epoch")

    preimage = (
        f"{_V3_DOMAIN_TAG}{chain}:{token_address}:{threshold}:{epoch}"
    )
    return hashlib.sha256(preimage.encode("utf-8")).digest()


# ── Gate metadata v3 ───────────────────────────────────────────────


def build_gate_metadata_v3(
    *,
    cid: str,
    chain: str,
    token_address: str,
    threshold: int,
    epoch: int,
    encrypted_aes_key_b64: str,
) -> dict:
    """Build a v3 gate-metadata dict.

    Field order is pinned by ``tasking/README.md`` (Interface Contracts):
    ``version, cid, chain, tokenAddress, threshold, epoch, encryptedAesKey``.

    Threshold-zero mitigation: when ``threshold == 0`` the caller MUST
    also pass ``epoch == 0`` so that the uploader-side metadata agrees
    with the canister's collapse. Passing ``threshold == 0`` together
    with ``epoch != 0`` raises ``ValueError``. See
    ``tasking/README.md`` (Key Design Decisions §5).
    """
    if not isinstance(cid, str) or not cid:
        raise ValueError("CID must be a non-empty string")
    _require_chain(chain)
    _require_token_address(token_address)
    threshold = _require_nat(threshold, name="threshold")
    epoch = _require_nat(epoch, name="epoch")

    if threshold == 0 and epoch != 0:
        raise ValueError(
            "threshold==0 requires epoch==0 (canister collapses epoch to 0; "
            "uploader metadata must match — see derivation-spec.md §v3.4)"
        )

    if not isinstance(encrypted_aes_key_b64, str) or not _BASE64_RE.match(
        encrypted_aes_key_b64
    ):
        raise ValueError(
            "encrypted_aes_key_b64 must be a non-empty standard base64 string"
        )

    return {
        "version": GATE_METADATA_VERSION_V3,
        "cid": cid,
        "chain": chain,
        "tokenAddress": token_address,
        "threshold": str(threshold),
        "epoch": epoch,
        "encryptedAesKey": encrypted_aes_key_b64,
    }


def gate_metadata_v3_to_json(metadata: Mapping[str, Any]) -> str:
    """Serialize a v3 gate-metadata dict to its canonical JSON string.

    Uses ``separators=(",", ":")`` and ``sort_keys=False`` so the field
    order in the input dict is preserved. Producers should always pass
    the dict returned from :func:`build_gate_metadata_v3`, which uses
    the canonical order.
    """
    if metadata.get("version") != GATE_METADATA_VERSION_V3:
        raise ValueError(
            f"gate_metadata_v3_to_json: expected version "
            f"{GATE_METADATA_VERSION_V3}, got {metadata.get('version')!r}"
        )
    return json.dumps(dict(metadata), separators=(",", ":"), sort_keys=False)


# ── Parsing / dispatch ─────────────────────────────────────────────


def _coerce_raw(raw: Union[str, bytes, Mapping[str, Any]]) -> Union[dict, None]:
    """Best-effort decode of ``raw`` into a dict. Returns None on failure."""
    if isinstance(raw, Mapping):
        return dict(raw)
    if isinstance(raw, (bytes, bytearray)):
        try:
            raw = raw.decode("utf-8")
        except UnicodeDecodeError:
            return None
    if isinstance(raw, str):
        try:
            decoded = json.loads(raw)
        except (ValueError, TypeError):
            return None
        if isinstance(decoded, dict):
            return decoded
    return None


def parse_gate_metadata_v3(
    raw: Union[str, bytes, Mapping[str, Any]],
) -> Union[dict, None]:
    """Parse a v3 gate-metadata record.

    Returns ``None`` for any record whose ``version`` is not the integer
    ``3``. v3 records pass through every field validation rule pinned in
    ``docs/derivation-spec.md`` §v3.9; on validation failure ``None`` is
    returned (the canister, not the SDK, is the source of truth — a
    decryptor that gets ``None`` should treat the record as malformed
    and refuse to spend a gate request on it).
    """
    record = _coerce_raw(raw)
    if record is None:
        return None
    if record.get("version") != GATE_METADATA_VERSION_V3:
        return None

    # version is an int 3 (not "3", not 3.0). Equality already enforced
    # by the check above because Python ``3 == 3.0`` is True but ``3 ==
    # "3"`` is False; we additionally reject bool (since bool is a subtype
    # of int and ``True == 1``).
    if isinstance(record["version"], bool) or not isinstance(record["version"], int):
        return None

    cid = record.get("cid")
    if not isinstance(cid, str) or not cid:
        return None

    chain = record.get("chain")
    if chain not in VALID_CHAINS:
        return None

    token_address = record.get("tokenAddress")
    if not isinstance(token_address, str) or not _TOKEN_ADDR_RE.match(token_address):
        return None

    threshold = record.get("threshold")
    if not isinstance(threshold, str) or not _THRESHOLD_STR_RE.match(threshold):
        return None

    epoch = record.get("epoch")
    if isinstance(epoch, bool) or not isinstance(epoch, int) or epoch < 0:
        return None

    # threshold-zero parity check: a v3 record claiming threshold "0"
    # must carry epoch 0 in metadata (the canister would collapse it
    # regardless, so a non-zero epoch indicates a malformed uploader).
    if threshold == "0" and epoch != 0:
        return None

    encrypted_aes_key = record.get("encryptedAesKey")
    if not isinstance(encrypted_aes_key, str) or not _BASE64_RE.match(
        encrypted_aes_key
    ):
        return None

    # Return a fresh dict so callers can mutate without affecting input.
    return {
        "version": GATE_METADATA_VERSION_V3,
        "cid": cid,
        "chain": chain,
        "tokenAddress": token_address,
        "threshold": threshold,
        "epoch": epoch,
        "encryptedAesKey": encrypted_aes_key,
    }


def _parse_gate_metadata_v1(
    raw: Union[str, bytes, Mapping[str, Any]],
) -> Union[dict, None]:
    """Parse a v1 gate-metadata record. Returns the raw dict unchanged.

    The dispatch parser routes ``version == 1`` records here. We
    intentionally **do not normalize** — v1's existing builders and
    serializers in ``haven_aol.core`` are the canonical shape, and any
    field rewrite here would break the byte-identity guarantee called
    out in ``tasking/README.md`` (Key Design Decisions §1).
    """
    record = _coerce_raw(raw)
    if record is None:
        return None
    if record.get("version") != 1:
        return None
    if isinstance(record["version"], bool) or not isinstance(record["version"], int):
        return None
    # Minimal sanity: required v1 fields must exist. We don't re-validate
    # every byte here because v1's builders already enforce it on the
    # write side, and the dispatch parser's contract is "return the
    # existing v1 record unchanged."
    for required in ("cid", "chain", "tokenAddress", "threshold", "encryptedAesKey"):
        if required not in record:
            return None
    return dict(record)


def parse_gate_metadata(
    raw: Union[str, bytes, Mapping[str, Any]],
) -> Union[dict, None]:
    """Dispatching gate-metadata parser.

    Routes records to the v1 or v3 parser based on the integer
    ``version`` discriminator:

      * ``version == 1`` → v1 parser (record returned unchanged).
      * ``version == 3`` → v3 parser (record returned with validated fields).
      * anything else    → ``None``.

    Returns a dict (with the ``version`` key intact) or ``None`` on any
    parse / validation failure.
    """
    record = _coerce_raw(raw)
    if record is None:
        return None
    version = record.get("version")
    if isinstance(version, bool):
        return None
    if version == GATE_METADATA_VERSION_V3:
        return parse_gate_metadata_v3(record)
    if version == 1:
        return _parse_gate_metadata_v1(record)
    return None


# ── EIP-712 typed data ─────────────────────────────────────────────


def build_eip712_gate_request_v3_typed_data(
    *,
    evm_address: str,
    transport_public_key: bytes,
    epoch: int,
    nonce: int,
    eip712_chain_id: int,
    eip712_verifying_contract: str,
) -> dict:
    """Build the EIP-712 typed-data dict for a v3 gate request.

    The returned dict is suitable for ``eth_account.messages.encode_typed_data``
    (or any other EIP-712 signer) to consume. Field order inside
    ``types.GateRequestV3`` is the order pinned in
    ``EIP712_GATE_REQUEST_V3_TYPE_STRING``: ``evmAddress``,
    ``transportPublicKey``, ``epoch``, ``nonce``.

    The EIP-712 domain matches the canister's ``eip712DomainSeparator``
    helper in ``src/backend/main.mo`` (three-field domain — no
    ``version`` field; ``name`` is ``"HavenAOL"``).
    """
    _require_token_address(evm_address)  # same regex; address shape is identical
    _require_token_address(eip712_verifying_contract)
    if not isinstance(transport_public_key, (bytes, bytearray)) or not transport_public_key:
        raise ValueError("transport_public_key must be non-empty bytes")
    _require_nat(epoch, name="epoch")
    _require_nat(nonce, name="nonce")
    _require_nat(eip712_chain_id, name="eip712_chain_id")

    return {
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"},
            ],
            "GateRequestV3": [
                {"name": "evmAddress", "type": "address"},
                {"name": "transportPublicKey", "type": "bytes"},
                {"name": "epoch", "type": "uint256"},
                {"name": "nonce", "type": "uint256"},
            ],
        },
        "primaryType": "GateRequestV3",
        "domain": {
            "name": "HavenAOL",
            "chainId": eip712_chain_id,
            "verifyingContract": eip712_verifying_contract,
        },
        "message": {
            "evmAddress": evm_address,
            "transportPublicKey": "0x" + bytes(transport_public_key).hex(),
            "epoch": epoch,
            "nonce": nonce,
        },
    }


__all__ = [
    "EPOCH_LENGTH_SECONDS",
    "GATE_METADATA_VERSION_V3",
    "EIP712_GATE_REQUEST_V3_TYPE_STRING",
    "EIP712_GATE_REQUEST_V3_TYPEHASH",
    "current_epoch",
    "compute_derivation_input_v3",
    "build_gate_metadata_v3",
    "gate_metadata_v3_to_json",
    "parse_gate_metadata_v3",
    "parse_gate_metadata",
    "build_eip712_gate_request_v3_typed_data",
]
