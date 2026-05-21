# ICP Mainnet Deployment and Test Runbook

This runbook documents exactly how `haven-aol` was deployed and tested on ICP mainnet, including Windows/WSL specifics, identity/key access, cycles handling, deployed canisters, and upgrade steps for future releases.

## 1) Environment Used

- **Host OS:** Windows 10/11 (PowerShell)
- **Build/Deploy runtime:** **WSL Linux** (Motoko toolchain requires WSL)
- **Repo path on Windows:** `E:\Repos\haven-aol`
- **Repo path inside WSL:** `/mnt/e/Repos/haven-aol`

### Why WSL is required

Motoko build tooling is not supported directly on Windows for this project flow, so all build/deploy/test commands were executed in WSL.

## 2) Tooling Prerequisites

Run these in WSL:

```bash
sudo apt update
sudo apt install -y nodejs npm python3-pip python3.12-venv build-essential curl
curl https://sh.rustup.rs -sSf | sh -s -- -y
npm install -g icp-cli ic-wasm
```

Verify:

```bash
icp --version
ic-wasm --version
node --version
python3 --version
```

## 3) Project Configuration Used for Mainnet

Mainnet environment in `icp.yaml` deploys only `backend`:

- `backend` canister source: `src/backend/main.mo`
- External canister IDs injected as env vars:
  - `PUBLIC_CANISTER_ID:evm_rpc = 7hfb6-caaaa-aaaar-qadga-cai`
  - `VETKD_CANISTER_ID = vrqyr-saaaa-aaaan-qzn4q-cai`
  - `VETKD_KEY_NAME = insecure_test_key_1`

## 4) Identity, Key Access, and Balances

### Identity handling

In WSL, if keyring/DBus is unavailable, identity must be created with plaintext storage:

```bash
icp identity new mainnet-validation-20260506 --storage plaintext
```

Use/select identity for deployment:

```bash
icp identity default mainnet-validation-20260506
icp identity principal
icp identity account-id
```

### Check ICP token balance (for fees + cycles minting)

```bash
icp token balance icp
```

### Check cycles balance

```bash
icp cycles balance
```

### Mint cycles when needed

Examples used during deployment:

```bash
icp cycles mint --cycles 1500000000000
icp cycles mint --icp 0.41
```

> Notes:
> - Minting/ledger operations require enough ICP to cover transfer fees.
> - If `--icp 1` fails due to fee overhead, mint in smaller staged amounts as above.

## 5) Build and Mainnet Deployment

From WSL in project root:

```bash
cd /mnt/e/Repos/haven-aol
icp build -e ic
icp deploy -e ic --identity mainnet-validation-20260506
```

## 6) Deployed Contracts / Canisters

### Deployed by this project (mainnet `ic` env)

- **`backend`**
  - Canister ID: `dciac-uaaaa-aaaad-qlzuq-cai`
  - Check status:
    ```bash
    icp canister status backend -e ic
    ```

### Referenced external mainnet canisters (not deployed by this repo in `ic` env)

- **EVM RPC canister**: `7hfb6-caaaa-aaaar-qadga-cai`
- **VetKD canister**: `vrqyr-saaaa-aaaan-qzn4q-cai`

## 7) Mainnet Functional Testing Performed

Smoke test script:

- Path: `tests/mainnet-smoke.sh`
- Purpose: verifies `health`, `getVetKDPublicKey`, and `requestDecryptionKey` error-path behavior + live EVM RPC path (does not cover attestation; see warmup + `attestHolding` below)

Run from WSL:

```bash
cd /mnt/e/Repos/haven-aol
ICP_MAINNET_IDENTITY=mainnet-validation-20260506 bash tests/mainnet-smoke.sh
```

Checks included:

- `M0`: `health` query returns ok
- `M1`: `getVetKDPublicKey` returns non-empty value
- `M2-M5`: validation errors for malformed request fields
- `M6`: real `eth_call` path; accepts `InsufficientBalance` or `EvmRpcError` result as pass condition

## 8) Windows -> WSL Invocation Pattern

If operating from PowerShell, run deployment/testing via WSL explicitly:

```powershell
wsl bash -lc "cd /mnt/e/Repos/haven-aol && icp build -e ic && icp deploy -e ic --identity mainnet-validation-20260506"
wsl bash -lc "cd /mnt/e/Repos/haven-aol && ICP_MAINNET_IDENTITY=mainnet-validation-20260506 bash tests/mainnet-smoke.sh"
```

## 9) Upgrade Procedure for Future Improvements

When new backend improvements are ready, use this process in the same environment (WSL + same identity):

1. Pull latest code and validate tests locally.
2. Build:
   ```bash
   icp build -e ic
   ```
3. Upgrade backend canister:
   ```bash
   icp canister install backend -e ic --mode upgrade --identity mainnet-validation-20260506
   ```
