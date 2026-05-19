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
  ok: IDL.Record({
    encrypted_key: IDL.Vec(IDL.Nat8),
    verification_key: IDL.Vec(IDL.Nat8),
  }),
  err: GateErrorVariant,
});

const idlFactory = () =>
  IDL.Service({
    requestDecryptionKey: IDL.Func([GateRequestType], [GateResultVariant], []),
    getVetKDPublicKey: IDL.Func([], [IDL.Vec(IDL.Nat8)], ["query"]),
  });

// ============================================================================
// Actor Instance Reuse
// ============================================================================

/**
 * Cache Actor instances per HttpAgent to avoid redundant IDL parsing.
 * Uses WeakMap so actors are GC'd when the agent is GC'd.
 */
const actorCache = new WeakMap<HttpAgent, Map<string, ReturnType<typeof Actor.createActor>>>();

function getOrCreateActor(agent: HttpAgent, canisterId: string) {
  let agentMap = actorCache.get(agent);
  if (!agentMap) {
    agentMap = new Map();
    actorCache.set(agent, agentMap);
  }
  let actor = agentMap.get(canisterId);
  if (!actor) {
    actor = Actor.createActor(idlFactory, { agent, canisterId });
    agentMap.set(canisterId, actor);
  }
  return actor;
}

// ============================================================================
// Public API
// ============================================================================

function buildChainVariant(chain: Chain): Record<string, null> {
  return { [chain]: null };
}

/**
 * Call the canister's requestDecryptionKey endpoint.
 *
 * Returns both the encrypted derived key AND the verification key in one
 * response — eliminates the need for a separate fetchVerificationKey call.
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
  const actor = getOrCreateActor(agent, canisterId);
  const raw = await actor.requestDecryptionKey({
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
  }) as { ok?: { encrypted_key: Uint8Array; verification_key: Uint8Array }; err?: unknown };

  if (raw.ok) {
    return {
      ok: {
        encryptedKey: new Uint8Array(raw.ok.encrypted_key),
        verificationKey: new Uint8Array(raw.ok.verification_key),
      },
    };
  }
  return { err: raw.err } as GateResult;
}

/**
 * Call the canister's getVetKDPublicKey endpoint (verification key).
 * Uses query call (fast path, ~200ms instead of ~5s).
 */
export async function fetchVerificationKey(
  agent: HttpAgent,
  canisterId: string,
): Promise<Uint8Array> {
  const actor = getOrCreateActor(agent, canisterId);
  const result = (await actor.getVetKDPublicKey()) as Uint8Array;
  return new Uint8Array(result);
}
