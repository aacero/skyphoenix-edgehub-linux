//! Secret-reference resolution (E7 Phase A).
//!
//! A widget's `authToken` (and any future credential) is stored in `ui_state`,
//! which is serialised verbatim into `config.toml`. A literal token there is a
//! plaintext secret on disk - so instead the config should hold only a
//! *reference*, resolved to the real value at request time and never persisted:
//!
//! | form                  | meaning                                      |
//! |-----------------------|----------------------------------------------|
//! | `${env:VAR}`          | read environment variable `VAR`              |
//! | `file:/path/to/token` | read a protected owner-only file (trimmed)   |
//! | `secret://svc/key`    | OS keyring - Phase B, not yet implemented    |
//! | anything else         | a legacy plaintext literal (still honoured)  |
//!
//! Plaintext is deliberately still honoured: E1 shipped a token field, so real
//! users may already have one typed in, and silently breaking their widget is
//! worse than the exposure they already have. `is_plaintext` lets the UI flag it
//! so they can migrate. See [`resolve`].
//!
//! NOTHING in this module may log a secret's value - only its *kind* and, on
//! failure, the reference (which is a variable name or path, not the secret).

use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::path::Path;

/// Credential files are expected to contain one short token or URL. Keeping the
/// cap deliberately small prevents a mistaken path from pulling an arbitrary
/// file into memory or forwarding its contents to a widget request.
pub const MAX_SECRET_FILE_BYTES: u64 = 8 * 1024;

