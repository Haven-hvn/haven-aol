# V4 Bond curve pricing — haven-aol change checklist

Companion to the design spec at `/root/docs/planning/v4-bond-price-source.md`.
§1–8 below are the original Bond-mode plan (implemented by an agent);
§9 records the reserve-denomination revision; §10 records the Chainlink
removal. End state: the curve is the ONLY price source. Nothing here
changes the EIP-712 surface: `oracleAddress` is not a signed field
(`oracleAddress` stays `text` in Candid).

## 0. Conventions this plan follows

- Controller-gated admin surface uses the existing pattern:
  `Principal.isController(msg.caller)` + `Runtime.trap` (`main.mo:2762`,
  `:2794`).
- Caches are heap `Map`s with janitor eviction, not `stable` state
  (`marketCapCache` at `:329`, janitor at `:2789-2812`). The Bond config
  table below follows the same pattern — accept re-set-after-upgrade, and
  say so in the setter's doc comment.
- All EVM reads funnel through `ethCallRaw` + `abiWordAt` (`:1657-1708`,
  `:1638-1652`).

## 1. `src/backend/main.mo` — config table

Add after the oracle constants (`:273-282`):

- `BOND_ADDRESS_DEFAULT : Text = "0xc5a076cad94176c2996B32d8466Be1cE757FAa27"`
  — the mint.club V2 Bond is CREATE2-deployed on mainnets; confirm the
  address is identical on every mainnet chain in `chainToRpcServices`
  (`:399-412`) before deploy, and record the check in the deploy log.
  EthSepolia uses the separate testnet Bond `BOND_ADDRESS_SEPOLIA`
  (`0x8dce…C0c`, from the @mint.club/v2-sdk BOND registry).
- `type BondConfig = { bond : Text; wrappedNative : Text; nativeUsdFeed : Text }`
- Heap map `bondConfig : Map.Map<Text, BondConfig>` keyed by the same
  chain-key function used for `marketCapCacheKey` (`:1594`), plus a
  controller-gated `setBondConfig(chain : Chain, cfg : BondConfig)` setter
  (trap non-controllers, §0) and a `getBondConfig` query for operators.
- Seed defaults for all five chains at init (EthMainnet, BaseMainnet,
  ArbitrumOne, OptimismMainnet, EthSepolia — mainnets share the CREATE2
  address, Sepolia uses `BOND_ADDRESS_SEPOLIA`, each with its verified
  wrapped-native reserve). `setBondConfig` still overrides per chain.

## 2. `src/backend/main.mo` — readers

In the "Oracle + ERC20 reads" section (`:1626-1819`):

- `SELECTOR_PRICE_FOR_NEXT_MINT : Text = "840d885d"` and
  `SELECTOR_TOKEN_BOND : Text = "d9fe0eae"` next to the existing selectors
  (`:1628-1634`). Selectors computed via `viem.toFunctionSelector`; re-verify
  against a live node pre-deploy (acceptance criterion in the design spec).
- `fetchBondPriceForNextMint(chain, bond, token) : async Result.Result<Nat, Text>`
  — `ethCallRaw(chain, bond, "0x" # SELECTOR_PRICE_FOR_NEXT_MINT # pad(token))`
  then `abiWordAt(hex, 0)`; zero → `#err("…: zero next-mint price")`
  (fail-closed, never unlock on zero).
- `fetchBondReserve(chain, bond, token) : async Result.Result<Text, Text>` —
  `ethCallRaw` with `SELECTOR_TOKEN_BOND`; `tokenBond` returns a tuple whose
  index 4 is the reserve token (per the SDK's `computeUsdRateForBondToken`;
  only index 4 is load-bearing). Tuple decoding needs offset-chasing past
  the head words — extend `abiWordAt`-style helpers, do not hand-roll a full
  ABI decoder. Compare lowercase against `cfg.wrappedNative`; mismatch →
  `#err("…: unsupported reserve …")`.
