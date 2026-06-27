// =============================================================================
// Haven-AOL Protocol v3 — TypeScript SDK tests
//
// Sprint 3 · Task 02. Twin of `packages/python/tests/test_haven_aol_v3.py`.
// Uses `node --test` (same runner as the v1 unit tests in this folder).
//
// Test strategy:
//   • Fixture parity: every "positive" vector in
//     `tests/fixtures/derivation-v3-vectors.json` MUST hash to the pinned
//     digest. This is the cross-stack byte-identity gate.
//   • Constant parity: epoch length, type string, typehash, version.
//   • Build/serialise/parse round-trips with canonical field order.
//   • Threshold-zero / nonzero-epoch invariant (canister §v3.4).
//   • Dispatcher: v1 records pass through unchanged; v3 records narrow
//     correctly; unknown/garbage records return null.
//   • EIP-712 typed-data shape exact (`GateRequestV3` field order, no
//     `version` field on the domain).
// =============================================================================

import { describe, it } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import {
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
  type Chain,
  type GateMetadataV3Json,
} from "../index.js";
import { parseGateMetadataAny } from "../metadata.js";

// Resolve the fixture path. At test runtime the compiled module lives at
// `packages/typescript/dist/test/v3.test.js`. Four `..` segments walk to
// the repo root; from there the canonical fixture lives at
// `tests/fixtures/derivation-v3-vectors.json`.
//
//   dist/test/v3.test.js  →  ..  →  dist/
//                         →  ..  →  packages/typescript/
//                         →  ..  →  packages/
//                         →  ..  →  <repo root>
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const FIXTURE_PATH = path.join(REPO_ROOT, "tests", "fixtures", "derivation-v3-vectors.json");

interface FixturePositiveVector {
  name: string;
  kind: "positive";
  input: { chain: Chain; tokenAddress: string; threshold: number; epoch: number };
  expected: { preimageUtf8: string; preimageHex: string; derivationInputHex: string };
}

interface FixtureFile {
  version: number;
  constants: {
    epochLengthSeconds: number;
    domainTag: string;
    vetkdContext: string;
    eip712TypeString: string;
    eip712TypehashHex: string;
  };
  vectors: Array<FixturePositiveVector | { name: string; kind: string }>;
}

const FIXTURE: FixtureFile = JSON.parse(fs.readFileSync(FIXTURE_PATH, "utf-8"));
const POSITIVE_VECTORS: FixturePositiveVector[] = FIXTURE.vectors.filter(
  (v): v is FixturePositiveVector => v.kind === "positive",
);

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// ── Protocol constants parity ───────────────────────────────────────────────

describe("v3 protocol constants", () => {
  it("EPOCH_LENGTH_SECONDS matches fixture", () => {
    assert.equal(EPOCH_LENGTH_SECONDS, FIXTURE.constants.epochLengthSeconds);
    assert.equal(EPOCH_LENGTH_SECONDS, 2_592_000);
  });

  it("GATE_METADATA_VERSION_V3 is the integer 3", () => {
    assert.equal(GATE_METADATA_VERSION_V3, 3);
    assert.equal(typeof GATE_METADATA_VERSION_V3, "number");
  });

  it("EIP712_GATE_REQUEST_V3_TYPE_STRING matches fixture (whitespace-exact)", () => {
    assert.equal(EIP712_GATE_REQUEST_V3_TYPE_STRING, FIXTURE.constants.eip712TypeString);
  });

  it("EIP712_GATE_REQUEST_V3_TYPEHASH matches fixture hex", () => {
    assert.equal(toHex(EIP712_GATE_REQUEST_V3_TYPEHASH), FIXTURE.constants.eip712TypehashHex);
    assert.equal(EIP712_GATE_REQUEST_V3_TYPEHASH.length, 32);
  });
});

// ── currentEpoch ────────────────────────────────────────────────────────────

describe("currentEpoch", () => {
  it("returns a non-negative integer", () => {
    const e = currentEpoch();
    assert.equal(Number.isInteger(e), true);
    assert.ok(e >= 0);
  });

  it("equals floor(Date.now()/1000/EPOCH_LENGTH_SECONDS)", () => {
    // Stub Date.now then restore. Pinned millisecond timestamp converts to
    // a known epoch number under the documented formula.
    const stubMs = 1_750_000_000_000; // approx mid-2025 — well-defined epoch
    const expected = Math.floor(stubMs / 1000 / EPOCH_LENGTH_SECONDS);
    const original = Date.now;
    try {
      (Date.now as unknown as () => number) = () => stubMs;
      assert.equal(currentEpoch(), expected);
    } finally {
      (Date.now as unknown as () => number) = original;
    }
  });
});

// ── Derivation byte-identity vs fixture ─────────────────────────────────────

