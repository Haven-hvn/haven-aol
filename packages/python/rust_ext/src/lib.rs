use ic_management_canister_types::{VetKDCurve, VetKDKeyId};
use ic_vetkeys::{DerivedPublicKey, IbeCiphertext, IbeIdentity, IbeSeed, MasterPublicKey};
use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use rand::{CryptoRng, RngCore};

fn derive_verification_key_rs(
    key_name: &str,
    canister_id_bytes: &[u8],
    context: &[u8],
) -> Result<Vec<u8>, String> {
    let key_id = VetKDKeyId {
        curve: VetKDCurve::Bls12_381_G2,
        name: key_name.to_string(),
    };
    let master_key = MasterPublicKey::for_mainnet_key(&key_id)
        .ok_or_else(|| format!("Unknown key name: {key_name}"))?;
    let canister_key = master_key.derive_canister_key(canister_id_bytes);
    let derived_key = canister_key.derive_sub_key(context);
    Ok(derived_key.serialize())
}

/// Derive the VetKD verification key offline from the mainnet master public key.
#[pyfunction]
fn derive_verification_key(
    key_name: &str,
    canister_id_bytes: &[u8],
    context: &[u8],
) -> PyResult<Vec<u8>> {
    derive_verification_key_rs(key_name, canister_id_bytes, context)
        .map_err(PyValueError::new_err)
}

fn deserialize_derived_public_key_rs(bytes: &[u8]) -> Result<Vec<u8>, &'static str> {
    let dpk = DerivedPublicKey::deserialize(bytes).map_err(|_| "Invalid DerivedPublicKey bytes")?;
    Ok(dpk.serialize())
}

/// Deserialize a DerivedPublicKey from bytes (e.g. fetched from canister).
#[pyfunction]
fn deserialize_derived_public_key(bytes: &[u8]) -> PyResult<Vec<u8>> {
    deserialize_derived_public_key_rs(bytes).map_err(PyValueError::new_err)
}

fn ibe_encrypt_rs(
    derived_public_key_bytes: &[u8],
    identity_bytes: &[u8],
    plaintext: &[u8],
    rng: &mut (impl CryptoRng + RngCore),
) -> Result<Vec<u8>, &'static str> {
    let derived_key = DerivedPublicKey::deserialize(derived_public_key_bytes)
        .map_err(|_| "Invalid DerivedPublicKey bytes")?;
    let identity = IbeIdentity::from_bytes(identity_bytes);
    let seed = IbeSeed::random(rng);
    let ciphertext = IbeCiphertext::encrypt(&derived_key, &identity, plaintext, &seed);
    Ok(ciphertext.serialize())
}

/// IBE-encrypt plaintext using a derived public key and identity.
#[pyfunction]
fn ibe_encrypt(
    derived_public_key_bytes: &[u8],
    identity_bytes: &[u8],
    plaintext: &[u8],
) -> PyResult<Vec<u8>> {
    ibe_encrypt_rs(
        derived_public_key_bytes,
        identity_bytes,
        plaintext,
        &mut rand::thread_rng(),
    )
    .map_err(PyValueError::new_err)
}

#[pymodule]
fn haven_aol_vetkeys(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(derive_verification_key, m)?)?;
    m.add_function(wrap_pyfunction!(deserialize_derived_public_key, m)?)?;
    m.add_function(wrap_pyfunction!(ibe_encrypt, m)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::rngs::StdRng;
    use rand::SeedableRng;

    #[test]
    fn derive_key_1_deterministic() {
        let canister = [1u8; 10];
        let ctx = b"accessol_v1";
        let a = derive_verification_key_rs("key_1", &canister, ctx).expect("derive a");
        let b = derive_verification_key_rs("key_1", &canister, ctx).expect("derive b");
        assert!(!a.is_empty());
        assert_eq!(a, b);
    }

    #[test]
    fn derive_unknown_key_fails() {
        let err = derive_verification_key_rs("nonexistent_key", &[0u8; 10], b"ctx").unwrap_err();
        assert!(err.contains("nonexistent_key"));
    }

    #[test]
    fn deserialize_roundtrips_serialized_derived_key() {
        let derived = derive_verification_key_rs("key_1", &[2u8; 10], b"ctx").expect("derive");
        let again = deserialize_derived_public_key_rs(&derived).expect("deserialize");
        assert_eq!(derived, again);
    }

    #[test]
    fn deserialize_rejects_garbage() {
        let err = deserialize_derived_public_key_rs(&[0u8; 4]).unwrap_err();
        assert_eq!(err, "Invalid DerivedPublicKey bytes");
    }

    #[test]
    fn ibe_encrypt_produces_non_empty_ciphertext() {
        let derived = derive_verification_key_rs("key_1", &[3u8; 10], b"ctx").expect("derive");
        let mut rng = StdRng::seed_from_u64(42);
        let ct = ibe_encrypt_rs(&derived, b"id", b"hello", &mut rng).expect("encrypt");
        assert!(!ct.is_empty());
    }

    #[test]
    fn ibe_encrypt_rejects_invalid_derived_key_bytes() {
        let mut rng = StdRng::seed_from_u64(7);
        let err = ibe_encrypt_rs(&[0u8; 8], b"id", b"x", &mut rng).unwrap_err();
        assert_eq!(err, "Invalid DerivedPublicKey bytes");
    }
}
