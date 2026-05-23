# Attestation cost and on-chain receipt (mainnet)

Canister: `dciac-uaaaa-aaaad-qlzuq-cai`  
Method: `attestHolding` (update)

ICP does not expose per-method billing history to controllers. This analysis combines:

1. **Measured** balance deltas on the backend canister (2026-05-22 probe).
2. **Historical** production error text from a failed signing attempt (2026-05-21 haven-cli).
3. **Declared** cycle forward caps in `src/backend/main.mo`.

---

## Design rationale: why t-Schnorr / Ed25519

There is no separate ADR in the repo; this section records the intent implied by the `feat: attestation service` implementation and haven-cli integration.

### Problem attestation solves

The **gate** flow (`requestDecryptionKey`) returns VetKD material for decryption. Attestation is a separate path for a **portable holding proof** bundled into off-chain metadata (e.g. haven-cli → Arkiv entity payload) without issuing a decryption key.

Consumers should be able to check offline:

> The Haven-AOL canister `dciac-uaaaa-aaaad-qlzuq-cai` attests that wallet **W** held at least **threshold** of token **T** on chain **C** at time **timestamp**, for content **cidHash**.

### Two-layer trust model

| Layer | Mechanism | Proves |
|-------|-----------|--------|
| **Inbound** | EIP-712 `AttestRequest` + Motoko `ecrecover` | Caller controls `evmAddress` (same anti-impersonation model as the gate) |
| **Outbound** | t-Schnorr / Ed25519 over `HAVEN_ATTEST_V1:…` preimage | The **ICP service** issued this balance snapshot and bound it to `cidHash` + time |

Inbound proof alone does not let a third party trust a JSON blob stored on Arkiv: anyone can fabricate `{ evmAddress, balanceAtCheck, … }`. The outbound signature ties the record to a **stable canister-derived key** (`derivation_path = haven_attest_v1`, exposed via `getAttestationPublicKey`).

### Alternatives considered (and why we did not use them)

| Approach | Approx. backend cost | Trade-off |
|----------|---------------------|-----------|
| **Return `Attestation` struct only** (no canister signature) | ~3B (EVM balance check only) | Cheapest, but **not a cryptographic receipt** from the canister; Arkiv readers must trust the uploader or replay the full update call themselves |
| **IC request id / certified ingress only** | ~3B + heavy per-verifier IC lookups | Not a compact field in metadata; poor fit for indexers and offline verification |
| **Threshold ECDSA** (`sign_with_ecdsa`) | Similar billions of cycles | Ethereum-shaped signatures; attestation is not an EVM transaction, and verify stacks already use Ed25519-friendly tooling for this metadata |
| **VetKD-derived signing** | Wrong tool + high cost | VetKD is for **conditional encryption keys**, not attestations; used only in the gate path |
| **t-Schnorr / Ed25519** (chosen) | ~29B–36B per success | Standard ICP chain-key API; compact ~64-byte sig; fast offline verify |

The meaningful cost fork is **unsigned record vs canister-signed receipt**, not Ed25519 vs another Schnorr curve. Most of the “cheaper methodologies” save money by dropping issuer binding, not by swapping signature algorithms.

### Why Schnorr on ICP specifically

- Canisters do not hold private keys in Wasm; threshold signing goes through the **management canister** (`sign_with_schnorr`, `schnorr_public_key`).
- **Ed25519** verification is cheap and widely available in TypeScript/Python (haven-cli, indexers).
- The preimage is a simple UTF-8 string (`encodeAttestation` in `src/backend/main.mo`), not an EVM struct—no chain RPC at verify time.
- Signing is **separate** from VetKD: gate users pay for key derivation; attestation users pay for a signed statement.

### Product integration (haven-cli)

On gated upload, `sync_step` calls `attest_holding` and, on success, attaches `attestation` + `signature` to the Arkiv payload (`haven_cli/services/arkiv_sync.py`). Failure is **non-blocking** (upload continues without attestation). That integration expects a **verifiable** third-party field, not merely a log line from the uploader.

### Possible future changes

If cost becomes the primary constraint:

