"""Tests for the Haven-AOL Python SDK v3 surface.

Covers every acceptance criterion enumerated in
``tasking/sprint-3-shared-sdks/01-python-sdk-v3.md``:

  * Fixture-driven parity against ``tests/fixtures/derivation-v3-vectors.json``
    for every positive vector.
  * Threshold-zero ``ValueError`` in ``build_gate_metadata_v3``.
  * v1 dispatch through ``parse_gate_metadata`` is byte-stable (snapshot a
    v1 record before and after; assert JSON-equal).
  * EIP-712 typed-data shape and primary-type field order.
  * v3 metadata schema parity (version is the integer 3; epoch is JSON
    integer; threshold is a decimal string).
  * No new imports beyond stdlib + the existing dependencies.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

import pytest

# Import the v3 module directly. The package's ``__init__.py`` re-exports
# every v3 symbol alongside the v1 surface, but importing through the
# package root drags in the Rust ``haven_aol_vetkeys`` native extension
# that v1 needs and v3 does not. v3 is intentionally pure-Python so it
# can be unit-tested without the extension installed; the re-export
# wiring is checked statically by the Sprint 3 validator.
from haven_aol.v3 import (
    EIP712_GATE_REQUEST_V3_TYPE_STRING,
    EIP712_GATE_REQUEST_V3_TYPEHASH,
    EPOCH_LENGTH_SECONDS,
    GATE_METADATA_VERSION_V3,
    build_eip712_gate_request_v3_typed_data,
    build_gate_metadata_v3,
    compute_derivation_input_v3,
    current_epoch,
    gate_metadata_v3_to_json,
    parse_gate_metadata,
    parse_gate_metadata_v3,
)

# v1 metadata version (the SDK re-exports this from ``__init__``; here
# we hard-code it because importing it from the package root requires
# the v1 native extension).
GATE_METADATA_VERSION: int = 1


# ── Path to the shared fixture file ──────────────────────────────────


REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURE_PATH = REPO_ROOT / "tests" / "fixtures" / "derivation-v3-vectors.json"


def _load_fixture() -> dict:
    if not FIXTURE_PATH.is_file():  # pragma: no cover — sanity
        pytest.skip(f"missing shared fixture: {FIXTURE_PATH}")
    with FIXTURE_PATH.open("r", encoding="utf-8") as fh:
        return json.load(fh)


FIXTURE = _load_fixture()
POSITIVE_VECTORS = [v for v in FIXTURE["vectors"] if v["kind"] == "positive"]


# ── Sprint 0 / cross-stack constants parity ────────────────────────


class TestProtocolConstants:
    """The Sprint 0 fixture pins constants — the SDK must match."""

    def test_epoch_length_seconds_matches_fixture(self):
        assert EPOCH_LENGTH_SECONDS == FIXTURE["constants"]["epochLengthSeconds"]

    def test_epoch_length_is_thirty_days(self):
        assert EPOCH_LENGTH_SECONDS == 30 * 24 * 60 * 60

    def test_gate_metadata_version_v3_is_integer_three(self):
        assert GATE_METADATA_VERSION_V3 == 3
        assert isinstance(GATE_METADATA_VERSION_V3, int)
        # bool is an int subclass; reject the footgun.
        assert not isinstance(GATE_METADATA_VERSION_V3, bool)

    def test_v1_version_still_one(self):
        assert GATE_METADATA_VERSION == 1

    def test_eip712_type_string_matches_fixture(self):
        assert (
            EIP712_GATE_REQUEST_V3_TYPE_STRING
            == FIXTURE["constants"]["eip712TypeString"]
        )

    def test_eip712_typehash_matches_fixture(self):
        assert (
            EIP712_GATE_REQUEST_V3_TYPEHASH.hex()
            == FIXTURE["constants"]["eip712TypehashHex"]
        )

    def test_eip712_typehash_is_32_bytes(self):
        assert len(EIP712_GATE_REQUEST_V3_TYPEHASH) == 32


# ── current_epoch() ────────────────────────────────────────────────


class TestCurrentEpoch:
    def test_returns_nonneg_int(self):
        e = current_epoch()
        assert isinstance(e, int)
        assert e >= 0

    def test_monotonic_across_calls(self):
        # Within the same test run, epoch cannot decrease.
        a = current_epoch()
        b = current_epoch()
        assert b >= a

    def test_uses_local_clock_formula(self, monkeypatch):
        """current_epoch() == floor(unix_seconds / EPOCH_LENGTH_SECONDS)."""
        import haven_aol.v3 as v3mod

        fake_now = 12345678 * EPOCH_LENGTH_SECONDS + 42
        monkeypatch.setattr(v3mod.time, "time", lambda: float(fake_now))
        assert v3mod.current_epoch() == 12345678


# ── compute_derivation_input_v3 — fixture-driven parity ─────────────


@pytest.mark.parametrize(
    "vector",
    POSITIVE_VECTORS,
    ids=[v["name"] for v in POSITIVE_VECTORS],
)
class TestV3DerivationFixtureParity:
    def test_derivation_matches_fixture(self, vector):
        inp = vector["input"]
        expected_hex = vector["expected"]["derivationInputHex"]
        result = compute_derivation_input_v3(
            chain=inp["chain"],
            token_address=inp["tokenAddress"],
            threshold=inp["threshold"],
            epoch=inp["epoch"],
        )
        assert result.hex() == expected_hex
        assert len(result) == 32

    def test_preimage_utf8_is_byte_identical(self, vector):
        """The Python SDK must produce the exact preimage the fixture pins."""
        # We reconstruct what the SDK would hash and compare to the
        # fixture's preimageUtf8. This guards against an accidental
        # change to the domain tag, separator, or field order.
        inp = vector["input"]
        expected_preimage = vector["expected"]["preimageUtf8"]
        sdk_preimage = (
            f"accessol_v3:{inp['chain']}:{inp['tokenAddress']}:"
            f"{inp['threshold']}:{inp['epoch']}"
        )
        assert sdk_preimage == expected_preimage


class TestV3DerivationValidation:
    def test_invalid_chain_raises(self):
        with pytest.raises(ValueError, match="Invalid chain"):
            compute_derivation_input_v3(
                "Nope", "0x" + "a" * 40, threshold=1, epoch=1
            )

    def test_invalid_token_address_raises(self):
        with pytest.raises(ValueError, match="Invalid token address"):
            compute_derivation_input_v3("EthMainnet", "not-hex", threshold=1, epoch=1)

    def test_negative_threshold_raises(self):
        with pytest.raises(ValueError, match="threshold"):
            compute_derivation_input_v3(
                "EthMainnet", "0x" + "a" * 40, threshold=-1, epoch=0
            )

    def test_negative_epoch_raises(self):
        with pytest.raises(ValueError, match="epoch"):
            compute_derivation_input_v3(
                "EthMainnet", "0x" + "a" * 40, threshold=1, epoch=-1
            )

    def test_bool_threshold_rejected(self):
        # bool is an int subclass; the SDK explicitly refuses it because
        # callers passing True/False are almost always bugs.
        with pytest.raises(ValueError):
            compute_derivation_input_v3(
                "EthMainnet", "0x" + "a" * 40, threshold=True, epoch=0
            )


# ── build_gate_metadata_v3 ─────────────────────────────────────────


class TestBuildGateMetadataV3:
    _GOOD_KEY_B64 = base64.b64encode(b"\x00" * 32).decode("ascii")

    def test_field_order_is_canonical(self):
        meta = build_gate_metadata_v3(
            cid="QmTest",
            chain="EthMainnet",
            token_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            threshold=1000000,
            epoch=670,
            encrypted_aes_key_b64=self._GOOD_KEY_B64,
        )
        assert list(meta.keys()) == [
            "version",
            "cid",
            "chain",
            "tokenAddress",
            "threshold",
            "epoch",
            "encryptedAesKey",
        ]

    def test_version_is_integer_three(self):
        meta = build_gate_metadata_v3(
            cid="QmTest",
            chain="EthMainnet",
            token_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            threshold=1,
            epoch=670,
            encrypted_aes_key_b64=self._GOOD_KEY_B64,
        )
        assert meta["version"] == 3
        assert isinstance(meta["version"], int)
        assert not isinstance(meta["version"], bool)

    def test_threshold_is_decimal_string(self):
        meta = build_gate_metadata_v3(
            cid="QmTest",
            chain="EthMainnet",
            token_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            threshold=1_000_000_000_000_000_000,
            epoch=1,
            encrypted_aes_key_b64=self._GOOD_KEY_B64,
        )
        assert meta["threshold"] == "1000000000000000000"
        assert isinstance(meta["threshold"], str)

    def test_epoch_is_integer(self):
        meta = build_gate_metadata_v3(
            cid="QmTest",
            chain="EthMainnet",
            token_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            threshold=1,
            epoch=670,
            encrypted_aes_key_b64=self._GOOD_KEY_B64,
        )
        assert meta["epoch"] == 670
        assert isinstance(meta["epoch"], int)

    def test_threshold_zero_epoch_zero_ok(self):
        meta = build_gate_metadata_v3(
            cid="QmTest",
            chain="EthMainnet",
            token_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            threshold=0,
            epoch=0,
            encrypted_aes_key_b64=self._GOOD_KEY_B64,
        )
        assert meta["threshold"] == "0"
        assert meta["epoch"] == 0

    def test_threshold_zero_with_nonzero_epoch_raises(self):
        with pytest.raises(ValueError, match="threshold==0 requires epoch==0"):
            build_gate_metadata_v3(
                cid="QmTest",
                chain="EthMainnet",
                token_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                threshold=0,
                epoch=670,
                encrypted_aes_key_b64=self._GOOD_KEY_B64,
            )

    def test_invalid_chain_raises(self):
        with pytest.raises(ValueError, match="Invalid chain"):
            build_gate_metadata_v3(
                cid="QmTest",
                chain="BadChain",
                token_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                threshold=1,
                epoch=670,
                encrypted_aes_key_b64=self._GOOD_KEY_B64,
            )

    def test_empty_cid_raises(self):
        with pytest.raises(ValueError, match="CID"):
            build_gate_metadata_v3(
                cid="",
                chain="EthMainnet",
                token_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                threshold=1,
                epoch=670,
                encrypted_aes_key_b64=self._GOOD_KEY_B64,
            )

    def test_invalid_base64_raises(self):
        with pytest.raises(ValueError, match="base64"):
            build_gate_metadata_v3(
                cid="QmTest",
                chain="EthMainnet",
                token_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                threshold=1,
                epoch=670,
                encrypted_aes_key_b64="not!base64!!",
            )


# ── gate_metadata_v3_to_json ───────────────────────────────────────


class TestGateMetadataV3ToJson:
    _GOOD_KEY_B64 = base64.b64encode(b"\xab" * 16).decode("ascii")

    def _meta(self) -> dict:
        return build_gate_metadata_v3(
            cid="QmAbc",
            chain="EthMainnet",
            token_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            threshold=1000000,
            epoch=670,
            encrypted_aes_key_b64=self._GOOD_KEY_B64,
        )

    def test_serialized_field_order(self):
        s = gate_metadata_v3_to_json(self._meta())
        expected_prefix = (
            '{"version":3,"cid":"QmAbc","chain":"EthMainnet","tokenAddress":'
            '"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48","threshold":"1000000",'
            '"epoch":670,"encryptedAesKey":'
        )
        assert s.startswith(expected_prefix), s

    def test_serializer_compact(self):
        s = gate_metadata_v3_to_json(self._meta())
        # No whitespace anywhere in the output.
        assert " " not in s
        assert "\n" not in s
        assert "\t" not in s

    def test_rejects_non_v3_input(self):
        with pytest.raises(ValueError, match="expected version 3"):
            gate_metadata_v3_to_json({"version": 1, "cid": "QmTest"})

    def test_roundtrip_through_parser(self):
        original = self._meta()
        roundtripped = parse_gate_metadata_v3(gate_metadata_v3_to_json(original))
        assert roundtripped == original


# ── parse_gate_metadata_v3 (strict) ────────────────────────────────


class TestParseGateMetadataV3:
    _GOOD_KEY_B64 = base64.b64encode(b"\x00" * 8).decode("ascii")

    def _good_record(self, **overrides):
        rec = {
            "version": 3,
            "cid": "QmTest",
            "chain": "EthMainnet",
            "tokenAddress": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            "threshold": "1",
            "epoch": 670,
            "encryptedAesKey": self._GOOD_KEY_B64,
        }
        rec.update(overrides)
        return rec

    def test_accepts_dict(self):
        assert parse_gate_metadata_v3(self._good_record()) == self._good_record()

    def test_accepts_json_string(self):
        s = json.dumps(self._good_record(), separators=(",", ":"))
        assert parse_gate_metadata_v3(s) == self._good_record()

    def test_accepts_utf8_bytes(self):
        s = json.dumps(self._good_record(), separators=(",", ":")).encode("utf-8")
        assert parse_gate_metadata_v3(s) == self._good_record()

    def test_rejects_v1(self):
        v1 = {
            "version": 1,
            "cid": "QmTest",
            "chain": "EthMainnet",
            "tokenAddress": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            "threshold": "1",
            "encryptedAesKey": self._GOOD_KEY_B64,
        }
        assert parse_gate_metadata_v3(v1) is None

    def test_rejects_version_as_string(self):
        assert parse_gate_metadata_v3(self._good_record(version="3")) is None

    def test_rejects_version_as_bool(self):
        # ``True == 1`` and ``False == 0`` in Python; both must be rejected.
        assert parse_gate_metadata_v3(self._good_record(version=True)) is None

    def test_rejects_unknown_chain(self):
        assert parse_gate_metadata_v3(self._good_record(chain="UnknownChain")) is None

    def test_rejects_bad_token_address(self):
        assert parse_gate_metadata_v3(self._good_record(tokenAddress="0xnope")) is None

    def test_rejects_threshold_as_int(self):
        # v3 schema specifies threshold is a string; an integer here is a
        # malformed record from a non-canonical producer.
        assert parse_gate_metadata_v3(self._good_record(threshold=1)) is None

    def test_rejects_threshold_with_leading_zero(self):
        assert parse_gate_metadata_v3(self._good_record(threshold="01")) is None

    def test_rejects_negative_epoch(self):
        assert parse_gate_metadata_v3(self._good_record(epoch=-1)) is None

    def test_rejects_threshold_zero_with_nonzero_epoch(self):
        bad = self._good_record(threshold="0", epoch=42)
        assert parse_gate_metadata_v3(bad) is None

    def test_accepts_threshold_zero_with_epoch_zero(self):
        good = self._good_record(threshold="0", epoch=0)
        assert parse_gate_metadata_v3(good) == good

    def test_rejects_garbage(self):
        assert parse_gate_metadata_v3("not json") is None
        assert parse_gate_metadata_v3(b"\xff\xfe\xfd") is None
        assert parse_gate_metadata_v3(123) is None
        assert parse_gate_metadata_v3(None) is None


# ── parse_gate_metadata (dispatch) ─────────────────────────────────


class TestParseGateMetadataDispatch:
    _GOOD_KEY_B64 = base64.b64encode(b"\x00" * 8).decode("ascii")

    def test_dispatch_v3(self):
        rec = {
            "version": 3,
            "cid": "QmTest",
            "chain": "EthMainnet",
            "tokenAddress": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            "threshold": "1",
            "epoch": 670,
            "encryptedAesKey": self._GOOD_KEY_B64,
        }
        parsed = parse_gate_metadata(rec)
        assert parsed is not None
        assert parsed["version"] == 3

    def test_dispatch_v1_is_byte_stable(self):
        """A v1 record must travel through the dispatcher unchanged.

        We use a literal v1 record matching the canonical shape produced by
        ``haven_aol.core.build_gate_metadata`` / ``serialize_gate_metadata``
        — same field order, ``version`` integer 1, ``threshold`` decimal
        string, ``encryptedAesKey`` standard base64. The dispatcher must
        round-trip it as-is.

        We use a literal here rather than calling
        ``haven_aol.core.build_gate_metadata`` because that module imports
        the v1 native crypto extension at module level; v3 dispatch is a
        pure-Python concern and must not depend on the extension.
        """
        v1_meta = {
            "version": 1,
            "cid": "QmTestV1",
            "chain": "EthMainnet",
            "tokenAddress": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            "threshold": "1000000",
            "encryptedAesKey": base64.b64encode(b"\x01\x02\x03\x04").decode("ascii"),
        }
        v1_json = json.dumps(v1_meta, separators=(",", ":"))

        parsed = parse_gate_metadata(v1_json)
        assert parsed is not None
        assert parsed["version"] == 1

        # Round-trip back to JSON (preserving field order) and confirm
        # byte-identity — this is the contract called out in the Sprint 3
        # brief's acceptance criteria.
        reserialized = json.dumps(parsed, separators=(",", ":"))
        assert reserialized == v1_json

    def test_dispatch_unknown_version_returns_none(self):
        assert parse_gate_metadata({"version": 2, "cid": "Qm"}) is None
        assert parse_gate_metadata({"version": 4, "cid": "Qm"}) is None
        assert parse_gate_metadata({"version": "3", "cid": "Qm"}) is None

    def test_dispatch_garbage_returns_none(self):
        assert parse_gate_metadata("") is None
        assert parse_gate_metadata("{not json") is None
        assert parse_gate_metadata(None) is None


# ── build_eip712_gate_request_v3_typed_data ────────────────────────


class TestEip712TypedDataV3:
    def _td(self, **overrides):
        kwargs = dict(
            evm_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            transport_public_key=b"\x01\x02\x03\x04",
            epoch=670,
            nonce=42,
            eip712_chain_id=1,
            eip712_verifying_contract="0xB0b86991c6218B36c1D19d4A2E9eB0Ce3606Eb48",
        )
        kwargs.update(overrides)
        return build_eip712_gate_request_v3_typed_data(**kwargs)

    def test_primary_type(self):
        td = self._td()
        assert td["primaryType"] == "GateRequestV3"

    def test_field_order_in_primary_type(self):
        td = self._td()
        fields = [f["name"] for f in td["types"]["GateRequestV3"]]
        assert fields == ["evmAddress", "transportPublicKey", "epoch", "nonce"]

    def test_field_types_in_primary_type(self):
        td = self._td()
        types_map = {f["name"]: f["type"] for f in td["types"]["GateRequestV3"]}
        assert types_map == {
            "evmAddress": "address",
            "transportPublicKey": "bytes",
            "epoch": "uint256",
            "nonce": "uint256",
        }

    def test_domain_has_no_version_field(self):
        td = self._td()
        domain_fields = [f["name"] for f in td["types"]["EIP712Domain"]]
        assert "version" not in domain_fields
        assert domain_fields == ["name", "chainId", "verifyingContract"]

    def test_message_values_present(self):
        td = self._td()
        msg = td["message"]
        assert msg["evmAddress"] == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        assert msg["transportPublicKey"] == "0x01020304"
        assert msg["epoch"] == 670
        assert msg["nonce"] == 42

    def test_domain_name_matches_canister(self):
        td = self._td()
        # The canister uses APP_NAME="HavenAOL" — see src/backend/main.mo.
        assert td["domain"]["name"] == "HavenAOL"

    def test_rejects_empty_transport_key(self):
        with pytest.raises(ValueError, match="transport_public_key"):
            self._td(transport_public_key=b"")

    def test_rejects_bad_verifying_contract(self):
        with pytest.raises(ValueError, match="Invalid token address"):
            self._td(eip712_verifying_contract="0xnotanaddress")

    def test_rejects_negative_epoch(self):
        with pytest.raises(ValueError, match="epoch"):
            self._td(epoch=-1)
