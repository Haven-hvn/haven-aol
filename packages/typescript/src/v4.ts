// =============================================================================
// Haven-AOL Protocol v4 — TypeScript SDK module
//
// Market-cap-gated progressive unlock ("drip") per
// haven-v4-marketcap-drip.md. This module is the TypeScript twin of
// `packages/python/src/haven_aol/v4.py`. Every public symbol is
// byte-identical to its Python counterpart and to the canister's v4
// derivation (`src/backend/main.mo` :: `computeDerivationInputV4`).
//
// Source-of-truth references — DO NOT divergently re-derive any of these:
//   • docs/derivation-spec.md (§Protocol v4) — preimage template, domain tag,
//     VetKD context, EIP-712 typehash bytes.
//   • tests/fixtures/derivation-v4-vectors.json — byte-identity vectors that
//     must pass in all three implementations (Motoko / Python / TypeScript).
//
// Design contracts (do not break):
//   • No new runtime dependencies. SHA-256 via Web Crypto, keccak256 via
//     `ethers` — same as v3.
//   • Pure functions; no I/O, no side effects. NO oracle calls live here:
//     market-cap enforcement is canister-side (`requestDecryptionKeyV4`).
//   • v4 is additive; it shares `Chain` with v1/v3 and nothing else.
//   • Arkiv marker: entities carrying v4 gates store `gate_type = 4`
//     (ATTR_UINT; 1=per-file, 3=per-epoch, 4=per-marketcap;
//     `gate_type == gate.version`). The gate JSON `version` field is unchanged.
// =============================================================================

import { keccak256, toUtf8Bytes, getBytes } from "ethers";
import { Chain, VALID_CHAINS } from "./types.js";

// -----------------------------------------------------------------------------
// Public constants
// -----------------------------------------------------------------------------

/** Epoch length in seconds — shared constant across v1/v3/v4. */
export const EPOCH_LENGTH_SECONDS = 2_592_000 as const;

/**
 * The integer literal uploaders place in the `version` field of a
 * gate-metadata JSON record to indicate Protocol v4 (`{"version": 4, ...}`).
 */
export const GATE_METADATA_VERSION_V4 = 4 as const;

/**
 * Canonical UTF-8 type string for the EIP-712 `GateRequestV4` struct.
 * Byte-identical to the canister constant (`EIP712_GATE_REQUEST_V4_TYPE_STRING`),
 * Python `EIP712_GATE_REQUEST_V4_TYPE_STRING`, and fixture
 * `constants.eip712TypeString`.
 */
export const EIP712_GATE_REQUEST_V4_TYPE_STRING =
  "GateRequestV4(address evmAddress,bytes transportPublicKey,uint256 epoch,uint256 marketCapTarget,uint256 nonce)" as const;

/**
 * 32-byte keccak256 of `EIP712_GATE_REQUEST_V4_TYPE_STRING`, verified at
 * module load against the pinned hex (same invariant pattern as v3).
 */
export const EIP712_GATE_REQUEST_V4_TYPEHASH: Uint8Array = (() => {
  const computed = getBytes(keccak256(toUtf8Bytes(EIP712_GATE_REQUEST_V4_TYPE_STRING)));
  const pinnedHex = "b9d5f143468a4d6e11bd1d2ff3eb546445b99a1e871adde2cd2c6008e2980afd";
  if (Buffer.from(computed).toString("hex") !== pinnedHex) {
    throw new Error(
      "haven-aol v4: EIP712_GATE_REQUEST_V4_TYPEHASH drift — pinned hex does not equal " +
        "keccak256(EIP712_GATE_REQUEST_V4_TYPE_STRING). This is a build-time invariant " +
        "violation; do not edit the constant by hand — re-derive from the type string.",
    );
  }
  return computed;
})();

/**
 * Canister-side market-cap burst-cache TTL in seconds. Deliberately SHORT
 * (five minutes), not an epoch: crypto markets reprice continuously and a
 * long-lived snapshot would make unlock decisions meaningless. Mirrors
 * MARKET_CAP_CACHE_TTL_SECONDS in src/backend/main.mo.
 */
export const MARKET_CAP_CACHE_TTL_SECONDS = 300 as const;