1. **Optional signing** — API flag to return `#ok` without `signature` for low-trust contexts (~3B path only).
2. **Batch / amortized attest** — not implemented; would complicate replay and Arkiv semantics.
3. **Revisit threshold ECDSA** — only if verifiers require Ethereum-native signature tooling and accept similar cycle cost.

Any change should preserve the inbound EIP-712 wallet proof; that addresses a different threat (address impersonation) than the outbound canister signature.

### Progressive encryption and batched Schnorr receipts

**Progressive encryption (uploader)** — already supported at the file level:

- haven-cli uses `encrypt_file_streaming` (chunked AES-GCM, default 1 MiB chunks) so large single files encrypt without loading the whole object into memory.
- That is independent of attestation: encryption is local; attestation runs later in `SyncStep` when a **root CID** exists.

**What the canister does today** — one `attestHolding` per call:

- One EIP-712 `AttestRequest` (wallet proof + nonce).
- One EVM `balanceOf` (shared cost ~3B net).
- One `sign_with_schnorr` over one `HAVEN_ATTEST_V1:…` preimage bound to a **single** `cidHash` (~26B net).
- haven-cli sets `cidHash = SHA-256(root_cid)` once per Arkiv sync, not per encrypt chunk.

So: **yes, encrypt progressively; no, Schnorr receipts are not batched today.** Each successful attest is ~29B–36B backend cycles.

**Could you batch receipts?** Only with new protocol work. ICP `sign_with_schnorr` signs **one message blob per call**; there is no single chain-key op that signs N unrelated attestations for ~26B total.

| Strategy | Backend cost (order of magnitude) | Trade-off |
|----------|-----------------------------------|-----------|
| **Status quo** — one attest per entity / `root_cid` at sync | ~29B once per upload | Simple; matches one Arkiv entity; no per-chunk proof |
| **N attest calls** (one per file or segment CID) | ~29B × N | Strong per-object provenance; expensive |
| **One attest, batch preimage** — e.g. Merkle root of `cidHash`es in one `Attestation` + one sign | ~29B once | Cheapest multi-file receipt; verifiers need Merkle inclusion proofs per file |
| **New `attestHoldingBatch`** — one balance check, loop `sign_with_schnorr` N times | ~3B + 26B×N | Saves repeated EVM RPC only; signing still dominates |
| **Defer attest** — encrypt/upload many files, attest once when final `root_cid` is known | ~29B once | Best cost/latency for multi-part uploads if one composite CID is acceptable |

**Practical recommendation for haven-cli-style uploads:**

1. Keep **streaming encrypt** per file (or per segment file) as today.
2. Run **one attestation** after the **final** `root_cid` is pinned (current `sync_step` pattern), not after every chunk or segment—unless product requires per-segment holding proofs.
3. If many CIDs must be covered in one receipt, extend the canister with an explicit **batch/Merkle attestation** type (new preimage + Candid), rather than calling `attestHolding` in a loop.

**Nonce / replay:** Each `attestHolding` consumes a scoped nonce. Batching multiple logical attestations in one update still needs a defined nonce story (one nonce per batch request, or per item in a batch API).

---

## What the canister returns (the receipt)

A successful call returns Candid `AttestResult`:

```candid
variant {
  ok : record {
    attestation : Attestation;
    signature : blob;  // Ed25519 / t-Schnorr (64 bytes typical)
  };
  err : GateError;
}
```

`Attestation` fields:

| Field | Meaning |
|-------|---------|
| `evmAddress` | Wallet that signed the EIP-712 `AttestRequest` |
| `chain` | EVM chain variant (`EthMainnet`, …) |
| `tokenAddress` | ERC-20 checked (e.g. USDC) |
| `threshold` | Minimum balance required (token base units) |
| `balanceAtCheck` | On-chain `balanceOf` at call time |
| `cidHash` | 64-hex SHA-256 of content CID (no `0x` required) |
| `timestamp` | Unix seconds when attestation was built |

The canister signs the UTF-8 preimage:

```text
HAVEN_ATTEST_V1:{chain}:{tokenAddress}:{threshold}:{evmAddress}:{cidHash}:{timestamp}:{balanceAtCheck}
```