/// What a stored credential string denotes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecretRef<'a> {
    /// `${env:VAR}` - resolved from the process environment.
    Env(&'a str),
    /// `file:/path` - resolved by reading the file.
    File(&'a str),
    /// `secret://service/key` - OS keyring (Phase B).
    Keyring(&'a str),
    /// A bare literal: the legacy plaintext form.
    Plaintext(&'a str),
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SecretError {
    #[error("environment variable `{0}` is not set")]
    EnvMissing(String),
    #[error("secret file `{0}` could not be read: {1}")]
    FileUnreadable(String, String),
    #[error("secret file path `{0}` must be absolute")]
    FilePathNotAbsolute(String),
    #[error("secret file `{0}` must not be a symbolic link")]
    FileSymlink(String),
    #[error("secret file `{0}` is not a regular file")]
    FileNotRegular(String),
    #[error("secret file `{0}` is owned by user {1}, not the current user {2}")]
    FileNotOwned(String, u32, u32),
    #[error("secret file `{0}` has unsafe permissions {1:o}; remove all group and other access")]
    FilePermissions(String, u32),
    #[error("secret file `{0}` exceeds the {1}-byte limit")]
    FileTooLarge(String, u64),
    #[error("secret file `{0}` is not valid UTF-8")]
    FileInvalidUtf8(String),
    #[error("secret file `{0}` is empty")]
    FileEmpty(String),
    #[error("`secret://` references need the keyring backend, which this build does not have")]
    KeyringUnsupported,
    #[error("`{0}` is not a usable reference")]
    Malformed(String),
}

/// Classify a stored credential string without resolving it.
///
/// Note the ordering: the `${env:}`/`file:`/`secret://` prefixes are checked
/// first, so a literal that merely *starts* with something similar (e.g. a
/// token that happens to begin "file") only matches when the full prefix is
/// present.
pub fn classify(raw: &str) -> SecretRef<'_> {
    let t = raw.trim();
    if let Some(rest) = t.strip_prefix("${env:") {
        if let Some(var) = rest.strip_suffix('}') {
            return SecretRef::Env(var.trim());
        }
        // "${env:FOO" with no closing brace - the user meant a ref, so treat it
        // as one (and fail loudly) rather than send a malformed literal as a
        // Bearer token to a remote host.
        return SecretRef::Env(rest.trim());
    }
    if let Some(rest) = t.strip_prefix("file:") {
        return SecretRef::File(rest.trim());
    }
    if let Some(rest) = t.strip_prefix("secret://") {
        return SecretRef::Keyring(rest.trim());
    }
    SecretRef::Plaintext(raw)
}

/// True when the stored value is a bare secret sitting in `config.toml`.
///
/// An empty value is NOT plaintext - nothing is stored, so there is nothing to
/// warn about (that is just an unconfigured widget).
pub fn is_plaintext(raw: &str) -> bool {
    !raw.trim().is_empty() && matches!(classify(raw), SecretRef::Plaintext(_))
}

fn unreadable(path: &str, error: impl std::fmt::Display) -> SecretError {
    SecretError::FileUnreadable(path.to_string(), error.to_string())
}

fn open_secret_file(path_text: &str) -> Result<File, SecretError> {
    let path = Path::new(path_text);
    if !path.is_absolute() {
        return Err(SecretError::FilePathNotAbsolute(path_text.to_string()));
    }

    // Reject unsafe file kinds before opening so a FIFO or device can never
    // block or cause side effects. The descriptor is validated again below so
    // replacing the path between this check and open cannot bypass the policy.
    let path_metadata = fs::symlink_metadata(path).map_err(|e| unreadable(path_text, e))?;
    if path_metadata.file_type().is_symlink() {
        return Err(SecretError::FileSymlink(path_text.to_string()));
    }
    if !path_metadata.is_file() {
        return Err(SecretError::FileNotRegular(path_text.to_string()));
    }

    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;

        options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(path).map_err(|e| unreadable(path_text, e))?;
    let metadata = file.metadata().map_err(|e| unreadable(path_text, e))?;
    if !metadata.is_file() {
        return Err(SecretError::FileNotRegular(path_text.to_string()));
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;

        let owner = metadata.uid();
        // SAFETY: geteuid has no preconditions and does not dereference memory.
        let current_user = unsafe { libc::geteuid() };
        if owner != current_user {
            return Err(SecretError::FileNotOwned(
                path_text.to_string(),
                owner,
                current_user,
            ));
        }
        let permissions = metadata.mode() & 0o777;
        if permissions & 0o077 != 0 {
            return Err(SecretError::FilePermissions(
                path_text.to_string(),
                permissions,
            ));
        }
    }

    if metadata.len() > MAX_SECRET_FILE_BYTES {
        return Err(SecretError::FileTooLarge(
            path_text.to_string(),
            MAX_SECRET_FILE_BYTES,
        ));
    }
    Ok(file)
}

fn read_bounded_secret(mut reader: impl Read, path: &str) -> Result<String, SecretError> {
    let mut bytes = Vec::new();
    (&mut reader)
        .take(MAX_SECRET_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| unreadable(path, e))?;
    // Check the bytes actually read as well as metadata.len(): a file can grow
    // after it is opened, but it must never bypass the cap.
    if bytes.len() as u64 > MAX_SECRET_FILE_BYTES {
        return Err(SecretError::FileTooLarge(
            path.to_string(),
            MAX_SECRET_FILE_BYTES,
        ));
    }
    String::from_utf8(bytes).map_err(|_| SecretError::FileInvalidUtf8(path.to_string()))
}

fn read_secret_file(path: &str) -> Result<String, SecretError> {
    read_bounded_secret(open_secret_file(path)?, path)
}

/// Resolve a stored credential to the value to actually send.
///
/// Errors carry the *reference* (a var name or path), never the secret.
pub fn resolve(raw: &str) -> Result<String, SecretError> {
    match classify(raw) {
        SecretRef::Env(var) => {
            if var.is_empty() {
                return Err(SecretError::Malformed(raw.trim().to_string()));
            }
            std::env::var(var).map_err(|_| SecretError::EnvMissing(var.to_string()))
        }
        SecretRef::File(path) => {
            if path.is_empty() {
                return Err(SecretError::Malformed(raw.trim().to_string()));
            }
            let contents = read_secret_file(path)?;
            // Trim: a token file almost always ends in a newline, and sending
            // that in an Authorization header breaks the request in a way that
            // is very hard to see.
            let trimmed = contents.trim();
            if trimmed.is_empty() {
                return Err(SecretError::FileEmpty(path.to_string()));
            }
            Ok(trimmed.to_string())
        }
        SecretRef::Keyring(_) => Err(SecretError::KeyringUnsupported),
        SecretRef::Plaintext(v) => Ok(v.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
    use std::path::PathBuf;

    fn protected_file(path: &Path, contents: impl AsRef<[u8]>) {
        fs::write(path, contents).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
    }

    fn file_ref(path: &Path) -> String {
        format!("file:{}", path.display())
    }

    #[test]
    fn classifies_each_form() {
        assert_eq!(classify("${env:CI_TOKEN}"), SecretRef::Env("CI_TOKEN"));
        assert_eq!(classify("file:/run/tok"), SecretRef::File("/run/tok"));
        assert_eq!(classify("secret://edge/ci"), SecretRef::Keyring("edge/ci"));
        assert_eq!(classify("ghp_literal"), SecretRef::Plaintext("ghp_literal"));
    }

    #[test]
    fn classify_tolerates_surrounding_whitespace() {
        assert_eq!(classify("  ${env:TOK}  "), SecretRef::Env("TOK"));
        assert_eq!(classify(" file: /run/tok "), SecretRef::File("/run/tok"));
    }

    // A token that merely starts with letters resembling a scheme must stay a
    // literal - otherwise a real token could be silently reinterpreted as a path.
    #[test]
    fn a_literal_resembling_a_scheme_is_still_a_literal() {
        assert_eq!(
            classify("filesystem-token"),
            SecretRef::Plaintext("filesystem-token")
        );
        assert_eq!(classify("secretive"), SecretRef::Plaintext("secretive"));
        assert_eq!(classify("${envelope}"), SecretRef::Plaintext("${envelope}"));
    }

    #[test]
    fn is_plaintext_flags_only_bare_literals() {
        assert!(is_plaintext("ghp_abc123"));
        assert!(!is_plaintext("${env:TOK}"));
        assert!(!is_plaintext("file:/run/tok"));
        assert!(!is_plaintext("secret://a/b"));
        // Nothing stored → nothing to warn about.
        assert!(!is_plaintext(""));
        assert!(!is_plaintext("   "));
    }

    #[test]
    fn resolves_env_ref() {
        let _g = crate::TEST_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::env::set_var("XENEON_TEST_SECRET", "s3cr3t");
        assert_eq!(resolve("${env:XENEON_TEST_SECRET}").unwrap(), "s3cr3t");
        std::env::remove_var("XENEON_TEST_SECRET");
    }

    #[test]
    fn missing_env_ref_errors_and_names_the_var_not_a_value() {
        let _g = crate::TEST_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::env::remove_var("XENEON_TEST_ABSENT");
        let err = resolve("${env:XENEON_TEST_ABSENT}").unwrap_err();
        assert_eq!(err, SecretError::EnvMissing("XENEON_TEST_ABSENT".into()));
        assert!(err.to_string().contains("XENEON_TEST_ABSENT"));
    }

    #[test]
    fn unclosed_env_ref_is_never_treated_as_a_plaintext_token() {
        let _g = crate::TEST_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::env::remove_var("XENEON_TEST_UNCLOSED");

        assert_eq!(
            classify("${env:XENEON_TEST_UNCLOSED"),
            SecretRef::Env("XENEON_TEST_UNCLOSED")
        );
        assert_eq!(
            resolve("${env:XENEON_TEST_UNCLOSED").unwrap_err(),
            SecretError::EnvMissing("XENEON_TEST_UNCLOSED".into())
        );
    }

    #[test]
    fn resolves_file_ref_and_trims_the_trailing_newline() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("tok");
        // The newline is the realistic case: `echo tok > file` leaves one, and
        // sending it in a header breaks auth confusingly.
        protected_file(&p, "file-token\n");
        let r = resolve(&file_ref(&p)).unwrap();
        assert_eq!(r, "file-token");
    }

    #[test]
    fn relative_file_ref_is_rejected_before_it_is_opened() {
        let err = resolve("file:relative/private-token").unwrap_err();
        assert_eq!(
            err,
            SecretError::FilePathNotAbsolute("relative/private-token".into())
        );
    }

    #[test]
    fn unreadable_file_errors_with_the_path() {
        let err = resolve("file:/nonexistent/xeneon/tok").unwrap_err();
        assert!(
            matches!(err, SecretError::FileUnreadable(ref p, _) if p == "/nonexistent/xeneon/tok")
        );
    }

    #[test]
    fn empty_file_is_an_error_not_an_empty_token() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("empty");
        protected_file(&p, "\n  \n");
        let err = resolve(&file_ref(&p)).unwrap_err();
        assert!(matches!(err, SecretError::FileEmpty(_)));
    }

    #[test]
    fn symlink_file_ref_is_rejected_without_following_it() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target");
        let link = dir.path().join("link");
        protected_file(&target, "must-not-be-read");
        symlink(&target, &link).unwrap();

        assert_eq!(
            resolve(&file_ref(&link)).unwrap_err(),
            SecretError::FileSymlink(link.display().to_string())
        );
    }

    #[test]
    fn directory_and_fifo_file_refs_are_rejected_as_non_regular() {
        let dir = tempfile::tempdir().unwrap();
        let directory = dir.path().join("directory");
        fs::create_dir(&directory).unwrap();
        assert_eq!(
            resolve(&file_ref(&directory)).unwrap_err(),
            SecretError::FileNotRegular(directory.display().to_string())
        );

        let fifo = dir.path().join("fifo");
        let fifo_c = CString::new(fifo.as_os_str().as_bytes()).unwrap();
        // SAFETY: fifo_c is a valid, NUL-terminated path and mkfifo does not
        // retain the pointer.
        assert_eq!(unsafe { libc::mkfifo(fifo_c.as_ptr(), 0o600) }, 0);
        assert_eq!(
            resolve(&file_ref(&fifo)).unwrap_err(),
            SecretError::FileNotRegular(fifo.display().to_string())
        );
    }

    #[test]
    fn file_owned_by_another_user_is_rejected() {
        // A non-root test process can use a known root-owned regular file. A
        // root test process can create a fixture and give it to UID 1.
        // SAFETY: geteuid has no preconditions.
        let current_user = unsafe { libc::geteuid() };
        let (path, _guard) = if current_user == 0 {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("foreign");
            protected_file(&path, "must-not-be-read");
            let path_c = CString::new(path.as_os_str().as_bytes()).unwrap();
            // SAFETY: path_c is valid for the duration of the call. Passing -1
            // for the group leaves it unchanged.
            assert_eq!(
                unsafe { libc::chown(path_c.as_ptr(), 1, u32::MAX) },
                0,
                "root test process must be able to prepare a foreign-owned fixture"
            );
            (path, Some(dir))
        } else {
            (PathBuf::from("/etc/passwd"), None)
        };
        let owner = fs::metadata(&path).unwrap().uid();
        assert_ne!(owner, current_user);

        assert_eq!(
            resolve(&file_ref(&path)).unwrap_err(),
            SecretError::FileNotOwned(path.display().to_string(), owner, current_user)
        );
    }

    #[test]
    fn group_or_other_access_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("shared");
        protected_file(&p, "must-not-be-read");
        fs::set_permissions(&p, fs::Permissions::from_mode(0o640)).unwrap();

        assert_eq!(
            resolve(&file_ref(&p)).unwrap_err(),
            SecretError::FilePermissions(p.display().to_string(), 0o640)
        );
    }

    #[test]
    fn input_at_size_limit_is_accepted_and_one_byte_more_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let at_limit = dir.path().join("at-limit");
        protected_file(&at_limit, vec![b'a'; MAX_SECRET_FILE_BYTES as usize]);
        assert_eq!(
            resolve(&file_ref(&at_limit)).unwrap().len(),
            MAX_SECRET_FILE_BYTES as usize
        );

        let oversized = dir.path().join("oversized");
        protected_file(&oversized, vec![b'a'; MAX_SECRET_FILE_BYTES as usize + 1]);
        assert_eq!(
            resolve(&file_ref(&oversized)).unwrap_err(),
            SecretError::FileTooLarge(oversized.display().to_string(), MAX_SECRET_FILE_BYTES)
        );
    }

    #[test]
    fn bounded_reader_rejects_a_file_that_grows_after_metadata_validation() {
        let bytes = vec![b'a'; MAX_SECRET_FILE_BYTES as usize + 1];
        assert_eq!(
            read_bounded_secret(bytes.as_slice(), "/already-open-fixture").unwrap_err(),
            SecretError::FileTooLarge("/already-open-fixture".into(), MAX_SECRET_FILE_BYTES)
        );
    }

    #[test]
    fn invalid_utf8_secret_file_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("invalid-utf8");
        protected_file(&p, [0xff, 0xfe]);
        assert_eq!(
            resolve(&file_ref(&p)).unwrap_err(),
            SecretError::FileInvalidUtf8(p.display().to_string())
        );
    }

    #[test]
    fn keyring_ref_is_unsupported_in_phase_a() {
        assert_eq!(
            resolve("secret://edge/ci").unwrap_err(),
            SecretError::KeyringUnsupported
        );
    }

    #[test]
    fn plaintext_still_resolves_to_itself() {
        // Legacy values must keep working - breaking a user's widget is worse
        // than the exposure they already have; the UI warns instead.
        assert_eq!(resolve("ghp_literal").unwrap(), "ghp_literal");
    }

    #[test]
    fn empty_ref_forms_are_malformed_not_silently_empty() {
        assert!(matches!(resolve("${env:}"), Err(SecretError::Malformed(_))));
        assert!(matches!(resolve("file:"), Err(SecretError::Malformed(_))));
    }
}
