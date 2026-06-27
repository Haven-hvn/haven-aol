"""Tests for the Haven-AOL Python package."""

import base64
import json

import pytest

from haven_aol import (
    compute_derivation_input,
    encrypt_file,
    derive_verification_key,
    ibe_encrypt_aes_key,
    build_gate_metadata,
    serialize_gate_metadata,
)


# ── Derivation hash test vectors from docs/derivation-spec.md ──


class TestDerivationInput:
    """Test compute_derivation_input against spec test vectors."""

    def test_vector_1_eth_mainnet_usdc(self):
        result = compute_derivation_input(
            chain="EthMainnet",
            token_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            threshold=1000000,
            cid="QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco",
        )
        assert result.hex() == "e16d8738a6ea707f75e887fd3fce3e96d2fe061d075c5fe2821e94b2c9ad3b17"

    def test_vector_2_arbitrum_one(self):
        result = compute_derivation_input(
            chain="ArbitrumOne",
            token_address="0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8",
            threshold=500000000000000000,
            cid="bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi",
        )
        assert result.hex() == "04308f0e299c1647072257d0965e1f982fba21030538ee89323f82cab1c995d3"

    def test_vector_3_sepolia_zero_threshold(self):
        result = compute_derivation_input(
            chain="EthSepolia",
            token_address="0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
            threshold=0,
            cid="QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn",
        )
        assert result.hex() == "6ea156594a7f7400610f328f4b5daf61d3036100d7bab69d33eb2a53575936d7"

    def test_output_is_32_bytes(self):
        result = compute_derivation_input(
            "EthMainnet", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", 1, "QmTest"
        )
        assert len(result) == 32

    def test_invalid_chain_raises(self):
        with pytest.raises(ValueError, match="Invalid chain"):
            compute_derivation_input("InvalidChain", "0x" + "a" * 40, 1, "QmTest")

    def test_invalid_address_raises(self):
        with pytest.raises(ValueError, match="Invalid token address"):
            compute_derivation_input("EthMainnet", "not-an-address", 1, "QmTest")

    def test_negative_threshold_raises(self):
        with pytest.raises(ValueError, match="non-negative"):
            compute_derivation_input("EthMainnet", "0x" + "a" * 40, -1, "QmTest")

    def test_empty_cid_raises(self):
        with pytest.raises(ValueError, match="non-empty"):
            compute_derivation_input("EthMainnet", "0x" + "a" * 40, 1, "")


# ── AES encryption tests ──


class TestEncryptFile:
    """Test AES-256-GCM encryption."""

    def test_basic_encrypt_decrypt(self):
        plaintext = b"Hello, token-gated world!"
        ciphertext, key, iv = encrypt_file(plaintext)

        # Format: [12-byte IV][ciphertext + 16-byte tag]
        assert len(ciphertext) == 12 + len(plaintext) + 16
        assert ciphertext[:12] == iv
        assert len(key) == 32

        # Verify we can decrypt
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        aesgcm = AESGCM(key)
        decrypted = aesgcm.decrypt(iv, ciphertext[12:], None)
        assert decrypted == plaintext

    def test_custom_key(self):
        key = b"\x42" * 32
        ciphertext, returned_key, iv = encrypt_file(b"test", aes_key=key)
        assert returned_key == key

    def test_invalid_key_length_raises(self):
        with pytest.raises(ValueError, match="32 bytes"):
            encrypt_file(b"test", aes_key=b"short")

    def test_empty_plaintext(self):
        ciphertext, key, iv = encrypt_file(b"")
        assert len(ciphertext) == 12 + 0 + 16  # IV + empty + tag


# ── VetKD verification key derivation tests ──