- `getMarketCapUsdBond(chain, token, bond) : async Result.Result<Nat, Text>` —
  mirrors `getMarketCapUsd` (`:1792-1819`): cache lookup first (same
  `marketCapCache`, same 300s TTL — no new cache), then
  `fetchTokenDecimals` + `fetchTotalSupply` (reuse as-is) +
  `fetchBondPriceForNextMint` + `fetchBondReserve` +
  `fetchOraclePriceUsd8(chain, cfg.nativeUsdFeed)` (reuse, staleness policy
  included), then:

  ```
  capUsd8 = totalSupplyRaw × priceNextMintWei × reserveUsd8
            / 10^tokenDecimals / 10^reserveDecimals
  ```

  `reserveDecimals` comes from the `getDetail`-equivalent data already on
  hand — for v1 (wrapped-native reserves) it is a chain constant (18);
  assert rather than assume: read `decimals()` on the reserve token once and
  permanently cache it via the existing `tokenDecimalsCache` mechanism
  (`:1711-1732`).
- Branch point: `requestDecryptionKeyV4` Step D (`:2179-2212`) and the public
  `getMarketCapUsd` (`:1792`) both dispatch on
  `lower(oracleAddress) == lower(cfg.bond)` → Bond path, else Chainlink path.
  Keep the delete-then-fetch ordering (`:2186-2189`) on both paths.

## 3. `src/backend/main.mo` — comment updates (same diff, do not skip)

- `:251-282` (VetKD context / staleness rationale): note the reserve-feed
  leg and that Bond mode prices supply × marginal price.
- `:1238-1252` (`oracleAddress` field docs): Bond address selects Bond mode.
- `:2086-2094` (Step A/D overview): add the dispatch rule in one line.

## 4. `src/backend/backend.did` — comments only

- `:172-176` (v4 derivation comment): `oracleAddress` is "a Chainlink
  aggregator, or the chain's Bond contract to select curve pricing".
- `:219-223` (`getMarketCapUsd` comment): same widening. No signature change:
  `(Chain, text, text)` already carries `(chain, token, oracleAddress)`.

## 5. `packages/typescript/src/v4.ts` + `src/test/v4.test.ts`

- Widen the `oracleAddress` doc comment (`v4.ts:136-137`): Chainlink proxy
  *or* chain Bond address (Bond mode).
- Add `BOND_ADDRESSES : Record<string, string>` (mirror the dapp's
  `BOND_ADDRESS_HINTS` in `haven-dapp/src/lib/v4/market-cap.ts:51-54`) plus
  `isBondModeAddress(chainKey, addr)` helper; export both from `index.ts`
  if `ORACLE_PRICE_DECIMALS` is the export-bar precedent (`index.ts:54`).
- Tests: Bond-mode address classification vectors (checksummed, lowercase,
  non-Bond), and a constant-parity test against the dapp hints + canister
  default (same style as the existing oracle-constants test at
  `v4.test.ts:97-100`).

## 6. `packages/python/src/haven_aol/v4.py` + `tests/test_haven_aol_v4.py`

- Same doc-comment widening (`v4.py:170-171`) and a `is_bond_mode_address`
  helper with `BOND_ADDRESSES`; parity test next to the constants test
  (`test_haven_aol_v4.py:67-68`). No behavior change: the SDK performs no
  oracle calls (`v4.py:25`).

## 7. `tests/` — vectors

- `tests/fixtures/derivation-v4-vectors.json`: **no change** — derivation
  keys on `(chain, tokenAddress, threshold, effectiveEpoch, marketCapTarget)`
  and `oracleAddress` is not in the context. State this in the PR.
- Add Bond-mode cases to `tests/integration.test.mjs` (live-fork style,
  following whatever v4 coverage exists there) or `mainnet-smoke.sh`:
  bonded token with Bond-as-oracle opens past its rung; wrong-reserve token
  fails closed. (`mainnet-smoke.sh` M12/M12b now pin ArbitrumOne default +
  Sepolia testnet distinction instead of the old null case.)

## 8. Deploy order

1. Deploy canister with five-chain config; verify selectors + per-chain
   Bond/ether addresses (mainnet CREATE2 sameness, Sepolia testnet
   distinction) in the deploy log.
2. `setBondConfig` for any further chains (or Bond upgrades) via controller
   proposal.
3. Dapp wizard ships the same train (seals whole-ETH targets) — see the
   shipping constraint in the design spec §5. Neither window may exist.

## 9. Amendment (implemented): reserve-denominated targets, no USD feed

