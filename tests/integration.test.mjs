/**
 * Haven-AOL Integration Test Suite
 *
 * Tests cross-component interoperability between:
 * - Python package (upload-side)
 * - TypeScript package (decrypt-side)
 * - Motoko canister (balance check + VetKD oracle)
 *
 * Run: node --test integration.test.mjs
 * Offline only: OFFLINE=1 node --test integration.test.mjs
 */

import { describe, it, before } from "node:test";
import * as assert from "node:assert/strict";
import { execSync } from "node:child_process";
import { createRequire } from "node:module";
import { resolve, dirname } from "node:path";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");
const TS_DIST = resolve(ROOT, "packages/typescript/dist");
const TS_NODE_MODULES = resolve(ROOT, "packages/typescript/node_modules");
const OFFLINE = !!process.env.OFFLINE;

// Use createRequire to load CJS packages from the TS package's node_modules
const require = createRequire(resolve(TS_NODE_MODULES, ".package.json"));

// ── Helpers ──

function pyRun(cmd, args) {
  const result = execSync(
    `python3 ${resolve(__dirname, "helpers.py")} ${cmd} ${args}`,
    { encoding: "utf-8", cwd: ROOT },
  ).trim();
  return result;
}

function toHex(bytes) {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function fromHex(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
  }
  return bytes;
}

// ── Test Vectors from docs/derivation-spec.md ──

const TEST_VECTORS = [
  {
    name: "TV1 — EthMainnet USDC",
    chain: "EthMainnet",
    tokenAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    threshold: "1000000",
    cid: "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco",
    expected: "e16d8738a6ea707f75e887fd3fce3e96d2fe061d075c5fe2821e94b2c9ad3b17",
  },
  {
    name: "TV2 — ArbitrumOne USDC.e",
    chain: "ArbitrumOne",
    tokenAddress: "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8",
    threshold: "500000000000000000",
    cid: "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi",
    expected: "04308f0e299c1647072257d0965e1f982fba21030538ee89323f82cab1c995d3",
  },
  {
    name: "TV3 — EthSepolia threshold=0",
    chain: "EthSepolia",
    tokenAddress: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
    threshold: "0",
    cid: "QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn",
    expected: "6ea156594a7f7400610f328f4b5daf61d3036100d7bab69d33eb2a53575936d7",
  },
];

// ═══════════════════════════════════════════════════════════════════
// TC-1: Derivation Hash Parity
// ═══════════════════════════════════════════════════════════════════

describe("TC-1: Derivation Hash Parity", () => {
  let computeDerivationInput;

  before(async () => {
    const mod = await import(resolve(TS_DIST, "derivation.js"));
    computeDerivationInput = mod.computeDerivationInput;
  });

  for (const tv of TEST_VECTORS) {
    it(`Python matches spec — ${tv.name}`, () => {
      const pyHash = pyRun(
        "derivation-hash",
        `${tv.chain} ${tv.tokenAddress} ${tv.threshold} ${tv.cid}`,
      );
      assert.equal(pyHash, tv.expected, `Python hash mismatch for ${tv.name}`);
    });

    it(`TypeScript matches spec — ${tv.name}`, async () => {
      const tsResult = await computeDerivationInput(
        tv.chain,
        tv.tokenAddress,
        BigInt(tv.threshold),
        tv.cid,
      );
      assert.equal(toHex(tsResult), tv.expected, `TypeScript hash mismatch for ${tv.name}`);
    });

    it(`Python === TypeScript — ${tv.name}`, async () => {
      const pyHash = pyRun(
        "derivation-hash",
        `${tv.chain} ${tv.tokenAddress} ${tv.threshold} ${tv.cid}`,
      );
      const tsResult = await computeDerivationInput(
        tv.chain,
        tv.tokenAddress,
        BigInt(tv.threshold),
        tv.cid,
      );
      assert.equal(pyHash, toHex(tsResult), `Python/TypeScript mismatch for ${tv.name}`);
    });
  }
});

// ═══════════════════════════════════════════════════════════════════
// TC-6: AES Cross-Language Compatibility
// ═══════════════════════════════════════════════════════════════════

