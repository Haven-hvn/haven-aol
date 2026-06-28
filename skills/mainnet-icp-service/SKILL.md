---
name: mainnet-icp-service
description: Build Haven-AOL features by integrating with the deployed ICP mainnet backend service instead of local canister deployment. Use when updating frontend/client code that calls the gate API, wiring EIP-712 signing, validating canister responses, or running service-level tests.
---

# Build Against Mainnet Service (Not Local Deploy)

## Project Context

Haven-AOL is a token-gated decryption access service on ICP:

- Creators encrypt content keys and publish gate metadata.
- Consumers prove EVM wallet ownership with EIP-712 signatures.
- The canister verifies ownership + token balance conditions, then returns an encrypted VetKD-derived key when policy is satisfied.
- Client code then derives/decrypts locally to unlock content.

The service supports **two coexisting protocols**:
- **v1** — per-CID derivation (each file gets a unique key)
- **v3** — corpus + epoch derivation (one key unlocks all files in a 30-day epoch)

Typical uses:

- DAO/DataDAO membership-gated content access
- paid/private media delivery
- agent-to-agent shared resource gating using on-chain token thresholds

## Intent

Agents working in this repository should treat ICP mainnet as the default backend runtime.

- Service host: `https://icp-api.io`
- Service canister ID: `dciac-uaaaa-aaaad-qlzuq-cai`
- Identity used for ops in this repo: `mainnet-validation-20260506`

## Integration Points In This Repo

- Backend API contract (source of truth): `src/backend/backend.did`
- Client canister binding (request payload shape): `packages/typescript/src/canister.ts`
- Frontend/decrypt integration flow: `packages/typescript/src/decrypt.ts`
- EIP-712 payload helpers (v1): `packages/typescript/src/eip712.ts`
- v3 SDK (TypeScript): `packages/typescript/src/v3.ts`
- v3 SDK (Python): `packages/python/src/haven_aol/v3.py`
- Service smoke checks: `tests/mainnet-smoke.sh`

When changing integration behavior, update these files first, then verify against mainnet service responses.

## Required Agent Behavior

1. Build features as a client of the deployed service (request/response compatibility first).
2. Do not switch to local canister build/deploy as a default debugging path.
3. Validate changes by calling mainnet service endpoints and reporting actual outputs.
4. Only run `icp build`, `icp deploy`, or upgrade operations if the user explicitly asks.

## Standard Mainnet Commands

Run from repo root in WSL:

```bash
cd /mnt/e/Repos/haven-aol
```

Status/service checks:

```bash
icp canister status backend -e ic --identity mainnet-validation-20260506
icp canister call backend health '()' -e ic --query -o candid
```

Service smoke test:

```bash
ICP_MAINNET_IDENTITY=mainnet-validation-20260506 bash tests/mainnet-smoke.sh
```

## Gate API Contract — v1

`requestDecryptionKey` expects:

- `chain`
- `tokenAddress`
- `threshold`
- `cid`
- `evmAddress`
- `transportPublicKey`
- `nonce`
- `signature` (65-byte `r||s||v`)
- `eip712ChainId`
- `eip712VerifyingContract`

## Gate API Contract — v3

`requestDecryptionKeyV3` expects:

- `chain`
- `tokenAddress`
- `threshold`
- `epoch` (replaces `cid` from v1)
- `evmAddress`
- `transportPublicKey`
- `nonce`
- `signature` (65-byte `r||s||v`)
- `eip712ChainId`
- `eip712VerifyingContract`

`batchRequestDecryptionKeyV3` uses the same fields plus `cids` (up to 20). The CID list shapes the response only — it does NOT participate in derivation or the EIP-712 signature. One VetKD key is derived and replicated for every CID.

Any client/frontend integration must serialize this shape exactly as in `packages/typescript/src/canister.ts` and `src/backend/backend.did`.

## EIP-712 Signing Rules — v1

Typed data must be:

- `domain.name = "HavenAOL"`
- `domain.chainId = 1`
- `domain.verifyingContract = eip712VerifyingContract`
- `primaryType = "GateRequest"`
- message fields:
  - `evmAddress` (`address`)
  - `transportPublicKey` (`bytes`)
  - `nonce` (`uint256`)

## EIP-712 Signing Rules — v3

Typed data must be:

- `domain.name = "HavenAOL"`
- `domain.chainId = 1`
- `domain.verifyingContract = eip712VerifyingContract`
- `primaryType = "GateRequestV3"`
- message fields:
  - `evmAddress` (`address`)
  - `transportPublicKey` (`bytes`)
  - `epoch` (`uint256`)
  - `nonce` (`uint256`)

Type string: `GateRequestV3(address evmAddress,bytes transportPublicKey,uint256 epoch,uint256 nonce)`

Pinned typehash: `bf3ae938...` (see `EIP712_GATE_REQUEST_V3_TYPEHASH` in `packages/typescript/src/v3.ts` for full hex).

Use wallet `signTypedDataV4` compatible signing. Do not use EIP-191 personal sign.

## v3 Epoch Mechanics

- Epoch length: 2,592,000 seconds (30 days)
- `currentEpoch() = floor(unixSeconds / 2_592_000)`
- Requests with `epoch > currentEpoch()` are rejected with `#InvalidEpoch` before any side effects
- Threshold-zero collapse: if `threshold == 0`, effective epoch is forced to 0 for derivation (free access), but the wire epoch is still validated against future-epoch rejection

## v3 Approval Cache

Balance-check results are cached per `(chain, token, threshold, epoch, wallet)` with a 30-day TTL. On cache hit, the EVM RPC `eth_call` is skipped. This means:

- A wallet that was verified once will not trigger another EVM RPC call for 30 days (or until the epoch rotates)
- Threshold-zero requests bypass the cache entirely (no balance check needed)
- The cache is bounded by epoch rotation — entries from epoch N can never serve requests in epoch N+1

## Expected Service-Level Outcomes

### v1 and v3 (shared)

- Valid signature + unfunded wallet: `InsufficientBalance`
- Malformed/invalid signature: `InvalidSignature`
- Reused nonce in same domain/type scope: `NonceAlreadyUsed`

### v3 only

- Future epoch (`epoch > currentEpoch()`): `InvalidEpoch`
- Threshold-zero request: succeeds without balance check (returns VetKD key directly)

## Debugging Priority

If behavior is unexpected:

1. Compare request payload against `backend.did` + `canister.ts`.
2. Compare EIP-712 payload/signature construction against `eip712.ts` (v1) or `v3.ts` (v3).
3. Re-run against mainnet and inspect returned `GateError`.
4. Only then consider backend deployment work, and only with explicit user approval.
