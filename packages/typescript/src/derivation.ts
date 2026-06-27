import { Chain } from "./types.js";

/**
 * Compute the derivation input hash per docs/derivation-spec.md.
 * Output is 32 raw SHA-256 bytes, used as VetKD `input` and IBE identity.
 */
export async function computeDerivationInput(
  chain: Chain,
  tokenAddress: string,
  threshold: bigint,
  cid: string,
): Promise<Uint8Array> {
  const preimage = `accessol:${chain}:${tokenAddress}:${threshold.toString()}:${cid}`;
  const encoded = new TextEncoder().encode(preimage);
  const hash = await crypto.subtle.digest("SHA-256", encoded);
  return new Uint8Array(hash);
}
