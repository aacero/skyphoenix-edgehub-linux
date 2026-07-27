#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mint-license.sh - issue a Xeneon Edge Pro licence key.
#
# Thin wrapper over the issuer tool (tools/license-tool). The SECRET signing seed
# is NEVER passed on the command line or in the environment (either can expose
# it to another same-user process). It is read only from a protected file:
#
#   env XENEON_LICENSE_SEED_FILE=/absolute/path/to/xeneon-license-seed \
#     ./scripts/mint-license.sh --to "Ada Lovelace <ada@x.io>" --id XE-0007
#
# Seed files must have an absolute path, be owned by the current user, use
# owner-only permissions such as 0600, and be no larger than 256 bytes.
#
# First time only - create the keypair, paste the PUBLIC key into
# core/src/license.rs, and store the PRIVATE seed in your password manager:
#
#   cargo run -q --locked --manifest-path tools/license-tool/Cargo.toml -- keygen
#
# Options (passed through to `mint`): --to <name/email>  --id <id>
#   [--tier pro]  [--expires <unix-seconds|never>]   (default: pro, never)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
readonly MAX_SEED_INPUT_BYTES=256

if [[ -v XENEON_LICENSE_SEED ]]; then
    unset XENEON_LICENSE_SEED
    echo "error: XENEON_LICENSE_SEED is unsupported because environment secrets are observable." >&2
    echo "       Use XENEON_LICENSE_SEED_FILE with an owner-only regular file." >&2
    exit 2
fi

# Build the issuer before reading or opening the private seed. Remove both
# related variables from the build environment so Cargo, rustc, build scripts,
# and any future compiler helpers cannot observe a seed or its file path.
env -u XENEON_LICENSE_SEED -u XENEON_LICENSE_SEED_FILE \
    cargo build -q --locked \
    --manifest-path tools/license-tool/Cargo.toml \
    --bin xeneon-license

if [ -n "${CARGO_TARGET_DIR:-}" ]; then
    case "$CARGO_TARGET_DIR" in
        /*) LICENSE_TARGET_DIR="$CARGO_TARGET_DIR" ;;
        *) LICENSE_TARGET_DIR="$PWD/$CARGO_TARGET_DIR" ;;
    esac
else
    LICENSE_TARGET_DIR="$PWD/tools/license-tool/target"
fi
LICENSE_BIN="$LICENSE_TARGET_DIR/debug/xeneon-license"
if [ ! -x "$LICENSE_BIN" ]; then
    echo "error: built issuer binary is missing: $LICENSE_BIN" >&2
    exit 1
fi

read_protected_seed_file() {
    local seed_path="$1"

    # Use one no-follow descriptor and validate that descriptor before reading.
    # Path-only shell checks would leave a race in which the file could be
    # replaced between `test`/`stat` and the redirection that reads it.
    python3 - "$seed_path" "$MAX_SEED_INPUT_BYTES" <<'PY'
import errno
import os
import stat
import sys

path = sys.argv[1]
limit = int(sys.argv[2])


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


if not os.path.isabs(path):
    fail("signing seed file path must be absolute")

flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
try:
    descriptor = os.open(path, flags)
except OSError as error:
    if error.errno == errno.ELOOP:
        fail("signing seed file must not be a symbolic link")
    fail(f"signing seed file could not be opened: {error.strerror}")

try:
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        fail("signing seed file must be a regular file")

    current_user = os.geteuid()
    if metadata.st_uid != current_user:
        fail(
            "signing seed file must be owned by the current user "
            f"(owner {metadata.st_uid}, current user {current_user})"
        )

    permissions = stat.S_IMODE(metadata.st_mode)
    if permissions & 0o077:
        fail(
            "signing seed file has unsafe permissions "
            f"{permissions:04o}; remove all group and other access"
        )

    if metadata.st_size > limit:
        fail(f"signing seed file exceeds the {limit}-byte limit")

    chunks = []
    size = 0
    while size <= limit:
        try:
            chunk = os.read(descriptor, min(4096, limit + 1 - size))
        except OSError as error:
            fail(f"signing seed file could not be read: {error.strerror}")
        if not chunk:
            break
        chunks.append(chunk)
        size += len(chunk)

    if size > limit:
        fail(f"signing seed file exceeds the {limit}-byte limit")
finally:
    os.close(descriptor)

# Signing seeds are base64url. Preserve the wrapper's established behavior of
# accepting surrounding or embedded ASCII whitespace from copied seed files.
sys.stdout.buffer.write(b"".join(b"".join(chunks).split()))
PY
}

if [ -z "${XENEON_LICENSE_SEED_FILE:-}" ]; then
    echo "error: no signing seed file. Set XENEON_LICENSE_SEED_FILE." >&2
    echo "       (Run 'cargo run --locked --manifest-path tools/license-tool/Cargo.toml -- keygen'" >&2
    echo "        once to create it, if you have not.)" >&2
    exit 2
fi
if ! SEED="$(read_protected_seed_file "$XENEON_LICENSE_SEED_FILE")"; then
    exit 2
fi
if [ -z "$SEED" ]; then
    echo "error: signing seed file is empty" >&2
    exit 2
fi

# Put the seed on a private descriptor only after the build is complete. Remove
# the value and path from the final process environment, duplicate the
# descriptor onto stdin, and close descriptor 3 before exec. A here-string adds
# one newline, which the CLI trims.
exec 3<<<"$SEED"
unset SEED XENEON_LICENSE_SEED_FILE
exec "$LICENSE_BIN" mint --seed-stdin "$@" <&3 3<&-
