// =============================================================================
// Haven-AOL Protocol v3 — TypeScript SDK module
//
// Sprint 3 · Task 02 (see tasking/sprint-3-shared-sdks/02-typescript-sdk-v3.md).
//
// This module is the TypeScript twin of `packages/python/src/haven_aol/v3.py`
// (Sprint 3 · Task 01). Every public symbol here is byte-identical to its
// Python counterpart and to the canister's v3 derivation
// (`src/backend/main.mo` :: `computeDerivationInputV3`).
//
// Source-of-truth references — DO NOT divergently re-derive any of these:
//   • docs/derivation-spec.md (§Protocol v3) — preimage template, domain tag,
//     VetKD context, EIP-712 typehash bytes, epoch-length constant.
//   • tests/fixtures/derivation-v3-vectors.json — byte-identity vectors that
//     must pass in all three implementations (Motoko / Python / TypeScript).
//   • tasking/README.md (§Interface Contracts) — public TS API names.
//
// Design contracts (do not break):
//   • No new runtime dependencies. SHA-256 via Web Crypto (already in use),
//     keccak256 via `ethers` (already a dep — see crypto.ts / canister.ts).
//   • Pure functions; no I/O, no side effects.
//   • v3 is *additive* — it never reaches into v1 helpers and never mutates
//     v1 state. The two protocols share `Chain` and nothing else.
//   • Symbol names are exact. The Python SDK validator pins these names; if
//     any change here, the cross-stack integration suite (Sprint 6) breaks.
// =============================================================================

import { keccak256, toUtf8Bytes, getBytes } from "ethers";
import { Chain, VALID_CHAINS } from "./types.js";

// -----------------------------------------------------------------------------
// Public constants (pinned by docs/derivation-spec.md §Protocol v3)
// -----------------------------------------------------------------------------

/**
 * Epoch length in seconds. 30 days * 86400 s/day = 2_592_000.
 *
 * Identical to canister `EPOCH_LENGTH_SECONDS` and Python
 * `EPOCH_LENGTH_SECONDS`. Changing this rotates every cached VetKey on the
 * next epoch boundary and is a wire-incompatible protocol change.
 */
export const EPOCH_LENGTH_SECONDS = 2_592_000 as const;

/**
 * The integer literal that uploaders MUST place in the `version` field of a
 * gate-metadata JSON record to indicate Protocol v3 (`{"version": 3, ...}`).
 * v1 records still carry `version: 1`. Both shapes coexist forever.
 */
export const GATE_METADATA_VERSION_V3 = 3 as const;

/**
 * Canonical UTF-8 type string for the EIP-712 `GateRequestV3` struct.
 *
 * This MUST be byte-identical to:
 *   • canister `EIP712_GATE_REQUEST_V3_TYPE_STRING` (`src/backend/main.mo`),
 *   • Python `EIP712_GATE_REQUEST_V3_TYPE_STRING`
 *     (`packages/python/src/haven_aol/v3.py`),
 *   • fixture `constants.eip712TypeString`.
 *
 * Whitespace inside the parens is significant — keccak256 of this exact
 * string yields the v3 typehash.
 */
export const EIP712_GATE_REQUEST_V3_TYPE_STRING =
  "GateRequestV3(address evmAddress,bytes transportPublicKey,uint256 epoch,uint256 nonce)" as const;

/**
 * 32-byte keccak256 of `EIP712_GATE_REQUEST_V3_TYPE_STRING`. Pre-computed
 * at module load to avoid recomputation on the hot path. The pinned hex is
 * the same value the canister, the Python SDK, and the test fixture all
 * declare independently; this module additionally verifies it via
 * `keccak256(toUtf8Bytes(EIP712_GATE_REQUEST_V3_TYPE_STRING))`.
 */