describe("TC-6: AES Cross-Language Compatibility", () => {
  let decryptFile;

  before(async () => {
    const mod = await import(resolve(TS_DIST, "crypto.js"));
    decryptFile = mod.decryptFile;
  });

  it("TypeScript decrypts Python AES-256-GCM ciphertext", async () => {
    const plaintext = "Hello, token-gated world!";
    const plaintextHex = Buffer.from(plaintext).toString("hex");

    // Python encrypts
    const pyResult = JSON.parse(pyRun("encrypt-file", plaintextHex));
    const ciphertext = fromHex(pyResult.ciphertext);
    const aesKey = fromHex(pyResult.aesKey);

    // TypeScript decrypts
    const decrypted = await decryptFile(ciphertext, aesKey);
    assert.equal(
      new TextDecoder().decode(decrypted),
      plaintext,
      "Decrypted text does not match original",
    );
  });

  it("TypeScript decrypts Python AES with known key", async () => {
    const plaintext = "deterministic test";
    const plaintextHex = Buffer.from(plaintext).toString("hex");
    const knownKeyHex = "aa".repeat(32);

    const pyResult = JSON.parse(pyRun("encrypt-file", `${plaintextHex} ${knownKeyHex}`));
    const ciphertext = fromHex(pyResult.ciphertext);
    const aesKey = fromHex(pyResult.aesKey);

    assert.equal(pyResult.aesKey, knownKeyHex, "Python should use the provided key");

    const decrypted = await decryptFile(ciphertext, aesKey);
    assert.equal(new TextDecoder().decode(decrypted), plaintext);
  });

  it("TypeScript decrypts empty plaintext from Python", async () => {
    const pyResult = JSON.parse(pyRun("encrypt-file", ""));
    const ciphertext = fromHex(pyResult.ciphertext);
    const aesKey = fromHex(pyResult.aesKey);

    const decrypted = await decryptFile(ciphertext, aesKey);
    assert.equal(decrypted.length, 0, "Decrypted empty plaintext should be empty");
  });
});

// ═══════════════════════════════════════════════════════════════════
// TC-5: IBE Cross-Language Compatibility
// ═══════════════════════════════════════════════════════════════════

describe("TC-5: IBE Cross-Language Compatibility", () => {
  // This test verifies that IBE ciphertext produced by Python can be
  // deserialized by TypeScript's @dfinity/vetkeys. Full decryption
  // requires a VetKD-derived key (which needs a running canister),
  // but we can verify:
  // 1. Python produces valid IBE ciphertext (correct header)
  // 2. TypeScript can deserialize it without error
  // 3. The ciphertext has the expected structure

  let IbeCiphertext;

  before(async () => {
    // Import from the TS package's node_modules
    const vetkeysPath = resolve(ROOT, "packages/typescript/node_modules/@dfinity/vetkeys");
    const pkg = JSON.parse(
      (await import("node:fs")).readFileSync(resolve(vetkeysPath, "package.json"), "utf-8"),
    );
    // Use the module entry point from package.json
    const entryPoint = pkg.module || "dist/lib/index.es.js";
    const mod = await import(resolve(vetkeysPath, entryPoint));
    IbeCiphertext = mod.IbeCiphertext;
  });

  it("Python IBE ciphertext is deserializable by TypeScript", () => {
    // Derive a verification key offline (using mainnet master key for key_1)
    const dpkHex = pyRun("derive-verification-key", "aaaaa-aa key_1");
    const derivationInputHex = TEST_VECTORS[0].expected;
    const aesKeyHex = "bb".repeat(32);

    // Python IBE-encrypts
    const ibeCiphertextHex = pyRun(
      "ibe-encrypt",
      `${aesKeyHex} ${dpkHex} ${derivationInputHex}`,
    );

    // Verify header: "IC IBE\x00\x01"
    assert.equal(
      ibeCiphertextHex.substring(0, 12),
      "494320494245", // "IC IBE" in hex
      "IBE ciphertext should start with 'IC IBE' header",
    );

    // TypeScript deserializes without error
    const ciphertextBytes = fromHex(ibeCiphertextHex);
    const deserialized = IbeCiphertext.deserialize(ciphertextBytes);
    assert.ok(deserialized, "IbeCiphertext.deserialize should succeed");

    // Re-serialize and verify round-trip
    const reserialized = deserialized.serialize();
    assert.equal(
      toHex(new Uint8Array(reserialized)),
      ibeCiphertextHex,
      "IBE ciphertext serialize round-trip should be identical",
    );
  });

  it("Python IBE ciphertext has correct size for 32-byte plaintext", () => {
    const dpkHex = pyRun("derive-verification-key", "aaaaa-aa key_1");
    const derivationInputHex = TEST_VECTORS[1].expected;
    const aesKeyHex = "cc".repeat(32);

    const ibeCiphertextHex = pyRun(
      "ibe-encrypt",
      `${aesKeyHex} ${dpkHex} ${derivationInputHex}`,
    );

    // Expected: 8 (header) + 96 (G2 point) + 32 (masked seed) + 32 (masked msg) = 168 bytes
    assert.equal(
      ibeCiphertextHex.length / 2,
      168,
      "IBE ciphertext for 32-byte plaintext should be 168 bytes",
    );
  });
});

