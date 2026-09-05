"""Tests for the Haven-AOL Python SDK v4 surface (market-cap-gated drip).

Covers:

  * Fixture-driven parity against ``tests/fixtures/derivation-v4-vectors.json``
    for every positive vector — the same shared file the Motoko canister and
    TypeScript SDK are pinned against.
  * Target-participation: two identical gate tuples with different
    ``market_cap_target`` values derive different keys.
  * Threshold-zero collapse parity in metadata building (ValueError).
  * v4 metadata schema rules (version integer 4; threshold decimal string;
    epoch / marketCapTarget JSON integers; oracleAddress address-shaped).
  * Dispatch through ``parse_gate_metadata`` routes version 4.
  * EIP-712 typed-data shape and primary-type field order.

No native extension required — v4 is pure Python.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from haven_aol.v3 import parse_gate_metadata
from haven_aol.v4 import (
    BOND_ADDRESSES,
    EIP712_GATE_REQUEST_V4_TYPE_STRING,
    EIP712_GATE_REQUEST_V4_TYPEHASH,
    GATE_METADATA_VERSION_V4,
    MARKET_CAP_CACHE_TTL_SECONDS,
    build_eip712_gate_request_v4_typed_data,
    build_gate_metadata_v4,
    compute_derivation_input_v4,
    gate_metadata_v4_to_json,
    is_bond_address,
    parse_gate_metadata_v4,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURE_PATH = REPO_ROOT / "tests" / "fixtures" / "derivation-v4-vectors.json"


def _load_fixture() -> dict:
    if not FIXTURE_PATH.is_file():  # pragma: no cover — sanity
        pytest.skip(f"missing shared fixture: {FIXTURE_PATH}")
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


FIXTURE = _load_fixture()


# ── Constants pinning ───────────────────────────────────────────────


class TestV4Constants:
    def test_version_discriminator(self):
        assert GATE_METADATA_VERSION_V4 == 4

    def test_typehash_matches_fixture(self):
        constants = FIXTURE["constants"]
        assert bytes.fromhex(constants["eip712TypehashHex"]) == EIP712_GATE_REQUEST_V4_TYPEHASH
        assert constants["eip712TypeString"] == EIP712_GATE_REQUEST_V4_TYPE_STRING

    def test_market_cap_policy_constants_match_canister(self):
        constants = FIXTURE["constants"]
        assert MARKET_CAP_CACHE_TTL_SECONDS == constants["marketCapCacheTtlSeconds"] == 300

    def test_domain_tag_in_fixture(self):
        assert FIXTURE["constants"]["domainTag"] == "accessol_v4:"
        assert FIXTURE["constants"]["vetkdContext"] == "accessol_v4"


# ── Bond mode — address classification ──────────────────────────────


BOND_ADDRESS = "0xc5a076cad94176c2996B32d8466Be1cE757FAa27"  # dapp-hint casing
BOND_ADDRESS_SEPOLIA = "0x8dce343A86Aa950d539eeE0e166AFfd0Ef515C0c"  # testnet Bond
CHAINLINK_FEED = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"  # ETH/USD mainnet


class TestBondModeAddress:
    def test_bond_address_on_all_five_chains(self):
        assert is_bond_address("EthMainnet", BOND_ADDRESS) is True
        assert is_bond_address("BaseMainnet", BOND_ADDRESS) is True
        assert is_bond_address("ArbitrumOne", BOND_ADDRESS) is True
        assert is_bond_address("OptimismMainnet", BOND_ADDRESS) is True
        assert is_bond_address("EthSepolia", BOND_ADDRESS_SEPOLIA) is True
        # Cross-check: mainnet Bond is NOT the Sepolia Bond and vice versa.
        assert is_bond_address("EthSepolia", BOND_ADDRESS) is False
        assert is_bond_address("BaseMainnet", BOND_ADDRESS_SEPOLIA) is False

    def test_case_insensitive(self):
        assert is_bond_address("BaseMainnet", BOND_ADDRESS.lower()) is True
        assert is_bond_address("BaseMainnet", BOND_ADDRESS.upper()) is True

    def test_rejects_non_bond_and_unknown_chains(self):
        assert is_bond_address("BaseMainnet", CHAINLINK_FEED) is False
        assert is_bond_address("BaseMainnet", "0x" + "00" * 20) is False
        assert is_bond_address("NoSuchChain", BOND_ADDRESS) is False
        assert is_bond_address("BaseMainnet", "not-an-address") is False

    def test_bond_addresses_parity_with_canister_defaults(self):
        # Per-chain parity: mainnets track BOND_ADDRESS_DEFAULT, EthSepolia
        # tracks BOND_ADDRESS_SEPOLIA in src/backend/main.mo (lowercase
        # compare — the canister lowercases, so EIP-55 casing is not
        # load-bearing).
        import re

        main_mo = (REPO_ROOT / "src" / "backend" / "main.mo").read_text(encoding="utf-8")
        default = re.search(r'BOND_ADDRESS_DEFAULT\s*:\s*Text\s*=\s*"([^"]+)"', main_mo)
        sepolia = re.search(r'BOND_ADDRESS_SEPOLIA\s*:\s*Text\s*=\s*"([^"]+)"', main_mo)
        assert default, "BOND_ADDRESS_DEFAULT not found in src/backend/main.mo"
        assert sepolia, "BOND_ADDRESS_SEPOLIA not found in src/backend/main.mo"
        expected = {
            "EthMainnet": default.group(1),
            "BaseMainnet": default.group(1),
            "ArbitrumOne": default.group(1),
            "OptimismMainnet": default.group(1),
            "EthSepolia": sepolia.group(1),
        }
        assert sorted(BOND_ADDRESSES) == sorted(expected)
        for chain, addr in expected.items():
            assert BOND_ADDRESSES[chain].lower() == addr.lower(), f"BOND_ADDRESSES[{chain}] drifted"


# ── Derivation input (fixture-driven) ───────────────────────────────


class TestDerivationInputFixtureParity:
    @pytest.mark.parametrize(
        "vector",
        [v for v in FIXTURE["vectors"] if v["kind"] in ("positive", "threshold-zero-collapse")],
        ids=lambda v: v["name"],
    )
    def test_vector_bytes(self, vector):
        inp = vector["input"]
        digest = compute_derivation_input_v4(
            chain=inp["chain"],
            token_address=inp["tokenAddress"],
            threshold=inp["threshold"],
            epoch=inp["epoch"],
            market_cap_target=inp["marketCapTarget"],
        ).hex()
        expected = vector["expected"]["derivationInputHex"]

        if vector["kind"] == "positive":
            assert digest == expected
        else:
            # threshold-zero-collapse: SDK computes literal bytes (epoch as
            # given), canister collapses. The fixture's expected value uses
            # effectiveEpoch; reproduce that by passing epoch=0.
            collapsed = compute_derivation_input_v4(
                chain=inp["chain"],
                token_address=inp["tokenAddress"],
                threshold=0,
                epoch=0,
                market_cap_target=inp["marketCapTarget"],
            ).hex()
            assert collapsed == expected
            assert digest != expected or inp["epoch"] == 0

    def test_target_participates_in_preimage(self):
        """Same corpus, different target → different key. Core drip property."""
        a = compute_derivation_input_v4("BaseMainnet", "0x" + "aa" * 20, 5, 670, 1_000_000)
        b = compute_derivation_input_v4("BaseMainnet", "0x" + "aa" * 20, 5, 670, 10_000_000)
        assert a != b

    def test_preimage_utf8_round_trip(self):
        vector = FIXTURE["vectors"][0]
        inp = vector["input"]
        preimage = vector["expected"]["preimageUtf8"]
        assert preimage.startswith("accessol_v4:")
        assert str(inp["marketCapTarget"]) in preimage

    @pytest.mark.parametrize(
        "kwargs",
        [
            {"chain": "Polygon", "token_address": "0x" + "ab" * 20, "threshold": 1, "epoch": 0, "market_cap_target": 1},
            {"chain": "BaseMainnet", "token_address": "nope", "threshold": 1, "epoch": 0, "market_cap_target": 1},
            {"chain": "BaseMainnet", "token_address": "0x" + "ab" * 20, "threshold": -1, "epoch": 0, "market_cap_target": 1},
            {"chain": "BaseMainnet", "token_address": "0x" + "ab" * 20, "threshold": 1, "epoch": -5, "market_cap_target": 1},
            {"chain": "BaseMainnet", "token_address": "0x" + "ab" * 20, "threshold": 1, "epoch": 0, "market_cap_target": True},
        ],
    )
    def test_invalid_inputs_raise(self, kwargs):
        with pytest.raises(ValueError):
            compute_derivation_input_v4(**kwargs)


# ── Gate metadata v4 ────────────────────────────────────────────────


VALID_META_KWARGS = dict(
    cid="bafybeiv4chunk",
    chain="BaseMainnet",
    token_address="0xAa70bC79fD1cB4a6FBA717018351F0C3c64B79Df",
    threshold=5,
    epoch=670,
    market_cap_target=5_000_000,
    oracle_address="0xc5A076cAd94176C2996b32d8466bE1cE757FAa27",
    encrypted_aes_key_b64="AAECAwQFBgcICQ==",
)


class TestBuildGateMetadataV4:
    def test_canonical_shape_and_field_order(self):
        meta = build_gate_metadata_v4(**VALID_META_KWARGS)
        assert list(meta.keys()) == [
            "version",
            "cid",
            "chain",
            "tokenAddress",
            "threshold",
            "epoch",
            "marketCapTarget",
            "oracleAddress",
            "encryptedAesKey",
        ]
        assert meta["version"] == 4
        assert meta["threshold"] == "5"
        assert isinstance(meta["epoch"], int)
        assert meta["marketCapTarget"] == 5_000_000

    def test_threshold_zero_requires_epoch_zero(self):
        with pytest.raises(ValueError, match="threshold==0 requires epoch==0"):
            build_gate_metadata_v4(**{**VALID_META_KWARGS, "threshold": 0, "epoch": 671})

    def test_invalid_oracle_address_raises(self):
        with pytest.raises(ValueError):
            build_gate_metadata_v4(**{**VALID_META_KWARGS, "oracle_address": "0x123"})

    def test_negative_target_raises(self):
        with pytest.raises(ValueError):
            build_gate_metadata_v4(**{**VALID_META_KWARGS, "market_cap_target": -1})

    def test_json_serializer_round_trip(self):
        meta = build_gate_metadata_v4(**VALID_META_KWARGS)
        as_json = gate_metadata_v4_to_json(meta)
        assert parse_gate_metadata_v4(as_json) == meta


# ── Parsing ─────────────────────────────────────────────────────────


class TestParseGateMetadataV4:
    def test_valid_record_parses(self):
        meta = build_gate_metadata_v4(**VALID_META_KWARGS)
        parsed = parse_gate_metadata_v4(json.dumps(meta))
        assert parsed == meta

    def test_wrong_version_returns_none(self):
        meta = build_gate_metadata_v4(**VALID_META_KWARGS)
        assert parse_gate_metadata_v4({**meta, "version": 3}) is None
        assert parse_gate_metadata_v4({**meta, "version": "4"}) is None
        assert parse_gate_metadata_v4({**meta, "version": True}) is None

    def test_missing_or_malformed_fields_return_none(self):
        good = build_gate_metadata_v4(**VALID_META_KWARGS)
        cases = [
            {**good, "cid": ""},
            {**good, "cid": None},
            {**good, "chain": "Polygon"},
            {**good, "tokenAddress": "0x123"},
            {**good, "threshold": 5},           # must be a string
            {**good, "threshold": "-1"},
            {**good, "epoch": "670"},           # must be an int
            {**good, "epoch": True},
            {**good, "marketCapTarget": "5000000"},
            {**good, "marketCapTarget": None},
            {**good, "oracleAddress": "not-an-address"},
            {**good, "encryptedAesKey": "!!!"},  # not base64
        ]
        for bad in cases:
            assert parse_gate_metadata_v4(bad) is None, bad

    def test_threshold_zero_epoch_parity_enforced(self):
        meta = build_gate_metadata_v4(**{**VALID_META_KWARGS, "threshold": 0, "epoch": 0})
        assert parse_gate_metadata_v4(meta) is not None
        tampered = {**meta, "threshold": "0", "epoch": 9}
        assert parse_gate_metadata_v4(tampered) is None

    def test_dispatch_routes_v4(self):
        meta = build_gate_metadata_v4(**VALID_META_KWARGS)
        assert parse_gate_metadata(json.dumps(meta)) == meta

    def test_dispatch_still_rejects_unknown_versions(self):
        assert parse_gate_metadata({"version": 2, "cid": "Qm"}) is None
        assert parse_gate_metadata({"version": 5, "cid": "Qm"}) is None


# ── EIP-712 typed data ──────────────────────────────────────────────


class TestEip712TypedDataV4:
    def test_shape_and_field_order(self):
        td = build_eip712_gate_request_v4_typed_data(
            evm_address="0x" + "bb" * 20,
            transport_public_key=b"\x02" + b"\x01" * 32,
            epoch=670,
            market_cap_target=5_000_000,
            nonce=42,
            eip712_chain_id=8453,
            eip712_verifying_contract="0x" + "cc" * 20,
        )

        assert td["primaryType"] == "GateRequestV4"
        assert [f["name"] for f in td["types"]["GateRequestV4"]] == [
            "evmAddress",
            "transportPublicKey",
            "epoch",
            "marketCapTarget",
            "nonce",
        ]
        assert td["message"]["marketCapTarget"] == 5_000_000
        assert td["domain"] == {
            "name": "HavenAOL",
            "chainId": 8453,
            "verifyingContract": "0x" + "cc" * 20,
        }

    def test_transport_key_hex_prefix(self):
        td = build_eip712_gate_request_v4_typed_data(
            evm_address="0x" + "bb" * 20,
            transport_public_key=bytes(range(1, 34)),
            epoch=0,
            market_cap_target=0,
            nonce=0,
            eip712_chain_id=1,
            eip712_verifying_contract="0x" + "cc" * 20,
        )
        assert td["message"]["transportPublicKey"].startswith("0x")

    def test_invalid_inputs_raise(self):
        base = dict(
            evm_address="0x" + "bb" * 20,
            transport_public_key=b"\x02" + b"\x01" * 32,
            epoch=0,
            market_cap_target=0,
            nonce=0,
            eip712_chain_id=1,
            eip712_verifying_contract="0x" + "cc" * 20,
        )
        with pytest.raises(ValueError):
            build_eip712_gate_request_v4_typed_data(**{**base, "transport_public_key": b""})
        with pytest.raises(ValueError):
            build_eip712_gate_request_v4_typed_data(**{**base, "market_cap_target": -2})
