import { Chain, GateMetadata, VALID_CHAINS } from "./types.js";
import {
  GateMetadataV3Json,
  isGateMetadataV3,
  parseGateMetadataV3,
} from "./v3.js";

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const THRESHOLD_RE = /^(0|[1-9][0-9]*)$/;

/**
 * Parse and validate v1 gate metadata JSON.
 *
 * **v1 contract — DO NOT CHANGE.** Signature, behavior, and error
 * semantics (throw on invalid) are frozen per
 * `tasking/sprint-3-shared-sdks/02-typescript-sdk-v3.md` §"Symbols that
 * must not change". For a non-throwing v1/v3 dispatcher see
 * `parseGateMetadataAny`.
 */
export function parseGateMetadata(json: string): GateMetadata {
  const obj = JSON.parse(json);

  if (obj.version !== 1) {
    throw new Error(`Unsupported gate metadata version: ${obj.version}`);
  }
  if (!VALID_CHAINS.includes(obj.chain)) {
    throw new Error(`Invalid chain: ${obj.chain}`);
  }
  if (typeof obj.tokenAddress !== "string" || !ADDRESS_RE.test(obj.tokenAddress)) {
    throw new Error(`Invalid tokenAddress: ${obj.tokenAddress}`);
  }
  if (typeof obj.threshold !== "string" || !THRESHOLD_RE.test(obj.threshold)) {
    throw new Error(`Invalid threshold: ${obj.threshold}`);
  }
  if (typeof obj.cid !== "string" || obj.cid.length === 0) {
    throw new Error("Missing or empty cid");
  }
  if (typeof obj.encryptedAesKey !== "string" || obj.encryptedAesKey.length === 0) {
    throw new Error("Missing or empty encryptedAesKey");
  }

  return {
    version: 1,
    cid: obj.cid,
    chain: obj.chain as Chain,
    tokenAddress: obj.tokenAddress,
    threshold: BigInt(obj.threshold),
    encryptedAesKey: obj.encryptedAesKey,
  };
}

/**
 * Discriminated dispatcher for v1 / v3 metadata.
 *
 * Soft-fail (returns `null` on any shape violation) so callers that fetch
 * a record of unknown version can branch cleanly. Discriminate on
 * `.version`: v1 → `GateMetadata` (with `bigint` threshold), v3 →
 * `GateMetadataV3Json` (with `string` threshold and `number` epoch).
 *
 * NOTE: We do NOT route v1 through the throwing `parseGateMetadata`
 * because the brief asks for a soft-fail dispatcher. The v1 validation
 * predicates here are kept byte-identical to `parseGateMetadata` so a
 * record that v1 throws on also returns `null` here.
 */
export function parseGateMetadataAny(
  raw: unknown,
): GateMetadata | GateMetadataV3Json | null {
  let obj: unknown;
  if (raw instanceof Uint8Array) {
    try {
      obj = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
    } catch {
      return null;
    }
  } else if (typeof raw === "string") {
    try {
      obj = JSON.parse(raw);
    } catch {
      return null;
    }
  } else {
    obj = raw;
  }

  if (typeof obj !== "object" || obj === null) return null;
  const rec = obj as Record<string, unknown>;

  // Reject booleans (which are not strict integers per our intent).
  if (rec.version === 3) {
    return isGateMetadataV3(rec) ? (rec as GateMetadataV3Json) : null;
  }
  if (rec.version === 1) {
    if (typeof rec.cid !== "string" || rec.cid.length === 0) return null;
    if (typeof rec.chain !== "string" || !VALID_CHAINS.includes(rec.chain as Chain)) return null;
    if (typeof rec.tokenAddress !== "string" || !ADDRESS_RE.test(rec.tokenAddress)) return null;
    if (typeof rec.threshold !== "string" || !THRESHOLD_RE.test(rec.threshold)) return null;
    if (typeof rec.encryptedAesKey !== "string" || rec.encryptedAesKey.length === 0) return null;
    return {
      version: 1,
      cid: rec.cid,
      chain: rec.chain as Chain,
      tokenAddress: rec.tokenAddress,
      threshold: BigInt(rec.threshold),
      encryptedAesKey: rec.encryptedAesKey,
    };
  }
  return null;
}

// Re-export the v3-only parser so callers that already know the record is v3
// can skip the dispatcher.
export { parseGateMetadataV3 };
