import {
  TransportSecretKey,
  EncryptedVetKey,
  DerivedPublicKey,
  IbeCiphertext,
  VetKey,
} from "@dfinity/vetkeys";

/** Generate an ephemeral transport key pair for VetKD. */
export function createTransportKeyPair(): {
  secretKey: TransportSecretKey;
  publicKey: Uint8Array;
} {
  const secretKey = TransportSecretKey.random();
  const publicKey = secretKey.publicKeyBytes();
  return { secretKey, publicKey };
}

/**
 * Decrypt and verify the encrypted VetKD key returned by the canister.
 */
export function recoverVetKey(
  encryptedKeyBytes: Uint8Array,
  transportSecretKey: TransportSecretKey,
  verificationKey: Uint8Array,
  derivationInput: Uint8Array,
): VetKey {
  const dpk = DerivedPublicKey.deserialize(verificationKey);
  const encryptedVetKey = EncryptedVetKey.deserialize(encryptedKeyBytes);
  return encryptedVetKey.decryptAndVerify(transportSecretKey, dpk, derivationInput);
}

/** Base64 decode (standard RFC 4648 §4). */
function base64Decode(b64: string): Uint8Array {
  // Works in both Node.js and browsers
  if (typeof Buffer !== "undefined") {
    return new Uint8Array(Buffer.from(b64, "base64"));
  }
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/**
 * IBE-decrypt the AES key from the gate metadata's encryptedAesKey field.
 */
export function ibeDecryptAesKey(
  encryptedAesKeyBase64: string,
  vetKey: VetKey,
): Uint8Array {
  const ciphertextBytes = base64Decode(encryptedAesKeyBase64);
  const ibeCiphertext = IbeCiphertext.deserialize(ciphertextBytes);
  return ibeCiphertext.decrypt(vetKey);
}

/** Copy Uint8Array to a fresh ArrayBuffer (avoids SharedArrayBuffer type issues). */
function toArrayBuffer(u: Uint8Array): ArrayBuffer {
  const buf = new ArrayBuffer(u.length);
  new Uint8Array(buf).set(u);
  return buf;
}

/**
 * AES-256-GCM decrypt. Input format: [12-byte IV][ciphertext + auth tag].
 */
export async function decryptFile(
  encryptedBytes: Uint8Array,
  aesKey: Uint8Array,
): Promise<Uint8Array> {
  if (encryptedBytes.length < 12) {
    throw new Error("Encrypted data too short (missing IV)");
  }
  const iv = encryptedBytes.slice(0, 12);
  const ciphertext = encryptedBytes.slice(12);

  const key = await crypto.subtle.importKey(
    "raw",
    toArrayBuffer(aesKey),
    { name: "AES-GCM" },
    false,
    ["decrypt"],
  );

  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: toArrayBuffer(iv) },
    key,
    toArrayBuffer(ciphertext),
  );

  return new Uint8Array(plaintext);
}
