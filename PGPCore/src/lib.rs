//! Thin JSON-over-C bridge around rPGP for the iOS mail client.
//!
//! One entry point: `pgpcore_call(request_json) -> response_json`.
//! Binary payloads travel as base64 inside the JSON.

use std::ffi::{c_char, CStr, CString};
use std::io::Cursor;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use pgp::composed::{
    ArmorOptions, CleartextSignedMessage, Deserializable, DetachedSignature, EncryptionCaps,
    KeyType, Message, MessageBuilder, SecretKeyParamsBuilder, SignedPublicKey, SignedSecretKey,
    SubkeyParamsBuilder,
};
use pgp::crypto::ecc_curve::ECCCurve;
use pgp::crypto::hash::HashAlgorithm;
use pgp::crypto::sym::SymmetricKeyAlgorithm;
use pgp::packet::{Signature, SignatureType};
use pgp::types::{CompressionAlgorithm, KeyDetails, Password, SigningKey, VerifyingKey};
use rand::thread_rng;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

type Res<T> = Result<T, String>;

fn e<E: std::fmt::Display>(err: E) -> String {
    err.to_string()
}

// ---------------------------------------------------------------- requests

#[derive(Deserialize)]
struct SecretRef {
    secret: String,
    #[serde(default)]
    passphrase: String,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Request {
    Generate {
        user_id: String,
        #[serde(default)]
        passphrase: String,
    },
    Inspect {
        data: String,
    },
    CheckPassphrase {
        secret: String,
        #[serde(default)]
        passphrase: String,
    },
    Encrypt {
        data: String,
        recipients: Vec<String>,
        signer: Option<SecretRef>,
    },
    Decrypt {
        data: String,
        #[serde(default)]
        secrets: Vec<SecretRef>,
        #[serde(default)]
        verifiers: Vec<String>,
    },
    SignDetached {
        data: String,
        signer: SecretRef,
    },
    VerifyDetached {
        data: String,
        signature: String,
        #[serde(default)]
        verifiers: Vec<String>,
    },
    VerifyCleartext {
        text: String,
        #[serde(default)]
        verifiers: Vec<String>,
    },
}

#[derive(Serialize)]
struct KeyInfo {
    fingerprint: String,
    key_id: String,
    user_ids: Vec<String>,
    is_secret: bool,
    created: u32,
    expires: Option<u64>,
    algorithm: String,
    can_encrypt: bool,
    revoked: bool,
    public_armored: String,
    armored: String,
}

#[derive(Serialize)]
struct SigInfo {
    /// "valid" | "invalid" | "unknown_key"
    status: &'static str,
    key_id: String,
    /// Fingerprint of the certificate (primary key) that verified the signature.
    signer_fingerprint: Option<String>,
    created: Option<u32>,
}

// ---------------------------------------------------------------- helpers

fn unb64(s: &str) -> Res<Vec<u8>> {
    B64.decode(s.as_bytes()).map_err(e)
}

fn parse_public(armored: &str) -> Res<SignedPublicKey> {
    let (key, _) = SignedPublicKey::from_reader_single(armored.as_bytes()).map_err(e)?;
    Ok(key)
}

fn parse_secret(armored: &str) -> Res<SignedSecretKey> {
    let (key, _) = SignedSecretKey::from_reader_single(armored.as_bytes()).map_err(e)?;
    Ok(key)
}

fn parse_publics(list: &[String]) -> Vec<SignedPublicKey> {
    list.iter().filter_map(|a| parse_public(a).ok()).collect()
}

fn is_revoked(sigs: &[Signature], kind: SignatureType) -> bool {
    sigs.iter().any(|s| s.typ() == Some(kind))
}

fn key_revoked(key: &SignedPublicKey) -> bool {
    is_revoked(&key.details.revocation_signatures, SignatureType::KeyRevocation)
}

fn kid(id: &pgp::types::KeyId) -> String {
    id.as_ref().iter().map(|b| format!("{:02X}", b)).collect()
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Expiry (unix seconds) of the primary key, from the newest user-id self signature.
fn key_expiry(key: &SignedPublicKey) -> Option<u64> {
    let created = key.primary_key.created_at().as_secs() as u64;
    let mut best: Option<(u32, Option<u64>)> = None;
    let sigs = key
        .details
        .users
        .iter()
        .flat_map(|u| u.signatures.iter())
        .chain(key.details.direct_signatures.iter());
    for sig in sigs {
        let sig_created = sig.created().map(|t| t.as_secs()).unwrap_or(0);
        let exp = sig
            .key_expiration_time()
            .map(|d| d.as_secs() as u64)
            .filter(|d| *d > 0)
            .map(|d| created + d);
        if best.map(|(c, _)| sig_created >= c).unwrap_or(true) {
            best = Some((sig_created, exp));
        }
    }
    best.and_then(|(_, exp)| exp)
}

enum EncKey<'a> {
    Primary(&'a SignedPublicKey),
    Sub(&'a pgp::composed::SignedPublicSubKey),
}

/// Pick the newest valid encryption-capable (sub)key of a certificate.
fn encryption_key(cert: &SignedPublicKey) -> Option<EncKey<'_>> {
    let now = now_secs();
    let mut best: Option<(u32, &pgp::composed::SignedPublicSubKey)> = None;
    for sub in &cert.public_subkeys {
        if !sub.key.algorithm().can_encrypt() {
            continue;
        }
        if is_revoked(&sub.signatures, SignatureType::SubkeyRevocation) {
            continue;
        }
        let binding = sub
            .signatures
            .iter()
            .filter(|s| s.typ() == Some(SignatureType::SubkeyBinding))
            .max_by_key(|s| s.created().map(|t| t.as_secs()).unwrap_or(0));
        let Some(binding) = binding else { continue };
        let flags = binding.key_flags();
        if !(flags.encrypt_comms() || flags.encrypt_storage()) {
            continue;
        }
        let created = sub.key.created_at().as_secs();
        if let Some(d) = binding.key_expiration_time() {
            let d = d.as_secs() as u64;
            if d > 0 && created as u64 + d < now {
                continue;
            }
        }
        if best.map(|(c, _)| created >= c).unwrap_or(true) {
            best = Some((created, sub));
        }
    }
    if let Some((_, sub)) = best {
        return Some(EncKey::Sub(sub));
    }
    if cert.primary_key.algorithm().can_encrypt() {
        let flagged = cert
            .details
            .users
            .iter()
            .flat_map(|u| u.signatures.iter())
            .any(|s| s.key_flags().encrypt_comms() || s.key_flags().encrypt_storage());
        if flagged {
            return Some(EncKey::Primary(cert));
        }
    }
    None
}

fn cert_usable(cert: &SignedPublicKey) -> Res<()> {
    if key_revoked(cert) {
        return Err(format!("key {:X} is revoked", cert.fingerprint()));
    }
    if let Some(exp) = key_expiry(cert) {
        if exp < now_secs() {
            return Err(format!("key {:X} is expired", cert.fingerprint()));
        }
    }
    Ok(())
}

fn key_info_public(key: &SignedPublicKey, is_secret: bool, armored: String) -> Res<KeyInfo> {
    let public_armored = key.to_armored_string(ArmorOptions::default()).map_err(e)?;
    Ok(KeyInfo {
        fingerprint: format!("{:X}", key.fingerprint()),
        key_id: kid(&key.legacy_key_id()),
        user_ids: key
            .details
            .users
            .iter()
            .map(|u| String::from_utf8_lossy(u.id.id()).into_owned())
            .collect(),
        is_secret,
        created: key.primary_key.created_at().as_secs(),
        expires: key_expiry(key),
        algorithm: format!("{:?}", key.primary_key.algorithm()),
        can_encrypt: encryption_key(key).is_some(),
        revoked: key_revoked(key),
        armored: if is_secret { armored } else { public_armored.clone() },
        public_armored,
    })
}

/// A secret key usable for signing: (key, is the primary).
fn with_signing_key<T>(
    secret: &SignedSecretKey,
    f: impl FnOnce(&dyn SigningKey) -> Res<T>,
) -> Res<T> {
    // Prefer a dedicated signing subkey, fall back to the primary key.
    for sub in &secret.secret_subkeys {
        if is_revoked(&sub.signatures, SignatureType::SubkeyRevocation) {
            continue;
        }
        let signs = sub.signatures.iter().any(|s| s.key_flags().sign());
        if signs && sub.key.algorithm().can_sign() {
            return f(&sub.key);
        }
    }
    f(&secret.primary_key)
}

/// Try to verify `check` against every (sub)key of every certificate.
enum VKey<'a> {
    Primary(&'a SignedPublicKey),
    Sub(&'a pgp::composed::SignedPublicSubKey),
}

impl VKey<'_> {
    fn verify_sig(&self, sig: &Signature, data: &[u8]) -> bool {
        match self {
            VKey::Primary(k) => sig.verify(*k, Cursor::new(data)).is_ok(),
            VKey::Sub(k) => sig.verify(*k, Cursor::new(data)).is_ok(),
        }
    }

    fn as_dyn(&self) -> &dyn VerifyingKey {
        match self {
            VKey::Primary(k) => *k,
            VKey::Sub(k) => *k,
        }
    }
}

fn find_verifier(
    certs: &[SignedPublicKey],
    check: impl Fn(VKey<'_>) -> bool,
) -> Option<String> {
    for cert in certs {
        if check(VKey::Primary(cert)) {
            return Some(format!("{:X}", cert.fingerprint()));
        }
        for sub in &cert.public_subkeys {
            if check(VKey::Sub(sub)) {
                return Some(format!("{:X}", cert.fingerprint()));
            }
        }
    }
    None
}

fn issuer_hex(sig: &Signature) -> String {
    if let Some(fp) = sig.issuer_fingerprint().first() {
        let hex = format!("{:X}", fp);
        // long key id = last 16 hex digits of a v4 fingerprint
        if hex.len() >= 16 {
            return hex[hex.len() - 16..].to_string();
        }
    }
    sig.issuer_key_id()
        .first()
        .map(|k| kid(k))
        .unwrap_or_default()
}

/// Does one of the certificates contain the key that issued this signature?
fn knows_issuer(certs: &[SignedPublicKey], sig: &Signature) -> bool {
    let id = issuer_hex(sig);
    if id.is_empty() {
        return false;
    }
    certs.iter().any(|c| {
        kid(&c.legacy_key_id()) == id
            || c.public_subkeys
                .iter()
                .any(|s| kid(&s.key.legacy_key_id()) == id)
    })
}

fn sig_info(sig: &Signature, certs: &[SignedPublicKey], verified: Option<String>) -> SigInfo {
    let status = match (&verified, knows_issuer(certs, sig)) {
        (Some(_), _) => "valid",
        (None, true) => "invalid",
        (None, false) => "unknown_key",
    };
    SigInfo {
        status,
        key_id: issuer_hex(sig),
        signer_fingerprint: verified,
        created: sig.created().map(|t| t.as_secs()),
    }
}

fn looks_armored(data: &[u8]) -> bool {
    let start = data
        .iter()
        .position(|b| !b.is_ascii_whitespace())
        .unwrap_or(0);
    data[start..].starts_with(b"-----BEGIN PGP")
}

// ---------------------------------------------------------------- operations

fn generate(user_id: String, passphrase: String) -> Res<Value> {
    let pw = if passphrase.is_empty() { None } else { Some(passphrase) };
    let mut sub = SubkeyParamsBuilder::default();
    sub.key_type(KeyType::ECDH(ECCCurve::Curve25519Legacy))
        .can_sign(false)
        .can_encrypt(EncryptionCaps::All)
        .can_authenticate(false)
        .passphrase(pw.clone());
    let mut params = SecretKeyParamsBuilder::default();
    params
        .key_type(KeyType::Ed25519Legacy)
        .can_certify(true)
        .can_sign(true)
        .can_encrypt(EncryptionCaps::None)
        .primary_user_id(user_id)
        .passphrase(pw)
        .subkeys(vec![sub.build().map_err(e)?]);
    let secret = params
        .build()
        .map_err(e)?
        .generate(thread_rng())
        .map_err(e)?;
    let armored = secret.to_armored_string(ArmorOptions::default()).map_err(e)?;
    let public = secret.to_public_key();
    let info = key_info_public(&public, true, armored)?;
    Ok(json!({ "key": info }))
}

fn inspect(data: String) -> Res<Value> {
    let bytes = unb64(&data)?;
    let mut keys: Vec<KeyInfo> = Vec::new();

    if let Ok((iter, _)) = SignedSecretKey::from_reader_many(Cursor::new(bytes.clone())) {
        for key in iter.flatten() {
            let armored = key.to_armored_string(ArmorOptions::default()).map_err(e)?;
            keys.push(key_info_public(&key.to_public_key(), true, armored)?);
        }
    }
    if keys.is_empty() {
        if let Ok((iter, _)) = SignedPublicKey::from_reader_many(Cursor::new(bytes)) {
            for key in iter.flatten() {
                keys.push(key_info_public(&key, false, String::new())?);
            }
        }
    }
    if keys.is_empty() {
        return Err("no OpenPGP key found".into());
    }
    Ok(json!({ "keys": keys }))
}

fn check_passphrase(secret: String, passphrase: String) -> Res<Value> {
    let key = parse_secret(&secret)?;
    let pw = Password::from(passphrase);
    let ok = key.primary_key.unlock(&pw, |_, _| Ok(())).is_ok();
    Ok(json!({ "valid": ok }))
}

fn encrypt(data: String, recipients: Vec<String>, signer: Option<SecretRef>) -> Res<Value> {
    let plain = unb64(&data)?;
    if recipients.is_empty() {
        return Err("no recipients".into());
    }
    let certs: Vec<SignedPublicKey> = recipients
        .iter()
        .map(|r| parse_public(r))
        .collect::<Res<_>>()?;

    let signer_key = match &signer {
        Some(s) => Some((parse_secret(&s.secret)?, Password::from(s.passphrase.clone()))),
        None => None,
    };

    let mut builder = MessageBuilder::from_bytes("", plain)
        .seipd_v1(thread_rng(), SymmetricKeyAlgorithm::AES256);
    builder.compression(CompressionAlgorithm::ZLIB);

    for cert in &certs {
        cert_usable(cert)?;
        match encryption_key(cert) {
            Some(EncKey::Sub(k)) => builder.encrypt_to_key(thread_rng(), k).map_err(e)?,
            Some(EncKey::Primary(k)) => builder.encrypt_to_key(thread_rng(), k).map_err(e)?,
            None => {
                return Err(format!(
                    "key {:X} has no usable encryption key",
                    cert.fingerprint()
                ))
            }
        };
    }

    let armored = match &signer_key {
        Some((secret, pw)) => with_signing_key(secret, |key| {
            // `key` only lives inside this closure, so finish the message here.
            let mut b = builder;
            b.sign(key, Password::from(&pw.read()[..]), HashAlgorithm::Sha256);
            b.to_armored_string(thread_rng(), ArmorOptions::default())
                .map_err(e)
        })?,
        None => builder
            .to_armored_string(thread_rng(), ArmorOptions::default())
            .map_err(e)?,
    };
    Ok(json!({ "armored": armored }))
}

fn decrypt(data: String, secrets: Vec<SecretRef>, verifiers: Vec<String>) -> Res<Value> {
    let bytes = unb64(&data)?;
    let certs = parse_publics(&verifiers);

    let keys: Vec<(SignedSecretKey, Password)> = secrets
        .iter()
        .filter_map(|s| {
            parse_secret(&s.secret)
                .ok()
                .map(|k| (k, Password::from(s.passphrase.clone())))
        })
        .collect();

    let mut msg = if looks_armored(&bytes) {
        Message::from_armor(Cursor::new(&bytes[..])).map_err(e)?.0
    } else {
        Message::from_bytes(Cursor::new(&bytes[..])).map_err(e)?
    };

    let was_encrypted = msg.is_encrypted();
    if was_encrypted {
        if keys.is_empty() {
            return Err("no secret key available".into());
        }
        let pws: Vec<&Password> = keys.iter().map(|(_, p)| p).collect();
        let sks: Vec<&SignedSecretKey> = keys.iter().map(|(k, _)| k).collect();
        msg = msg.decrypt_with_keys(pws, sks).map_err(e)?;
    }
    for _ in 0..4 {
        if msg.is_compressed() {
            msg = msg.decompress().map_err(e)?;
        }
    }
    let plain = msg.as_data_vec().map_err(e)?;

    let mut signatures: Vec<SigInfo> = Vec::new();
    if let Message::Signed { reader, .. } = &msg {
        for i in 0..reader.num_signatures() {
            let Some(sig) = reader.signature(i) else { continue };
            let verified =
                find_verifier(&certs, |k| msg.verify_nested_explicit(i, k.as_dyn()).is_ok());
            signatures.push(sig_info(sig, &certs, verified));
        }
    }

    Ok(json!({
        "data": B64.encode(plain),
        "was_encrypted": was_encrypted,
        "signatures": signatures,
    }))
}

fn sign_detached(data: String, signer: SecretRef) -> Res<Value> {
    let bytes = unb64(&data)?;
    let secret = parse_secret(&signer.secret)?;
    let pw = Password::from(signer.passphrase);
    let armored = with_signing_key(&secret, |key| {
        let sig = DetachedSignature::sign_binary_data(
            thread_rng(),
            &Box::new(key),
            &pw,
            HashAlgorithm::Sha256,
            Cursor::new(&bytes[..]),
        )
        .map_err(e)?;
        sig.to_armored_string(ArmorOptions::default()).map_err(e)
    })?;
    Ok(json!({ "armored": armored, "micalg": "pgp-sha256" }))
}

fn verify_detached(data: String, signature: String, verifiers: Vec<String>) -> Res<Value> {
    let bytes = unb64(&data)?;
    let sig_bytes = unb64(&signature)?;
    let certs = parse_publics(&verifiers);
    let (sig, _) = DetachedSignature::from_reader_single(Cursor::new(sig_bytes)).map_err(e)?;
    let verified = find_verifier(&certs, |k| k.verify_sig(&sig.signature, &bytes));
    Ok(json!({ "signatures": [sig_info(&sig.signature, &certs, verified)] }))
}

fn verify_cleartext(text: String, verifiers: Vec<String>) -> Res<Value> {
    let certs = parse_publics(&verifiers);
    let (msg, _) = CleartextSignedMessage::from_string(&text).map_err(e)?;
    let mut signatures = Vec::new();
    for sig in msg.signatures() {
        let signed = msg.signed_text();
        let verified = find_verifier(&certs, |k| k.verify_sig(sig, signed.as_bytes()));
        signatures.push(sig_info(sig, &certs, verified));
    }
    Ok(json!({ "text": msg.text(), "signatures": signatures }))
}

fn dispatch(req: Request) -> Res<Value> {
    match req {
        Request::Generate { user_id, passphrase } => generate(user_id, passphrase),
        Request::Inspect { data } => inspect(data),
        Request::CheckPassphrase { secret, passphrase } => check_passphrase(secret, passphrase),
        Request::Encrypt { data, recipients, signer } => encrypt(data, recipients, signer),
        Request::Decrypt { data, secrets, verifiers } => decrypt(data, secrets, verifiers),
        Request::SignDetached { data, signer } => sign_detached(data, signer),
        Request::VerifyDetached { data, signature, verifiers } => {
            verify_detached(data, signature, verifiers)
        }
        Request::VerifyCleartext { text, verifiers } => verify_cleartext(text, verifiers),
    }
}

/// Run one JSON request and return the JSON response.
pub fn call(request: &str) -> String {
    let result = serde_json::from_str::<Request>(request)
        .map_err(e)
        .and_then(dispatch);
    let value = match result {
        Ok(Value::Object(mut map)) => {
            map.insert("ok".into(), Value::Bool(true));
            Value::Object(map)
        }
        Ok(other) => json!({ "ok": true, "value": other }),
        Err(message) => json!({ "ok": false, "error": message }),
    };
    value.to_string()
}

// ---------------------------------------------------------------- C ABI

/// # Safety
/// `request` must be a valid NUL-terminated UTF-8 string. The returned pointer
/// must be released with `pgpcore_free`.
#[no_mangle]
pub unsafe extern "C" fn pgpcore_call(request: *const c_char) -> *mut c_char {
    let response = if request.is_null() {
        json!({ "ok": false, "error": "null request" }).to_string()
    } else {
        match CStr::from_ptr(request).to_str() {
            Ok(s) => std::panic::catch_unwind(|| call(s)).unwrap_or_else(|_| {
                json!({ "ok": false, "error": "internal error" }).to_string()
            }),
            Err(_) => json!({ "ok": false, "error": "request is not UTF-8" }).to_string(),
        }
    };
    CString::new(response)
        .unwrap_or_else(|_| CString::new("{\"ok\":false,\"error\":\"encoding\"}").unwrap())
        .into_raw()
}

/// # Safety
/// `ptr` must come from `pgpcore_call` and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn pgpcore_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

// ---------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;

    fn run(v: Value) -> Value {
        serde_json::from_str(&call(&v.to_string())).unwrap()
    }

    fn gen(uid: &str, pw: &str) -> Value {
        let r = run(json!({"op": "generate", "user_id": uid, "passphrase": pw}));
        assert_eq!(r["ok"], true, "{r}");
        r["key"].clone()
    }

    #[test]
    fn roundtrip_encrypt_sign() {
        let alice = gen("Alice <alice@example.org>", "geheim");
        let bob = gen("Bob <bob@example.org>", "");
        assert_eq!(alice["can_encrypt"], true);
        assert_eq!(alice["is_secret"], true);

        let enc = run(json!({
            "op": "encrypt",
            "data": B64.encode("Hallo Bob äöü"),
            "recipients": [bob["public_armored"], alice["public_armored"]],
            "signer": {"secret": alice["armored"], "passphrase": "geheim"},
        }));
        assert_eq!(enc["ok"], true, "{enc}");
        let armored = enc["armored"].as_str().unwrap();

        let dec = run(json!({
            "op": "decrypt",
            "data": B64.encode(armored),
            "secrets": [{"secret": bob["armored"], "passphrase": ""}],
            "verifiers": [alice["public_armored"]],
        }));
        assert_eq!(dec["ok"], true, "{dec}");
        assert_eq!(dec["was_encrypted"], true);
        let plain = B64.decode(dec["data"].as_str().unwrap()).unwrap();
        assert_eq!(String::from_utf8(plain).unwrap(), "Hallo Bob äöü");
        assert_eq!(dec["signatures"][0]["status"], "valid", "{dec}");
        assert_eq!(dec["signatures"][0]["signer_fingerprint"], alice["fingerprint"]);

        // Without the sender's certificate the signature is merely unknown.
        let dec2 = run(json!({
            "op": "decrypt",
            "data": B64.encode(armored),
            "secrets": [{"secret": alice["armored"], "passphrase": "geheim"}],
        }));
        assert_eq!(dec2["ok"], true, "{dec2}");
        assert_eq!(dec2["signatures"][0]["status"], "unknown_key");

        // Wrong passphrase must fail.
        let dec3 = run(json!({
            "op": "decrypt",
            "data": B64.encode(armored),
            "secrets": [{"secret": alice["armored"], "passphrase": "falsch"}],
        }));
        assert_eq!(dec3["ok"], false);
    }

    #[test]
    fn detached_signature() {
        let alice = gen("Alice <alice@example.org>", "pw");
        let body = "Content-Type: text/plain\r\n\r\nHallo\r\n";
        let sig = run(json!({
            "op": "sign_detached",
            "data": B64.encode(body),
            "signer": {"secret": alice["armored"], "passphrase": "pw"},
        }));
        assert_eq!(sig["ok"], true, "{sig}");
        let armored = sig["armored"].as_str().unwrap();

        let ok = run(json!({
            "op": "verify_detached",
            "data": B64.encode(body),
            "signature": B64.encode(armored),
            "verifiers": [alice["public_armored"]],
        }));
        assert_eq!(ok["signatures"][0]["status"], "valid", "{ok}");

        let bad = run(json!({
            "op": "verify_detached",
            "data": B64.encode("manipuliert"),
            "signature": B64.encode(armored),
            "verifiers": [alice["public_armored"]],
        }));
        assert_eq!(bad["signatures"][0]["status"], "invalid", "{bad}");
    }

    #[test]
    fn inspect_and_passphrase() {
        let alice = gen("Alice <alice@example.org>", "pw");
        let info = run(json!({
            "op": "inspect",
            "data": B64.encode(alice["public_armored"].as_str().unwrap()),
        }));
        assert_eq!(info["ok"], true, "{info}");
        assert_eq!(info["keys"][0]["fingerprint"], alice["fingerprint"]);
        assert_eq!(info["keys"][0]["is_secret"], false);
        assert_eq!(info["keys"][0]["user_ids"][0], "Alice <alice@example.org>");

        let sec = run(json!({
            "op": "inspect",
            "data": B64.encode(alice["armored"].as_str().unwrap()),
        }));
        assert_eq!(sec["keys"][0]["is_secret"], true, "{sec}");

        let good = run(json!({"op": "check_passphrase", "secret": alice["armored"], "passphrase": "pw"}));
        assert_eq!(good["valid"], true);
        let bad = run(json!({"op": "check_passphrase", "secret": alice["armored"], "passphrase": "x"}));
        assert_eq!(bad["valid"], false);
    }
}