/**
 * Chain-keyed mint.club V2 Bond contract addresses. Mainnet Bond is
 * CREATE2-deployed (same address on every mainnet chain); EthSepolia
 * uses the separate testnet deployment (from the @mint.club/v2-sdk BOND
 * registry). The canister seeds all five chains from `BOND_ADDRESS_DEFAULT`
 * / `BOND_ADDRESS_SEPOLIA` in `src/backend/main.mo`; other chains need
 * `setBondConfig`.
 *
 * Mirrors the dapp's `BOND_ADDRESS_HINTS` (`haven-dapp/src/lib/v4/market-cap.ts`),
 * keyed here by SDK `Chain` rather than Mint Club network key.
 */
export const BOND_ADDRESSES: Record<string, string> = {
  EthMainnet: "0xc5a076cad94176c2996B32d8466Be1cE757FAa27",
  BaseMainnet: "0xc5a076cad94176c2996B32d8466Be1cE757FAa27",
  ArbitrumOne: "0xc5a076cad94176c2996B32d8466Be1cE757FAa27",
  OptimismMainnet: "0xc5a076cad94176c2996B32d8466Be1cE757FAa27",
  EthSepolia: "0x8dce343A86Aa950d539eeE0e166AFfd0Ef515C0c",
};

/**
 * Bond-address check: does `addr` (any hex casing) name the Bond
 * contract for `chainKey`? The canister requires the gate's
 * `oracleAddress` to be the Bond — the curve is the only price source —
 * so anything else fails closed. Unknown chains never match.
 */
export function isBondAddress(chainKey: string, addr: string): boolean {
  const expected = BOND_ADDRESSES[chainKey];
  if (typeof expected !== "string" || typeof addr !== "string") return false;
  return addr.toLowerCase() === expected.toLowerCase();
}

// Internal pinned values.
const V4_DOMAIN_TAG = "accessol_v4:";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const THRESHOLD_RE = /^(0|[1-9][0-9]*)$/;

function isPlainString(x: unknown): x is string {
  return typeof x === "string";
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

function normalizeNat(value: number | bigint, name: string): bigint {
  if (typeof value === "bigint") {
    if (value < 0n) throw new RangeError(`${name} must be non-negative`);
    return value;
  }
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new TypeError(`${name} must be an integer or bigint, got ${typeof value}`);
  }
  if (value < 0) throw new RangeError(`${name} must be non-negative, got ${value}`);
  return BigInt(value);
}

function toHexPrefixed(bytes: Uint8Array): `0x${string}` {
  let hex = "";
  for (let i = 0; i < bytes.length; i += 1) {
    hex += bytes[i].toString(16).padStart(2, "0");
  }
  return `0x${hex}`;
}

// -----------------------------------------------------------------------------
// Public types
// -----------------------------------------------------------------------------

/**
 * v4 gate-metadata JSON shape. Canonical field order (see
 * `gateMetadataV4ToJson`): `version`, `cid`, `chain`, `tokenAddress`,
 * `threshold`, `epoch`, `marketCapTarget`, `oracleAddress`, `encryptedAesKey`.
 *
 * • `threshold` is a decimal string (JSON-safe bigints).
 * • `epoch` / `marketCapTarget` are JSON numbers. `marketCapTarget` is
 *   whole reserve units (whole ETH for v1 native-reserve tokens) — the
 *   Bond curve is the only price source, so there is no USD leg.
 * • `oracleAddress` must be the chain's Bond contract address (see
 *   `isBondAddress`); anything else fails closed.
 */
export interface GateMetadataV4Json {
  version: 4;
  cid: string;
  chain: Chain;
  tokenAddress: string;
  threshold: string;
  epoch: number;
  marketCapTarget: number;
  oracleAddress: string;
  encryptedAesKey: string;
}

/**
 * EIP-712 typed-data payload for a v4 gate request. The `GateRequestV4`
 * field order is FROZEN — it must match `EIP712_GATE_REQUEST_V4_TYPE_STRING`.
 */
export interface GateRequestV4TypedData {
  domain: {
    name: "HavenAOL";
    chainId: bigint;
    verifyingContract: string;
  };
  primaryType: "GateRequestV4";
  types: {
    EIP712Domain: Array<{ name: string; type: string }>;
    GateRequestV4: Array<{ name: string; type: string }>;
  };
  message: {
    evmAddress: string;
    transportPublicKey: `0x${string}`;
    epoch: bigint;
    marketCapTarget: bigint;
    nonce: bigint;
  };
}

// -----------------------------------------------------------------------------
// Derivation (SHA-256 over the v4 preimage)
// -----------------------------------------------------------------------------