export const EIP712_GATE_REQUEST_V3_TYPEHASH: Uint8Array = (() => {
  const computed = getBytes(keccak256(toUtf8Bytes(EIP712_GATE_REQUEST_V3_TYPE_STRING)));
  const pinnedHex = "bf3ae9382ccda27b087c12bfb5fd82fa7ccc60857623462a4c7fec696bc7d7af";
  if (Buffer.from(computed).toString("hex") !== pinnedHex) {
    throw new Error(
      "haven-aol v3: EIP712_GATE_REQUEST_V3_TYPEHASH drift — pinned hex does not equal " +
        "keccak256(EIP712_GATE_REQUEST_V3_TYPE_STRING). This is a build-time invariant " +
        "violation; do not edit the constant by hand — re-derive from the type string.",
    );
  }
  return computed;
})();

// Internal pinned values (kept private — exposed via the constants above).
const V3_DOMAIN_TAG = "accessol_v3:";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const THRESHOLD_RE = /^(0|[1-9][0-9]*)$/;

// -----------------------------------------------------------------------------
// Public types
// -----------------------------------------------------------------------------

/**
 * v3 gate-metadata JSON shape. Field order in the canonical serialization
 * matches `gateMetadataV3ToJson`: `version`, `cid`, `chain`, `tokenAddress`,
 * `threshold`, `epoch`, `encryptedAesKey`.
 *
 * • `version` is the literal integer `3`.
 * • `threshold` is the decimal *string* representation of a `bigint` (so JSON
 *   can carry values >= 2^53). v1 also serialises threshold as a string.
 * • `epoch` is a JSON `number`. Safe up to ~285,000 years from the Unix epoch.
 * • `encryptedAesKey` is RFC 4648 §4 base64 of the IBE ciphertext.
 */
export interface GateMetadataV3Json {
  version: 3;
  cid: string;
  chain: Chain;
  tokenAddress: string;
  threshold: string;
  epoch: number;
  encryptedAesKey: string;
}

/**
 * EIP-712 typed-data payload for a v3 single-CID gate request. The shape
 * mirrors what `ethers.TypedDataEncoder` and `viem.signTypedData` consume.
 *
 * The `GateRequestV3` field order is FROZEN — it must match
 * `EIP712_GATE_REQUEST_V3_TYPE_STRING` byte-for-byte. Any reordering changes
 * the typehash and breaks the canister verifier.
 */
export interface GateRequestV3TypedData {
  domain: {
    name: "HavenAOL";
    chainId: bigint;
    verifyingContract: string;
  };
  primaryType: "GateRequestV3";
  types: {
    EIP712Domain: Array<{ name: string; type: string }>;
    GateRequestV3: Array<{ name: string; type: string }>;
  };
  message: {
    evmAddress: string;
    transportPublicKey: `0x${string}`;
    epoch: bigint;
    nonce: bigint;
  };
}

// -----------------------------------------------------------------------------
// Epoch
// -----------------------------------------------------------------------------

/**
 * Current epoch derived from the *local clock*. Identical to the canister's
 * `getCurrentEpoch` query and to Python's `current_epoch()`.
 *
 *   floor(Date.now() / 1000 / EPOCH_LENGTH_SECONDS)
 *
 * Callers MUST treat this as advisory: clients that disagree with the
 * canister by ≥1 epoch will get rejected at the `#InvalidEpoch` check. Use
 * this to choose the epoch for an upload; do NOT use it as a security
 * boundary.
 */
export function currentEpoch(): number {
  return Math.floor(Date.now() / 1000 / EPOCH_LENGTH_SECONDS);
}

// -----------------------------------------------------------------------------
// Derivation (SHA-256 over the v3 preimage)
// -----------------------------------------------------------------------------

function normalizeThreshold(threshold: number | bigint): bigint {
  if (typeof threshold === "bigint") return threshold;
  if (typeof threshold !== "number" || !Number.isInteger(threshold)) {
    throw new TypeError(`threshold must be an integer or bigint, got ${typeof threshold}`);
  }
  if (threshold < 0) {
    throw new RangeError(`threshold must be non-negative, got ${threshold}`);
  }
  return BigInt(threshold);
}