describe("computeDerivationInputV3 — fixture parity", () => {
  for (const vec of POSITIVE_VECTORS) {
    it(`vector ${vec.name}: 32-byte digest matches`, async () => {
      const out = await computeDerivationInputV3(
        vec.input.chain,
        vec.input.tokenAddress,
        vec.input.threshold,
        vec.input.epoch,
      );
      assert.equal(out.length, 32);
      assert.equal(toHex(out), vec.expected.derivationInputHex);
    });

    it(`vector ${vec.name}: preimage utf8 matches`, async () => {
      // Re-derive preimage independently to assert the pinned string. The
      // SDK does not export the preimage; we re-build it the same way and
      // assert against the fixture so any drift in either implementation
      // surfaces here.
      const preimage = `accessol_v3:${vec.input.chain}:${vec.input.tokenAddress}:${vec.input.threshold}:${vec.input.epoch}`;
      assert.equal(preimage, vec.expected.preimageUtf8);
    });
  }
});

describe("computeDerivationInputV3 — validation", () => {
  it("rejects unknown chain", async () => {
    await assert.rejects(
      () =>
        computeDerivationInputV3(
          // @ts-expect-error intentional invalid chain
          "Polygon",
          "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          1n,
          670n,
        ),
      /Invalid chain/,
    );
  });

  it("rejects bad token address", async () => {
    await assert.rejects(
      () => computeDerivationInputV3("EthMainnet", "0xnotanaddress", 1n, 670n),
      /tokenAddress/,
    );
  });

  it("rejects negative threshold", async () => {
    await assert.rejects(
      () =>
        computeDerivationInputV3(
          "EthMainnet",
          "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          -1,
          670,
        ),
      /threshold/,
    );
  });

  it("rejects negative epoch", async () => {
    await assert.rejects(
      () =>
        computeDerivationInputV3(
          "EthMainnet",
          "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          1,
          -1,
        ),
      /epoch/,
    );
  });

  it("accepts bigint inputs", async () => {
    const v = POSITIVE_VECTORS[0];
    const out = await computeDerivationInputV3(
      v.input.chain,
      v.input.tokenAddress,
      BigInt(v.input.threshold),
      BigInt(v.input.epoch),
    );
    assert.equal(toHex(out), v.expected.derivationInputHex);
  });
});

// ── buildGateMetadataV3 ─────────────────────────────────────────────────────

describe("buildGateMetadataV3", () => {
  const baseArgs = {
    cid: "QmTestV3",
    chain: "EthMainnet" as Chain,
    tokenAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    threshold: 1_000_000n,
    epoch: 670,
    encryptedAesKey: "dGVzdA==",
  };

  it("returns a v3 record with version=3 integer", () => {
    const m = buildGateMetadataV3(baseArgs);
    assert.equal(m.version, 3);
    assert.equal(typeof m.version, "number");
  });

  it("serialises threshold as decimal string", () => {
    const m = buildGateMetadataV3(baseArgs);
    assert.equal(m.threshold, "1000000");
    assert.equal(typeof m.threshold, "string");
  });

  it("serialises epoch as integer number", () => {
    const m = buildGateMetadataV3(baseArgs);
    assert.equal(m.epoch, 670);
    assert.equal(typeof m.epoch, "number");
  });

  it("threshold=0, epoch=0 is accepted", () => {
    const m = buildGateMetadataV3({ ...baseArgs, threshold: 0n, epoch: 0 });
    assert.equal(m.threshold, "0");
    assert.equal(m.epoch, 0);
  });

  it("threshold=0, epoch!=0 throws (canister would collapse)", () => {
    assert.throws(
      () => buildGateMetadataV3({ ...baseArgs, threshold: 0n, epoch: 670 }),
      /threshold==0 requires epoch==0/,
    );
  });

  it("rejects invalid chain", () => {
    assert.throws(
      // @ts-expect-error intentional
      () => buildGateMetadataV3({ ...baseArgs, chain: "Polygon" }),
      /Invalid chain/,
    );
  });

  it("rejects empty cid", () => {
    assert.throws(() => buildGateMetadataV3({ ...baseArgs, cid: "" }), /cid/);
  });

  it("rejects empty encryptedAesKey", () => {
    assert.throws(
      () => buildGateMetadataV3({ ...baseArgs, encryptedAesKey: "" }),
      /encryptedAesKey/,
    );
  });
});

// ── gateMetadataV3ToJson ────────────────────────────────────────────────────