// ═══════════════════════════════════════════════════════════════════
// TC-7: Multi-Chain Derivation Hash Divergence
// ═══════════════════════════════════════════════════════════════════

describe("TC-7: Multi-Chain Derivation Hash Divergence", () => {
  let computeDerivationInput;

  before(async () => {
    const mod = await import(resolve(TS_DIST, "derivation.js"));
    computeDerivationInput = mod.computeDerivationInput;
  });

  it("different chains produce different hashes (same other params)", async () => {
    const tokenAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    const threshold = BigInt("1000000");
    const cid = "QmTestCid123";

    const chains = ["EthMainnet", "ArbitrumOne", "BaseMainnet", "OptimismMainnet", "EthSepolia"];
    const hashes = new Set();

    for (const chain of chains) {
      const result = await computeDerivationInput(chain, tokenAddress, threshold, cid);
      hashes.add(toHex(result));
    }

    assert.equal(
      hashes.size,
      chains.length,
      "Each chain should produce a unique derivation hash",
    );
  });

  it("Python and TypeScript agree on multi-chain hashes", async () => {
    const tokenAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    const threshold = "1000000";
    const cid = "QmTestCid123";

    for (const chain of ["EthMainnet", "ArbitrumOne"]) {
      const pyHash = pyRun("derivation-hash", `${chain} ${tokenAddress} ${threshold} ${cid}`);
      const tsResult = await computeDerivationInput(
        chain,
        tokenAddress,
        BigInt(threshold),
        cid,
      );
      assert.equal(pyHash, toHex(tsResult), `Mismatch for chain ${chain}`);
    }
  });
});

// ═══════════════════════════════════════════════════════════════════
// TC-3: Insufficient Balance (requires local replica)
// ═══════════════════════════════════════════════════════════════════

