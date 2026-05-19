/** Haven-AOL — decrypt-side library for conditional token-gated access on DFINITY ICP. */

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
} from "./types.js";
export { VALID_CHAINS } from "./types.js";

// Functions
export { parseGateMetadata } from "./metadata.js";
export { computeDerivationInput } from "./derivation.js";
export { createTransportKeyPair, recoverVetKey, ibeDecryptAesKey, decryptFile } from "./crypto.js";
export { requestDecryptionKey, fetchVerificationKey, fetchAttestationPublicKey } from "./canister.js";
export { decryptGatedFile, HavenAolError } from "./decrypt.js";
export { buildGateRequestTypedData, parseSignatureHex } from "./eip712.js";