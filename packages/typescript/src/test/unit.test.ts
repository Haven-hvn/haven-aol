import { describe, it } from "node:test";
import * as assert from "node:assert/strict";
import { computeDerivationInput } from "../derivation.js";
import { parseGateMetadata } from "../metadata.js";
import { decryptFile } from "../crypto.js";
import { HavenAolError } from "../decrypt.js";
import { buildGateRequestTypedData, parseSignatureHex } from "../eip712.js";

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// ── HavenAolError ──

describe("HavenAolError", () => {
  it("wraps gate error payload", () => {
    const payload = { InvalidThreshold: null };
    const err = new HavenAolError(payload);
    assert.equal(err.name, "HavenAolError");
    assert.ok(err.message.includes("Haven-AOL gate error"));
    assert.deepEqual(err.gateError, payload);
  });
});

// ── Derivation hash test vectors from docs/derivation-spec.md ──

describe("computeDerivationInput", () => {
  it("test vector 1 — EthMainnet USDC", async () => {
    const result = await computeDerivationInput(
      "EthMainnet",
      "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      BigInt("1000000"),
      "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco",
    );
    assert.equal(
      toHex(result),
      "e16d8738a6ea707f75e887fd3fce3e96d2fe061d075c5fe2821e94b2c9ad3b17",
    );
  });

  it("test vector 2 — ArbitrumOne USDC.e", async () => {
    const result = await computeDerivationInput(
      "ArbitrumOne",
      "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8",
      BigInt("500000000000000000"),
      "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi",
    );
    assert.equal(
      toHex(result),
      "04308f0e299c1647072257d0965e1f982fba21030538ee89323f82cab1c995d3",
    );
  });

  it("test vector 3 — EthSepolia threshold=0", async () => {
    const result = await computeDerivationInput(
      "EthSepolia",
      "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
      BigInt("0"),
      "QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn",
    );
    assert.equal(
      toHex(result),
      "6ea156594a7f7400610f328f4b5daf61d3036100d7bab69d33eb2a53575936d7",
    );
  });
});

// ── parseGateMetadata ──

describe("parseGateMetadata", () => {
  const validObj = {
    version: 1,
    cid: "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco",
    chain: "EthMainnet",
    tokenAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    threshold: "1000000",
    encryptedAesKey: "dGVzdA==",
  };
  const validJson = JSON.stringify(validObj);

  it("parses valid metadata", () => {
    const m = parseGateMetadata(validJson);
    assert.equal(m.version, 1);
    assert.equal(m.chain, "EthMainnet");
    assert.equal(m.threshold, BigInt("1000000"));
    assert.equal(m.cid, "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco");
  });

  it("rejects invalid version", () => {
    assert.throws(
      () => parseGateMetadata(JSON.stringify({ ...validObj, version: 2 })),
      /version/,
    );
  });

  it("rejects invalid chain", () => {
    assert.throws(
      () => parseGateMetadata(JSON.stringify({ ...validObj, chain: "Polygon" })),
      /chain/i,
    );
  });

  it("rejects invalid tokenAddress", () => {
    assert.throws(
      () => parseGateMetadata(JSON.stringify({ ...validObj, tokenAddress: "0xZZZ" })),
      /tokenAddress/i,
    );
  });

  it("rejects threshold with leading zeros", () => {
    assert.throws(
      () => parseGateMetadata(JSON.stringify({ ...validObj, threshold: "007" })),
      /threshold/i,
    );
  });

  it("rejects empty cid", () => {
    assert.throws(
      () => parseGateMetadata(JSON.stringify({ ...validObj, cid: "" })),
      /cid/i,
    );
  });
});

// ── AES-256-GCM decryptFile ──

describe("decryptFile", () => {
  it("decrypts AES-256-GCM [IV][ciphertext+tag] format", async () => {
    const plaintext = new TextEncoder().encode("hello haven-aol");
    const rawKey = crypto.getRandomValues(new Uint8Array(32));
    const iv = crypto.getRandomValues(new Uint8Array(12));

    const key = await crypto.subtle.importKey("raw", rawKey, { name: "AES-GCM" }, false, [
      "encrypt",
    ]);
    const ciphertext = new Uint8Array(
      await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, plaintext),
    );

    // Assemble [IV][ciphertext+tag]
    const encrypted = new Uint8Array(12 + ciphertext.length);
    encrypted.set(iv, 0);
    encrypted.set(ciphertext, 12);

    const result = await decryptFile(encrypted, rawKey);
    assert.deepEqual(result, plaintext);
  });

  it("rejects data shorter than IV", async () => {
    await assert.rejects(
      () => decryptFile(new Uint8Array(5), new Uint8Array(32)),
      /too short/,
    );
  });
});

// ── EIP-712 helpers ──

describe("eip712 helpers", () => {
  it("builds GateRequest typed data payload", () => {
    const typedData = buildGateRequestTypedData({
      evmAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      transportPublicKey: new Uint8Array([1, 2, 3]),
      nonce: 42n,
      eip712ChainId: 1n,
      eip712VerifyingContract: "0x1111111111111111111111111111111111111111",
    });
    assert.equal(typedData.domain.name, "HavenAOL");
    assert.equal(typedData.primaryType, "GateRequest");
    assert.equal(typedData.message.transportPublicKey, "0x010203");
    assert.equal(typedData.message.nonce, 42n);
  });

  it("parses 65-byte hex signature", () => {
    const sig = `0x${"11".repeat(64)}1b`;
    const out = parseSignatureHex(sig);
    assert.equal(out.length, 65);
    assert.equal(out[0], 0x11);
    assert.equal(out[64], 0x1b);
  });

  it("rejects invalid signature length", () => {
    assert.throws(() => parseSignatureHex("0x1234"), /65-byte/);
  });
});