function normalizeEpoch(epoch: number | bigint): bigint {
  if (typeof epoch === "bigint") return epoch;
  if (typeof epoch !== "number" || !Number.isInteger(epoch)) {
    throw new TypeError(`epoch must be an integer or bigint, got ${typeof epoch}`);
  }
  if (epoch < 0) {
    throw new RangeError(`epoch must be non-negative, got ${epoch}`);
  }
  return BigInt(epoch);
}

function validateChain(chain: Chain): void {
  if (!VALID_CHAINS.includes(chain)) {
    throw new Error(`Invalid chain: ${String(chain)}`);
  }
}

function validateTokenAddress(tokenAddress: string): void {
  if (typeof tokenAddress !== "string" || !ADDRESS_RE.test(tokenAddress)) {
    throw new Error(`Invalid tokenAddress: ${String(tokenAddress)}`);
  }
}

/**
 * Compute the v3 derivation input (32 raw SHA-256 bytes).
 *
 * Preimage template — byte-identical across Motoko / Python / TypeScript:
 *
 *     "accessol_v3:" + chain + ":" + tokenAddress + ":" +
 *         decimal(threshold) + ":" + decimal(epoch)
 *
 * • `tokenAddress` casing is preserved verbatim (Motoko, Python, and TS all
 *   *do not* lowercase before hashing — balance checks lowercase separately).
 * • `threshold` and `epoch` are rendered as canonical base-10 with no leading
 *   zeros, no sign, no thousands separators (matches Motoko `Nat.toText`).
 *
 * Returns a fresh `Uint8Array` of length 32 (the SHA-256 digest), suitable
 * for use as VetKD `input` and IBE identity.
 */
export async function computeDerivationInputV3(
  chain: Chain,
  tokenAddress: string,
  threshold: number | bigint,
  epoch: number | bigint,
): Promise<Uint8Array> {
  validateChain(chain);
  validateTokenAddress(tokenAddress);
  const thr = normalizeThreshold(threshold);
  const epo = normalizeEpoch(epoch);

  const preimage = `${V3_DOMAIN_TAG}${chain}:${tokenAddress}:${thr.toString()}:${epo.toString()}`;
  const encoded = new TextEncoder().encode(preimage);
  const hash = await crypto.subtle.digest("SHA-256", encoded);
  return new Uint8Array(hash);
}

// -----------------------------------------------------------------------------
// Gate metadata v3 — build, serialise, parse
// -----------------------------------------------------------------------------

function isPlainString(x: unknown): x is string {
  return typeof x === "string";
}

/**
 * Construct a `GateMetadataV3Json` record from typed inputs. Performs the
 * same uploader-side validation the Python SDK does and refuses to emit a
 * record that the canister would silently collapse:
 *
 *   • `threshold === 0n` requires `epoch === 0n`. The canister's v3
 *     derivation collapses epoch to 0 when threshold is 0 (see
 *     docs/derivation-spec.md §v3.4). Building a record that names a
 *     nonzero epoch alongside a zero threshold would be invisibly rewritten
 *     on the canister; we refuse to encode that ambiguity at the SDK layer.
 *
 * Throws (instead of returning null) so the failure surfaces at the call
 * site of the uploader — encryption time is the right time to discover that
 * the gate parameters are malformed.
 */
