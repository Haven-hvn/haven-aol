"""Haven-AOL Protocol v4 — Python SDK surface.

Market-cap-gated progressive unlock ("drip") per
``haven-v4-marketcap-drip.md`` and ``docs/derivation-spec.md``
§Protocol v4. v4 is purely additive to v1/v3: this module introduces

  * ``GATE_METADATA_VERSION_V4``           — JSON ``version`` discriminator
  * ``EIP712_GATE_REQUEST_V4_TYPE_STRING`` — exact EIP-712 type string
  * ``EIP712_GATE_REQUEST_V4_TYPEHASH``    — keccak256 of the type string
  * ``MARKET_CAP_CACHE_TTL_SECONDS``       — canister burst-cache TTL (300)
  * ``BOND_ADDRESSES``                     — chain-keyed Bond contracts
  * ``is_bond_address``                      — Bond-address check
  * ``compute_derivation_input_v4``        — 32-byte SHA-256 derivation
  * ``build_gate_metadata_v4``             — gate-metadata JSON builder
  * ``parse_gate_metadata_v4``             — v4-only parser (None on any
                                              non-v4 record)
  * ``build_eip712_gate_request_v4_typed_data``
                                            — EIP-712 typed-data dict for
                                              eth_account signers

Design notes mirror ``haven_aol.v3``:

* No new dependencies — stdlib only. The keccak256 typehash is hard-coded.
* The SDK does NOT enforce the canister's threshold-zero collapse; it only
  refuses to *build* metadata asserting ``threshold == 0, epoch != 0``.
* The SDK performs NO oracle calls. Market-cap enforcement lives in the
  canister (`requestDecryptionKeyV4`); publishers/readers may preview with
  off-chain data but the gate decision is on-chain.
* No I/O. All functions are pure.
* Arkiv marker: entities carrying v4 gates store ``gate_type = 4``
  (ATTR_UINT; 1=per-file, 3=per-epoch, 4=per-marketcap;
  ``gate_type == gate.version``). The gate JSON ``version`` field itself
  is unchanged by that rename.
"""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any, Mapping, Union

# ── Constants ──────────────────────────────────────────────────────

#: Length of a v3/v4 epoch in seconds (30 days). Shared with v3.
EPOCH_LENGTH_SECONDS: int = 2_592_000

#: JSON ``version`` discriminator for v4 gate-metadata records.
GATE_METADATA_VERSION_V4: int = 4

#: ASCII domain tag prefixed onto the v4 derivation preimage.
_V4_DOMAIN_TAG: str = "accessol_v4:"

#: EIP-712 primary-type string for v4 gate requests. Whitespace is exact;
#: keccak256 of this UTF-8 byte string is the typehash.
EIP712_GATE_REQUEST_V4_TYPE_STRING: str = (
    "GateRequestV4(address evmAddress,bytes transportPublicKey,"
    "uint256 epoch,uint256 marketCapTarget,uint256 nonce)"
)

#: keccak256 of ``EIP712_GATE_REQUEST_V4_TYPE_STRING`` encoded UTF-8.
#: Pinned in ``tests/fixtures/derivation-v4-vectors.json``
#: (``constants.eip712TypehashHex``).
EIP712_GATE_REQUEST_V4_TYPEHASH: bytes = bytes.fromhex(
    "b9d5f143468a4d6e11bd1d2ff3eb546445b99a1e871adde2cd2c6008e2980afd"
)

#: Canister-side market-cap burst-cache TTL (seconds). Deliberately short:
#: crypto markets reprice continuously, so a long-lived snapshot would make
#: unlock decisions meaningless. Mirrors MARKET_CAP_CACHE_TTL_SECONDS in
#: src/backend/main.mo.
MARKET_CAP_CACHE_TTL_SECONDS: int = 300

#: Chain-keyed mint.club V2 Bond contract addresses. Mainnet Bond is
#: CREATE2-deployed (same address on every mainnet chain); EthSepolia uses
#: the separate testnet deployment (from the @mint.club/v2-sdk BOND
#: registry). The canister seeds all five chains from
#: ``BOND_ADDRESS_DEFAULT`` / ``BOND_ADDRESS_SEPOLIA`` in
#: ``src/backend/main.mo``; further chains need ``setBondConfig``.
#: Mirrors the dapp's ``BOND_ADDRESS_HINTS``
#: (``haven-dapp/src/lib/v4/market-cap.ts``), keyed here by SDK chain
#: name rather than Mint Club network key.
BOND_ADDRESSES: dict = {
    "EthMainnet": "0xc5a076cad94176c2996B32d8466Be1cE757FAa27",
    "BaseMainnet": "0xc5a076cad94176c2996B32d8466Be1cE757FAa27",
    "ArbitrumOne": "0xc5a076cad94176c2996B32d8466Be1cE757FAa27",
    "OptimismMainnet": "0xc5a076cad94176c2996B32d8466Be1cE757FAa27",
    "EthSepolia": "0x8dce343A86Aa950d539eeE0e166AFfd0Ef515C0c",
}


