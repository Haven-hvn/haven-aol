import { HttpAgent, AnonymousIdentity } from "@icp-sdk/core/agent";
import { DecryptOptions } from "./types.js";
import { parseGateMetadata } from "./metadata.js";
import { computeDerivationInput } from "./derivation.js";
import { createTransportKeyPair, recoverVetKey, ibeDecryptAesKey, decryptFile } from "./crypto.js";
import { requestDecryptionKey, fetchVerificationKey } from "./canister.js";

/**
 * End-to-end orchestrated decryption flow.
 *
 * The caller provides the agent config, EVM address, gate metadata JSON,
 * and the pre-fetched encrypted file bytes (IPFS fetch is caller's responsibility).
 */
export async function decryptGatedFile(options: DecryptOptions): Promise<Uint8Array> {
  const { gateMetadataJson, evmAddress, encryptedFileBytes, canisterId, host, fetchRootKey } = options;

  // 1. Parse gate metadata
  const metadata = parseGateMetadata(gateMetadataJson);

  // 2. Compute derivation input
  const derivationInput = await computeDerivationInput(
    metadata.chain,
    metadata.tokenAddress,
    metadata.threshold,
    metadata.cid,
  );

  // 3. Create anonymous agent (canister checks EVM balance, not ICP identity)
  const agent = await HttpAgent.create({
    host,
    identity: new AnonymousIdentity(),
  });
  if (fetchRootKey) {
    await agent.fetchRootKey();
  }

  // 4. Generate ephemeral transport key pair
  const { secretKey, publicKey } = createTransportKeyPair();

  // 5. Call canister to get encrypted VetKD key
  const result = await requestDecryptionKey(agent, canisterId, {
    chain: metadata.chain,
    tokenAddress: metadata.tokenAddress,
    threshold: metadata.threshold,
    cid: metadata.cid,
    evmAddress,
    transportPublicKey: publicKey,
    nonce: options.nonce,
    signature: options.signature,
    eip712ChainId: options.eip712ChainId,
    eip712VerifyingContract: options.eip712VerifyingContract,
  });

  if ("err" in result) {
    throw new HavenAolError(result.err);
  }

  // 6. Fetch verification key
  const verificationKeyBytes = await fetchVerificationKey(agent, canisterId);

  // 7. Recover VetKD key
  const vetKey = recoverVetKey(result.ok, secretKey, verificationKeyBytes, derivationInput);

  // 8. IBE-decrypt the AES key
  const aesKey = ibeDecryptAesKey(metadata.encryptedAesKey, vetKey);

  // 9. AES-GCM decrypt the file
  return decryptFile(encryptedFileBytes, aesKey);
}

/** Typed error wrapping a GateError from the canister. */
export class HavenAolError extends Error {
  public readonly gateError: unknown;
  constructor(gateError: unknown) {
    const msg = JSON.stringify(gateError);
    super(`Haven-AOL gate error: ${msg}`);
    this.name = "HavenAolError";
    this.gateError = gateError;
  }
}