4. Warm up **both** public-key caches (required after first deploy; safe to re-run on upgrades):
   ```bash
   icp canister call backend warmupVetKDPublicKey '()' -e ic --identity mainnet-validation-20260506
   icp canister call backend warmupAttestationPublicKey '()' -e ic --identity mainnet-validation-20260506
   ```
   From PowerShell (non-interactive):
   ```powershell
   wsl bash -lc "cd /mnt/e/Repos/haven-aol && printf 'y\n' | icp canister call backend warmupVetKDPublicKey '()' -e ic --identity mainnet-validation-20260506"
   wsl bash -lc "cd /mnt/e/Repos/haven-aol && printf 'y\n' | icp canister call backend warmupAttestationPublicKey '()' -e ic --identity mainnet-validation-20260506"
   ```
   | Warmup | Query that needs it | Key size |
   |--------|---------------------|----------|
   | `warmupVetKDPublicKey` | `getVetKDPublicKey` | 96 bytes (VetKD transport key) |
   | `warmupAttestationPublicKey` | `getAttestationPublicKey` | 32 bytes (Ed25519 / t-Schnorr) |
   > **Why:** Both getters are query calls that read from persistent cache populated by warmup.
   > Caches survive upgrades, so warmups are only strictly required after a fresh deploy or if a query traps with "not yet cached". Re-running is harmless.
5. Verify post-upgrade status and cached keys:
   ```bash
   icp canister status backend -e ic
   icp canister call backend getVetKDPublicKey '()' -e ic --identity mainnet-validation-20260506 --query
   icp canister call backend getAttestationPublicKey '()' -e ic --identity mainnet-validation-20260506 --query
   ```
6. Re-run smoke tests:
   ```bash
   ICP_MAINNET_IDENTITY=mainnet-validation-20260506 bash tests/mainnet-smoke.sh
   ```

## 10) AI Agent Unblock: EIP-712 Changes On This Machine

If another agent says it cannot compile because `moc` is unavailable, run this exact flow on this machine.

### From PowerShell (recommended wrapper)

```powershell
wsl bash -lc "cd /mnt/e/Repos/haven-aol && icp build -e ic"
```

If build succeeds, proceed to upgrade, warmups, and smoke tests:

```powershell
wsl bash -lc "cd /mnt/e/Repos/haven-aol && icp canister install backend -e ic --mode upgrade --identity mainnet-validation-20260506 --yes"
wsl bash -lc "cd /mnt/e/Repos/haven-aol && printf 'y\n' | icp canister call backend warmupVetKDPublicKey '()' -e ic --identity mainnet-validation-20260506"
wsl bash -lc "cd /mnt/e/Repos/haven-aol && printf 'y\n' | icp canister call backend warmupAttestationPublicKey '()' -e ic --identity mainnet-validation-20260506"
wsl bash -lc "cd /mnt/e/Repos/haven-aol && ICP_MAINNET_IDENTITY=mainnet-validation-20260506 bash tests/mainnet-smoke.sh"
```

### If `moc` still appears missing

Run in WSL:

```bash
cd /mnt/e/Repos/haven-aol
icp build -e ic --debug
```

Then verify tool availability:

```bash
which node npm icp
icp --version
```

In this project, compile/deploy should be executed through `icp build` / `icp deploy` in WSL rather than trying to invoke `moc` directly from Windows.

## 11) Backend API (mainnet)

Candid source of truth: `src/backend/backend.did`.

| Endpoint | Type | Purpose |
|----------|------|---------|
| `requestDecryptionKey` | update | EIP-712 gate proof → balance check → VetKD encrypted key |
| `getVetKDPublicKey` | query | VetKD verification key (requires `warmupVetKDPublicKey`) |
| `warmupVetKDPublicKey` | update | Populate VetKD key cache |
| `attestHolding` | update | EIP-712 holding proof → balance check → signed attestation |
| `getAttestationPublicKey` | query | Ed25519 key for verifying attestations (requires `warmupAttestationPublicKey`) |
| `warmupAttestationPublicKey` | update | Populate attestation key cache |
| `health` | query | Liveness check |

**Attestation flow:** Client signs an EIP-712 `AttestRequest`; canister verifies wallet + token balance, then signs a canonical `Attestation` blob with t-Schnorr (derivation path `haven_attest_v1`). Verifiers fetch `getAttestationPublicKey` and check the signature offline. See README for payload fields.

## 12) Canister logs

Controllers can fetch trap/debug output:

```bash
icp canister logs backend -e ic --identity mainnet-validation-20260506
```

Logs are sparse unless the canister traps or emits explicit debug output.

## 13) Quick Troubleshooting Notes

- **Motoko build fails on Windows:** run in WSL.
- **PowerShell `&&` issues:** run commands separately or through `wsl bash -lc`.
- **Identity keyring errors in WSL:** recreate identity with `--storage plaintext`.
- **Insufficient cycles:** check `icp cycles balance`, then mint more cycles.
- **Deployment uses wrong identity:** pass `--identity` explicitly in deploy/install commands.
- **`getVetKDPublicKey` / `getAttestationPublicKey` trap:** run the matching warmup (see §9 step 4).
- **Warmup hangs on prompt:** pass explicit args `'()'` and pipe `printf 'y\n'` if the CLI asks for confirmation.
- **`IC0406` / “could not perform remote call” on `attestHolding` or `requestDecryptionKey`:** mainnet `eth_call` needs **~30B** forwarded cycles (10B traps). Backend uses `CYCLE_BUDGET = 30_000_000_000` for EVM RPC + VetKD; `SCHNORR_CYCLE_BUDGET = 35_000_000_000` for signing. Regress with `pytest tests/mainnet_attest_probe.py`.
- **Upgrade fails “Memory-incompatible program upgrade”:** avoid renaming `let`/`var` bindings in `persistent actor` between releases; change values only when possible.
- **Install fails “out of cycles”:** `icp canister top-up backend --amount 400b -e ic` then retry upgrade.
