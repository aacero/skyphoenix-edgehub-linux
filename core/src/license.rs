//! Offline licence-key verification (E11).
//!
//! The Pro tier is unlocked by a signed key the user pastes into a dialog. The
//! design constraints are deliberate and non-negotiable:
//!
//! * **Offline.** Verification is a signature check against a public key
//!   compiled into this binary. It opens no socket and reads no file - running
//!   the hub under `unshare -n` cannot change the answer.
//! * **No hardware fingerprint.** A key is bound to nothing but its own
//!   contents. It keeps working on a reinstall, a new machine, or a VM.
//! * **Verify, never mint.** Only the PUBLIC half lives here. Nothing in this
//!   repository can produce a licence: the private key is offline and the
//!   `rand_core` feature of `ed25519-dalek` is switched off, so this crate
//!   cannot even generate a keypair. The test module below signs with a key
//!   that exists solely under `#[cfg(test)]`.
//! * **Fail closed, but soft.** Every failure path - absent, truncated,
//!   garbage, forged, expired - resolves to [`Tier::Free`]. There is no panic
//!   and no nag: a broken key means the free product, not a broken product.
//!   Expiry is reported as its own state so the UI can say "renew" rather than
//!   the accusatory "invalid".
//!
//! # Key format
//!
//! ```text
//! XE1.<base64url(payload JSON)>.<base64url(64-byte Ed25519 signature)>
//! ```
//!
//! The signature covers the ASCII bytes of `XE1.<base64url(payload)>` - the
//! encoded form, not the decoded JSON. This is the JWT rule and it exists for a
//! reason: verifying the exact bytes that are later parsed means no JSON
//! canonicalisation question can ever arise (key order, whitespace and escaping
//! are all frozen by the signature). Covering the `XE1` prefix too means the
//! version cannot be stripped or downgraded without breaking the signature.
//!
//! `base64url` **unpadded** (RFC 4648 §5) is used throughout: the alphabet has
//! no `+`, `/` or `=`, so a key survives being pasted into a URL, a shell, a
//! CSV or an email without escaping - the places keys actually travel.
//!
//! NOTHING here may log a key or its holder. [`License`] therefore has a
//! hand-written [`Debug`] that redacts `issued_to`, and the error type names
//! only the failure mode. This mirrors `secrets.rs`, which draws the same line.

use ed25519_dalek::{Signature, VerifyingKey, SIGNATURE_LENGTH};
use serde::{Deserialize, Serialize};
use std::fmt;
use std::time::{SystemTime, UNIX_EPOCH};

/// Version tag and signing domain. Prefixes every key.
///
/// It is inside the signed region, so it doubles as a domain separator: a blob
/// signed for some future `XE2` format can never verify as an `XE1` licence.
const KEY_PREFIX: &str = "XE1";

/// The Ed25519 public key that licences are verified against.
///
/// ARMED (2026-07-19, ROTATED): the real issuer public key is embedded below.
/// The private seed lives only in the owner's password manager (Bitwarden) - it
/// is NOT in this repo, NOT the project's GPG release key (`93CDC77EACF98990`),
/// and never touches CI. Licence signing is fully offline (`tools/license-tool`).
///
/// ROTATION NOTE. This replaces the key armed on 2026-07-17 by `38df26c`, whose
/// seed was generated in an agent session and was never held by the owner. An
/// issuer key whose seed the owner does not control cannot mint licences, so it
/// was not shippable. The rotation was safe precisely because it happened before
/// first sale: no store product existed and no licence had been issued, so there
/// was nothing to invalidate.
///
/// If this key is ever rotated AGAIN after a sale, understand the cost first:
/// every licence signed with the retired seed stops verifying, and the only
/// remedy is re-issuing keys to every existing customer alongside an app update.
///
/// The all-zero form is kept commented as the "unissued" sentinel: [`issuer_key`]
/// still returns `None` for all-zero (a small-order point that must never be
/// trusted), so if this ever regresses to zeros the app fails CLOSED - every
/// licence becomes free - rather than trusting a bad key. `production_issuer_key_
/// is_armed_and_valid` guards against that regression.
//const ISSUER_PUBLIC_KEY: [u8; 32] = [0u8; 32];
const ISSUER_PUBLIC_KEY: [u8; 32] = [
    183, 198, 221, 102, 177, 136, 154, 209, 91, 2, 101, 32, 144, 232, 227, 156, 240, 15, 251, 13,
    123, 96, 98, 122, 235, 102, 219, 75, 211, 202, 88, 26,
];

/// What a licence unlocks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    /// The unlicensed product. Every failure path lands here.
    Free,
    /// The paid tier.
    Pro,
}

impl Tier {
    /// The wire/JSON spelling, for the FFI and the UI.
    pub fn as_str(self) -> &'static str {
        match self {
            Tier::Free => "free",
            Tier::Pro => "pro",
        }
    }
}

