import { Actor, HttpAgent } from "@icp-sdk/core/agent";
import { IDL } from "@icp-sdk/core/candid";
import { Chain, GateResult } from "./types.js";

// Candid IDL factory for the Haven-AOL backend canister
const ChainVariant = IDL.Variant({
  EthMainnet: IDL.Null,
  EthSepolia: IDL.Null,
  ArbitrumOne: IDL.Null,
  BaseMainnet: IDL.Null,
  OptimismMainnet: IDL.Null,
});

const GateRequestType = IDL.Record({
  chain: ChainVariant,
  tokenAddress: IDL.Text,
  threshold: IDL.Nat,
  cid: IDL.Text,
  evmAddress: IDL.Text,
  transportPublicKey: IDL.Vec(IDL.Nat8),
  nonce: IDL.Nat,
  signature: IDL.Vec(IDL.Nat8),
  eip712ChainId: IDL.Nat,
  eip712VerifyingContract: IDL.Text,
});

const GateErrorVariant = IDL.Variant({
  InsufficientBalance: IDL.Record({ required: IDL.Nat, actual: IDL.Nat }),
  InvalidAddress: IDL.Text,
  InvalidThreshold: IDL.Null,
  EvmRpcError: IDL.Text,
  VetKDError: IDL.Text,
  InvalidSignature: IDL.Text,
  NonceAlreadyUsed: IDL.Null,
});

const GateResultVariant = IDL.Variant({
  ok: IDL.Vec(IDL.Nat8),
  err: GateErrorVariant,
});

const idlFactory = () =>
  IDL.Service({
    requestDecryptionKey: IDL.Func([GateRequestType], [GateResultVariant], []),
    getVetKDPublicKey: IDL.Func([], [IDL.Vec(IDL.Nat8)], []),
  });

function buildChainVariant(chain: Chain): Record<string, null> {
  return { [chain]: null };
}

/**
 * Call the canister's requestDecryptionKey endpoint.
 */
export async function requestDecryptionKey(
  agent: HttpAgent,
  canisterId: string,
  request: {
    chain: Chain;
    tokenAddress: string;
    threshold: bigint;
    cid: string;
    evmAddress: string;
    transportPublicKey: Uint8Array;
    nonce: bigint;
    signature: Uint8Array;
    eip712ChainId: bigint;
    eip712VerifyingContract: string;
  },
): Promise<GateResult> {
  const actor = Actor.createActor(idlFactory, { agent, canisterId });
  const result = await actor.requestDecryptionKey({
    chain: buildChainVariant(request.chain),
    tokenAddress: request.tokenAddress,
    threshold: request.threshold,
    cid: request.cid,
    evmAddress: request.evmAddress,
    transportPublicKey: request.transportPublicKey,
    nonce: request.nonce,
    signature: request.signature,
    eip712ChainId: request.eip712ChainId,
    eip712VerifyingContract: request.eip712VerifyingContract,
  }) as GateResult;
  return result;
}

/**
 * Call the canister's getVetKDPublicKey endpoint (verification key).
 */
export async function fetchVerificationKey(
  agent: HttpAgent,
  canisterId: string,
): Promise<Uint8Array> {
  const actor = Actor.createActor(idlFactory, { agent, canisterId });
  const result = (await actor.getVetKDPublicKey()) as Uint8Array;
  return new Uint8Array(result);
}