describe("gateMetadataV3ToJson", () => {
  const meta = buildGateMetadataV3({
    cid: "QmTestV3",
    chain: "EthMainnet",
    tokenAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    threshold: 1_000_000n,
    epoch: 670,
    encryptedAesKey: "dGVzdA==",
  });

  it("emits canonical field order (version,cid,chain,tokenAddress,threshold,epoch,encryptedAesKey)", () => {
    const s = gateMetadataV3ToJson(meta);
    // Find the index of each key in the serialised string; verify ascending.
    const keys = ["\"version\"", "\"cid\"", "\"chain\"", "\"tokenAddress\"", "\"threshold\"", "\"epoch\"", "\"encryptedAesKey\""];
    let last = -1;
    for (const k of keys) {
      const idx = s.indexOf(k);
      assert.ok(idx > last, `key ${k} should appear after the previous one; got idx=${idx} last=${last} in ${s}`);
      last = idx;
    }
  });

  it("produces compact JSON (no whitespace between tokens)", () => {
    const s = gateMetadataV3ToJson(meta);
    assert.equal(s.includes(": "), false);
    assert.equal(s.includes(", "), false);
  });

  it("round-trips through parseGateMetadataV3", () => {
    const s = gateMetadataV3ToJson(meta);
    const parsed = parseGateMetadataV3(s);
    assert.deepEqual(parsed, meta);
  });

  it("throws on non-v3 input", () => {
    // @ts-expect-error intentional
    assert.throws(() => gateMetadataV3ToJson({ ...meta, version: 1 }), /version=3/);
  });
});

// ── parseGateMetadataV3 (strict) ────────────────────────────────────────────

describe("parseGateMetadataV3", () => {
  const validRec: GateMetadataV3Json = {
    version: 3,
    cid: "QmTest",
    chain: "EthMainnet",
    tokenAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    threshold: "1",
    epoch: 670,
    encryptedAesKey: "dGVzdA==",
  };

  it("accepts an object", () => {
    assert.deepEqual(parseGateMetadataV3({ ...validRec }), validRec);
  });

  it("accepts a JSON string", () => {
    assert.deepEqual(parseGateMetadataV3(JSON.stringify(validRec)), validRec);
  });

  it("accepts a UTF-8 Uint8Array", () => {
    const bytes = new TextEncoder().encode(JSON.stringify(validRec));
    assert.deepEqual(parseGateMetadataV3(bytes), validRec);
  });

  it("rejects v1 record (returns null)", () => {
    assert.equal(parseGateMetadataV3({ ...validRec, version: 1 }), null);
  });

  it("rejects version=\"3\" string", () => {
    assert.equal(parseGateMetadataV3({ ...validRec, version: "3" }), null);
  });

  it("rejects unknown chain", () => {
    assert.equal(parseGateMetadataV3({ ...validRec, chain: "Polygon" }), null);
  });

  it("rejects bad token address", () => {
    assert.equal(parseGateMetadataV3({ ...validRec, tokenAddress: "0xZZZ" }), null);
  });

  it("rejects threshold as int", () => {
    assert.equal(parseGateMetadataV3({ ...validRec, threshold: 1 }), null);
  });

  it("rejects threshold with leading zero", () => {
    assert.equal(parseGateMetadataV3({ ...validRec, threshold: "007" }), null);
  });

  it("rejects negative epoch", () => {
    assert.equal(parseGateMetadataV3({ ...validRec, epoch: -1 }), null);
  });

  it("rejects non-integer epoch", () => {
    assert.equal(parseGateMetadataV3({ ...validRec, epoch: 1.5 }), null);
  });

  it("rejects threshold=0 with nonzero epoch (§v3.4 invariant)", () => {
    assert.equal(parseGateMetadataV3({ ...validRec, threshold: "0", epoch: 670 }), null);
  });

  it("accepts threshold=0 with epoch=0", () => {
    const rec = { ...validRec, threshold: "0", epoch: 0 };
    assert.deepEqual(parseGateMetadataV3(rec), rec);
  });

  it("rejects garbage", () => {
    assert.equal(parseGateMetadataV3("not json"), null);
    assert.equal(parseGateMetadataV3(42), null);
    assert.equal(parseGateMetadataV3(null), null);
  });
});

// ── isGateMetadataV3 ────────────────────────────────────────────────────────

describe("isGateMetadataV3", () => {
  const valid: GateMetadataV3Json = {
    version: 3,
    cid: "Qm",
    chain: "EthMainnet",
    tokenAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    threshold: "1",
    epoch: 0,
    encryptedAesKey: "dGVzdA==",
  };

  it("accepts valid", () => assert.equal(isGateMetadataV3(valid), true));
  it("rejects v1", () => assert.equal(isGateMetadataV3({ ...valid, version: 1 }), false));
  it("rejects null", () => assert.equal(isGateMetadataV3(null), false));
  it("rejects bool epoch", () => assert.equal(isGateMetadataV3({ ...valid, epoch: true }), false));
});

// ── Dispatcher: parseGateMetadataAny ────────────────────────────────────────