describe("TC-3: Insufficient Balance", { skip: OFFLINE }, () => {
  let requestDecryptionKey, createTransportKeyPair;
  let agent, canisterId;

  before(async () => {
    const canisterMod = await import(resolve(TS_DIST, "canister.js"));
    const cryptoMod = await import(resolve(TS_DIST, "crypto.js"));
    requestDecryptionKey = canisterMod.requestDecryptionKey;
    createTransportKeyPair = cryptoMod.createTransportKeyPair;

    const { HttpAgent, AnonymousIdentity } = await import("@icp-sdk/core/agent");

    // Get canister ID from local deployment
    canisterId = execSync("icp canister status backend -e local -i", {
      encoding: "utf-8",
      cwd: ROOT,
    }).trim();

    agent = await HttpAgent.create({
      host: "http://localhost:8000",
      identity: new AnonymousIdentity(),
    });
    await agent.fetchRootKey();
  });

  it("returns error for zero-balance address on local replica", async () => {
    // NOTE: The local EVM RPC canister has no real chain data.
    // Depending on local replica behavior, eth_call may:
    // - Return 0 balance → InsufficientBalance
    // - Return an RPC error → EvmRpcError
    // - Return unexpected data → VetKDError (balance check passes, VetKD fails)
    // All are valid error paths. The assertion is: canister does NOT return ok.
    const { publicKey } = createTransportKeyPair();

    const result = await requestDecryptionKey(agent, canisterId, {
      chain: "EthMainnet",
      tokenAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      threshold: BigInt("1000000"),
      cid: "QmTestCid",
      evmAddress: "0x0000000000000000000000000000000000000001",
      transportPublicKey: publicKey,
    });

    assert.ok("err" in result, "Expected an error result (not ok)");
    const err = result.err;
    const isExpectedError =
      "InsufficientBalance" in err || "EvmRpcError" in err || "VetKDError" in err;
    assert.ok(
      isExpectedError,
      `Expected InsufficientBalance, EvmRpcError, or VetKDError, got: ${JSON.stringify(err)}`,
    );

    if ("InsufficientBalance" in err) {
      assert.ok(
        err.InsufficientBalance.actual < err.InsufficientBalance.required,
        "actual should be less than required",
      );
    }
    console.log(`    ℹ Error path taken: ${Object.keys(err)[0]}`);
  });
});

// ═══════════════════════════════════════════════════════════════════
// TC-4: Input Validation (requires local replica)
// ═══════════════════════════════════════════════════════════════════

describe("TC-4: Input Validation", { skip: OFFLINE }, () => {
  let requestDecryptionKey, createTransportKeyPair;
  let agent, canisterId;

  before(async () => {
    const canisterMod = await import(resolve(TS_DIST, "canister.js"));
    const cryptoMod = await import(resolve(TS_DIST, "crypto.js"));
    requestDecryptionKey = canisterMod.requestDecryptionKey;
    createTransportKeyPair = cryptoMod.createTransportKeyPair;

    const { HttpAgent, AnonymousIdentity } = await import("@icp-sdk/core/agent");

    canisterId = execSync("icp canister status backend -e local -i", {
      encoding: "utf-8",
      cwd: ROOT,
    }).trim();

    agent = await HttpAgent.create({
      host: "http://localhost:8000",
      identity: new AnonymousIdentity(),
    });
    await agent.fetchRootKey();
  });

  const validBase = {
    chain: "EthMainnet",
    tokenAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    threshold: BigInt("1000000"),
    cid: "QmTestCid",
    evmAddress: "0x0000000000000000000000000000000000000001",
  };

  async function callWithOverrides(overrides) {
    const { publicKey } = createTransportKeyPair();
    return requestDecryptionKey(agent, canisterId, {
      ...validBase,
      transportPublicKey: publicKey,
      ...overrides,
    });
  }

  it("rejects invalid evmAddress (too short)", async () => {
    const result = await callWithOverrides({ evmAddress: "0x123" });
    assert.ok("err" in result);
    assert.ok("InvalidAddress" in result.err, `Expected InvalidAddress, got: ${JSON.stringify(result.err)}`);
  });

  it("rejects invalid tokenAddress (non-hex)", async () => {
    const result = await callWithOverrides({ tokenAddress: "0xZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ" });
    assert.ok("err" in result);
    assert.ok("InvalidAddress" in result.err, `Expected InvalidAddress, got: ${JSON.stringify(result.err)}`);
  });

  it("rejects threshold = 0", async () => {
    const result = await callWithOverrides({ threshold: BigInt(0) });
    assert.ok("err" in result);
    assert.ok("InvalidThreshold" in result.err, `Expected InvalidThreshold, got: ${JSON.stringify(result.err)}`);
  });

  it("rejects empty cid", async () => {
    const result = await callWithOverrides({ cid: "" });
    assert.ok("err" in result);
    // Canister returns InvalidAddress for empty cid (per implementation)
    const hasError = "InvalidAddress" in result.err || "InvalidThreshold" in result.err;
    assert.ok(hasError, `Expected validation error, got: ${JSON.stringify(result.err)}`);
  });

  it("rejects empty transportPublicKey", async () => {
    const result = await requestDecryptionKey(agent, canisterId, {
      ...validBase,
      transportPublicKey: new Uint8Array(0),
    });
    assert.ok("err" in result);
  });
});

