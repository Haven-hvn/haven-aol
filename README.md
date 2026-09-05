# Haven-AOL

**Always Online** on [DFINITY Internet Computer](https://internetcomputer.org/): an ICP-native layer for **smart access management** across web3 — **conditional key access** for token-gated content, **shared access** patterns suited to **DAOs**, **DataDAOs**, **agent swarms**, and other cooperative setups.

This repository contains:

- **Motoko canister** (`src/backend`) — balance-checked gates, VetKD-derived decryption keys, and **token-holding attestations**. Supports protocol v1 (per-CID), protocol v3 (corpus + epoch), and protocol v4 (market-cap-gated drip).
- **TypeScript SDK** (`packages/typescript`) — decrypt-side client library (`haven-aol` on npm).
- **Python SDK** (`packages/python`) — upload-side encryption and metadata (`haven-aol` on PyPI).
- **secp256k1** (`packages/secp256k1`) — pure-Motoko ECDSA public key recovery, used by the canister for fast native `ecrecover`.

## Protocol Versions

Haven-AOL supports three coexisting protocols. Uploaders choose which protocol a piece of content uses via the `version` field in gate metadata. On Arkiv, the same number is stored as the `gate_type` attribute (`ATTR_UINT`): `1`=per-file, `3`=per-epoch, `4`=per-marketcap (`gate_type == gate.version`, numeric only, no `gate_version` key).

### v1 — Per-CID derivation

Each content identifier (CID) gets a **unique** VetKD derivation key. A community uploading N files pays N balance-checks and N VetKD derivations. Best for individual file gating with distinct keys per file.

**Derivation preimage:**
```
SHA-256("accessol:" + chain + ":" + tokenAddress + ":" + threshold + ":" + cid)
```

**VetKD context:** `accessol_v1`

### v3 — Corpus + epoch derivation

One VetKD key unlocks **every CID** a community uploads within a 30-day epoch. A single balance-check gates a whole "corpus" of content. Designed for communities publishing many files under the same access policy.

**Derivation preimage:**
```
SHA-256("accessol_v3:" + chain + ":" + tokenAddress + ":" + threshold + ":" + effectiveEpoch)
```

**VetKD context:** `accessol_v3` (distinct master public key from v1)

**Epoch length:** 2,592,000 seconds (30 days). `currentEpoch() = floor(unixSeconds / 2_592_000)`.

**Threshold-zero collapse:** If `threshold == 0`, `effectiveEpoch` is forced to `0` regardless of the wire epoch. This gives free-tier / open-access content an identical key across all epochs.

**Approval cache:** Balance-check results are cached per `(chain, token, threshold, epoch, wallet)` with a 30-day TTL. On cache hit, the EVM RPC `eth_call` is **skipped**, making the hot path significantly cheaper. Cache entries auto-expire when their epoch rotates or the TTL elapses.

---

### v4 — Market-cap-gated drip derivation

Progressive unlock for public DAO drops: a release is split into chunks, each pinned to its own unlock target `T_i` (**whole reserve units** — whole ETH for native-reserve tokens). The canister refuses to derive a chunk key until the gate token's **bonding-curve market cap** (`totalSupply × priceForNextMint`, natively in the reserve token) reaches that chunk's target. Spec: `haven-v4-marketcap-drip.md`. Only mint.club V2 bonding-curve tokens can gate — by construction, not by allowlist.

**Derivation preimage:**
```
SHA-256("accessol_v4:" + chain + ":" + tokenAddress + ":" + threshold + ":" + effectiveEpoch + ":" + marketCapTarget)
```

**VetKD context:** `accessol_v4` (distinct master public key from v1/v3)

**Market-cap oracle:** the chain's mint.club V2 **Bond contract** — the curve is the ONLY price source, there is no Chainlink leg. `oracleAddress` must name the chain's Bond contract (case-insensitive, checked against a per-chain table with compiled-in defaults plus a controller-only `setBondConfig` override); anything else fails closed **before** touching the chain. `marketCapTarget` is whole reserve units, compared as `supplyRaw × priceNextMintWei / 10^tokenDecimals >= marketCapTarget × 10^reserveDecimals`. Cap is supply × *marginal* (next-mint) price — the bonding-curve convention, not a DEX-clearing valuation.

**Curve ceiling:** every token has a hard max — `maxSupply × finalPrice`. Rungs sealed above it can never unlock (see the dapp's seal-time curve-max guard). The curve is immutable after token creation, so the ceiling can only be raised by launching a new token with larger curve parameters.

**Market-cap burst cache:** cap snapshots are cached per `(chain, token)` for **300 seconds only** — deliberately NOT the 30-day approval-cache epoch. Crypto markets reprice continuously; a long-lived snapshot would make unlock decisions meaningless. A failed refresh never extends a stale snapshot's life. ERC20 `decimals()` IS cached permanently (immutable per contract). Zero-price or failed curve reads fail closed.

**Gate order:** future-epoch rejection → EIP-712 verify (signature commits to `(epoch, marketCapTarget)`) → holder gate (shared approval cache with v3) → market-cap gate → VetKD derive.

---

### v4 — Gate flow (market-cap decryption keys)

| Method | Call type | Description |
|--------|-----------|-------------|
| `requestDecryptionKeyV4` | update | Gate proof → balance check (cached) → live curve-cap check → VetKD v4 ciphertext |
| `getVetKDPublicKeyV4` | query | VetKD verification key for v4 (cached; distinct from v1/v3 keys) |
| `warmupVetKDPublicKeyV4` | update | Populate v4 VetKD key cache |
| `getMarketCap` | update | Diagnostic: live cap in **whole reserve units** via `(chain, token, oracleAddress)` |
| `evictExpiredMarketCaps` | update | Controller-only janitor for the 5-minute cap burst cache |
| `getBondConfig` | query | Effective Bond config (wrapped-native pair) for a chain |
| `setBondConfig` | update | Controller-only Bond-config override per chain (heap-only: re-set after upgrades) |

**EIP-712 type (v4):**
```
GateRequestV4(address evmAddress,bytes transportPublicKey,uint256 epoch,uint256 marketCapTarget,uint256 nonce)
```

**Key differences from v3:**
- Request carries `marketCapTarget` (whole **reserve units**, not USD) + `oracleAddress`; both participate in validation (`oracleAddress` is pinned to the chain's Bond contract but is NOT a signed field).
- The signature commits to the requested target — a reader cannot sign once at a low target and claim a higher-unlocked chunk.
- New errors: `#MarketCapNotReached { required, actual }` (whole reserve units) and `#InvalidOracle` (non-Bond oracle, unsupported non-native reserve, or failed curve read).
- Derivation includes the target: two drip chunks with different targets always derive different keys, even at identical `(chain, token, threshold, epoch)`.

---

## Quick start

See [`tests/README.md`](tests/README.md) for integration tests, local replica setup, and dependency installation (including native VetKD bindings).

---

## Backend canister API

Candid interface: [`src/backend/backend.did`](src/backend/backend.did). Mainnet canister: `dciac-uaaaa-aaaad-qlzuq-cai`.

### v1 — Gate flow (decryption keys)

1. Client signs an EIP-712 `GateRequest` (`requestDecryptionKey`).
2. Canister verifies wallet ownership (native `ecrecover`), checks on-chain token balance via EVM RPC, then derives a **VetKD** key for the gate.
3. Client decrypts content locally using the returned encrypted key + verification key.

| Method | Call type | Description |
|--------|-----------|-------------|
| `requestDecryptionKey` | update | Gate proof → balance check → VetKD ciphertext |
| `batchRequestDecryptionKey` | update | Up to 20 CIDs, one balance check, N derivations |
| `getVetKDPublicKey` | query | VetKD verification key for v1 (cached) |
| `warmupVetKDPublicKey` | update | Populate v1 VetKD key cache |

**EIP-712 type (v1):**
```
GateRequest(address evmAddress,bytes transportPublicKey,uint256 nonce)
```

### v3 — Gate flow (corpus + epoch decryption keys)

1. Client signs an EIP-712 `GateRequestV3` (`requestDecryptionKeyV3`). The signature covers the epoch, not the CID.
2. Canister verifies wallet ownership (native `ecrecover`), checks that `epoch <= currentEpoch()`, then checks the approval cache or performs a balance check via EVM RPC. If the threshold is met, it derives a **VetKD v3** key for the `(chain, token, threshold, epoch)` tuple.
3. Client decrypts content locally. One key unlocks every CID uploaded under the same policy in that epoch.

| Method | Call type | Description |
|--------|-----------|-------------|
| `requestDecryptionKeyV3` | update | Gate proof → balance check (cached) → VetKD v3 ciphertext |
| `batchRequestDecryptionKeyV3` | update | Up to 20 CIDs, **one** VetKey derived and replicated per CID |
| `getVetKDPublicKeyV3` | query | VetKD verification key for v3 (cached; distinct from v1 key) |
| `warmupVetKDPublicKeyV3` | update | Populate v3 VetKD key cache |
| `getCurrentEpoch` | query | Returns current 30-day epoch number (ops diagnostic) |
| `evictExpiredApprovals` | update | Controller-only janitor for approval-cache eviction (batch) |

**EIP-712 type (v3):**
```
GateRequestV3(address evmAddress,bytes transportPublicKey,uint256 epoch,uint256 nonce)
```

**Key differences from v1:**
- `cid` in the request is replaced by `epoch`.
- `batchRequestDecryptionKeyV3` derives only **one** VetKD key regardless of CID count — the CID list shapes the response only.
- Balance checks are cached; a hot-path request with a valid approval cache entry skips EVM RPC entirely.
- Future epochs (`epoch > currentEpoch()`) are rejected with `#InvalidEpoch` before any side effects.
- Threshold-zero requests bypass both the cache and the balance check (free access), but the wire epoch is still validated against future-epoch rejection.

### Attestation flow (signed holding proof)

For use cases that need a **portable, verifiable proof** of token holding (without returning a decryption key):

1. Client signs an EIP-712 `AttestRequest` (`attestHolding`).
2. Canister verifies wallet + balance, then signs a canonical attestation with **t-Schnorr / Ed25519** (derivation path `haven_attest_v1`).
3. Verifiers fetch `getAttestationPublicKey` and validate the signature offline.

| Method | Call type | Description |
|--------|-----------|-------------|
| `attestHolding` | update | Holding proof → balance check → signed `Attestation` |
| `batchAttestHolding` | update | Merkle-tree attestation for multiple CIDs |
| `getAttestationPublicKey` | query | Ed25519 public key for signature verification (cached) |
| `warmupAttestationPublicKey` | update | Populate attestation key cache |

Attestation payload fields: `evmAddress`, `chain`, `tokenAddress`, `threshold`, `balanceAtCheck`, `cidHash`, `timestamp` (Unix seconds). Canonical signing preimage: `HAVEN_ATTEST_V1:{chain}:...` (see `encodeAttestation` in `src/backend/main.mo`).

---

## Gate error variants

| Error | Meaning |
|-------|---------|
| `InsufficientBalance` | Wallet holds fewer tokens than the threshold |
| `InvalidAddress` | EVM address format is invalid |
| `InvalidThreshold` | Threshold is invalid |
| `EvmRpcError` | EVM RPC canister call failed |
| `VetKDError` | VetKD derivation failed |
| `InvalidSignature` | EIP-712 signature verification failed |
| `NonceAlreadyUsed` | Nonce was already consumed in this scope |
| `InvalidEpoch` | (v3+) Epoch is in the future |
| `MarketCapNotReached` | (v4 only) Live curve cap below the chunk's unlock target (whole reserve units) |
| `InvalidOracle` | (v4 only) Non-Bond oracle, unsupported (non-native) reserve, or failed curve read |

---

## Post-deploy warmups

After deploy or if a query traps with "not yet cached", run **all three** warmups (update calls; caches persist across upgrades):

```bash
icp canister call backend warmupVetKDPublicKey '()' -e ic --identity <YOUR_IDENTITY>
icp canister call backend warmupVetKDPublicKeyV3 '()' -e ic --identity <YOUR_IDENTITY>
icp canister call backend warmupVetKDPublicKeyV4 '()' -e ic --identity <YOUR_IDENTITY>
icp canister call backend warmupAttestationPublicKey '()' -e ic --identity <YOUR_IDENTITY>
```

TypeScript helpers: `fetchVerificationKey`, `fetchAttestationPublicKey` in [`packages/typescript/src/canister.ts`](packages/typescript/src/canister.ts).

---

## Packages

### Python SDK (`haven-aol` on PyPI)

Upload-side encryption and metadata. Supports v1 (`haven_aol.core`), v3 (`haven_aol.v3`), and v4 (`haven_aol.v4`, including the `is_bond_address` classifier).

```python
from haven_aol.v3 import (
    current_epoch,
    compute_derivation_input_v3,
    build_gate_metadata_v3,
    build_eip712_gate_request_v3_typed_data,
)
```

- `current_epoch()` — local clock floor division by 30-day epoch.
- `compute_derivation_input_v3(chain, token_address, threshold, epoch)` — SHA-256 derivation preimage.
- `build_gate_metadata_v3(...)` — constructs v3 gate metadata dict (enforces threshold-zero ↔ epoch-zero).
- `parse_gate_metadata(raw)` — dispatching parser for both v1 and v3 metadata.
- `build_eip712_gate_request_v3_typed_data(...)` — EIP-712 typed data for `eth_account`.

Source: [`packages/python/src/haven_aol/v3.py`](packages/python/src/haven_aol/v3.py)

Tests: [`packages/python/tests/test_haven_aol_v3.py`](packages/python/tests/test_haven_aol_v3.py)

### TypeScript SDK (`haven-aol` on npm)

Decrypt-side client library. Supports v1, v3, and v4 (including the `isBondAddress` classifier and `BOND_ADDRESSES`).

```typescript
import {
  // v3
  currentEpoch,
  computeDerivationInputV3,
  buildGateMetadataV3,
  buildGateRequestV3TypedData,
  parseGateMetadataAny,       // dispatches v1 or v3
  // v1
  decryptGatedFile,
  requestDecryptionKey,
} from "haven-aol";
```

Source: [`packages/typescript/src/v3.ts`](packages/typescript/src/v3.ts)

Tests: [`packages/typescript/src/test/v3.test.ts`](packages/typescript/src/test/v3.test.ts)

---

## Cross-stack verification

v3 derivation is pinned by a **shared test fixture** — [`tests/fixtures/derivation-v3-vectors.json`](tests/fixtures/derivation-v3-vectors.json) — that all three implementations (Motoko canister, Python SDK, TypeScript SDK) must match byte-for-byte. v4 derivation is pinned the same way by [`tests/fixtures/derivation-v4-vectors.json`](tests/fixtures/derivation-v4-vectors.json).
