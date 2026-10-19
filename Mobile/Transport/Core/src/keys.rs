use crate::error::{Code, Failure};
use russh::keys::{Algorithm, HashAlg, PrivateKey, PublicKey};
use std::sync::Arc;

/// What the key list shows (M8a): type, OpenSSH public line, `ssh-keygen -lf` fingerprint.
#[derive(Clone, Debug)]
pub struct KeyInfo {
    pub algorithm: String,
    pub public_key: String,
    pub fingerprint: String,
}

impl KeyInfo {
    pub fn of(key: &PublicKey) -> KeyInfo {
        KeyInfo {
            algorithm: key.algorithm().as_str().to_owned(),
            public_key: key.to_openssh().unwrap_or_default(),
            fingerprint: key.fingerprint(HashAlg::Sha256).to_string(),
        }
    }
}

/// A decrypted private key, parsed in Rust and never handed to Swift.
pub struct LoadedKey {
    pub key: Arc<PrivateKey>,
    pub info: KeyInfo,
}

impl LoadedKey {
    /// An OpenSSH private key file (`openssh-key-v1`: ED25519, ECDSA P-256/384/521, RSA; plain or with a
    /// passphrase), or a PEM/PKCS#8 file. DSA and other types are refused.
    pub fn parse(data: &[u8], passphrase: Option<&str>) -> Result<LoadedKey, Failure> {
        let text = std::str::from_utf8(data).map_err(|_| Failure::new(Code::InvalidKey, "not a text key file"))?;
        let key = if text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
            let key = PrivateKey::from_openssh(text).map_err(|e| Failure::new(Code::InvalidKey, e.to_string()))?;
            if key.is_encrypted() {
                let passphrase = passphrase.filter(|p| !p.is_empty())
                    .ok_or_else(|| Failure::new(Code::WrongPassphrase, "the key is encrypted"))?;
                key.decrypt(passphrase).map_err(|_| Failure::new(Code::WrongPassphrase, "the passphrase is wrong"))?
            } else {
                key
            }
        } else {
            russh::keys::decode_secret_key(text, passphrase).map_err(|e| match e {
                russh::keys::Error::KeyIsEncrypted => Failure::new(Code::WrongPassphrase, "the key is encrypted"),
                other => Failure::new(Code::InvalidKey, other.to_string()),
            })?
        };
        match key.algorithm() {
            Algorithm::Ed25519 | Algorithm::Ecdsa { .. } | Algorithm::Rsa { .. } => {}
            other => return Err(Failure::new(Code::Unsupported, format!("unsupported key type {}", other.as_str()))),
        }
        let info = KeyInfo::of(key.public_key());
        Ok(LoadedKey { key: Arc::new(key), info })
    }
}

/// Encodes an external signer's raw signature as the SSH signature blob for `algorithm`:
/// Ed25519 takes the 64 signature bytes, ECDSA the fixed-width r‖s (CryptoKit's rawRepresentation).
pub fn signature_blob(algorithm: &Algorithm, raw: &[u8]) -> Result<(String, Vec<u8>), Failure> {
    match algorithm {
        Algorithm::Ed25519 => {
            if raw.len() != 64 {
                return Err(Failure::new(Code::InvalidKey, "Ed25519 signatures are 64 bytes"));
            }
            Ok((algorithm.as_str().to_owned(), raw.to_vec()))
        }
        Algorithm::Ecdsa { curve } => {
            let width = match curve {
                russh::keys::EcdsaCurve::NistP256 => 32,
                russh::keys::EcdsaCurve::NistP384 => 48,
                russh::keys::EcdsaCurve::NistP521 => 66,
            };
            if raw.len() != width * 2 {
                return Err(Failure::new(Code::InvalidKey, "ECDSA signature has the wrong length"));
            }
            let mut blob = Vec::new();
            mpint(&mut blob, &raw[..width]);
            mpint(&mut blob, &raw[width..]);
            Ok((algorithm.as_str().to_owned(), blob))
        }
        other => Err(Failure::new(Code::Unsupported, format!("external signing for {} is unsupported", other.as_str()))),
    }
}

fn mpint(out: &mut Vec<u8>, magnitude: &[u8]) {
    let trimmed: &[u8] = {
        let start = magnitude.iter().position(|&b| b != 0).unwrap_or(magnitude.len());
        &magnitude[start..]
    };
    let pad = trimmed.first().is_some_and(|&b| b & 0x80 != 0);
    let length = trimmed.len() + usize::from(pad);
    out.extend_from_slice(&(length as u32).to_be_bytes());
    if pad {
        out.push(0);
    }
    out.extend_from_slice(trimmed);
}

pub fn ssh_string(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    out.extend_from_slice(bytes);
}