def is_bond_address(chain: str, address: str) -> bool:
    """Bond-address check.

    Returns True iff ``address`` (any hex casing) names the Bond contract
    for ``chain``. The canister requires the gate's ``oracle_address`` to
    be the Bond — the curve is the only price source — so anything else
    fails closed. Unknown chains never match.
    """
    expected = BOND_ADDRESSES.get(chain)
    if not isinstance(expected, str) or not isinstance(address, str):
        return False
    return address.lower() == expected.lower()

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


# ── Derivation input ───────────────────────────────────────────────


def compute_derivation_input_v4(
    chain: str,
    token_address: str,
    threshold: int,
    epoch: int,
    market_cap_target: int,
) -> bytes:
    """Compute the v4 derivation input.

    Returns the 32-byte SHA-256 digest of the UTF-8 preimage::

        "accessol_v4:" + chain + ":" + tokenAddress + ":"
            + decimal(threshold) + ":" + decimal(epoch) + ":"
            + decimal(marketCapTarget)

    The market-cap target ALWAYS participates in the preimage (no collapse):
    two chunks of one drip with different targets derive different keys even
    under identical gate tuples. No threshold-zero collapse is performed here
    either — byte parity is against literal inputs; the canister collapses
    server-side and the integration suite pins that behaviour.

    Byte-identity vectors: ``tests/fixtures/derivation-v4-vectors.json``.

    Raises:
        ValueError: on invalid chain/token address or negative integers.
    """
    _require_chain(chain)
    _require_token_address(token_address)
    _require_nat(threshold, name="threshold")
    _require_nat(epoch, name="epoch")
    _require_nat(market_cap_target, name="market_cap_target")

    preimage = (
        f"{_V4_DOMAIN_TAG}{chain}:{token_address}:{threshold}:"
        f"{epoch}:{market_cap_target}"
    )
    return hashlib.sha256(preimage.encode("utf-8")).digest()


# ── Gate metadata v4 ───────────────────────────────────────────────


def build_gate_metadata_v4(
    *,
    cid: str,
    chain: str,
    token_address: str,
    threshold: int,
    epoch: int,
    market_cap_target: int,
    oracle_address: str,
    encrypted_aes_key_b64: str,
) -> dict:
    """Build a v4 gate-metadata dict.

    Field order is pinned by ``tests/fixtures/derivation-v4-vectors.json``
    consumers and mirrors the canister's ``GateRequestV4`` semantics:
    ``version, cid, chain, tokenAddress, threshold, epoch, marketCapTarget,
    oracleAddress, encryptedAesKey``.

    Threshold-zero mitigation matches v3: ``threshold == 0`` requires
    ``epoch == 0`` (canister collapse rule). ``market_cap_target`` is whole
    reserve units (whole ETH for v1 native-reserve tokens) — the Bond curve
    is the only price source, so there is no USD leg.
    ``oracle_address`` must name the chain's Bond contract (see
    ``is_bond_address``); anything else fails closed.
    """
    if not isinstance(cid, str) or not cid:
        raise ValueError("CID must be a non-empty string")
    _require_chain(chain)
    _require_token_address(token_address)
    threshold = _require_nat(threshold, name="threshold")
    epoch = _require_nat(epoch, name="epoch")
    market_cap_target = _require_nat(market_cap_target, name="market_cap_target")
    _require_token_address(oracle_address)

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
        "version": GATE_METADATA_VERSION_V4,
        "cid": cid,
        "chain": chain,
        "tokenAddress": token_address,
        "threshold": str(threshold),
        "epoch": epoch,
        "marketCapTarget": market_cap_target,
        "oracleAddress": oracle_address,
        "encryptedAesKey": encrypted_aes_key_b64,
    }