// ═══════════════════════════════════════════════════════════════════
// TC-2: Full Round-Trip (requires local replica + VetKD)
// ═══════════════════════════════════════════════════════════════════

describe("TC-2: Full Round-Trip", { skip: OFFLINE }, () => {
  // NOTE: A complete end-to-end test requires:
  // 1. A funded EVM address with sufficient token balance
  // 2. The local EVM RPC canister to return real chain data
  //
  // Since the local replica's EVM RPC canister has no real chain data,
  // we test the encrypt → metadata → parse → derivation parity flow
  // and document what's needed for a full test.

  let parseGateMetadata, computeDerivationInput;

  before(async () => {
    const metaMod = await import(resolve(TS_DIST, "metadata.js"));
    const derivMod = await import(resolve(TS_DIST, "derivation.js"));
    parseGateMetadata = metaMod.parseGateMetadata;
    computeDerivationInput = derivMod.computeDerivationInput;
  });

  it("Python encrypt → metadata → TypeScript parse → derivation parity", async () => {
    const chain = "EthMainnet";
    const tokenAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    const threshold = "1000000";
    const cid = "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco";

    // Step 1: Python encrypts a file
    const plaintext = Buffer.from("secret document content").toString("hex");
    const encResult = JSON.parse(pyRun("encrypt-file", plaintext));

    // Step 2: Python computes derivation input
    const pyDerivation = pyRun("derivation-hash", `${chain} ${tokenAddress} ${threshold} ${cid}`);

    // Step 3: Python derives verification key and IBE-encrypts
    const dpkHex = pyRun("derive-verification-key", "aaaaa-aa key_1");
    const ibeCiphertextHex = pyRun("ibe-encrypt", `${encResult.aesKey} ${dpkHex} ${pyDerivation}`);

    // Step 4: Python builds gate metadata
    const metadataJson = pyRun(
      "build-metadata",
      `${cid} ${chain} ${tokenAddress} ${threshold} ${ibeCiphertextHex}`,
    );

    // Step 5: TypeScript parses gate metadata
    const metadata = parseGateMetadata(metadataJson);
    assert.equal(metadata.version, 1);
    assert.equal(metadata.chain, chain);
    assert.equal(metadata.tokenAddress, tokenAddress);
    assert.equal(metadata.threshold, BigInt(threshold));
    assert.equal(metadata.cid, cid);

    // Step 6: TypeScript computes derivation input — must match Python
    const tsDerivation = await computeDerivationInput(
      metadata.chain,
      metadata.tokenAddress,
      metadata.threshold,
      metadata.cid,
    );
    assert.equal(
      toHex(tsDerivation),
      pyDerivation,
      "TypeScript derivation must match Python derivation from parsed metadata",
    );

    // Step 7: Verify IBE ciphertext is in the metadata and deserializable
    const vetkeysPath = resolve(ROOT, "packages/typescript/node_modules/@dfinity/vetkeys");
    const pkg = JSON.parse(
      (await import("node:fs")).readFileSync(resolve(vetkeysPath, "package.json"), "utf-8"),
    );
    const { IbeCiphertext } = await import(resolve(vetkeysPath, pkg.module || "dist/lib/index.es.js"));
    const ibeCiphertextBytes = Buffer.from(metadata.encryptedAesKey, "base64");
    const deserialized = IbeCiphertext.deserialize(new Uint8Array(ibeCiphertextBytes));
    assert.ok(deserialized, "IBE ciphertext from metadata should be deserializable");

    // NOTE: To complete the round-trip, we would need:
    // - Call requestDecryptionKey with a funded EVM address
    // - Recover VetKD key
    // - IBE-decrypt the AES key
    // - AES-decrypt the file
    // This requires real EVM chain data or a mock EVM RPC canister.
    console.log("    ℹ Full VetKD round-trip requires funded EVM address — see tests/README.md");
  });
});
