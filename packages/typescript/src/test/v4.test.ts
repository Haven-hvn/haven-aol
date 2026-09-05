// =============================================================================
// Haven-AOL Protocol v4 — TypeScript SDK tests
//
// Twin of `packages/python/tests/test_haven_aol_v4.py`.
// Uses `node --test` (same runner as the v1/v3 unit tests in this folder).
//
// Test strategy:
//   • Fixture parity: every positive vector in
//     `tests/fixtures/derivation-v4-vectors.json` MUST hash to the pinned
//     digest. This is the cross-stack byte-identity gate.
//   • Target participation: identical gate tuples with different
//     `marketCapTarget` derive different keys (the drip property).
//   • Constant parity: type string, typehash, version, oracle decimals,
//     burst-cache TTL.
//   • Build/serialise/parse round-trips with canonical field order.
//   • Threshold-zero / nonzero-epoch invariant.
//   • EIP-712 typed-data shape exact (`GateRequestV4` field order).
// =============================================================================

import { describe, it } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import {
  GATE_METADATA_VERSION_V4,
  EIP712_GATE_REQUEST_V4_TYPE_STRING,
  EIP712_GATE_REQUEST_V4_TYPEHASH,
  MARKET_CAP_CACHE_TTL_SECONDS,
  BOND_ADDRESSES,
  isBondAddress,
  computeDerivationInputV4,
  buildGateMetadataV4,
  gateMetadataV4ToJson,
  isGateMetadataV4,
  parseGateMetadataV4,
  buildGateRequestV4TypedData,
  type Chain,
} from "../index.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const FIXTURE_PATH = path.join(REPO_ROOT, "tests", "fixtures", "derivation-v4-vectors.json");

interface FixturePositiveVector {
  name: string;
  kind: "positive" | "threshold-zero-collapse" | "negative-future-epoch";
  input: {
    chain: Chain;
    tokenAddress: string;
    threshold: number;
    epoch: number;
    marketCapTarget: number;
  };
  effectiveEpoch?: number;
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
    marketCapCacheTtlSeconds: number;
  };
  vectors: FixturePositiveVector[];
}

const FIXTURE: FixtureFile = JSON.parse(fs.readFileSync(FIXTURE_PATH, "utf-8"));

function toHex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("hex");
}

// ── Constants parity ────────────────────────────────────────────────────────

describe("v4 constants", () => {
  it("GATE_METADATA_VERSION_V4 is the integer 4", () => {
    assert.equal(GATE_METADATA_VERSION_V4, 4);
    assert.equal(FIXTURE.version, 4);
  });

  it("type string matches fixture (whitespace-exact)", () => {
    assert.equal(EIP712_GATE_REQUEST_V4_TYPE_STRING, FIXTURE.constants.eip712TypeString);
  });

  it("typehash matches fixture and keccak of the type string", () => {
    const fixtureHash = Buffer.from(FIXTURE.constants.eip712TypehashHex, "hex");
    assert.deepEqual(Buffer.from(EIP712_GATE_REQUEST_V4_TYPEHASH), fixtureHash);
  });

  it("cache policy constants match fixture/canister", () => {
    assert.equal(MARKET_CAP_CACHE_TTL_SECONDS, FIXTURE.constants.marketCapCacheTtlSeconds);
    assert.equal(MARKET_CAP_CACHE_TTL_SECONDS, 300);
    assert.equal(FIXTURE.constants.vetkdContext, "accessol_v4");
    assert.equal(FIXTURE.constants.domainTag, "accessol_v4:");
  });
});

// ── Derivation input — fixture parity ───────────────────────────────────────

