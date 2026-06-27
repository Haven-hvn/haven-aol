/// Finite field arithmetic modulo the secp256k1 field prime p.
///
/// p = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
///   = 2²⁵⁶ - 2³² - 977
///
/// All values are represented as Nat in [0, p-1].
/// Motoko's Nat is arbitrary-precision, so no overflow is possible.
import Constants "Constants";

module {

  let P : Nat = Constants.P;

  /// Reduce a natural number modulo p.
  public func fromNat(n : Nat) : Nat {
    n % P;
  };

  /// Return the Nat value (identity; included for API symmetry).
  public func toNat(a : Nat) : Nat {
    a;
  };

  /// (a + b) mod p
  public func add(a : Nat, b : Nat) : Nat {
    (a + b) % P;
  };

  /// (a - b) mod p
  public func sub(a : Nat, b : Nat) : Nat {
    if (a >= b) {
      (a - b) % P;
    } else {
      (P - ((b - a) % P)) % P;
    };
  };

  /// (a * b) mod p
  public func mul(a : Nat, b : Nat) : Nat {
    (a * b) % P;
  };

  /// -a mod p
  public func neg(a : Nat) : Nat {
    if (a == 0) { 0 } else { P - (a % P) };
  };

  /// a⁻¹ mod p using Fermat's little theorem: a^(p-2) mod p
  public func inv(a : Nat) : Nat {
    assert a != 0;
    modPow(a, P - 2, P);
  };

  /// Square root mod p, or null if a is not a quadratic residue.
  /// For secp256k1, p ≡ 3 (mod 4), so sqrt(a) = a^((p+1)/4) mod p.
  public func sqrt(a : Nat) : ?Nat {
    let reduced = a % P;
    if (reduced == 0) return ?0;
    let candidate = modPow(reduced, (P + 1) / 4, P);
    if ((candidate * candidate) % P == reduced) {
      ?candidate;
    } else {
      null;
    };
  };

  /// Modular exponentiation via square-and-multiply.
  /// Computes base^exp mod modulus.
  public func modPow(base : Nat, exp : Nat, modulus : Nat) : Nat {
    if (modulus == 1) return 0;
    var result : Nat = 1;
    var b = base % modulus;
    var e = exp;
    while (e > 0) {
      if (e % 2 == 1) {
        result := (result * b) % modulus;
      };
      e := e / 2;
      b := (b * b) % modulus;
    };
    result;
  };
};
