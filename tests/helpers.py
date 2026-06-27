"""Haven-AOL integration test helpers — called by the Node.js test orchestrator."""

import base64
import json
import sys

from haven_aol import (
    compute_derivation_input,
    encrypt_file,
    derive_verification_key,
    ibe_encrypt_aes_key,
    build_gate_metadata,
    serialize_gate_metadata,
)


def cmd_derivation_hash():
    """Compute derivation hash. Args: chain tokenAddress threshold cid"""
    chain, token_address, threshold_str, cid = sys.argv[2:6]
    result = compute_derivation_input(chain, token_address, int(threshold_str), cid)
    print(result.hex())


def cmd_encrypt_file():
    """AES encrypt. Args: [plaintext_hex] [aes_key_hex]"""
    plaintext = bytes.fromhex(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else b""
    aes_key = bytes.fromhex(sys.argv[3]) if len(sys.argv) > 3 else None
    ciphertext, key, iv = encrypt_file(plaintext, aes_key=aes_key)
    print(json.dumps({
        "ciphertext": ciphertext.hex(),
        "aesKey": key.hex(),
        "iv": iv.hex(),
    }))


def cmd_ibe_encrypt():
    """IBE encrypt AES key. Args: aes_key_hex dpk_hex derivation_input_hex"""
    aes_key = bytes.fromhex(sys.argv[2])
    dpk = bytes.fromhex(sys.argv[3])
    derivation_input = bytes.fromhex(sys.argv[4])
    result = ibe_encrypt_aes_key(aes_key, dpk, derivation_input)
    print(result.hex())


def cmd_derive_verification_key():
    """Derive verification key offline. Args: canister_id_text key_name"""
    canister_id = sys.argv[2]
    key_name = sys.argv[3]
    result = derive_verification_key(canister_id, key_name=key_name)
    print(result.hex())


def cmd_build_metadata():
    """Build gate metadata. Args: cid chain tokenAddress threshold encrypted_aes_key_hex"""
    cid, chain, token_address, threshold_str, enc_key_hex = sys.argv[2:7]
    meta = build_gate_metadata(cid, chain, token_address, int(threshold_str), bytes.fromhex(enc_key_hex))
    print(serialize_gate_metadata(meta))


COMMANDS = {
    "derivation-hash": cmd_derivation_hash,
    "encrypt-file": cmd_encrypt_file,
    "ibe-encrypt": cmd_ibe_encrypt,
    "derive-verification-key": cmd_derive_verification_key,
    "build-metadata": cmd_build_metadata,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(f"Usage: python helpers.py <{'|'.join(COMMANDS.keys())}> [args...]", file=sys.stderr)
        sys.exit(1)
    COMMANDS[sys.argv[1]]()
