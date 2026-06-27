# secp256k1 — Motoko ECDSA Public Key Recovery

Pure Motoko implementation of secp256k1 ECDSA public key recovery (`ecrecover`), providing the same functionality as Ethereum's `ecrecover` precompile (address `0x01`).

## Why?

On ICP, calling Ethereum's `ecrecover` via the EVM RPC canister takes 5-8 seconds due to HTTPS outcalls and consensus. This package computes the same result in <20ms as an inline synchronous call — **no network, no inter-canister calls, no async/await**.

## Installation

### Local path dependency (recommended during development)

```toml
# mops.toml
[dependencies]
secp256k1 = { path = "packages/secp256k1" }
```

### From mops registry (after publishing)

```toml
[dependencies]
secp256k1 = "0.1.0"
```

## Usage

```motoko
import Secp256k1 "mo:secp256k1";

// Recover Ethereum address from signature
// (you provide your own keccak256 implementation)
let result = Secp256k1.ecrecover(
  messageHash,   // 32-byte Blob (e.g. EIP-712 digest)
  v,             // Nat8: 27 or 28
  r,             // 32-byte Blob
  s,             // 32-byte Blob
  keccak256,     // (Blob) -> Blob
);

switch (result) {
  case (#ok(address)) {
    // address is a 20-byte Blob (Ethereum address)
  };
  case (#err(msg)) {
    // Handle error
  };
};
```

### Recover public key only (without address derivation)

```motoko
let result = Secp256k1.recoverPublicKey(hash, v, r, s);
// Returns #ok(Blob) — 65-byte uncompressed public key (0x04 || x || y)
```

## API

### `ecrecover(hash, v, r, s, keccak256) : { #ok : Blob; #err : Text }`

Recovers the 20-byte Ethereum address from an ECDSA signature. Equivalent to Solidity's `ecrecover(hash, v, r, s)`.

**Parameters:**
- `hash : Blob` — 32-byte message digest
- `v : Nat8` — Recovery ID (27 or 28)
- `r : Blob` — 32-byte signature r component
- `s : Blob` — 32-byte signature s component
- `keccak256 : (Blob) -> Blob` — Keccak-256 hash function

**Returns:** `{ #ok : Blob; #err : Text }` — 20-byte address on success

### `recoverPublicKey(hash, v, r, s) : { #ok : Blob; #err : Text }`

Recovers the uncompressed public key (65 bytes) without computing the Ethereum address.

## Architecture

```
src/
├── lib.mo          # Public API: ecrecover, recoverPublicKey
├── Field.mo        # Fp arithmetic (mod p, the field prime)
├── Scalar.mo       # Fn arithmetic (mod n, the curve order)
├── Point.mo        # Jacobian EC point operations
└── Constants.mo    # secp256k1 parameters (p, n, G, b)
```

### Design Decisions

- **Jacobian coordinates** — Avoids expensive modular inversions during point addition/doubling. Only one inversion at the end (toAffine).
- **Fermat's little theorem for inversions** — `a⁻¹ = a^(p-2) mod p`. Simple, constant-time-ish, correct.
- **keccak256 passed as parameter** — The canister already has keccak256; no need to duplicate it in the package.
- **Motoko `Nat` for bigints** — Arbitrary precision natively, no overflow possible.

## Performance

- **Instruction count:** ~100-200 million (well within ICP's 5B limit)
- **Wall time:** <20ms per recovery
- **Cycles cost:** ~0.1-0.2B cycles (~$0.00000013)

Compare to EVM RPC ecrecover: 5-8 seconds, ~10B cycles (~$0.000013).

## Testing

```bash
cd packages/secp256k1
mops test
```

### Generating test vectors

```bash
cd test
npm install ethers
node generate-vectors.mjs
```

## License

MIT