export function buildGateMetadataV3(args: {
  cid: string;
  chain: Chain;
  tokenAddress: string;
  threshold: number | bigint;
  epoch: number | bigint;
  encryptedAesKey: string;
}): GateMetadataV3Json {
  validateChain(args.chain);
  validateTokenAddress(args.tokenAddress);
  if (typeof args.cid !== "string" || args.cid.length === 0) {
    throw new Error("cid must be a non-empty string");
  }
  if (typeof args.encryptedAesKey !== "string" || args.encryptedAesKey.length === 0) {
    throw new Error("encryptedAesKey must be a non-empty string");
  }
  const thr = normalizeThreshold(args.threshold);
  const epo = normalizeEpoch(args.epoch);
  if (thr === 0n && epo !== 0n) {
    throw new Error(
      "threshold==0 requires epoch==0 (canister collapses epoch to 0; uploader " +
        "metadata must match — see docs/derivation-spec.md §v3.4)",
    );
  }
  const epochAsNumber = Number(epo);
  if (!Number.isSafeInteger(epochAsNumber)) {
    throw new RangeError(
      `epoch ${epo.toString()} exceeds Number.MAX_SAFE_INTEGER; JSON cannot round-trip safely`,
    );
  }
  return {
    version: 3,
    cid: args.cid,
    chain: args.chain,
    tokenAddress: args.tokenAddress,
    threshold: thr.toString(),
    epoch: epochAsNumber,
    encryptedAesKey: args.encryptedAesKey,
  };
}

/**
 * Canonical JSON serialiser for v3 metadata. Fixed field order matches
 * `tasking/README.md` §Gate metadata v3 JSON shape. No whitespace between
 * tokens — matches Python's `json.dumps(separators=(",", ":"))`.
 *
 * Because field order in object-literal initialisers is preserved by every
 * JS engine since ES2015 (modulo integer-keyed entries, which we do not
 * have), `JSON.stringify` emits keys in declaration order. We re-declare
 * the object inline rather than serialising the caller-supplied one to
 * guarantee the canonical order even if the caller built theirs out of
 * order.
 */
export function gateMetadataV3ToJson(meta: GateMetadataV3Json): string {
  if (meta.version !== 3) {
    throw new Error(`gateMetadataV3ToJson expects version=3, got ${String(meta.version)}`);
  }
  const canonical = {
    version: meta.version,
    cid: meta.cid,
    chain: meta.chain,
    tokenAddress: meta.tokenAddress,
    threshold: meta.threshold,
    epoch: meta.epoch,
    encryptedAesKey: meta.encryptedAesKey,
  };
  return JSON.stringify(canonical);
}

/**
 * Type guard: is `meta` a structurally-valid `GateMetadataV3Json`?
 *
 * Performs the same shape and value checks as `parseGateMetadataV3` but does
 * not parse JSON — it inspects an already-deserialised object. Useful for
 * narrowing the return of the dispatching `parseGateMetadata` when the
 * caller already has the parsed result in hand.
 */
export function isGateMetadataV3(meta: unknown): meta is GateMetadataV3Json {
  if (typeof meta !== "object" || meta === null) return false;
  const m = meta as Record<string, unknown>;
  if (m.version !== 3) return false;
  if (typeof m.cid !== "string" || m.cid.length === 0) return false;
  if (!isPlainString(m.chain) || !VALID_CHAINS.includes(m.chain as Chain)) return false;
  if (typeof m.tokenAddress !== "string" || !ADDRESS_RE.test(m.tokenAddress)) return false;
  if (typeof m.threshold !== "string" || !THRESHOLD_RE.test(m.threshold)) return false;
  if (typeof m.epoch !== "number" || !Number.isInteger(m.epoch) || m.epoch < 0) return false;
  if (typeof m.encryptedAesKey !== "string" || m.encryptedAesKey.length === 0) return false;
  // threshold-zero ↔ epoch-zero invariant (see §v3.4)
  if (m.threshold === "0" && m.epoch !== 0) return false;
  return true;
}

/**
 * Strict v3 metadata parser. Accepts a JSON string, a UTF-8 byte array
 * (Uint8Array), or an already-deserialised object. Returns `null` on any
 * shape or value violation — soft-fail semantics mirror Python's
 * `parse_gate_metadata_v3` so the dispatching `parseGateMetadata` can fall
 * through to the v1 path on a non-v3 record.
 *
 * Threshold-zero / nonzero-epoch records are rejected (return null). The
 * canister would silently collapse epoch to 0 for derivation, but uploader
 * intent is ambiguous, so we refuse to decode.
 */