Supersedes the feed-based pricing in §2 and the "no Candid change" claim
in the header. Bond mode prices natively in reserve units — `marketCapTarget`
means whole reserve units (whole ETH for v1 native-reserve tokens) on that
path, whole USD in Chainlink mode. No `latestRoundData()` anywhere on the
Bond path: 3 `eth_call`s per warm refresh (tokenBond probe + supply +
price; both decimals legs permanently cached), zero oracle failure modes.

Candid deltas (v4 unreleased — no live clients to migrate):
- `BondConfig` loses `nativeUsdFeed` (now `{ bond; wrappedNative }`);
  compiled-in EthMainnet/BaseMainnet defaults drop the feed addresses;
  `setBondConfig` validation drops a block.
- `getMarketCapUsd(chain, text, text)` → `getMarketCap(chain, text, text)`,
  returning whole target units (USD in Chainlink mode, reserve units in
  Bond mode). `smoke.sh` M13 + trailing NOTE updated (stale-feed case deleted).

`main.mo` mechanics (all heap state — no stable migration):
- Burst cache namespaced by mode (`chain|token|bond` vs `chain|token|feed`);
  without this the two legs would read each other's units. Entries carry
  their scale (`{ capScaled; scaleDecimals; fetchedAt }`).
- `tokenDecimalsCache` split onto its own key (`tokenDecimalsCacheKey`);
  it previously reused the cap-cache key function.
- `getMarketCapUsdBondInternal` → `getMarketCapBondInternal`, returning
  `{ capReserveWei; reserveDecimals }`; Step D re-reads the just-recorded
  cache row so the scale travels with the value, then compares
  `capScaled >= marketCapTarget × 10^scaleDecimals` and reports
  `MarketCapNotReached.actual` in whole target units.
- `MAX_ORACLE_STALENESS_SECONDS` retained — Chainlink-mode policy only.

Verified: `mops check src/backend/main.mo` clean (pre-existing warnings
only); TS suite 96/96; Python v3+v4 suites 95/95 (`test_haven_aol.py`
fails to collect — pre-existing, needs the `haven_aol_vetkeys` native
extension, unrelated to this change).

## 10. Amendment (implemented): Chainlink removal — curve-only pricing

The Chainlink leg is deleted, not deprecated. v4 is mint.club-only;
`oracleAddress` is a Bond pin (fail-closed otherwise), `marketCapTarget`
is whole reserve units, always.

`src/backend/main.mo` (heap-only state throughout — no stable migration):
- Deleted: `fetchOraclePriceUsd8`, `SELECTOR_LATEST_ROUND_DATA`,
  `ORACLE_PRICE_DECIMALS`, `MAX_ORACLE_STALENESS_SECONDS`,
  `getMarketCapUsdInternal` (the entire Chainlink leg).
- `getMarketCapBondInternal` → `getMarketCapInternal` (single path).
- Cache de-namespaced to `chain|token` (one unit exists — nothing to
  namespace); entry keeps `{ capScaled; scaleDecimals }` (reserve-wei /
  reserve decimals).
- `isBondMode` → `isBondOracle`: the check is now a pin, not a dispatch.
  Step D and `getMarketCap` reject non-Bond oracles with `#InvalidOracle`
  / `#err` before any chain read.
- Comments: type docs, Step D header, `MarketCapNotReached` (reserve units
  always), `#InvalidOracle` (non-Bond oracle, bad reserve, failed probe).

Candid (`backend.did`, comments + two renames, v4 unreleased):
- `getMarketCapUsd` → `getMarketCap` (kept 3-arg: oracle pin enforced).
- `BondConfig` field removal (from §9) stands.

SDKs (TS + Python):
- `ORACLE_PRICE_DECIMALS` export deleted (`v4`, `index`/`__init__`,
  both test files); `derivation-v4-vectors.json` loses
  `constants.oraclePriceDecimals` (one-line diff).
- `isBondModeAddress` → `isBondAddress` (TS), `is_bond_mode_address` →
  `is_bond_address` (Python): check, not classifier.
- `marketCapTarget` docs: whole reserve units, always.

Verified: `mops check` clean; TS rebuilt from source 96/96; Python v3+v4
95/95 (`test_haven_aol.py` collection still needs `haven_aol_vetkeys` —
pre-existing). `mainnet-smoke.sh` needed no Chainlink edits (M13 already
Bond-pinned).
