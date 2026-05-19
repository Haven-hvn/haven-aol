/// secp256k1 ECDSA public key recovery (ecrecover) for Motoko.
///
/// Implements the Ethereum `ecrecover` precompile logic:
///   Given a 32-byte message hash and an ECDSA signature (v, r, s),
///   recover the signer's uncompressed public key, then derive the
///   20-byte Ethereum address via keccak256.
///
/// This replaces the need for an EVM RPC call to address 0x01.
import Nat8 "mo:core/Nat8";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Field "Field";
import Scalar "Scalar";
import Point "Point";
import Constants "Constants";

module {

  /// Recover the uncompressed public key (65 bytes: 0x04 || x || y)
  /// from a message hash and ECDSA signature.
  ///
  /// Parameters:
  ///   hash : Blob — 32-byte message digest (e.g. EIP-712 digest)
  ///   v    : Nat8 — recovery ID (27 or 28, per Ethereum convention)
  ///   r    : Blob — 32-byte signature r component
  ///   s    : Blob — 32-byte signature s component
  ///
  /// Returns:
  ///   #ok(Blob)  — 65-byte uncompressed public key
  ///   #err(Text) — error description
  public func recoverPublicKey(
    hash : Blob,
    v : Nat8,
    r : Blob,
    s : Blob,
  ) : { #ok : Blob; #err : Text } {
    // 1. Validate inputs
    if (hash.size() != 32) return #err("hash must be 32 bytes");
    if (r.size() != 32) return #err("r must be 32 bytes");
    if (s.size() != 32) return #err("s must be 32 bytes");
    if (v != 27 and v != 28) return #err("v must be 27 or 28");

    let recId : Nat = Nat8.toNat(v) - 27; // 0 or 1

    // 2. Convert r, s, hash to Nat
    let rN = blobToNat(r);
    let sN = blobToNat(s);
    let msgN = blobToNat(hash);

    // 3. Validate r, s ∈ [1, n-1]
    if (rN == 0 or rN >= Constants.N) return #err("r out of range");
    if (sN == 0 or sN >= Constants.N) return #err("s out of range");

    // 4. Compute R point from r and recovery ID
    // x-coordinate of R = r (for recId 0 or 1, we don't add n since r < n < p for secp256k1)
    let x = rN;

    // Compute y² = x³ + 7 (mod p)
    let x3 = Field.mul(Field.mul(x, x), x);
    let ySquared = Field.add(x3, Constants.B);

    // Compute y = sqrt(y²) mod p
    let ?ySqrt = Field.sqrt(ySquared) else return #err("invalid signature: no curve point for r");

    // Choose y parity based on recovery ID
    // recId 0 → y is even, recId 1 → y is odd
    let y = if ((ySqrt % 2) == recId) {
      ySqrt;
    } else {
      Field.neg(ySqrt);
    };

    // R = (x, y) on the curve
    let R = Point.fromAffine(x, y);

    // 5. Compute public key: Q = r⁻¹ * (s*R - msg*G)
    let rInv = Scalar.inv(rN);

    // s * R
    let sR = Point.mulScalar(R, sN);

    // msg * G
    let G = Point.fromAffine(Constants.Gx, Constants.Gy);
    let msgG = Point.mulScalar(G, msgN);

    // s*R - msg*G = s*R + (-(msg*G))
    let diff = Point.add(sR, Point.neg(msgG));

    // Q = r⁻¹ * (s*R - msg*G)
    let Q = Point.mulScalar(diff, rInv);

    if (Point.isInfinity(Q)) return #err("recovered point is at infinity");

    // 6. Encode as uncompressed point (0x04 || x[32] || y[32])
    let pubKeyBytes = Point.toUncompressed(Q);
    if (pubKeyBytes.size() == 0) return #err("failed to encode public key");

    #ok(pubKeyBytes);
  };

  /// Recover the Ethereum address (20 bytes) from a message hash and signature.
  /// Equivalent to Solidity's ecrecover(hash, v, r, s).
  ///
  /// The keccak256 function is passed in as a parameter since the canister
  /// already has its own implementation.
  ///
  /// Parameters:
  ///   hash      : Blob — 32-byte message digest
  ///   v         : Nat8 — recovery ID (27 or 28)
  ///   r         : Blob — 32-byte signature r component
  ///   s         : Blob — 32-byte signature s component
  ///   keccak256 : (Blob) -> Blob — keccak256 hash function
  ///
  /// Returns:
  ///   #ok(Blob)  — 20-byte Ethereum address
  ///   #err(Text) — error description
  public func ecrecover(
    hash : Blob,
    v : Nat8,
    r : Blob,
    s : Blob,
    keccak256 : (Blob) -> Blob,
  ) : { #ok : Blob; #err : Text } {
    switch (recoverPublicKey(hash, v, r, s)) {
      case (#err(msg)) { #err(msg) };
      case (#ok(pubKey)) {
        // pubKey is 65 bytes: 0x04 || x[32] || y[32]
        // Address = keccak256(x || y)[12..32]  (last 20 bytes of the hash)
        let pubKeyArray = Blob.toArray(pubKey);
        let xyBytes = Array.tabulate<Nat8>(64, func(i : Nat) : Nat8 = pubKeyArray[i + 1]);
        let hashed = keccak256(Blob.fromArray(xyBytes));
        let hashedArray = Blob.toArray(hashed);
        let address = Array.tabulate<Nat8>(20, func(i : Nat) : Nat8 = hashedArray[i + 12]);
        #ok(Blob.fromArray(address));
      };
    };
  };

  /// Convert a big-endian Blob to a Nat.
  func blobToNat(b : Blob) : Nat {
    let bytes = Blob.toArray(b);
    var result : Nat = 0;
    for (byte in bytes.vals()) {
      result := result * 256 + Nat8.toNat(byte);
    };
    result;
  };
};