export function parseGateMetadataV3(raw: unknown): GateMetadataV3Json | null {
  let candidate: unknown;
  if (raw instanceof Uint8Array) {
    try {
      candidate = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
    } catch {
      return null;
    }
  } else if (typeof raw === "string") {
    try {
      candidate = JSON.parse(raw);
    } catch {
      return null;
    }
  } else {
    candidate = raw;
  }
  if (!isGateMetadataV3(candidate)) return null;
  return candidate;
}

// -----------------------------------------------------------------------------
// EIP-712 typed data — `GateRequestV3`
// -----------------------------------------------------------------------------

function toHexPrefixed(bytes: Uint8Array): `0x${string}` {
  let hex = "";
  for (let i = 0; i < bytes.length; i += 1) {
    hex += bytes[i].toString(16).padStart(2, "0");
  }
  return `0x${hex}`;
}

/**
 * Build the EIP-712 typed-data payload for a v3 single-CID gate request.
 *
 * Field order under `types.GateRequestV3` MUST match
 * `EIP712_GATE_REQUEST_V3_TYPE_STRING` exactly:
 * `evmAddress`, `transportPublicKey`, `epoch`, `nonce`. The canister's
 * verifier hashes the typehash, then each field in this order, then
 * compares to the user-supplied signature. Re-ordering breaks v3.
 *
 * The EIP-712 domain has three fields (`name`, `chainId`, `verifyingContract`)
 * and intentionally OMITS `version` — same shape the canister derives via
 * `eip712DomainSeparator` (src/backend/main.mo). Adding a `version` field
 * here would silently rotate the domain separator and reject every v3
 * signature.
 */
export function buildGateRequestV3TypedData(args: {
  evmAddress: string;
  transportPublicKey: Uint8Array;
  epoch: number | bigint;
  nonce: number | bigint;
  eip712ChainId: number | bigint;
  eip712VerifyingContract: string;
}): GateRequestV3TypedData {
  if (typeof args.evmAddress !== "string" || !ADDRESS_RE.test(args.evmAddress)) {
    throw new Error(`Invalid evmAddress: ${String(args.evmAddress)}`);
  }
  if (
    typeof args.eip712VerifyingContract !== "string" ||
    !ADDRESS_RE.test(args.eip712VerifyingContract)
  ) {
    throw new Error(
      `Invalid eip712VerifyingContract: ${String(args.eip712VerifyingContract)}`,
    );
  }
  if (!(args.transportPublicKey instanceof Uint8Array) || args.transportPublicKey.length === 0) {
    throw new Error("transportPublicKey must be a non-empty Uint8Array");
  }
  const epoch = normalizeEpoch(args.epoch);
  const nonce = typeof args.nonce === "bigint" ? args.nonce : BigInt(args.nonce);
  if (nonce < 0n) {
    throw new RangeError("nonce must be non-negative");
  }
  const chainId =
    typeof args.eip712ChainId === "bigint" ? args.eip712ChainId : BigInt(args.eip712ChainId);
  if (chainId < 0n) {
    throw new RangeError("eip712ChainId must be non-negative");
  }
  return {
    domain: {
      name: "HavenAOL",
      chainId,
      verifyingContract: args.eip712VerifyingContract,
    },
    primaryType: "GateRequestV3",
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "verifyingContract", type: "address" },
      ],
      GateRequestV3: [
        { name: "evmAddress", type: "address" },
        { name: "transportPublicKey", type: "bytes" },
        { name: "epoch", type: "uint256" },
        { name: "nonce", type: "uint256" },
      ],
    },
    message: {
      evmAddress: args.evmAddress,
      transportPublicKey: toHexPrefixed(args.transportPublicKey),
      epoch,
      nonce,
    },
  };
}
