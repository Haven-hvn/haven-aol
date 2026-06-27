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
- EIP-712 payload helpers: `packages/typescript/src/eip712.ts`
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

## Gate API Contract (Must Match Exactly)

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

Any client/frontend integration must serialize this shape exactly as in `packages/typescript/src/canister.ts` and `src/backend/backend.did`.

## EIP-712 Signing Rules

Typed data must be:

- `domain.name = "HavenAOL"`
- `domain.chainId = 1`
- `domain.verifyingContract = eip712VerifyingContract`
- `primaryType = "GateRequest"`
- message fields:
  - `evmAddress` (`address`)
  - `transportPublicKey` (`bytes`)
  - `nonce` (`uint256`)

Use wallet `signTypedDataV4` compatible signing. Do not use EIP-191 personal sign.

## Expected Service-Level Outcomes

- Valid signature + unfunded wallet: `InsufficientBalance`
- Malformed/invalid signature: `InvalidSignature`
- Reused nonce in same domain/type scope: `NonceAlreadyUsed`

## Debugging Priority

If behavior is unexpected:

1. Compare request payload against `backend.did` + `canister.ts`.
2. Compare EIP-712 payload/signature construction against `eip712.ts`.
3. Re-run against mainnet and inspect returned `GateError`.
4. Only then consider backend deployment work, and only with explicit user approval.
