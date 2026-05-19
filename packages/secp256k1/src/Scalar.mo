/// Scalar arithmetic modulo the secp256k1 curve order n.
///
/// n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
///
/// Used for operations on scalar multipliers (private keys, signature components).
import Constants "Constants";

module {

  let N : Nat = Constants.N;

  /// Reduce a natural number modulo n.
  public func fromNat(value : Nat) : Nat {
    value % N;
  };

  /// Return the Nat value.
  public func toNat(a : Nat) : Nat {
    a;
  };

  /// (a + b) mod n
  public func add(a : Nat, b : Nat) : Nat {
    (a + b) % N;
  };

  /// (a - b) mod n
  public func sub(a : Nat, b : Nat) : Nat {
    if (a >= b) {
      (a - b) % N;
    } else {
      (N - ((b - a) % N)) % N;
    };
  };

  /// (a * b) mod n
  public func mul(a : Nat, b : Nat) : Nat {
    (a * b) % N;
  };

  /// -a mod n
  public func neg(a : Nat) : Nat {
    if (a == 0) { 0 } else { N - (a % N) };
  };

  /// a⁻¹ mod n using Fermat's little theorem: a^(n-2) mod n
  public func inv(a : Nat) : Nat {
    assert a != 0;
    modPow(a, N - 2, N);
  };

  /// Modular exponentiation via square-and-multiply.
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
