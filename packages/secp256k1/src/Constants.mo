/// secp256k1 curve constants.
///
/// Curve equation: y² = x³ + 7 (mod p)
/// Field prime p = 2²⁵⁶ - 2³² - 977
/// Curve order n (number of points on the curve)
/// Generator point G
module {

  /// Field prime: p = 2²⁵⁶ - 2³² - 977
  public let P : Nat = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

  /// Curve order (number of points)
  public let N : Nat = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

  /// Curve parameter b (y² = x³ + b)
  public let B : Nat = 7;

  /// Generator point x-coordinate
  public let Gx : Nat = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;

  /// Generator point y-coordinate
  public let Gy : Nat = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
};
