/** Supported EVM chains — must match Candid Chain variant names exactly. */
export type Chain =
  | "EthMainnet"
  | "EthSepolia"
  | "ArbitrumOne"
  | "BaseMainnet"
  | "OptimismMainnet";

export const VALID_CHAINS: readonly Chain[] = [
  "EthMainnet",
  "EthSepolia",
  "ArbitrumOne",
  "BaseMainnet",
  "OptimismMainnet",
];

/** Parsed gate metadata from the upload-side JSON. */
export interface GateMetadata {
  version: number;
  cid: string;
  chain: Chain;
  tokenAddress: string;
  threshold: bigint;
  encryptedAesKey: string; // base64
}

/** Candid-compatible gate request for the canister call. */
export interface GateRequest {
  chain: { [K in Chain]?: null };
  tokenAddress: string;
  threshold: bigint;
  cid: string;
  evmAddress: string;
  transportPublicKey: Uint8Array;
  nonce: bigint;
  signature: Uint8Array;
  eip712ChainId: bigint;
  eip712VerifyingContract: string;
}

export interface InsufficientBalanceError {
  InsufficientBalance: { required: bigint; actual: bigint };
}

export type GateError =
  | InsufficientBalanceError
  | { InvalidAddress: string }
  | { InvalidThreshold: null }
  | { EvmRpcError: string }
  | { VetKDError: string }
  | { InvalidSignature: string }
  | { NonceAlreadyUsed: null };

export type GateResult = { ok: { encryptedKey: Uint8Array; verificationKey: Uint8Array } } | { err: GateError };

/** Options for the convenience decryptGatedFile function. */
export interface DecryptOptions {
  gateMetadataJson: string;
  evmAddress: string;
  encryptedFileBytes: Uint8Array;
  canisterId: string;
  host: string;
  nonce: bigint;
  signature: Uint8Array;
  eip712ChainId: bigint;
  eip712VerifyingContract: string;
  fetchRootKey?: boolean;
}

export interface GateRequestTypedData {
  domain: {
    name: "HavenAOL";
    chainId: bigint;
    verifyingContract: string;
  };
  primaryType: "GateRequest";
  types: {
    EIP712Domain: Array<{ name: "name" | "chainId" | "verifyingContract"; type: "string" | "uint256" | "address" }>;
    GateRequest: Array<{ name: "evmAddress" | "transportPublicKey" | "nonce"; type: "address" | "bytes" | "uint256" }>;
  };
  message: {
    evmAddress: string;
    transportPublicKey: `0x${string}`;
    nonce: bigint;
  };
}
