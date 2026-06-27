"""Haven-AOL — upload-side encryption library for conditional token-gated access on ICP.

Public surface:

* **v1** (token-gated, per-CID derivation) — exported from ``haven_aol.core``.
  Requires the native ``haven_aol_vetkeys`` extension at runtime.
* **v3** (corpus-scoped, epoch-bound derivation) — exported from
  ``haven_aol.v3``. Pure Python, no native extension required.

v1 and v3 coexist forever; uploaders pick per-file via ``metadata.version``.
"""

# v1 surface. Imports are wrapped in a try/except so that consumers who
# only need v3 (which is pure Python — no native crypto extension) can
# load this package without ``haven_aol_vetkeys`` installed. Production
# consumers (haven-cli, haven-dapp's Python integration) MUST install
# the extension; v1 symbols will be unavailable when it is missing.
#
# Cross-stack note: this lazy-import pattern is the same one used by
# ``cryptography``'s native binding fallback path. It is intentional
# and documented in ``tasking/sprint-3-shared-sdks/01-python-sdk-v3.md``
# (the SDK is "pure code + tests"; haven_aol_vetkeys is the consumer's
# responsibility).
try:
    from haven_aol.core import (
        compute_derivation_input,
        encrypt_file,
        derive_verification_key,
        ibe_encrypt_aes_key,
        build_gate_metadata,
        serialize_gate_metadata,
    )

    _V1_AVAILABLE = True
except ImportError:  # haven_aol_vetkeys / cryptography missing
    _V1_AVAILABLE = False

# v3 surface — always available (pure Python).
from haven_aol.v3 import (
    EPOCH_LENGTH_SECONDS,
    GATE_METADATA_VERSION_V3,
    EIP712_GATE_REQUEST_V3_TYPE_STRING,
    EIP712_GATE_REQUEST_V3_TYPEHASH,
    current_epoch,
    compute_derivation_input_v3,
    build_gate_metadata_v3,
    gate_metadata_v3_to_json,
    parse_gate_metadata_v3,
    parse_gate_metadata,
    build_eip712_gate_request_v3_typed_data,
)

#: v1 metadata version constant (re-exported for symmetry with v3).
GATE_METADATA_VERSION: int = 1

__all__ = [
    # v1 surface (available iff haven_aol_vetkeys is installed)
    "compute_derivation_input",
    "encrypt_file",
    "derive_verification_key",
    "ibe_encrypt_aes_key",
    "build_gate_metadata",
    "serialize_gate_metadata",
    "GATE_METADATA_VERSION",
    # v3 surface (always available)
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
