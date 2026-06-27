/** Haven-AOL — decrypt-side library for conditional token-gated access on DFINITY ICP. */

// ── v1 (unchanged — see Sprint 0 §"v1 must not change") ──────────────────────

// Types
export type {
  Chain,
  GateMetadata,
  GateRequest,
  GateResult,
  GateError,
  InsufficientBalanceError,
  DecryptOptions,
  GateRequestTypedData,
  BatchGateRequest,
  BatchKeyEntry,
  BatchGateResult,
  BatchGateRequestTypedData,
} from "./types.js";
export { VALID_CHAINS } from "./types.js";

// Functions
export { parseGateMetadata, parseGateMetadataAny } from "./metadata.js";
export { computeDerivationInput } from "./derivation.js";
export { createTransportKeyPair, recoverVetKey, ibeDecryptAesKey, decryptFile } from "./crypto.js";
export { requestDecryptionKey, batchRequestDecryptionKey, fetchVerificationKey, fetchAttestationPublicKey } from "./canister.js";
export { decryptGatedFile, HavenAolError } from "./decrypt.js";
export { buildGateRequestTypedData, buildBatchGateRequestTypedData, parseSignatureHex } from "./eip712.js";

// ── v3 (additive — see tasking/sprint-3-shared-sdks/02-typescript-sdk-v3.md) ─

export type { GateMetadataV3Json, GateRequestV3TypedData } from "./v3.js";
export {
  EPOCH_LENGTH_SECONDS,
  GATE_METADATA_VERSION_V3,
  EIP712_GATE_REQUEST_V3_TYPE_STRING,
  EIP712_GATE_REQUEST_V3_TYPEHASH,
  currentEpoch,
  computeDerivationInputV3,
  buildGateMetadataV3,
  gateMetadataV3ToJson,
  isGateMetadataV3,
  parseGateMetadataV3,
  buildGateRequestV3TypedData,
} from "./v3.js";