Verification: fetch `getAttestationPublicKey` (query), verify `signature` over that preimage with derivation path `haven_attest_v1`.

---

## Measured cost: balance-check path (no signing)

Probe: valid EIP-712 proof, USDC on Ethereum mainnet, `threshold = 1`, unfunded ephemeral wallet → `#InsufficientBalance` (stops before `sign_with_schnorr`).

| Metric | Value |
|--------|-------|
| Wall clock | **7.77 s** |
| Backend cycles consumed (balance delta) | **3,031,202,874** (~3.03B) |
| WASM module | `0x036c4e10a1e6cb0b58753dab1aac5bc6663ddebc9e9ee14fa4a6e23b28d28a88` |

Rough USD (rule of thumb **1T cycles ≈ $1**): **~$0.003** per balance-check attestation attempt.

This path includes: ingress, EIP-712 + `ecrecover`, nonce map update, **EVM RPC `eth_call` (balanceOf)** with up to **30B cycles forwarded** (unused cycles refunded to the backend).

---

## Historical observation: signing step only

From haven-cli on **2026-05-21** (backend still forwarding **10B** to `sign_with_schnorr`):

```text
t-Schnorr signing failed: sign_with_schnorr request sent with 10_000_000_000 cycles,
but 26_153_846_153 cycles are required.
```

So a **successful** attest that reaches signing needs about **26.2B cycles** for that management-canister call alone (current forward cap: **35B**).

---

## Estimated total cost per successful attestation

| Step | Cycles (order of magnitude) |
|------|-----------------------------|
| Validation + `ecrecover` | ≪ 1B (no HTTPS outcall) |
| `eth_call` balanceOf (2-of-3 consensus) | ~0.1B–3B net (measured ~3B on failed path) |
| `sign_with_schnorr` | **~26.2B** (observed requirement) |
| **Total (backend net)** | **~29B–36B** per successful `attestHolding` |

Rough USD: **~$0.03–$0.04** per successful attestation (plus caller ingress fees on the identity that submits the update).

Warmup (amortized): `warmupAttestationPublicKey` uses `schnorr_public_key` under the same **35B** forward cap; run once per deploy / cache miss.

---

## Example receipts from mainnet

### Error receipt (measured 2026-05-22)

Wallet did not meet `threshold`; no Ed25519 signature issued.

```json
{
  "status": "err",
  "canisterId": "dciac-uaaaa-aaaad-qlzuq-cai",
  "error": {
    "InsufficientBalance": {
      "required": 1,
      "actual": 0
    }
  }
}
```

### Success receipt (shape; requires funded wallet)

When `balanceAtCheck >= threshold`, the canister returns:

```json
{
  "status": "ok",
  "canisterId": "dciac-uaaaa-aaaad-qlzuq-cai",
  "attestation": {
    "evmAddress": "0x…",
    "chain": "EthMainnet",
    "tokenAddress": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    "threshold": 1000000,
    "balanceAtCheck": 5000000,
    "cidHash": "64_hex_chars_sha256_of_cid",
    "timestamp": 1779404000
  },
  "signatureHex": "64_byte_ed25519_signature_hex",
  "signatureBytes": 64
}
```

**Note:** No successful `attestHolding` completions appear in canister logs to date; the success JSON above is the contract’s declared `AttestResult #ok` shape. Use a funded test wallet to mint a live receipt.

---

## Reproduce measurement

```bash
python3 -m venv .venv-probe && .venv-probe/bin/pip install icp-py-core eth-account
.venv-probe/bin/python tests/mainnet_attest_cost_probe.py
```

Emits full JSON: cycle deltas, forward budgets, historical sign cost, and a live error or success receipt.

---

## Forward caps in deployed WASM

| Inter-canister call | Cycles attached (`with cycles = …`) |
|---------------------|-------------------------------------|
| `evmRpc.eth_call` | `CYCLE_BUDGET` = **30_000_000_000** |
| `ic.sign_with_schnorr` | `SCHNORR_CYCLE_BUDGET` = **35_000_000_000** |
| `ic.schnorr_public_key` (warmup) | **35_000_000_000** |

Only **net** consumed cycles reduce the backend balance; forwards are mostly refunded.