/**
 * Compute the v4 derivation input (32 raw SHA-256 bytes).
 *
 * Preimage template — byte-identical across Motoko / Python / TypeScript:
 *
 *     "accessol_v4:" + chain + ":" + tokenAddress + ":" +
 *         decimal(threshold) + ":" + decimal(epoch) + ":" +
 *         decimal(marketCapTarget)
 *
 * The market-cap target ALWAYS participates (no collapse): two chunks of one
 * drip with different targets derive different keys even under identical gate
 * tuples. Token address casing is preserved verbatim; integers render as
 * canonical base-10 (matches Motoko `Nat.toText`).
 */
export async function computeDerivationInputV4(
  chain: Chain,
  tokenAddress: string,
  threshold: number | bigint,
  epoch: number | bigint,
  marketCapTarget: number | bigint,
): Promise<Uint8Array> {
  validateChain(chain);
  validateTokenAddress(tokenAddress);
  const thr = normalizeNat(threshold, "threshold");
  const epo = normalizeNat(epoch, "epoch");
  const target = normalizeNat(marketCapTarget, "marketCapTarget");

  const preimage = `${V4_DOMAIN_TAG}${chain}:${tokenAddress}:${thr.toString()}:${epo.toString()}:${target.toString()}`;
  const encoded = new TextEncoder().encode(preimage);
  const hash = await crypto.subtle.digest("SHA-256", encoded);
  return new Uint8Array(hash);
}

// -----------------------------------------------------------------------------
// Gate metadata v4 — build, serialise, parse
// -----------------------------------------------------------------------------

/**
 * Construct a `GateMetadataV4Json` record from typed inputs. Same
 * uploader-side validation contract as v3 (throws instead of returning null;
 * threshold-zero requires epoch-zero).
 */
export function buildGateMetadataV4(args: {
  cid: string;
  chain: Chain;
  tokenAddress: string;
  threshold: number | bigint;
  epoch: number | bigint;
  marketCapTarget: number | bigint;
  oracleAddress: string;
  encryptedAesKey: string;
}): GateMetadataV4Json {
  validateChain(args.chain);
  validateTokenAddress(args.tokenAddress);
  validateTokenAddress(args.oracleAddress);
  if (typeof args.cid !== "string" || args.cid.length === 0) {
    throw new Error("cid must be a non-empty string");
  }
  if (typeof args.encryptedAesKey !== "string" || args.encryptedAesKey.length === 0) {
    throw new Error("encryptedAesKey must be a non-empty string");
  }
  const thr = normalizeNat(args.threshold, "threshold");
  const epo = normalizeNat(args.epoch, "epoch");
  const target = normalizeNat(args.marketCapTarget, "marketCapTarget");
  if (thr === 0n && epo !== 0n) {
    throw new Error(
      "threshold==0 requires epoch==0 (canister collapses epoch to 0; uploader " +
        "metadata must match — see docs/derivation-spec.md §v3.4)",
    );
  }
  const epochAsNumber = Number(epo);
  const targetAsNumber = Number(target);
  if (!Number.isSafeInteger(epochAsNumber)) {
    throw new RangeError(
      `epoch ${epo.toString()} exceeds Number.MAX_SAFE_INTEGER; JSON cannot round-trip safely`,
    );
  }
  if (!Number.isSafeInteger(targetAsNumber)) {
    throw new RangeError(
      `marketCapTarget ${target.toString()} exceeds Number.MAX_SAFE_INTEGER; JSON cannot round-trip safely`,
    );
  }
  return {
    version: 4,
    cid: args.cid,
    chain: args.chain,
    tokenAddress: args.tokenAddress,
    threshold: thr.toString(),
    epoch: epochAsNumber,
    marketCapTarget: targetAsNumber,
    oracleAddress: args.oracleAddress,
    encryptedAesKey: args.encryptedAesKey,
  };
}

/** Canonical JSON serialiser for v4 metadata (fixed field order, compact). */
export function gateMetadataV4ToJson(meta: GateMetadataV4Json): string {
  if (meta.version !== 4) {
    throw new Error(`gateMetadataV4ToJson expects version=4, got ${String(meta.version)}`);
  }
  const canonical = {
    version: meta.version,
    cid: meta.cid,
    chain: meta.chain,
    tokenAddress: meta.tokenAddress,
    threshold: meta.threshold,
    epoch: meta.epoch,
    marketCapTarget: meta.marketCapTarget,
    oracleAddress: meta.oracleAddress,
    encryptedAesKey: meta.encryptedAesKey,
  };
  return JSON.stringify(canonical);
}