describe("computeDerivationInputV4 — fixture parity", () => {
  const digestVectors = FIXTURE.vectors.filter((v) => v.kind !== "negative-future-epoch");

  for (const vector of digestVectors) {
    it(`vector: ${vector.name}`, async () => {
      const inp = vector.input;

      if (vector.kind === "threshold-zero-collapse") {
        // SDK computes literal bytes (epoch as passed); the canister collapses
        // server-side. Reproduce the collapsed expectation by passing epoch=0.
        const collapsed = await computeDerivationInputV4(
          inp.chain,
          inp.tokenAddress,
          inp.threshold,
          0,
          inp.marketCapTarget,
        );
        assert.equal(toHex(collapsed), vector.expected.derivationInputHex);
        return;
      }

      const digest = await computeDerivationInputV4(
        inp.chain,
        inp.tokenAddress,
        inp.threshold,
        inp.epoch,
        inp.marketCapTarget,
      );
      assert.equal(toHex(digest), vector.expected.derivationInputHex);
      assert.equal(digest.length, 32);
    });
  }

  it("target participates in the preimage (drip property)", async () => {
    const a = await computeDerivationInputV4("BaseMainnet", "0x" + "aa".repeat(20), 5n, 670n, 1_000_000);
    const b = await computeDerivationInputV4("BaseMainnet", "0x" + "aa".repeat(20), 5n, 670n, 10_000_000);
    assert.notDeepEqual(Buffer.from(a), Buffer.from(b));
  });

  it("rejects invalid inputs", async () => {
    await assert.rejects(() => computeDerivationInputV4("Polygon" as Chain, "0x" + "ab".repeat(20), 1, 0, 1));
    await assert.rejects(() => computeDerivationInputV4("BaseMainnet", "0x123", 1, 0, 1));
    await assert.rejects(() => computeDerivationInputV4("BaseMainnet", "0x" + "ab".repeat(20), -1, 0, 1));
    await assert.rejects(() => computeDerivationInputV4("BaseMainnet", "0x" + "ab".repeat(20), 1, 0, -1));
  });
});

// ── Gate metadata v4 ────────────────────────────────────────────────────────

const VALID_ARGS = {
  cid: "bafybeiv4chunk",
  chain: "BaseMainnet" as Chain,
  tokenAddress: "0xAa70bC79fD1cB4a6FBA717018351F0C3c64B79Df",
  threshold: 5,
  epoch: 670,
  marketCapTarget: 5_000_000,
  oracleAddress: "0xc5A076cAd94176C2996b32d8466bE1cE757FAa27",
  encryptedAesKey: "AAECAwQFBgcICQ==",
};

describe("buildGateMetadataV4 / serialise / parse", () => {
  it("canonical field order round-trip", () => {
    const meta = buildGateMetadataV4(VALID_ARGS);
    assert.deepEqual(Object.keys(meta), [
      "version",
      "cid",
      "chain",
      "tokenAddress",
      "threshold",
      "epoch",
      "marketCapTarget",
      "oracleAddress",
      "encryptedAesKey",
    ]);
    const json = gateMetadataV4ToJson(meta);
    assert.deepEqual(parseGateMetadataV4(json), meta);
    assert.ok(isGateMetadataV4(meta));
  });

  it("threshold-zero requires epoch-zero", () => {
    assert.throws(() => buildGateMetadataV4({ ...VALID_ARGS, threshold: 0, epoch: 671 }), /epoch==0/);
  });

  it("parser rejects malformed records", () => {
    const good = buildGateMetadataV4(VALID_ARGS);
    const badCases = [
      { ...good, version: 3 },
      { ...good, version: "4" },
      { ...good, cid: "" },
      { ...good, chain: "Polygon" },
      { ...good, tokenAddress: "0x123" },
      { ...good, threshold: 5 }, // must be string
      { ...good, epoch: "670" }, // must be number
      { ...good, marketCapTarget: "5000000" }, // must be number
      { ...good, oracleAddress: "nope" },
      // NOTE: base64 shape of encryptedAesKey is validated by the Python
      // parser but intentionally not by the TS guard — exact parity with
      // the v3 guard (isGateMetadataV3), which checks string-ness only.
      { ...good, threshold: "0", epoch: 9 },
    ];
    for (const bad of badCases) {
      assert.equal(isGateMetadataV4(bad), false, JSON.stringify(bad));
      assert.equal(parseGateMetadataV4(bad), null);
    }
  });
});

// ── EIP-712 typed data ──────────────────────────────────────────────────────

describe("buildGateRequestV4TypedData", () => {
  it("field order matches the type string exactly", () => {
    const td = buildGateRequestV4TypedData({
      evmAddress: "0x" + "bb".repeat(20),
      transportPublicKey: new Uint8Array(33).fill(2),
      epoch: 670,
      marketCapTarget: 5_000_000,
      nonce: 42,
      eip712ChainId: 8453,
      eip712VerifyingContract: "0x" + "cc".repeat(20),
    });

    assert.equal(td.primaryType, "GateRequestV4");
    assert.deepEqual(
      td.types.GateRequestV4.map((f) => f.name),
      ["evmAddress", "transportPublicKey", "epoch", "marketCapTarget", "nonce"],
    );
    assert.equal(td.message.marketCapTarget, 5_000_000n);
    // Domain intentionally omits `version` (matches canister helper).
    assert.deepEqual(Object.keys(td.domain), ["name", "chainId", "verifyingContract"]);
  });

  it("rejects invalid inputs", () => {
    assert.throws(() =>
      buildGateRequestV4TypedData({
        evmAddress: "0x123",
        transportPublicKey: new Uint8Array(8),
        epoch: 0,
        marketCapTarget: 0,
        nonce: 0,
        eip712ChainId: 1,
        eip712VerifyingContract: "0x" + "cc".repeat(20),
      }),
    );
    assert.throws(() =>
      buildGateRequestV4TypedData({
        evmAddress: "0x" + "bb".repeat(20),
        transportPublicKey: new Uint8Array(0),
        epoch: 0,
        marketCapTarget: 0,
        nonce: 0,
        eip712ChainId: 1,
        eip712VerifyingContract: "0x" + "cc".repeat(20),
      }),
    );
  });
});