def gate_metadata_v4_to_json(metadata: Mapping[str, Any]) -> str:
    """Serialize a v4 gate-metadata dict to its canonical JSON string."""
    if metadata.get("version") != GATE_METADATA_VERSION_V4:
        raise ValueError(
            f"gate_metadata_v4_to_json: expected version "
            f"{GATE_METADATA_VERSION_V4}, got {metadata.get('version')!r}"
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


def parse_gate_metadata_v4(
    raw: Union[str, bytes, Mapping[str, Any]],
) -> Union[dict, None]:
    """Parse a v4 gate-metadata record.

    Returns ``None`` for any record whose ``version`` is not the integer
    ``4``, or which fails any field validation rule (address shape, base64
    key, non-negative integers, threshold-zero/epoch-zero parity).
    """
    record = _coerce_raw(raw)
    if record is None:
        return None
    version = record.get("version")
    if isinstance(version, bool) or not isinstance(version, int):
        return None
    if version != GATE_METADATA_VERSION_V4:
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

    market_cap_target = record.get("marketCapTarget")
    if (
        isinstance(market_cap_target, bool)
        or not isinstance(market_cap_target, int)
        or market_cap_target < 0
    ):
        return None

    oracle_address = record.get("oracleAddress")
    if not isinstance(oracle_address, str) or not _TOKEN_ADDR_RE.match(oracle_address):
        return None

    # threshold-zero parity check (mirrors v3).
    if threshold == "0" and epoch != 0:
        return None

    encrypted_aes_key = record.get("encryptedAesKey")
    if not isinstance(encrypted_aes_key, str) or not _BASE64_RE.match(
        encrypted_aes_key
    ):
        return None

    return {
        "version": GATE_METADATA_VERSION_V4,
        "cid": cid,
        "chain": chain,
        "tokenAddress": token_address,
        "threshold": threshold,
        "epoch": epoch,
        "marketCapTarget": market_cap_target,
        "oracleAddress": oracle_address,
        "encryptedAesKey": encrypted_aes_key,
    }


# ── EIP-712 typed data ─────────────────────────────────────────────


def build_eip712_gate_request_v4_typed_data(
    *,
    evm_address: str,
    transport_public_key: bytes,
    epoch: int,
    market_cap_target: int,
    nonce: int,
    eip712_chain_id: int,
    eip712_verifying_contract: str,
) -> dict:
    """Build the EIP-712 typed-data dict for a v4 gate request.

    Suitable for ``eth_account.messages.encode_typed_data``. Field order
    inside ``types.GateRequestV4`` follows
    ``EIP712_GATE_REQUEST_V4_TYPE_STRING``: ``evmAddress``,
    ``transportPublicKey``, ``epoch``, ``marketCapTarget``, ``nonce``.

    Domain matches the canister's three-field ``eip712DomainSeparator``
    (name ``"HavenAOL"``, no version/salt).
    """
    _require_token_address(evm_address)  # same regex; address shape is identical
    _require_token_address(eip712_verifying_contract)
    if not isinstance(transport_public_key, (bytes, bytearray)) or not transport_public_key:
        raise ValueError("transport_public_key must be non-empty bytes")
    _require_nat(epoch, name="epoch")
    _require_nat(market_cap_target, name="market_cap_target")
    _require_nat(nonce, name="nonce")
    _require_nat(eip712_chain_id, name="eip712_chain_id")

    return {
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"},
            ],
            "GateRequestV4": [
                {"name": "evmAddress", "type": "address"},
                {"name": "transportPublicKey", "type": "bytes"},
                {"name": "epoch", "type": "uint256"},
                {"name": "marketCapTarget", "type": "uint256"},
                {"name": "nonce", "type": "uint256"},
            ],
        },
        "primaryType": "GateRequestV4",
        "domain": {
            "name": "HavenAOL",
            "chainId": eip712_chain_id,
            "verifyingContract": eip712_verifying_contract,
        },
        "message": {
            "evmAddress": evm_address,
            "transportPublicKey": "0x" + bytes(transport_public_key).hex(),
            "epoch": epoch,
            "marketCapTarget": market_cap_target,
            "nonce": nonce,
        },
    }


__all__ = [
    "GATE_METADATA_VERSION_V4",
    "EIP712_GATE_REQUEST_V4_TYPE_STRING",
    "EIP712_GATE_REQUEST_V4_TYPEHASH",
    "MARKET_CAP_CACHE_TTL_SECONDS",
    "BOND_ADDRESSES",
    "is_bond_address",
    "compute_derivation_input_v4",
    "build_gate_metadata_v4",
    "gate_metadata_v4_to_json",
    "parse_gate_metadata_v4",
    "build_eip712_gate_request_v4_typed_data",
]
