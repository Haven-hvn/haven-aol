/// Elliptic curve point operations on secp256k1 using Jacobian coordinates.
///
/// Jacobian representation: (X, Y, Z) corresponds to affine (X/Z², Y/Z³).
/// The point at infinity is represented as (_, _, 0).
///
/// Using Jacobian coordinates avoids expensive modular inversions during
/// point addition and doubling — only one inversion is needed at the end
/// when converting back to affine.
import Nat8 "mo:core/Nat8";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Field "Field";
import Constants "Constants";

module {

  /// Jacobian point representation.
  public type JPoint = {
    x : Nat;
    y : Nat;
    z : Nat;
  };

  /// Affine point representation.
  public type APoint = {
    x : Nat;
    y : Nat;
  };

  /// The point at infinity (identity element for EC addition).
  public let INFINITY : JPoint = { x = 0; y = 1; z = 0 };

  /// Create a Jacobian point from affine coordinates.
  public func fromAffine(ax : Nat, ay : Nat) : JPoint {
    { x = ax; y = ay; z = 1 };
  };

  /// Convert a Jacobian point to affine coordinates.
  /// Returns null for the point at infinity.
  public func toAffine(p : JPoint) : ?APoint {
    if (p.z == 0) return null;
    if (p.z == 1) return ?{ x = p.x; y = p.y };
    let zInv = Field.inv(p.z);
    let zInv2 = Field.mul(zInv, zInv);
    let zInv3 = Field.mul(zInv2, zInv);
    ?{
      x = Field.mul(p.x, zInv2);
      y = Field.mul(p.y, zInv3);
    };
  };

  /// Check if point is the identity (point at infinity).
  public func isInfinity(p : JPoint) : Bool {
    p.z == 0;
  };

  /// Point doubling in Jacobian coordinates.
  /// For secp256k1, curve parameter a = 0, which simplifies the formula.
  ///
  /// Formula (a=0):
  ///   S = 4 * X * Y²
  ///   M = 3 * X²
  ///   X' = M² - 2*S
  ///   Y' = M*(S - X') - 8*Y⁴
  ///   Z' = 2*Y*Z
  public func double(p : JPoint) : JPoint {
    if (p.z == 0) return p;
    if (p.y == 0) return INFINITY;

    let ysq = Field.mul(p.y, p.y);
    let s = Field.mul(Field.mul(4, Field.mul(p.x, ysq)), 1);
    let m = Field.mul(3, Field.mul(p.x, p.x));
    let x3 = Field.sub(Field.mul(m, m), Field.mul(2, s));
    let y3 = Field.sub(
      Field.mul(m, Field.sub(s, x3)),
      Field.mul(8, Field.mul(ysq, ysq)),
    );
    let z3 = Field.mul(2, Field.mul(p.y, p.z));
    { x = x3; y = y3; z = z3 };
  };

  /// Point addition in Jacobian coordinates.
  ///
  /// Handles special cases:
  /// - Either point is infinity → return the other
  /// - Points are equal → use doubling
  /// - Points are negations → return infinity
  public func add(p1 : JPoint, p2 : JPoint) : JPoint {
    if (p1.z == 0) return p2;
    if (p2.z == 0) return p1;

    let z1sq = Field.mul(p1.z, p1.z);
    let z2sq = Field.mul(p2.z, p2.z);
    let u1 = Field.mul(p1.x, z2sq);
    let u2 = Field.mul(p2.x, z1sq);
    let s1 = Field.mul(p1.y, Field.mul(p2.z, z2sq));
    let s2 = Field.mul(p2.y, Field.mul(p1.z, z1sq));

    if (u1 == u2) {
      if (s1 == s2) {
        return double(p1); // same point
      } else {
        return INFINITY; // point + (-point) = infinity
      };
    };

    let h = Field.sub(u2, u1);
    let r = Field.sub(s2, s1);
    let h2 = Field.mul(h, h);
    let h3 = Field.mul(h, h2);
    let u1h2 = Field.mul(u1, h2);

    let x3 = Field.sub(
      Field.sub(Field.mul(r, r), h3),
      Field.mul(2, u1h2),
    );
    let y3 = Field.sub(
      Field.mul(r, Field.sub(u1h2, x3)),
      Field.mul(s1, h3),
    );
    let z3 = Field.mul(h, Field.mul(p1.z, p2.z));

    { x = x3; y = y3; z = z3 };
  };

  /// Negate a point: -(X, Y, Z) = (X, -Y, Z)
  public func neg(p : JPoint) : JPoint {
    if (p.z == 0) return p;
    { x = p.x; y = Field.neg(p.y); z = p.z };
  };

  /// Scalar multiplication using double-and-add (left-to-right binary method).
  /// Computes k * P.
  public func mulScalar(p : JPoint, k : Nat) : JPoint {
    if (k == 0) return INFINITY;
    if (p.z == 0) return INFINITY;

    var result = INFINITY;
    var base = p;
    var scalar = k % Constants.N; // Reduce scalar modulo curve order

    while (scalar > 0) {
      if (scalar % 2 == 1) {
        result := add(result, base);
      };
      base := double(base);
      scalar := scalar / 2;
    };
    result;
  };

  /// Encode point as uncompressed public key (65 bytes: 0x04 || x[32] || y[32]).
  /// Returns empty blob for point at infinity.
  public func toUncompressed(p : JPoint) : Blob {
    let ?ap = toAffine(p) else return Blob.fromArray([]);
    let xBytes = natTo32Bytes(ap.x);
    let yBytes = natTo32Bytes(ap.y);
    let result = Array.tabulate<Nat8>(
      65,
      func(i : Nat) : Nat8 {
        if (i == 0) { 0x04 : Nat8 }
        else if (i <= 32) { xBytes[i - 1] }
        else { yBytes[i - 33] };
      },
    );
    Blob.fromArray(result);
  };

  /// Convert a Nat to a big-endian 32-byte array (zero-padded on the left).
  public func natTo32Bytes(n : Nat) : [Nat8] {
    let bytes = Array.tabulate<Nat8>(
      32,
      func(i : Nat) : Nat8 {
        // Byte at position i (big-endian): shift right by (31-i)*8 bits, take low byte
        let shift = (31 - i) * 8;
        let byte = (n / natPow2(shift)) % 256;
        Nat8.fromNat(byte);
      },
    );
    bytes;
  };

  /// Compute 2^n for Nat (used for byte extraction).
  func natPow2(n : Nat) : Nat {
    if (n == 0) return 1;
    var result : Nat = 1;
    var i : Nat = 0;
    while (i < n) {
      result *= 2;
      i += 1;
    };
    result;
  };
};