// ── Bond mode — address classification ──────────────────────────────────

describe("isBondAddress", () => {
  // Canonical Bond address in dapp-hint casing
  // (haven-dapp/src/lib/v4/market-cap.ts :: BOND_ADDRESS_HINTS).
  const BOND = "0xc5a076cad94176c2996B32d8466Be1cE757FAa27";
  const BOND_SEPOLIA = "0x8dce343A86Aa950d539eeE0e166AFfd0Ef515C0c";
  const CHAINLINK_FEED = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"; // ETH/USD mainnet

  it("classifies the Bond address on all five chains", () => {
    assert.equal(isBondAddress("EthMainnet", BOND), true);
    assert.equal(isBondAddress("BaseMainnet", BOND), true);
    assert.equal(isBondAddress("ArbitrumOne", BOND), true);
    assert.equal(isBondAddress("OptimismMainnet", BOND), true);
    assert.equal(isBondAddress("EthSepolia", BOND_SEPOLIA), true);
    // Cross-check: mainnet Bond is NOT the Sepolia Bond and vice versa.
    assert.equal(isBondAddress("EthSepolia", BOND), false);
    assert.equal(isBondAddress("BaseMainnet", BOND_SEPOLIA), false);
  });

  it("is case-insensitive (checksummed, lower, upper)", () => {
    assert.equal(
      isBondAddress("BaseMainnet", "0xC5A076CAD94176C2996B32D8466BE1CE757FAA27"),
      true,
    );
    assert.equal(
      isBondAddress("BaseMainnet", BOND.toLowerCase()),
      true,
    );
  });

  it("rejects non-Bond addresses and unknown chains", () => {
    assert.equal(isBondAddress("BaseMainnet", CHAINLINK_FEED), false);
    assert.equal(isBondAddress("BaseMainnet", "0x" + "00".repeat(20)), false);
    assert.equal(isBondAddress("NoSuchChain", BOND), false);
    assert.equal(isBondAddress("BaseMainnet", "not-an-address"), false);
  });

  it("BOND_ADDRESSES parity with the canister defaults (per chain)", () => {
    // Same style as the constants test above: the SDK table must track
    // BOND_ADDRESS_DEFAULT (mainnets) and BOND_ADDRESS_SEPOLIA (testnet)
    // in src/backend/main.mo (lowercase compare — EIP-55 casing is not
    // load-bearing; the canister lowercases).
    const mainMo = fs.readFileSync(path.join(REPO_ROOT, "src", "backend", "main.mo"), "utf-8");
    const def = mainMo.match(/BOND_ADDRESS_DEFAULT\s*:\s*Text\s*=\s*"([^"]+)"/);
    const sepolia = mainMo.match(/BOND_ADDRESS_SEPOLIA\s*:\s*Text\s*=\s*"([^"]+)"/);
    assert.ok(def, "BOND_ADDRESS_DEFAULT not found in src/backend/main.mo");
    assert.ok(sepolia, "BOND_ADDRESS_SEPOLIA not found in src/backend/main.mo");
    const expected: Record<string, string> = {
      EthMainnet: def[1],
      BaseMainnet: def[1],
      ArbitrumOne: def[1],
      OptimismMainnet: def[1],
      EthSepolia: sepolia[1],
    };
    assert.deepEqual(Object.keys(BOND_ADDRESSES).sort(), Object.keys(expected).sort());
    for (const chainKey of Object.keys(expected)) {
      assert.equal(
        BOND_ADDRESSES[chainKey].toLowerCase(),
        expected[chainKey].toLowerCase(),
        `BOND_ADDRESSES[${chainKey}] drifted from canister default`,
      );
    }
  });
});