describe("parseGateMetadataAny", () => {
  const v1Rec = {
    version: 1,
    cid: "QmV1Test",
    chain: "EthMainnet" as Chain,
    tokenAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    threshold: "1000000",
    encryptedAesKey: "dGVzdA==",
  };

  it("returns v1 record unchanged (bigint threshold)", () => {
    const out = parseGateMetadataAny(JSON.stringify(v1Rec));
    assert.notEqual(out, null);
    if (out === null) return;
    assert.equal(out.version, 1);
    if (out.version !== 1) return;
    assert.equal(out.threshold, 1_000_000n);
    assert.equal(out.cid, "QmV1Test");
  });

  it("returns v3 record narrowly typed", () => {
    const v3Rec: GateMetadataV3Json = {
      version: 3,
      cid: "QmV3Test",
      chain: "EthMainnet",
      tokenAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      threshold: "1",
      epoch: 670,
      encryptedAesKey: "dGVzdA==",
    };
    const out = parseGateMetadataAny(JSON.stringify(v3Rec));
    assert.notEqual(out, null);
    if (out === null) return;
    assert.equal(out.version, 3);
    // Narrow via the v3 type guard (the dispatcher's union return type uses
    // `number` for v1 version, so a literal compare on `out.version !== 3`
    // does not narrow). `isGateMetadataV3` is the canonical narrowing tool.
    if (!isGateMetadataV3(out)) {
      assert.fail("dispatcher returned non-v3 record for v3 input");
    }
    assert.equal(out.threshold, "1");
    assert.equal(out.epoch, 670);
  });

  it("returns null for unknown version", () => {
    assert.equal(parseGateMetadataAny(JSON.stringify({ ...v1Rec, version: 2 })), null);
  });

  it("returns null for garbage", () => {
    assert.equal(parseGateMetadataAny("not json"), null);
    assert.equal(parseGateMetadataAny({ random: true }), null);
  });
});

// ── EIP-712 typed data ──────────────────────────────────────────────────────

describe("buildGateRequestV3TypedData", () => {
  const validArgs = {
    evmAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    transportPublicKey: new Uint8Array([1, 2, 3, 4]),
    epoch: 670n,
    nonce: 42n,
    eip712ChainId: 1n,
    eip712VerifyingContract: "0x1111111111111111111111111111111111111111",
  };

  it("primaryType is GateRequestV3", () => {
    const td = buildGateRequestV3TypedData(validArgs);
    assert.equal(td.primaryType, "GateRequestV3");
  });

  it("field order matches EIP-712 type string (evmAddress,transportPublicKey,epoch,nonce)", () => {
    const td = buildGateRequestV3TypedData(validArgs);
    const fieldNames = td.types.GateRequestV3.map((f) => f.name);
    assert.deepEqual(fieldNames, ["evmAddress", "transportPublicKey", "epoch", "nonce"]);
  });

  it("field types match (address,bytes,uint256,uint256)", () => {
    const td = buildGateRequestV3TypedData(validArgs);
    const fieldTypes = td.types.GateRequestV3.map((f) => f.type);
    assert.deepEqual(fieldTypes, ["address", "bytes", "uint256", "uint256"]);
  });

  it("domain has no version field (matches canister)", () => {
    const td = buildGateRequestV3TypedData(validArgs);
    const domainFields = td.types.EIP712Domain.map((f) => f.name);
    assert.deepEqual(domainFields, ["name", "chainId", "verifyingContract"]);
    assert.equal("version" in td.domain, false);
  });

  it("domain.name === 'HavenAOL'", () => {
    const td = buildGateRequestV3TypedData(validArgs);
    assert.equal(td.domain.name, "HavenAOL");
  });

  it("transportPublicKey is 0x-prefixed hex", () => {
    const td = buildGateRequestV3TypedData(validArgs);
    assert.equal(td.message.transportPublicKey, "0x01020304");
  });

  it("rejects empty transport key", () => {
    assert.throws(
      () => buildGateRequestV3TypedData({ ...validArgs, transportPublicKey: new Uint8Array(0) }),
      /transportPublicKey/,
    );
  });

  it("rejects bad evmAddress", () => {
    assert.throws(
      () => buildGateRequestV3TypedData({ ...validArgs, evmAddress: "0xnope" }),
      /evmAddress/,
    );
  });

  it("rejects bad verifyingContract", () => {
    assert.throws(
      () =>
        buildGateRequestV3TypedData({
          ...validArgs,
          eip712VerifyingContract: "0xnope",
        }),
      /eip712VerifyingContract/,
    );
  });

  it("rejects negative epoch (number input)", () => {
    assert.throws(
      () => buildGateRequestV3TypedData({ ...validArgs, epoch: -1 }),
      /epoch/,
    );
  });
});
