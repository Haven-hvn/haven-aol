# Haven-AOL

**Always Online** on [DFINITY Internet Computer](https://internetcomputer.org/): an ICP-native layer for **smart access management** across web3 — **conditional key access** for token-gated content, **shared access** patterns suited to **DAOs**, **DataDAOs**, **agent swarms**, and other cooperative setups.

This repository contains:

- **Motoko canister** (`src/backend`) — balance-checked gates, VetKD-derived decryption keys, and **token-holding attestations**.
- **TypeScript SDK** (`packages/typescript`) — decrypt-side client library (`haven-aol` on npm).
- **Python SDK** (`packages/python`) — upload-side encryption and metadata (`haven-aol` on PyPI).

Gate derivation and VetKD context strings follow **protocol v1** in [`docs/derivation-spec.md`](docs/derivation-spec.md) (wire-compatible domain tags remain `accessol` / `accessol_v1` for existing payloads).

## Backend canister API

Candid interface: [`src/backend/backend.did`](src/backend/backend.did). Mainnet canister: `dciac-uaaaa-aaaad-qlzuq-cai`.

### Gate flow (decryption keys)

1. Client signs an EIP-712 gate request (`requestDecryptionKey`).
2. Canister verifies wallet ownership (native `ecrecover`), checks on-chain token balance via EVM RPC, then derives a **VetKD** key for the gate.
3. Client decrypts content locally using the returned encrypted key + verification key.

| Method | Call type | Description |
|--------|-----------|-------------|
| `requestDecryptionKey` | update | Gate proof → balance check → VetKD ciphertext |
| `getVetKDPublicKey` | query | VetKD verification key (cached) |
| `warmupVetKDPublicKey` | update | Populate VetKD key cache |

### Attestation flow (signed holding proof)

For use cases that need a **portable, verifiable proof** of token holding (without returning a decryption key):

1. Client signs an EIP-712 `AttestRequest` (`attestHolding`).
2. Canister verifies wallet + balance, then signs a canonical attestation with **t-Schnorr / Ed25519** (derivation path `haven_attest_v1`).
3. Verifiers fetch `getAttestationPublicKey` and validate the signature offline.

| Method | Call type | Description |
|--------|-----------|-------------|
| `attestHolding` | update | Holding proof → balance check → signed `Attestation` |
| `getAttestationPublicKey` | query | Ed25519 public key for signature verification (cached) |
| `warmupAttestationPublicKey` | update | Populate attestation key cache |

Attestation payload fields: `evmAddress`, `chain`, `tokenAddress`, `threshold`, `balanceAtCheck`, `cidHash`, `timestamp` (Unix seconds). Canonical signing preimage: `HAVEN_ATTEST_V1:{chain}:...` (see `encodeAttestation` in `src/backend/main.mo`).

### Post-deploy warmups (both required on fresh deploy)

After deploy or if a query traps with “not yet cached”, run **both** warmups (update calls; caches persist across upgrades):

```bash
icp canister call backend warmupVetKDPublicKey '()' -e ic --identity <YOUR_IDENTITY>
icp canister call backend warmupAttestationPublicKey '()' -e ic --identity <YOUR_IDENTITY>
```

Full mainnet deploy, upgrade, and warmup steps: [`docs/mainnet-icp-deploy-test-runbook.md`](docs/mainnet-icp-deploy-test-runbook.md).

TypeScript helpers: `fetchVerificationKey`, `fetchAttestationPublicKey` in [`packages/typescript/src/canister.ts`](packages/typescript/src/canister.ts).

## Quick start

See [`tests/README.md`](tests/README.md) for integration tests, local replica setup, and dependency installation (including native VetKD bindings).
