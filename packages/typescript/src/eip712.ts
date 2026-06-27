import { GateRequestTypedData, BatchGateRequestTypedData } from "./types.js";

function toHex(bytes: Uint8Array): `0x${string}` {
  return `0x${Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")}`;
}

export function parseSignatureHex(signatureHex: string): Uint8Array {
  const normalized = signatureHex.startsWith("0x") ? signatureHex.slice(2) : signatureHex;
  if (!/^[0-9a-fA-F]{130}$/.test(normalized)) {
    throw new Error("signature must be a 65-byte hex string");
  }
  const out = new Uint8Array(65);
  for (let i = 0; i < 65; i += 1) {
    out[i] = Number.parseInt(normalized.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

export function buildGateRequestTypedData(args: {
  evmAddress: string;
  transportPublicKey: Uint8Array;
  nonce: bigint;
  eip712ChainId: bigint;
  eip712VerifyingContract: string;
}): GateRequestTypedData {
  return {
    domain: {
      name: "HavenAOL",
      chainId: args.eip712ChainId,
      verifyingContract: args.eip712VerifyingContract,
    },
    primaryType: "GateRequest",
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "verifyingContract", type: "address" },
      ],
      GateRequest: [
        { name: "evmAddress", type: "address" },
        { name: "transportPublicKey", type: "bytes" },
        { name: "nonce", type: "uint256" },
      ],
    },
    message: {
      evmAddress: args.evmAddress,
      transportPublicKey: toHex(args.transportPublicKey),
      nonce: args.nonce,
    },
  };
}

export function buildBatchGateRequestTypedData(args: {
  evmAddress: string;
  transportKeyHash: Uint8Array; // keccak256(transportPublicKey) — 32 bytes
  cidsCommitment: Uint8Array; // keccak256(concat of derivation inputs) — 32 bytes
  nonce: bigint;
  eip712ChainId: bigint;
  eip712VerifyingContract: string;
}): BatchGateRequestTypedData {
  return {
    domain: {
      name: "HavenAOL",
      chainId: args.eip712ChainId,
      verifyingContract: args.eip712VerifyingContract,
    },
    primaryType: "BatchGateRequest",
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "verifyingContract", type: "address" },
      ],
      BatchGateRequest: [
        { name: "evmAddress", type: "address" },
        { name: "transportKeyHash", type: "bytes32" },
        { name: "cidsCommitment", type: "bytes32" },
        { name: "nonce", type: "uint256" },
      ],
    },
    message: {
      evmAddress: args.evmAddress,
      transportKeyHash: toHex(args.transportKeyHash),
      cidsCommitment: toHex(args.cidsCommitment),
      nonce: args.nonce,
    },
  };
}