/**
 * Type guard: is `meta` a structurally-valid `GateMetadataV4Json`?
 * Same rules as `parseGateMetadataV4` without the JSON decode step.
 */
export function isGateMetadataV4(meta: unknown): meta is GateMetadataV4Json {
  if (typeof meta !== "object" || meta === null) return false;
  const m = meta as Record<string, unknown>;
  if (m.version !== 4) return false;
  if (typeof m.cid !== "string" || m.cid.length === 0) return false;
  if (!isPlainString(m.chain) || !VALID_CHAINS.includes(m.chain as Chain)) return false;
  if (typeof m.tokenAddress !== "string" || !ADDRESS_RE.test(m.tokenAddress)) return false;
  if (typeof m.threshold !== "string" || !THRESHOLD_RE.test(m.threshold)) return false;
  if (typeof m.epoch !== "number" || !Number.isInteger(m.epoch) || m.epoch < 0) return false;
  if (
    typeof m.marketCapTarget !== "number" ||
    !Number.isInteger(m.marketCapTarget) ||
    m.marketCapTarget < 0
  ) {
    return false;
  }
  if (typeof m.oracleAddress !== "string" || !ADDRESS_RE.test(m.oracleAddress)) return false;
  if (typeof m.encryptedAesKey !== "string" || m.encryptedAesKey.length === 0) return false;
  // threshold-zero ↔ epoch-zero invariant (mirrors v3 §v3.4)
  if (m.threshold === "0" && m.epoch !== 0) return false;
  return true;
}

/**
 * Strict v4 metadata parser. Accepts a JSON string, a UTF-8 byte array
 * (Uint8Array), or an already-deserialised object. Returns `null` on any
 * shape or value violation — soft-fail semantics mirror Python's
 * `parse_gate_metadata_v4`.
 */
export function parseGateMetadataV4(raw: unknown): GateMetadataV4Json | null {
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
  if (!isGateMetadataV4(candidate)) return null;
  return candidate;
}

// -----------------------------------------------------------------------------
// EIP-712 typed data — `GateRequestV4`
// -----------------------------------------------------------------------------

/**
 * Build the EIP-712 typed-data payload for a v4 gate request.
 *
 * Field order under `types.GateRequestV4` MUST match
 * `EIP712_GATE_REQUEST_V4_TYPE_STRING` exactly: `evmAddress`,
 * `transportPublicKey`, `epoch`, `marketCapTarget`, `nonce`. The signature
 * commits to the requested unlock target — a reader cannot sign once at a
 * low target and later claim a higher-unlocked chunk.
 *
 * Domain has three fields (`name`, `chainId`, `verifyingContract`) and omits
 * `version` — identical shape to v1/v3 (canister `eip712DomainSeparator`).
 */
export function buildGateRequestV4TypedData(args: {
  evmAddress: string;
  transportPublicKey: Uint8Array;
  epoch: number | bigint;
  marketCapTarget: number | bigint;
  nonce: number | bigint;
  eip712ChainId: number | bigint;
  eip712VerifyingContract: string;
}): GateRequestV4TypedData {
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
  const epoch = normalizeNat(args.epoch, "epoch");
  const target = normalizeNat(args.marketCapTarget, "marketCapTarget");
  const nonce = normalizeNat(args.nonce, "nonce");
  const chainId = normalizeNat(args.eip712ChainId, "eip712ChainId");

  return {
    domain: {
      name: "HavenAOL",
      chainId,
      verifyingContract: args.eip712VerifyingContract,
    },
    primaryType: "GateRequestV4",
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "verifyingContract", type: "address" },
      ],
      GateRequestV4: [
        { name: "evmAddress", type: "address" },
        { name: "transportPublicKey", "type": "bytes" } as { name: string; type: string },
        { name: "epoch", type: "uint256" },
        { name: "marketCapTarget", type: "uint256" },
        { name: "nonce", type: "uint256" },
      ],
    },
    message: {
      evmAddress: args.evmAddress,
      transportPublicKey: toHexPrefixed(args.transportPublicKey),
      epoch,
      marketCapTarget: target,
      nonce,
    },
  };
}
