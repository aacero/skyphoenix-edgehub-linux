#!/usr/bin/env python3
"""Read one owner-issued release licence from a protected regular file."""

from __future__ import annotations

import errno
import os
import stat
import sys
from typing import NoReturn


MAX_LICENSE_BYTES = 4096


def fail(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def main(arguments: list[str]) -> int:
    if len(arguments) != 1:
        fail("owner licence reader requires exactly one file path")

    path = arguments[0]
    if not os.path.isabs(path):
        fail("owner licence file path must be absolute")

    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        if error.errno == errno.ELOOP:
            fail("owner licence file must not be a symbolic link")
        fail(f"owner licence file could not be opened: {error.strerror}")

    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail("owner licence file must be a regular file")
        if metadata.st_uid != os.geteuid():
            fail("owner licence file must be owned by the current user")

        permissions = stat.S_IMODE(metadata.st_mode)
        if permissions & 0o077:
            fail(
                "owner licence file must not grant group or other access "
                f"(mode {permissions:04o})"
            )
        if metadata.st_size > MAX_LICENSE_BYTES:
            fail(
                f"owner licence file exceeds the {MAX_LICENSE_BYTES}-byte limit"
            )

        chunks: list[bytes] = []
        size = 0
        while size <= MAX_LICENSE_BYTES:
            try:
                chunk = os.read(
                    descriptor, min(4096, MAX_LICENSE_BYTES + 1 - size)
                )
            except OSError as error:
                fail(f"owner licence file could not be read: {error.strerror}")
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        if size > MAX_LICENSE_BYTES:
            fail(
                f"owner licence file exceeds the {MAX_LICENSE_BYTES}-byte limit"
            )
    finally:
        os.close(descriptor)

    raw = b"".join(chunks).strip(b" \t\r\n")
    if not raw:
        fail("owner licence file is empty")
    if b"\0" in raw or any(byte in b" \t\r\n\v\f" for byte in raw):
        fail("owner licence file must contain exactly one whitespace-free key")
    try:
        key = raw.decode("ascii")
    except UnicodeDecodeError:
        fail("owner licence file is not ASCII")

    # No newline: callers capture this exact value and move it through a private
    # inherited descriptor. Errors above never echo any part of the key.
    sys.stdout.write(key)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