class TestDeriveVerificationKey:
    """Test offline VetKD public key derivation."""

    def test_derive_returns_96_bytes(self):
        # Use a known canister ID (the backend canister placeholder)
        canister_bytes = bytes(10)  # anonymous principal-like
        result = derive_verification_key(canister_bytes, key_name="key_1")
        assert len(result) == 96  # compressed G2 point

    def test_derive_from_text_principal(self):
        # aaaaa-aa is the management canister (all zeros, 1 byte)
        result = derive_verification_key("aaaaa-aa", key_name="key_1")
        assert len(result) == 96

    def test_derive_deterministic(self):
        canister_bytes = bytes(10)
        r1 = derive_verification_key(canister_bytes, key_name="key_1")
        r2 = derive_verification_key(canister_bytes, key_name="key_1")
        assert r1 == r2

    def test_different_context_different_key(self):
        canister_bytes = bytes(10)
        r1 = derive_verification_key(canister_bytes, context=b"accessol_v1")
        r2 = derive_verification_key(canister_bytes, context=b"other_context")
        assert r1 != r2

    def test_passthrough_verification_key(self):
        """Test local dev mode: pass verification key bytes directly."""
        # First derive a real key
        canister_bytes = bytes(10)
        real_key = derive_verification_key(canister_bytes, key_name="key_1")
        # Then pass it through the passthrough path
        result = derive_verification_key(
            canister_bytes, verification_key_bytes=real_key
        )
        assert result == real_key

    def test_invalid_key_name_raises(self):
        with pytest.raises(ValueError):
            derive_verification_key(bytes(10), key_name="nonexistent_key")

    def test_invalid_text_principal_raises(self):
        with pytest.raises(
            ValueError,
            match="invalid base32 principal string|principal checksum mismatch|principal too short|principal round-trip mismatch",
        ):
            derive_verification_key("not-a-valid-principal", key_name="key_1")

    def test_corrupt_text_principal_raises(self):
        """Malformed principal must not be accepted."""
        with pytest.raises(ValueError, match="principal round-trip mismatch"):
            derive_verification_key("aaaaa-ab", key_name="key_1")


# ── IBE encryption tests ──


class TestIbeEncrypt:
    """Test IBE encryption of AES keys."""

    def test_ibe_encrypt_produces_output(self):
        canister_bytes = bytes(10)
        dpk = derive_verification_key(canister_bytes, key_name="key_1")
        derivation_input = compute_derivation_input(
            "EthMainnet", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", 1000000, "QmTest"
        )
        aes_key = b"\x42" * 32

        result = ibe_encrypt_aes_key(aes_key, dpk, derivation_input)

        # IBE ciphertext: 8-byte header + 96-byte G2 + 32-byte masked seed + 32-byte masked msg
        # = 8 + 96 + 32 + 32 = 168 bytes for a 32-byte plaintext
        assert len(result) == 8 + 96 + 32 + 32

    def test_ibe_ciphertext_has_header(self):
        canister_bytes = bytes(10)
        dpk = derive_verification_key(canister_bytes, key_name="key_1")
        derivation_input = bytes(32)
        aes_key = b"\x00" * 32

        result = ibe_encrypt_aes_key(aes_key, dpk, derivation_input)
        # Header should be "IC IBE\x00\x01"
        assert result[:6] == b"IC IBE"


# ── Gate metadata tests ──


class TestBuildGateMetadata:
    """Test gate metadata construction."""

    def test_basic_metadata(self):
        meta = build_gate_metadata(
            cid="QmTest123",
            chain="EthMainnet",
            token_address="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            threshold=1000000,
            encrypted_aes_key=b"\x00" * 64,
        )
        assert meta["version"] == 1
        assert meta["cid"] == "QmTest123"
        assert meta["chain"] == "EthMainnet"
        assert meta["tokenAddress"] == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        assert meta["threshold"] == "1000000"  # string, not int
        assert isinstance(meta["threshold"], str)

    def test_threshold_is_string(self):
        meta = build_gate_metadata(
            cid="QmTest",
            chain="EthMainnet",
            token_address="0x" + "a" * 40,
            threshold=1000000000000000000,
            encrypted_aes_key=b"\x00",
        )
        assert meta["threshold"] == "1000000000000000000"
        assert isinstance(meta["threshold"], str)

    def test_encrypted_aes_key_is_base64(self):
        raw = b"\x01\x02\x03\x04"
        meta = build_gate_metadata(
            cid="QmTest",
            chain="EthMainnet",
            token_address="0x" + "a" * 40,
            threshold=0,
            encrypted_aes_key=raw,
        )
        decoded = base64.b64decode(meta["encryptedAesKey"])
        assert decoded == raw

    def test_invalid_chain_raises(self):
        with pytest.raises(ValueError):
            build_gate_metadata("QmTest", "BadChain", "0x" + "a" * 40, 1, b"\x00")


class TestSerializeGateMetadata:
    """Test JSON serialization."""

    def test_valid_json(self):
        meta = build_gate_metadata(
            cid="QmTest",
            chain="EthMainnet",
            token_address="0x" + "a" * 40,
            threshold=100,
            encrypted_aes_key=b"\x00",
        )
        json_str = serialize_gate_metadata(meta)
        parsed = json.loads(json_str)
        assert parsed["version"] == 1
        assert parsed["threshold"] == "100"

    def test_compact_json(self):
        meta = build_gate_metadata(
            cid="QmTest",
            chain="EthMainnet",
            token_address="0x" + "a" * 40,
            threshold=1,
            encrypted_aes_key=b"\x00",
        )
        json_str = serialize_gate_metadata(meta)
        # Compact format: no spaces
        assert " " not in json_str or json_str.count(" ") == 0
