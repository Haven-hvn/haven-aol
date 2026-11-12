# Haven-AOL ICP Redeployment Runbook

This runbook deploys a **new** Haven-AOL canister as `backend-v2` on an
**application subnet**. The old canister (`gny6k-fqaaa-aaaab-ag3ra-cai`) is **not
controlled by this runbook** and must be left untouched.

Why a new canister: the old canister is on a **`verified_application`** subnet while
its dependencies are on regular **application** subnets. Cycle-bearing inter-canister
calls (`eth_call`, `vetkd_derive_key`) fail with `IC0406`; no-cycle calls and
management-canister calls still work.

The new canister gets a **new canister ID**. Old v3/v4 content sealed under the old
canister will no longer decrypt. That is expected and acceptable for this deployment.

---

## 0. Prerequisites

- A controller identity for the **new** canister deployment (the repo uses
  `mainnet-validation-20260506`; the old canister's controllers are irrelevant here).
- Enough ICP/cycles to fund the new canister (suggested: **5T cycles** to start).
- The `icp` CLI installed and logged in.
- The latest source, including the EVM-RPC env-var fix:

```bash
cd /mnt/e/Repos/haven-aol
git fetch origin
git checkout fix/evm-rpc-canister-id
# or merge that branch into your deployment branch
```

The fix makes `main.mo` read `EVM_RPC_CANISTER_ID` first, then the legacy
`PUBLIC_CANISTER_ID:evm_rpc`, then fall back to `7hfb6-caaaa-aaaar-qadga-cai`.

---

## 1. Confirm the new canister entry

`icp.yaml` now has a separate `backend-v2` canister and the `ic` environment targets
only it. The old `backend` entry is kept for local development only.

```yaml
canisters:
  - name: backend
    recipe:
      type: "@dfinity/motoko@v4.1.0"
      configuration:
        main: src/backend/main.mo
  - name: backend-v2
    recipe:
      type: "@dfinity/motoko@v4.1.0"
      configuration:
        main: src/backend/main.mo
  - name: evm_rpc
    # ...

environments:
  - name: local
    network: local
    canisters: [backend, evm_rpc]
  - name: ic
    network: ic
    canisters: [backend-v2]
    settings:
      backend-v2:
        environment_variables:
          EVM_RPC_CANISTER_ID: "7hfb6-caaaa-aaaar-qadga-cai"
          PUBLIC_CANISTER_ID:evm_rpc: "7hfb6-caaaa-aaaar-qadga-cai"
          VETKD_CANISTER_ID: "vrqyr-saaaa-aaaan-qzn4q-cai"
          VETKD_KEY_NAME: "insecure_test_key_1"
          SCHNORR_KEY_NAME: "key_1"
```

Do **not** run `icp deploy backend -e ic` — `backend` is no longer in the `ic`
environment, and the old canister is not ours to touch. Use `backend-v2`.

---

## 2. Choose an application subnet

Do **not** use the old canister's verified application subnet
(`qxesv-zoxpm-vc64m-zxguk-5sj74-35vrb-tbgwg-pcird-5gr26-62oxl-cae`).

Known dependency subnets:

| Dependency | Canister | Subnet |
|---|---|---|
| VetKD test canister | `vrqyr-saaaa-aaaan-qzn4q-cai` | `cv73p-6v7zi-u67oy-7jc3h-qspsz-g5lrj-4fn7k-xrax3-thek2-sl46v-jae` (application) |
| EVM-RPC canister | `7hfb6-caaaa-aaaar-qadga-cai` | `pzp6e-ekpqk-3c5x7-2h6so-njoeq-mt45d-h3h6c-q3mxf-vpeq5-fk5o7-yae` (fiduciary / 34-node) |

Recommended first target: **`cv73p…`** (the VetKD canister's application subnet).
This makes the expensive VetKD call local. The EVM-RPC call becomes cross-subnet to
`pzp6e…`, which is cheap and should work from an application subnet.

`pzp6e…` is the fiduciary/threshold-signing subnet and is generally **not** open to
arbitrary canister deployment. Try it only if `cv73p…` does not work and you are
allowed to deploy there.

---

## 3. Deploy the new canister as `backend-v2`

```bash
cd /mnt/e/Repos/haven-aol

icp deploy backend-v2 -e ic \
  --subnet cv73p-6v7zi-u67oy-7jc3h-qspsz-g5lrj-4fn7k-xrax3-thek2-sl46v-jae \
  --identity mainnet-validation-20260506
```

The deploy:

- builds `src/backend/main.mo`
- creates a new canister on the selected application subnet
- installs the code
- applies the `backend-v2` settings, including:
  - `EVM_RPC_CANISTER_ID=7hfb6-caaaa-aaaar-qadga-cai`
  - `VETKD_CANISTER_ID=vrqyr-saaaa-aaaan-qzn4q-cai`
  - `VETKD_KEY_NAME=insecure_test_key_1`
  - `SCHNORR_KEY_NAME=key_1`

**Record the new canister ID printed by the deploy.** All clients must be updated to it.

---

## 4. Fund the new canister

The new canister starts with a small/default cycle balance. Top it up before warming
the caches — the Schnorr warmup forwards 35B cycles.

```bash
icp canister status backend-v2 -e ic --identity mainnet-validation-20260506
icp canister top-up backend-v2 --amount 5T -e ic --identity mainnet-validation-20260506
```

Check the balance and subnet afterward:

```bash
icp canister status backend-v2 -e ic --identity mainnet-validation-20260506
```

You should see a multi-trillion cycle balance and an application subnet id.

---

## 5. Warm the key caches

The new canister has empty VetKD/attestation caches. Run all four warmups once:

```bash
icp canister call backend-v2 warmupVetKDPublicKey '()' -e ic --identity mainnet-validation-20260506
icp canister call backend-v2 warmupVetKDPublicKeyV3 '()' -e ic --identity mainnet-validation-20260506
icp canister call backend-v2 warmupVetKDPublicKeyV4 '()' -e ic --identity mainnet-validation-20260506
icp canister call backend-v2 warmupAttestationPublicKey '()' -e ic --identity mainnet-validation-20260506
```

If any warmup fails with `not yet cached` or a cycle error, top up the canister and
retry. The caches survive upgrades but not canister deletion.

---

## 6. Verify the canister before touching clients

### Health and epoch

```bash
icp canister call backend-v2 health '()' -e ic --query --identity mainnet-validation-20260506
icp canister call backend-v2 getCurrentEpoch '()' -e ic --query --identity mainnet-validation-20260506
```

Expected: `("ok")` and a current epoch number.

### EVM-RPC path (the original failure)

```bash
icp canister call backend-v2 getMarketCap \
  '(variant { EthSepolia }, "0x52d139AD7EEb842e4c9Ce7EE0A6143fFdE89b73D", "0x8dce343A86Aa950d539eeE0e166AFfd0Ef515C0c")' \
  -e ic --identity mainnet-validation-20260506
```

Expected: a whole-reserve-unit market cap, or a gate-domain error such as
`InvalidOracle`. **Not** `IC0406` / `could not perform remote call`.

### Full v3 gate

Use the haven-cli wallet `0x37000ea882ff2B36D036D093F8c3c41d6e7A3828` (it holds
1,000,000 HVGATE on Sepolia) or any wallet holding at least 1 HVGATE:

```bash
icp canister call backend-v2 requestDecryptionKeyV3 '<record>' -e ic \
  --identity mainnet-validation-20260506
```

Expected: `variant { ok = record { encrypted_key = ...; verification_key = ... } }`.
The CLI's `haven decrypt` or the mobile app can produce the full signed record.

---

## 7. Update clients to the new canister ID

The new canister ID is different from `gny6k-fqaaa-aaaab-ag3ra-cai`. Update every
client that references the old ID.

### haven-cli

`haven_cli/services/haven_aol_icp.py` reads `HAVEN_AOL_CANISTER_ID` and defaults to
the old ID. Set the env var in the shell, systemd unit, or `.env`:

```bash
export HAVEN_AOL_CANISTER_ID=<NEW_CANISTER_ID>
export HAVEN_ICP_HOST=https://icp-api.io
```

For a durable change, update the default in `haven_aol_icp.py` and any docs/tests.

### haven-mobile

- `mobile-app/local.properties`:
  ```properties
  haven.aol.canisterId=<NEW_CANISTER_ID>
  haven.aol.icHost=https://ic0.app
  ```
- `.github/workflows/android.yml`: update the `haven.aol.canisterId` build property.
- `core-haven-aol/src/main/kotlin/haven/mobile/core/haven/aol/HavenAolDiModule.kt`:
  update the fallback from `gny6k-fqaaa-aaaab-ag3ra-cai` to the new ID.
- Rebuild the app.

### dsh-haven-aol

Update `canisterId:` in `cordis.patch.yml` (and any config/docs) to the new ID.

### Other references

Search the repos for the old ID and update docs, scripts, fixtures, and tests:

```bash
grep -rIn 'gny6k-fqaaa-aaaab-ag3ra-cai' .
```

---

## 8. End-to-end check

1. Mobile app: open a v3 item and unlock it. Expected: `UNLOCKING` → `READY`, no
   `Canister rejected requestDecryptionKeyV3`.
2. haven-cli: download/decrypt a v3 item with the funded wallet.
3. Check the canister logs/status for unexpected traps.

If the mobile wallet is **not** the CLI wallet, check its Sepolia HVGATE balance at
`0x52d139AD7EEb842e4c9Ce7EE0A6143fFdE89b73D`. If it holds 0, the canister will
correctly return `InsufficientBalance`; transfer at least 1 HVGATE (1e18 raw units).

---

## 9. Old canister

**Do not delete or modify the old canister.** It is not controlled by this runbook.
It will keep its cycles, data, and controllers; leave it as-is and ignore it. All new
traffic should point at the `backend-v2` canister ID.

---

## Troubleshooting

### `IC0406: could not perform remote call` on `getMarketCap`

The new canister is still making a call the subnet refuses to route. Check:

1. The canister's subnet is an **application** subnet, not verified application:
   ```bash
   icp canister status backend-v2 -e ic --identity mainnet-validation-20260506
   ```
2. `EVM_RPC_CANISTER_ID` is `7hfb6-caaaa-aaaar-qadga-cai`:
   ```bash
   icp canister settings show backend-v2 -e ic --identity mainnet-validation-20260506
   ```
3. If `cv73p…` still fails, try `pzp6e…` (the EVM-RPC canister's subnet) if you are
   allowed to deploy there.
4. If both fail, the issue is not the env var; inspect the canister's egress/routing
   and consider a different application subnet.

### `VetKDError: could not perform remote call` on a threshold-0 request

The VetKD call is not reaching `vrqyr-saaaa-aaaan-qzn4q-cai`. Check
`VETKD_CANISTER_ID` and `VETKD_KEY_NAME`. Colocating on `cv73p…` makes the VetKD call
local and is the preferred fix.

### `InsufficientBalance`

The requesting wallet holds less than the gate threshold on the gate chain. Fund the
wallet or use the funded CLI wallet `0x37000ea882ff2B36D036D093F8c3c41d6e7A3828`.

### `InvalidEpoch`

The client's epoch is in the future. Fetch `getCurrentEpoch` and use that value.

### `NonceAlreadyUsed`

The client reused a nonce. Generate a fresh nonce; the canister rejects replays.

### Canister out of cycles / `IC0503`

Top up cycles:

```bash
icp canister top-up backend-v2 --amount 1T -e ic --identity mainnet-validation-20260506
```

### Deploy says `backend-v2` already exists

Use a different new name (for example `backend-v3`) in `icp.yaml` and in the deploy
command. Do not fall back to `backend`; that name is not in the `ic` environment and
must not be pointed at the old canister.

---

## Quick reference

```bash
# Deploy the new canister on an application subnet
cd /mnt/e/Repos/haven-aol
icp deploy backend-v2 -e ic \
  --subnet cv73p-6v7zi-u67oy-7jc3h-qspsz-g5lrj-4fn7k-xrax3-thek2-sl46v-jae \
  --identity mainnet-validation-20260506

# Fund + warm
icp canister top-up backend-v2 --amount 5T -e ic --identity mainnet-validation-20260506
icp canister call backend-v2 warmupVetKDPublicKey '()' -e ic --identity mainnet-validation-20260506
icp canister call backend-v2 warmupVetKDPublicKeyV3 '()' -e ic --identity mainnet-validation-20260506
icp canister call backend-v2 warmupVetKDPublicKeyV4 '()' -e ic --identity mainnet-validation-20260506
icp canister call backend-v2 warmupAttestationPublicKey '()' -e ic --identity mainnet-validation-20260506

# Verify
icp canister call backend-v2 health '()' -e ic --query --identity mainnet-validation-20260506
icp canister call backend-v2 getMarketCap \
  '(variant { EthSepolia }, "0x52d139AD7EEb842e4c9Ce7EE0A6143fFdE89b73D", "0x8dce343A86Aa950d539eeE0e166AFfd0Ef515C0c")' \
  -e ic --identity mainnet-validation-20260506
```