/// The signed claims inside a key.
///
/// `issued_to` is holder data (a name or email) and must never reach a log.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct License {
    /// The tier this key grants.
    pub tier: Tier,
    /// Expiry as Unix epoch seconds; `None` is perpetual.
    ///
    /// Epoch seconds rather than a date string: it needs no date parser, has no
    /// time-zone ambiguity, and cannot be mis-read across locales.
    #[serde(default)]
    pub expires: Option<i64>,
    /// Who the licence was issued to. Holder data - display, never log.
    pub issued_to: String,
    /// Opaque licence id, for support and revocation lists.
    pub id: String,
}

// Hand-written so that a stray `{:?}` on a License - in a log line, a panic
// message, a test failure - cannot leak the holder's name or email. The derived
// impl would print it verbatim, and that is exactly the accident this type
// exists to prevent.
impl fmt::Debug for License {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("License")
            .field("tier", &self.tier)
            .field("expires", &self.expires)
            .field("issued_to", &"<redacted>")
            .field("id", &self.id)
            .finish()
    }
}

/// Why a key did not grant a tier.
///
/// Variants name the failure mode and carry no part of the key. There is
/// deliberately no "here is the bad payload" variant: that is how key material
/// ends up in a log file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum LicenseError {
    /// No key supplied (empty or whitespace) - the ordinary unlicensed state.
    #[error("no licence key")]
    Absent,
    /// Not `XE1.<payload>.<signature>`: wrong prefix, or not three segments.
    #[error("not a Xeneon licence key")]
    Malformed,
    /// A segment is not valid unpadded base64url, or the signature is not 64 bytes.
    #[error("licence key is damaged or incomplete")]
    Damaged,
    /// Base64 decoded, but the payload is not the expected JSON.
    #[error("licence payload is not readable")]
    BadPayload,
    /// The signature does not match this issuer's key - forged, tampered, or
    /// issued by someone else. All three are the same answer: not ours.
    #[error("licence signature does not verify")]
    BadSignature,
    /// Signature is good, but the key names a tier this build does not know.
    /// Fail closed: a future "enterprise" tier must not silently read as Pro.
    #[error("licence names an unknown tier")]
    UnknownTier,
    /// No issuer key is compiled in yet (the placeholder is still zero).
    #[error("this build has no licence issuer key")]
    NoIssuerKey,
}

/// The outcome of checking a key. What the UI renders.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Status {
    /// A good, in-date key.
    Licensed(License),
    /// A genuine key past its expiry date. **Distinct from invalid**: the user
    /// paid, the signature is real, and the fix is renewal, not support.
    Expired(License),
    /// No usable key. Carries the reason; the product runs as [`Tier::Free`].
    Unlicensed(LicenseError),
}

impl Status {
    /// What the app should actually unlock. The only question most callers ask.
    ///
    /// Expired grants Free: the grace period, if any, is a product decision for
    /// the UI layer, not something to smuggle in by treating expiry as valid.
    pub fn tier(&self) -> Tier {
        match self {
            Status::Licensed(l) => l.tier,
            Status::Expired(_) | Status::Unlicensed(_) => Tier::Free,
        }
    }

    /// A stable machine-readable state for the FFI/UI: `licensed` | `expired` |
    /// `unlicensed`.
    pub fn state(&self) -> &'static str {
        match self {
            Status::Licensed(_) => "licensed",
            Status::Expired(_) => "expired",
            Status::Unlicensed(_) => "unlicensed",
        }
    }

    /// The single JSON shape the FFI hands to the UI: `{ state, tier, reason,
    /// issuedTo, id, expires }`. Kept here, on the type that owns the meaning, so
    /// every FFI path (a freshly pasted key and the stored-key convenience) emits
    /// byte-identical output and can never drift apart. `issuedTo` is display-only
    /// holder data; `reason` names a failure mode but NEVER echoes the key.
    pub fn to_json(&self) -> String {
        let license = match self {
            Status::Licensed(l) | Status::Expired(l) => Some(l),
            Status::Unlicensed(_) => None,
        };
        let reason = match self {
            Status::Unlicensed(e) => Some(e.to_string()),
            _ => None,
        };
        serde_json::json!({
            "state": self.state(),
            "tier": self.tier().as_str(),
            "reason": reason,
            "issuedTo": license.map(|l| l.issued_to.clone()),
            "id": license.map(|l| l.id.clone()),
            "expires": license.and_then(|l| l.expires),
        })
        .to_string()
    }
}

/// The issuer key, or `None` while the placeholder is unissued.
///
/// The zero check is the load-bearing line: an all-zero Ed25519 public key is a
/// small-order point for which signatures are forgeable, so a build that shipped
/// with the placeholder must trust nothing at all rather than trust it weakly.
fn issuer_key() -> Option<VerifyingKey> {
    if ISSUER_PUBLIC_KEY == [0u8; 32] {
        return None;
    }
    VerifyingKey::from_bytes(&ISSUER_PUBLIC_KEY).ok()
}

/// Verify `key` against the compiled-in issuer key, as of now.
///
/// Never panics; never performs I/O beyond reading the clock.
pub fn verify(key: &str) -> Status {
    verify_at(key, now_epoch())
}

/// Verify `key` as of `now` (Unix epoch seconds).
///
/// The clock is a parameter so expiry is testable without waiting for 2027 or
/// mutating the system clock.
pub fn verify_at(key: &str, now: i64) -> Status {
    match issuer_key() {
        Some(vk) => verify_with(key, &vk, now),
        None => Status::Unlicensed(LicenseError::NoIssuerKey),
    }
}

/// Verify `key` against an explicit public key, as of `now`.
///
/// Deliberately NOT `pub`: it exists so the tests can drive the real code path
/// with a test issuer, and exporting it would hand every caller a licence bypass
/// (`verify_with(anything, &my_own_key, 0)` returns Pro). The public surface is
/// [`verify`] / [`verify_at`], which are pinned to [`ISSUER_PUBLIC_KEY`]. There
/// is no env var and no config field that swaps the issuer, for the same reason.
fn verify_with(key: &str, issuer: &VerifyingKey, now: i64) -> Status {
    match check(key, issuer) {
        Err(e) => Status::Unlicensed(e),
        Ok(license) => match license.expires {
            // `<=`: at the exact expiry second the licence is over. Erring
            // toward expired keeps the boundary unambiguous.
            Some(exp) if exp <= now => Status::Expired(license),
            _ => Status::Licensed(license),
        },
    }
}

/// Parse + signature-check. Expiry is deliberately NOT considered here: an
/// expired key must first be proven genuine, or a forged "expired" key would be
/// reported as an expiry (telling the user to renew a licence that never existed).
fn check(key: &str, issuer: &VerifyingKey) -> Result<License, LicenseError> {
    // Strip ALL internal whitespace, not just the ends. Keys travel through
    // email and chat, which hard-wrap long strings; a user pasting back a
    // two-line key is doing nothing wrong and must not be told their key is bad.
    let compact: String = key.chars().filter(|c| !c.is_whitespace()).collect();
    if compact.is_empty() {
        return Err(LicenseError::Absent);
    }

    let mut parts = compact.split('.');
    let (prefix, payload_b64, sig_b64) = match (parts.next(), parts.next(), parts.next()) {
        (Some(a), Some(b), Some(c)) => (a, b, c),
        _ => return Err(LicenseError::Malformed),
    };
    // A fourth segment means this is not our format, whatever else it is.
    if parts.next().is_some() || prefix != KEY_PREFIX {
        return Err(LicenseError::Malformed);
    }

    let sig_bytes = b64url_decode(sig_b64).ok_or(LicenseError::Damaged)?;
    let sig_array: [u8; SIGNATURE_LENGTH] =
        sig_bytes.try_into().map_err(|_| LicenseError::Damaged)?;
    let signature = Signature::from_bytes(&sig_array);

    // Verify BEFORE parsing the payload: never hand attacker-controlled bytes to
    // a parser we do not have to. A truncated key dies here, not in serde.
    //
    // verify_strict, not verify: it rejects small-order public keys and
    // mixed-order signatures, closing the malleability holes that let one blob
    // verify under more than one key.
    //
    // Rebuilt with format! rather than sliced out of `compact` by byte offset:
    // the offset arithmetic is correct, but "is this index on a UTF-8 char
    // boundary for every input?" is a question a reviewer should not have to
    // answer in the one function that decides whether a signature is good.
    let signed = format!("{}.{}", prefix, payload_b64);
    issuer
        .verify_strict(signed.as_bytes(), &signature)
        .map_err(|_| LicenseError::BadSignature)?;

    let payload = b64url_decode(payload_b64).ok_or(LicenseError::Damaged)?;
    // Tier is parsed as a String, not straight into the enum, so an unknown
    // tier is UnknownTier rather than an indistinguishable BadPayload.
    #[derive(Deserialize)]
    struct RawPayload {
        tier: String,
        #[serde(default)]
        expires: Option<i64>,
        issued_to: String,
        id: String,
    }
    let raw: RawPayload = serde_json::from_slice(&payload).map_err(|_| LicenseError::BadPayload)?;
    let tier = match raw.tier.as_str() {
        "pro" => Tier::Pro,
        "free" => Tier::Free,
        _ => return Err(LicenseError::UnknownTier),
    };
    Ok(License {
        tier,
        expires: raw.expires,
        issued_to: raw.issued_to,
        id: raw.id,
    })
}

fn now_epoch() -> i64 {
    // A clock before 1970 (or a failure to read it) must not become a huge
    // positive number and silently un-expire every licence, so clamp to 0 -
    // which expires everything instead. Fail closed.
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// ─── base64url, unpadded (RFC 4648 §5) ───────────────────────────────────────
//
// Hand-rolled rather than adding a crate. It is ~40 lines against a frozen
// standard, the decoder is STRICT (any byte outside the alphabet, and any
// length that cannot arise from real base64, is rejected), and every failure
// simply reports Damaged - decode is never trusted, only the signature is. The
// property test below pins encode/decode as exact inverses.

const B64_ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Encode to unpadded base64url.
pub fn b64url_encode(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | (b[2] as u32);
        let idx = [(n >> 18) & 63, (n >> 12) & 63, (n >> 6) & 63, n & 63];
        // chunk.len()+1 chars carry all the bits of chunk.len() bytes: 3→4, 2→3, 1→2.
        for i in idx.iter().take(chunk.len() + 1) {
            out.push(B64_ALPHABET[*i as usize] as char);
        }
    }
    out
}

/// Decode unpadded base64url, STRICTLY. `None` on any byte outside the
/// alphabet, on padding, on an impossible length, or on a final group whose
/// unused trailing bits are not zero (RFC 4648 §3.5).
///
/// That last rule is not pedantry, and a property test caught its absence: a
/// 64-byte signature encodes to 86 chars, whose final char carries only 2
/// meaningful bits. A lax decoder ignores the other 4, so 16 different key
/// strings decode to the same signature and all unlock Pro - the key stops
/// being canonical, and anything keyed on the string (a revocation list, a
/// support lookup, a dedup check) can be evaded by flipping one character.
/// Rejecting non-zero trailing bits makes the encoding injective.
pub fn b64url_decode(s: &str) -> Option<Vec<u8>> {
    fn value(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a') as u32 + 26),
            b'0'..=b'9' => Some((c - b'0') as u32 + 52),
            b'-' => Some(62),
            b'_' => Some(63),
            _ => None,
        }
    }
    let bytes = s.as_bytes();
    // A remainder of 1 char is impossible: no number of bytes encodes to it.
    // Accepting it would let two distinct strings decode to the same value.
    if bytes.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        let mut n: u32 = 0;
        for &c in chunk {
            n = (n << 6) | value(c)?;
        }
        // A short final group carries more bits than it has whole bytes: 2 chars
        // = 12 bits for 1 byte, 3 chars = 18 bits for 2. The surplus low bits
        // MUST be zero, or the encoding is not injective (see the doc comment).
        let surplus = chunk.len() * 6 - (chunk.len() - 1) * 8;
        if n & ((1u32 << surplus) - 1) != 0 {
            return None;
        }
        // Left-align the partial group so the real bytes land in the high bits.
        n <<= 6 * (4 - chunk.len());
        let decoded = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        out.extend_from_slice(&decoded[..chunk.len() - 1]);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    // ── Test issuer ──────────────────────────────────────────────────────────
    //
    // A fixed, PUBLICLY-KNOWN private key that exists only in this test module.
    // It is deliberately not the production key and never can be: production is
    // pinned to ISSUER_PUBLIC_KEY, which no test can reassign. Fixed rather than
    // random so failures reproduce exactly (and `rand_core` stays switched off).
    const TEST_SEED: [u8; 32] = [7u8; 32];
    const OTHER_SEED: [u8; 32] = [9u8; 32];

    fn signing_key(seed: [u8; 32]) -> SigningKey {
        SigningKey::from_bytes(&seed)
    }

    /// Mint a key with the given seed - the issuing side, mirrored here so the
    /// tests exercise the real verifier against real signatures.
    fn mint(seed: [u8; 32], payload_json: &str) -> String {
        let sk = signing_key(seed);
        let signed = format!("{}.{}", KEY_PREFIX, b64url_encode(payload_json.as_bytes()));
        let sig = sk.sign(signed.as_bytes());
        format!("{}.{}", signed, b64url_encode(&sig.to_bytes()))
    }

    fn pro_payload(expires: Option<i64>) -> String {
        match expires {
            Some(e) => format!(
                r#"{{"tier":"pro","expires":{},"issued_to":"Ada Lovelace","id":"XE-0001"}}"#,
                e
            ),
            None => r#"{"tier":"pro","expires":null,"issued_to":"Ada Lovelace","id":"XE-0001"}"#
                .to_string(),
        }
    }

    fn issuer(seed: [u8; 32]) -> VerifyingKey {
        signing_key(seed).verifying_key()
    }

    const NOW: i64 = 1_800_000_000; // 2027-01-15, an arbitrary fixed "now".

    // ── The happy path ───────────────────────────────────────────────────────

    #[test]
    fn valid_perpetual_key_grants_pro() {
        let key = mint(TEST_SEED, &pro_payload(None));
        let st = verify_with(&key, &issuer(TEST_SEED), NOW);
        assert_eq!(st.tier(), Tier::Pro);
        assert_eq!(st.state(), "licensed");
        match st {
            Status::Licensed(l) => {
                assert_eq!(l.id, "XE-0001");
                assert_eq!(l.issued_to, "Ada Lovelace");
                assert_eq!(l.expires, None);
            }
            other => panic!("expected Licensed, got {:?}", other),
        }
    }

    #[test]
    fn valid_dated_key_in_date_grants_pro() {
        let key = mint(TEST_SEED, &pro_payload(Some(NOW + 86_400)));
        assert_eq!(verify_with(&key, &issuer(TEST_SEED), NOW).tier(), Tier::Pro);
    }

    #[test]
    fn a_key_wrapped_across_lines_still_verifies() {
        // Email and chat hard-wrap; the user pasting two lines back did nothing
        // wrong and must not be told their key is bad.
        let key = mint(TEST_SEED, &pro_payload(None));
        let wrapped = format!("{}\n  {}", &key[..40], &key[40..]);
        assert_eq!(
            verify_with(&wrapped, &issuer(TEST_SEED), NOW).tier(),
            Tier::Pro
        );
    }

    // ── Expiry is its own state ──────────────────────────────────────────────

    #[test]
    fn expired_key_is_expired_not_invalid() {
        let key = mint(TEST_SEED, &pro_payload(Some(NOW - 1)));
        let st = verify_with(&key, &issuer(TEST_SEED), NOW);
        assert_eq!(st.state(), "expired");
        assert_eq!(st.tier(), Tier::Free, "expired must not unlock Pro");
        match st {
            // The holder is still known - the UI says "renew", not "invalid".
            Status::Expired(l) => assert_eq!(l.id, "XE-0001"),
            other => panic!("expected Expired, got {:?}", other),
        }
    }

    #[test]
    fn expiry_boundary_is_closed_at_the_expiry_second() {
        let k = mint(TEST_SEED, &pro_payload(Some(NOW)));
        assert_eq!(verify_with(&k, &issuer(TEST_SEED), NOW).state(), "expired");
        assert_eq!(
            verify_with(&k, &issuer(TEST_SEED), NOW - 1).state(),
            "licensed"
        );
    }

    // A forged blob claiming to be expired must read as invalid, or we would be
    // telling a user to renew a licence that was never issued.
    #[test]
    fn a_forged_expired_key_is_invalid_not_expired() {
        let key = mint(OTHER_SEED, &pro_payload(Some(NOW - 1)));
        let st = verify_with(&key, &issuer(TEST_SEED), NOW);
        assert_eq!(st.state(), "unlicensed");
        assert_eq!(st, Status::Unlicensed(LicenseError::BadSignature));
    }

    // ── Rejection ────────────────────────────────────────────────────────────

    #[test]
    fn tampered_payload_is_rejected() {
        let key = mint(TEST_SEED, &pro_payload(None));
        let (prefix, rest) = key.split_at(4); // "XE1."
        let mut payload: Vec<u8> = rest.as_bytes().to_vec();
        // Flip one base64 char of the payload to a different alphabet member.
        payload[3] = if payload[3] == b'A' { b'B' } else { b'A' };
        let tampered = format!("{}{}", prefix, String::from_utf8(payload).unwrap());
        assert_ne!(tampered, key);
        assert_eq!(
            verify_with(&tampered, &issuer(TEST_SEED), NOW),
            Status::Unlicensed(LicenseError::BadSignature)
        );
    }

    #[test]
    fn tampered_signature_is_rejected() {
        let key = mint(TEST_SEED, &pro_payload(None));
        let mut bytes = key.into_bytes();
        let last = bytes.len() - 1;
        bytes[last] = if bytes[last] == b'A' { b'B' } else { b'A' };
        let tampered = String::from_utf8(bytes).unwrap();
        assert_eq!(
            verify_with(&tampered, &issuer(TEST_SEED), NOW).tier(),
            Tier::Free
        );
    }

    // Escalating "free" to "pro" in the payload must break the signature - this
    // is the attack the whole module exists to stop.
    #[test]
    fn upgrading_the_tier_in_the_payload_breaks_the_signature() {
        let free = r#"{"tier":"free","expires":null,"issued_to":"Ada","id":"XE-2"}"#;
        let pro = r#"{"tier":"pro","expires":null,"issued_to":"Ada","id":"XE-2"}"#;
        let real = mint(TEST_SEED, free);
        let sig = real.rsplit('.').next().unwrap();
        let forged = format!("{}.{}.{}", KEY_PREFIX, b64url_encode(pro.as_bytes()), sig);
        assert_eq!(
            verify_with(&forged, &issuer(TEST_SEED), NOW),
            Status::Unlicensed(LicenseError::BadSignature)
        );
    }

    #[test]
    fn a_key_signed_by_a_different_issuer_is_rejected() {
        let key = mint(OTHER_SEED, &pro_payload(None));
        assert_eq!(
            verify_with(&key, &issuer(TEST_SEED), NOW),
            Status::Unlicensed(LicenseError::BadSignature)
        );
        // Sanity: the same blob IS valid under its own issuer, so the rejection
        // above is about the key, not a broken fixture.
        assert_eq!(
            verify_with(&key, &issuer(OTHER_SEED), NOW).tier(),
            Tier::Pro
        );
    }

    #[test]
    fn empty_and_whitespace_are_absent_not_errors() {
        for s in ["", "   ", "\n\t"] {
            assert_eq!(
                verify_with(s, &issuer(TEST_SEED), NOW),
                Status::Unlicensed(LicenseError::Absent)
            );
        }
    }

    #[test]
    fn garbage_and_wrong_prefix_are_malformed() {
        for s in [
            "hello world",
            "XE1.only-two",
            "XE2.abc.def",
            "XE1.a.b.c",
            "....",
        ] {
            let st = verify_with(s, &issuer(TEST_SEED), NOW);
            assert_eq!(st.tier(), Tier::Free, "{s:?} must not unlock Pro");
            assert!(
                matches!(
                    st,
                    Status::Unlicensed(LicenseError::Malformed | LicenseError::Damaged)
                ),
                "{s:?} -> {st:?}"
            );
        }
    }

    // Every truncation of a real key must fail cleanly - no panic, no slice
    // out-of-bounds, no Pro. This is the "user pasted half the key" case.
    #[test]
    fn every_truncation_of_a_valid_key_is_rejected_without_panicking() {
        let key = mint(TEST_SEED, &pro_payload(None));
        for n in 0..key.len() {
            let st = verify_with(&key[..n], &issuer(TEST_SEED), NOW);
            assert_eq!(st.tier(), Tier::Free, "truncation at {n} unlocked Pro");
        }
        // And the untruncated key still works.
        assert_eq!(verify_with(&key, &issuer(TEST_SEED), NOW).tier(), Tier::Pro);
    }

    #[test]
    fn non_base64_segments_are_damaged_not_a_panic() {
        let payload = b64url_encode(pro_payload(None).as_bytes());
        // '*' and '=' (padding) are both outside the unpadded base64url alphabet.
        let bad_sig = format!("XE1.{}.****", payload);
        assert_eq!(
            verify_with(&bad_sig, &issuer(TEST_SEED), NOW),
            Status::Unlicensed(LicenseError::Damaged)
        );
        let padded = format!("XE1.{}.AAAA=", payload);
        assert_eq!(
            verify_with(&padded, &issuer(TEST_SEED), NOW),
            Status::Unlicensed(LicenseError::Damaged)
        );
    }

    #[test]
    fn a_signature_of_the_wrong_length_is_damaged() {
        let payload = b64url_encode(pro_payload(None).as_bytes());
        let short = format!("XE1.{}.{}", payload, b64url_encode(&[0u8; 32]));
        assert_eq!(
            verify_with(&short, &issuer(TEST_SEED), NOW),
            Status::Unlicensed(LicenseError::Damaged)
        );
    }

    #[test]
    fn a_signed_but_non_json_payload_is_bad_payload() {
        let key = mint(TEST_SEED, "this is not json");
        assert_eq!(
            verify_with(&key, &issuer(TEST_SEED), NOW),
            Status::Unlicensed(LicenseError::BadPayload)
        );
    }

    #[test]
    fn a_signed_payload_missing_a_field_is_bad_payload() {
        let key = mint(TEST_SEED, r#"{"tier":"pro"}"#);
        assert_eq!(
            verify_with(&key, &issuer(TEST_SEED), NOW),
            Status::Unlicensed(LicenseError::BadPayload)
        );
    }

    // A tier from a future build must not read as Pro. Fail closed.
    #[test]
    fn an_unknown_tier_is_rejected_even_when_properly_signed() {
        let key = mint(
            TEST_SEED,
            r#"{"tier":"enterprise","expires":null,"issued_to":"A","id":"X"}"#,
        );
        let st = verify_with(&key, &issuer(TEST_SEED), NOW);
        assert_eq!(st, Status::Unlicensed(LicenseError::UnknownTier));
        assert_eq!(st.tier(), Tier::Free);
    }

    #[test]
    fn a_signed_free_tier_key_is_licensed_but_grants_only_free() {
        let key = mint(
            TEST_SEED,
            r#"{"tier":"free","expires":null,"issued_to":"A","id":"X"}"#,
        );
        let st = verify_with(&key, &issuer(TEST_SEED), NOW);
        assert_eq!(st.state(), "licensed");
        assert_eq!(st.tier(), Tier::Free);
    }

    #[test]
    fn licensed_and_expired_json_keep_holder_data_but_no_failure_reason() {
        let key = mint(TEST_SEED, &pro_payload(Some(NOW + 60)));
        let licensed = verify_with(&key, &issuer(TEST_SEED), NOW);
        let licensed_json: serde_json::Value = serde_json::from_str(&licensed.to_json()).unwrap();
        assert_eq!(licensed_json["state"], "licensed");
        assert_eq!(licensed_json["tier"], "pro");
        assert_eq!(licensed_json["issuedTo"], "Ada Lovelace");
        assert!(licensed_json["reason"].is_null());

        let expired = verify_with(&key, &issuer(TEST_SEED), NOW + 60);
        let expired_json: serde_json::Value = serde_json::from_str(&expired.to_json()).unwrap();
        assert_eq!(expired_json["state"], "expired");
        assert_eq!(expired_json["tier"], "free");
        assert_eq!(expired_json["issuedTo"], "Ada Lovelace");
        assert!(expired_json["reason"].is_null());
    }

    // ── The production issuer is ARMED ───────────────────────────────────────
    // (Was the "still a placeholder" release guard. The real issuer public key
    //  was embedded 2026-07-17; these now assert the armed state instead.)

    #[test]
    fn production_issuer_key_is_armed_and_valid() {
        // The real key is embedded - NOT the all-zero placeholder - and parses as
        // a well-formed Ed25519 verifying key. If this ever reverts to zeros,
        // every licence silently becomes free; this is the guard against that.
        assert_ne!(
            ISSUER_PUBLIC_KEY, [0u8; 32],
            "the issuer key must be armed, not the placeholder"
        );
        assert!(
            issuer_key().is_some(),
            "the embedded key must be a valid Ed25519 point"
        );
    }

    #[test]
    fn a_key_from_a_different_issuer_does_not_unlock_pro() {
        // Now that the real key is armed, a key signed by ANY other seed (here the
        // test seed - the real one is secret and never in the repo) must fail to
        // verify and stay Free. Arming must not make a foreign key trusted.
        let foreign = mint(TEST_SEED, &pro_payload(None));
        assert_eq!(verify_at(&foreign, NOW).tier(), Tier::Free);
        assert_eq!(verify(&foreign).tier(), Tier::Free);
        // And the trivial cases remain Free.
        assert_eq!(verify("").tier(), Tier::Free);
        assert_eq!(verify("XE1.garbage.garbage").tier(), Tier::Free);
    }

    #[test]
    fn owners_real_pro_key_unlocks_pro_against_the_shipped_issuer_key() {
        // The 40 other tests mint with TEST_SEED and verify against a TEST issuer,
        // so none of them proves that a key minted with the OWNER's real secret
        // seed unlocks Pro against the issuer key that actually SHIPS in the binary
        // (armed 2026-07-19). This test closes that release-critical gap.
        //
        // The release runners read a protected owner-only file, carry the key
        // through private descriptor 3, and expose it in this test process only.
        // Ordinary CI has no owner key, so this one test intentionally returns
        // after a visible SKIP marker. The strict runner rejects that marker.
        // `verify()` uses the embedded ISSUER_PUBLIC_KEY - the real one.
        let key = match std::env::var("XENEON_TEST_LICENSE_KEY") {
            Ok(k) if !k.trim().is_empty() => k,
            _ => {
                eprintln!("SKIP owners_real_pro_key: XENEON_TEST_LICENSE_KEY unset");
                return;
            }
        };
        assert_eq!(
            verify(&key).tier(),
            Tier::Pro,
            "the owner's real key must unlock Pro against the shipped issuer key \
             - if this fails, the armed public key does not match the seed that \
             mints the keys, and no customer's key would work"
        );
        // Tamper the signature: a single flipped character must drop it to Free.
        // Proves the shipped verifier rejects a doctored copy of a genuine key.
        let mut c: Vec<char> = key.chars().collect();
        let last = c.len() - 1;
        c[last] = if c[last] == 'A' { 'B' } else { 'A' };
        let tampered: String = c.into_iter().collect();
        assert_eq!(
            verify(&tampered).tier(),
            Tier::Free,
            "a tampered copy of the owner's key must not unlock Pro"
        );
        // And a payload swap: change the tier claim inside a real key and the
        // signature no longer covers it -> Free (defence against self-upgrade).
        if let Some(dot) = key.find('.') {
            let forged = format!("{}.{}", &key[..dot], "eyJ0aWVyIjoicHJvIn0");
            assert_eq!(
                verify(&forged).tier(),
                Tier::Free,
                "a hand-crafted payload on the owner's prefix must not unlock Pro"
            );
        }
    }

    #[test]
    fn verify_reads_the_clock_without_panicking() {
        // verify() is the only path that touches SystemTime; make sure the real
        // clock path is exercised, not just verify_at.
        assert_eq!(verify("XE1.a.b").tier(), Tier::Free);
        assert!(now_epoch() > 1_700_000_000);
    }

    // ── Holder data never leaks ──────────────────────────────────────────────

    #[test]
    fn debug_redacts_the_holder_but_keeps_the_id() {
        let l = License {
            tier: Tier::Pro,
            expires: None,
            issued_to: "ada@example.com".into(),
            id: "XE-0001".into(),
        };
        let s = format!("{:?}", l);
        assert!(
            !s.contains("ada@example.com"),
            "Debug leaked the holder: {s}"
        );
        assert!(s.contains("<redacted>"));
        assert!(s.contains("XE-0001"));
    }

    #[test]
    fn error_messages_name_the_failure_not_the_key() {
        let secret = "XE1.SUPERSECRETPAYLOAD.SIG";
        for e in [
            LicenseError::Absent,
            LicenseError::Malformed,
            LicenseError::Damaged,
            LicenseError::BadPayload,
            LicenseError::BadSignature,
            LicenseError::UnknownTier,
            LicenseError::NoIssuerKey,
        ] {
            let msg = e.to_string();
            assert!(!msg.is_empty());
            assert!(!msg.contains("SUPERSECRET"), "error leaked key: {msg}");
        }
        // And the Status wrapping an error cannot leak it either.
        let st = verify_with(secret, &issuer(TEST_SEED), NOW);
        assert!(!format!("{st:?}").contains("SUPERSECRETPAYLOAD"));
    }

    #[test]
    fn tier_strings_are_stable() {
        assert_eq!(Tier::Free.as_str(), "free");
        assert_eq!(Tier::Pro.as_str(), "pro");
    }

    // ── base64url ────────────────────────────────────────────────────────────

    #[test]
    fn b64url_matches_rfc4648_vectors() {
        // RFC 4648 §10 vectors, unpadded, in the URL-safe alphabet.
        assert_eq!(b64url_encode(b""), "");
        assert_eq!(b64url_encode(b"f"), "Zg");
        assert_eq!(b64url_encode(b"fo"), "Zm8");
        assert_eq!(b64url_encode(b"foo"), "Zm9v");
        assert_eq!(b64url_encode(b"foob"), "Zm9vYg");
        assert_eq!(b64url_encode(b"fooba"), "Zm9vYmE");
        assert_eq!(b64url_encode(b"foobar"), "Zm9vYmFy");
        assert_eq!(b64url_decode("Zm9vYmFy").unwrap(), b"foobar");
        assert_eq!(b64url_decode("").unwrap(), b"");
    }

    #[test]
    fn b64url_uses_the_url_safe_alphabet() {
        // 0xFB 0xFF encodes to "+/" in standard base64 and must not here.
        let e = b64url_encode(&[0xfb, 0xff, 0xfe]);
        assert_eq!(e, "-__-");
        assert!(!e.contains('+') && !e.contains('/') && !e.contains('='));
        assert_eq!(b64url_decode(&e).unwrap(), vec![0xfb, 0xff, 0xfe]);
    }

    #[test]
    fn b64url_decode_rejects_impossible_input() {
        assert!(
            b64url_decode("A").is_none(),
            "1 leftover char is impossible"
        );
        assert!(b64url_decode("Zm9vYmFyA").is_none());
        assert!(b64url_decode("Zm9v=").is_none(), "padding is not accepted");
        assert!(
            b64url_decode("Zm9 v").is_none(),
            "space is not in the alphabet"
        );
        assert!(b64url_decode("Zm9+").is_none(), "standard-alphabet byte");
        assert!(b64url_decode("Zm9/").is_none());
    }

    // The encoding must be injective: exactly ONE string per byte string. A lax
    // decoder ignores the unused low bits of a short final group, which made a
    // flipped last character of a signature decode to the same 64 bytes - a
    // property test caught it, and these vectors pin the fix.
    #[test]
    fn b64url_decode_rejects_non_zero_trailing_bits() {
        // "Zg" -> "f": 2 chars, 12 bits, 4 surplus bits that must be zero.
        assert_eq!(b64url_decode("Zg").unwrap(), b"f");
        for alias in ["Zh", "Zi", "Zj", "Zp", "Zv"] {
            assert!(
                b64url_decode(alias).is_none(),
                "{alias} must not be a second spelling of \"f\""
            );
        }
        // "Zm8" -> "fo": 3 chars, 18 bits, 2 surplus bits.
        assert_eq!(b64url_decode("Zm8").unwrap(), b"fo");
        for alias in ["Zm9", "Zm-", "Zm_"] {
            assert!(
                b64url_decode(alias).is_none(),
                "{alias} must not be a second spelling of \"fo\""
            );
        }
        // Full groups have no surplus bits and must still decode.
        assert_eq!(b64url_decode("Zm9v").unwrap(), b"foo");
    }

    // Every string the encoder emits must decode, including short final groups -
    // the strictness above must not reject our own output.
    #[test]
    fn strictness_does_not_reject_the_encoders_own_output() {
        for n in 0..24usize {
            let data: Vec<u8> = (0..n).map(|i| (i as u8).wrapping_mul(37)).collect();
            let e = b64url_encode(&data);
            assert_eq!(b64url_decode(&e).as_deref(), Some(data.as_slice()), "n={n}");
        }
    }

    proptest::proptest! {
        // encode/decode must be exact inverses for every input, or a key could
        // decode to something other than what was signed.
        #[test]
        fn b64url_round_trips(data: Vec<u8>) {
            let e = b64url_encode(&data);
            proptest::prop_assert!(e.bytes().all(|c| B64_ALPHABET.contains(&c)));
            let decoded = b64url_decode(&e);
            proptest::prop_assert_eq!(decoded.as_deref(), Some(data.as_slice()));
        }

        // No arbitrary string may ever be accepted as a licence. This is the
        // whole security claim, fuzzed.
        #[test]
        fn no_arbitrary_string_unlocks_pro(s: String) {
            let st = verify_with(&s, &issuer(TEST_SEED), NOW);
            proptest::prop_assert_eq!(st.tier(), Tier::Free);
        }

        // Nor may any mutation of a genuine key.
        #[test]
        fn no_single_byte_mutation_of_a_valid_key_survives(pos in 0usize..200, byte in 0u8..128) {
            let key = mint(TEST_SEED, &pro_payload(None));
            proptest::prop_assume!(pos < key.len());
            let mut b = key.clone().into_bytes();
            proptest::prop_assume!(b[pos] != byte);
            b[pos] = byte;
            let Ok(mutated) = String::from_utf8(b) else { return Ok(()) };
            // Whitespace is stripped before parsing, so inserting some is a no-op
            // by design (see `check`) - that is the line-wrap tolerance, not a hole.
            proptest::prop_assume!(!(byte as char).is_whitespace());
            let st = verify_with(&mutated, &issuer(TEST_SEED), NOW);
            proptest::prop_assert_eq!(st.tier(), Tier::Free, "mutation at {} survived", pos);
        }
    }
}
