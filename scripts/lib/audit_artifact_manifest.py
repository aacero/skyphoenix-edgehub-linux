#!/usr/bin/env python3
"""Create and verify a lease-protected audit evidence manifest on Linux."""

from __future__ import annotations

import errno
import fcntl
import fnmatch
import hashlib
import os
import signal
import stat
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path


MANIFEST_NAME = b"MANIFEST.sha256"
SIGNATURE_NAME = b"MANIFEST.sha256.asc"
LOCK_NAME = b".audit-finalization.lock"
TEMP_PREFIX = b".audit-manifest.tmp."
SIGNATURE_TEMP_PREFIX = b".audit-signature.tmp."
TRANSIENT_PATTERNS = (
    "*.lock",
    "*.tmp",
    "*.tmp.*",
    "*.temp",
    "*.part",
    "*.swp",
    "*.swo",
    "*~",
    ".#*",
)


class AuditError(RuntimeError):
    """A condition that makes an audit seal unsafe or ambiguous."""


@dataclass(frozen=True)
class Entry:
    relative: bytes
    path: bytes
    kind: str
    metadata: tuple[int, ...]


@dataclass
class HeldFile:
    entry: Entry
    descriptor: int


lease_break_requested = False


def handle_lease_break(_signal_number: int, _frame: object) -> None:
    global lease_break_requested
    lease_break_requested = True


def metadata_signature(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def output_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_nlink,
    )


def validate_metadata(path: bytes, metadata: os.stat_result, *, directory: bool) -> None:
    expected_uid = os.geteuid()
    expected_gid = os.getegid()
    display_path = os.fsdecode(path)
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected_type(metadata.st_mode):
        raise AuditError(f"symlink or special artifact entry is unsafe: {display_path}")
    if metadata.st_uid != expected_uid or metadata.st_gid != expected_gid:
        raise AuditError(
            "unsafe ownership for "
            f"{display_path}: expected {expected_uid}:{expected_gid}, "
            f"found {metadata.st_uid}:{metadata.st_gid}"
        )
    if metadata.st_mode & 0o022:
        raise AuditError(
            f"group/other-writable artifact entry is unsafe: {display_path}"
        )
    if not directory and metadata.st_nlink != 1:
        raise AuditError(f"multiply-linked artifact file is unsafe: {display_path}")


def validate_component(component: bytes, *, internal: bool = False) -> str:
    try:
        text = component.decode("utf-8", "strict")
    except UnicodeDecodeError as error:
        raise AuditError("artifact filename is not valid UTF-8") from error
    if not text or text in (".", ".."):
        raise AuditError(f"ambiguous artifact filename: {text!r}")
    if text != text.strip() or "\\" in text:
        raise AuditError(f"ambiguous artifact filename: {text!r}")
    if unicodedata.normalize("NFC", text) != text:
        raise AuditError(f"artifact filename is not NFC-normalized: {text!r}")
    if any(
        unicodedata.category(character).startswith("C")
        or unicodedata.category(character) in ("Zl", "Zp")
        for character in text
    ):
        raise AuditError(f"ambiguous control character in artifact filename: {text!r}")
    if not internal:
        allowed = set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            "abcdefghijklmnopqrstuvwxyz"
            "0123456789._+-"
        )
        if (
            text[0] == "."
            or text[-1] == "."
            or ".." in text
            or "#" in text
            or any(character not in allowed for character in text)
        ):
            raise AuditError(f"non-portable artifact filename: {text!r}")
    return text


def is_user_transient(name: str) -> bool:
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in TRANSIENT_PATTERNS)


def join_relative(parent: bytes, child: bytes) -> bytes:
    return child if not parent else parent + b"/" + child


def scan_tree(
    artifact_dir: bytes,
    *,
    mode: str,
    allowed_temp_name: bytes | None,
) -> dict[bytes, Entry]:
    entries: dict[bytes, Entry] = {}
    root_metadata = os.lstat(artifact_dir)
    validate_metadata(artifact_dir, root_metadata, directory=True)
    entries[b"."] = Entry(
        relative=b".",
        path=artifact_dir,
        kind="directory",
        metadata=metadata_signature(root_metadata),
    )

    def visit(directory: bytes, relative_parent: bytes) -> None:
        try:
            children = sorted(os.scandir(directory), key=lambda item: item.name)
        except OSError as error:
            raise AuditError(
                f"could not enumerate artifact directory {os.fsdecode(directory)}: {error}"
            ) from error

        for child in children:
            name = child.name
            if not isinstance(name, bytes):
                name = os.fsencode(name)
            relative = join_relative(relative_parent, name)
            path = os.path.join(directory, name)
            metadata = child.stat(follow_symlinks=False)
            root_entry = not relative_parent
            internal_name = root_entry and (
                name in (LOCK_NAME, MANIFEST_NAME, SIGNATURE_NAME)
                or name.startswith(TEMP_PREFIX)
                or name.startswith(SIGNATURE_TEMP_PREFIX)
            )
            text_name = validate_component(name, internal=internal_name)

            if name == LOCK_NAME:
                if not root_entry:
                    raise AuditError(
                        f"reserved lock name outside artifact root: {os.fsdecode(path)}"
                    )
                validate_metadata(path, metadata, directory=True)
                try:
                    lock_children = os.listdir(path)
                except OSError as error:
                    raise AuditError(f"could not inspect internal lock: {error}") from error
                if lock_children:
                    raise AuditError("internal finalization lock is not empty")
                entries[relative] = Entry(
                    relative=relative,
                    path=path,
                    kind="internal-lock",
                    metadata=metadata_signature(metadata),
                )
                continue

            if name == MANIFEST_NAME:
                if not root_entry:
                    raise AuditError(
                        f"reserved manifest name outside artifact root: {os.fsdecode(path)}"
                    )
                if mode == "generate":
                    raise AuditError("manifest already exists and will not be replaced")
                validate_metadata(path, metadata, directory=False)
                entries[relative] = Entry(
                    relative=relative,
                    path=path,
                    kind="manifest",
                    metadata=metadata_signature(metadata),
                )
                continue

            if name == SIGNATURE_NAME:
                if not root_entry:
                    raise AuditError(
                        f"reserved signature name outside artifact root: {os.fsdecode(path)}"
                    )
                if mode == "generate":
                    raise AuditError("manifest signature already exists")
                validate_metadata(path, metadata, directory=False)
                entries[relative] = Entry(
                    relative=relative,
                    path=path,
                    kind="signature",
                    metadata=metadata_signature(metadata),
                )
                continue

            if name.startswith(TEMP_PREFIX):
                if not root_entry or name != allowed_temp_name:
                    raise AuditError(
                        f"stale internal finalization temp file: {os.fsdecode(path)}"
                    )
                validate_metadata(path, metadata, directory=False)
                entries[relative] = Entry(
                    relative=relative,
                    path=path,
                    kind="internal-output",
                    metadata=output_identity(metadata),
                )
                continue

            if name.startswith(SIGNATURE_TEMP_PREFIX):
                raise AuditError(
                    f"stale internal finalization temp file: {os.fsdecode(path)}"
                )

            if is_user_transient(text_name):
                raise AuditError(
                    f"leftover user transient file must be removed: {os.fsdecode(path)}"
                )

            if stat.S_ISDIR(metadata.st_mode):
                validate_metadata(path, metadata, directory=True)
                entries[relative] = Entry(
                    relative=relative,
                    path=path,
                    kind="directory",
                    metadata=metadata_signature(metadata),
                )
                visit(path, relative)
                continue

            validate_metadata(path, metadata, directory=False)
            entries[relative] = Entry(
                relative=relative,
                path=path,
                kind="evidence",
                metadata=metadata_signature(metadata),
            )

    visit(artifact_dir, b"")

    if mode == "verify":
        if MANIFEST_NAME not in entries:
            raise AuditError("manifest does not exist")
        if SIGNATURE_NAME not in entries:
            raise AuditError("manifest signature does not exist")
    if mode == "generate" and allowed_temp_name not in entries:
        raise AuditError("internal manifest output file disappeared")
    return entries


def acquire_leases(entries: dict[bytes, Entry]) -> list[HeldFile]:
    global lease_break_requested
    lease_break_requested = False
    held: list[HeldFile] = []
    for relative in sorted(entries):
        entry = entries[relative]
        if entry.kind not in ("evidence", "manifest", "signature"):
            continue
        descriptor = os.open(
            entry.path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
        )
        try:
            current_metadata = metadata_signature(os.fstat(descriptor))
            if current_metadata != entry.metadata:
                raise AuditError(
                    "artifact path changed before lease acquisition: "
                    f"{os.fsdecode(entry.path)}"
                )
            fcntl.fcntl(descriptor, fcntl.F_SETOWN, os.getpid())
            fcntl.fcntl(descriptor, fcntl.F_SETLEASE, fcntl.F_RDLCK)
        except OSError as error:
            os.close(descriptor)
            if error.errno in (errno.EACCES, errno.EAGAIN):
                raise AuditError(
                    "an artifact file is still open for writing: "
                    f"{os.fsdecode(entry.path)}"
                ) from error
            raise AuditError(
                "kernel writer lease failed for "
                f"{os.fsdecode(entry.path)}: {error}"
            ) from error
        except Exception:
            os.close(descriptor)
            raise
        held.append(HeldFile(entry=entry, descriptor=descriptor))
    return held


def close_held_files(held: list[HeldFile]) -> None:
    for item in held:
        try:
            os.close(item.descriptor)
        except OSError:
            pass


def hash_descriptor(descriptor: int) -> str:
    digest = hashlib.sha256()
    offset = 0
    while True:
        chunk = os.pread(descriptor, 1024 * 1024, offset)
        if not chunk:
            break
        digest.update(chunk)
        offset += len(chunk)
    return digest.hexdigest()


def read_descriptor(descriptor: int, maximum_size: int) -> bytes:
    output = bytearray()
    offset = 0
    while len(output) <= maximum_size:
        chunk = os.pread(descriptor, min(1024 * 1024, maximum_size + 1 - len(output)), offset)
        if not chunk:
            return bytes(output)
        output.extend(chunk)
        offset += len(chunk)
    raise AuditError("manifest is larger than the generated evidence manifest")


def render_manifest(held: list[HeldFile]) -> bytes:
    lines: list[bytes] = []
    evidence = sorted(
        (item for item in held if item.entry.kind == "evidence"),
        key=lambda item: item.entry.relative,
    )
    if not evidence:
        raise AuditError("artifact directory contains no final evidence files")
    for item in evidence:
        digest = hash_descriptor(item.descriptor).encode("ascii")
        lines.append(digest + b"  ./" + item.entry.relative + b"\n")
    return b"".join(lines)


def validate_after_hash(
    artifact_dir: bytes,
    initial_entries: dict[bytes, Entry],
    held: list[HeldFile],
    *,
    mode: str,
    allowed_temp_name: bytes | None,
) -> None:
    def validate_held_inodes(stage: str) -> None:
        if lease_break_requested:
            raise AuditError(f"an artifact writer raced {stage}")
        for item in held:
            if fcntl.fcntl(item.descriptor, fcntl.F_GETLEASE) != fcntl.F_RDLCK:
                raise AuditError(
                    "an artifact writer broke the hash lease: "
                    f"{os.fsdecode(item.entry.path)}"
                )
            if metadata_signature(os.fstat(item.descriptor)) != item.entry.metadata:
                raise AuditError(
                    "artifact inode metadata changed during hashing: "
                    f"{os.fsdecode(item.entry.path)}"
                )

    validate_held_inodes("manifest hashing")
    final_entries = scan_tree(
        artifact_dir, mode=mode, allowed_temp_name=allowed_temp_name
    )
    if final_entries != initial_entries:
        initial_paths = set(initial_entries)
        final_paths = set(final_entries)
        added = sorted(final_paths - initial_paths)
        removed = sorted(initial_paths - final_paths)
        if added:
            detail = f"added path {os.fsdecode(added[0])}"
        elif removed:
            detail = f"removed path {os.fsdecode(removed[0])}"
        else:
            changed = next(
                path
                for path in sorted(initial_paths)
                if initial_entries[path] != final_entries[path]
            )
            detail = f"changed path/inode/metadata {os.fsdecode(changed)}"
        raise AuditError(f"artifact tree changed during hashing: {detail}")

    validate_held_inodes("the final metadata rescan")


def write_output(output_path: bytes, expected: Entry, content: bytes) -> None:
    descriptor = os.open(
        output_path, os.O_WRONLY | os.O_TRUNC | os.O_CLOEXEC | os.O_NOFOLLOW
    )
    try:
        if output_identity(os.fstat(descriptor)) != expected.metadata:
            raise AuditError("internal manifest output path changed before writing")
        view = memoryview(content)
        written = 0
        while written < len(view):
            written += os.write(descriptor, view[written:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def generate(artifact_dir: bytes, output_path: bytes) -> None:
    if os.path.dirname(output_path) != artifact_dir:
        raise AuditError("internal manifest output must be inside the artifact root")
    output_name = os.path.basename(output_path)
    if not output_name.startswith(TEMP_PREFIX):
        raise AuditError("internal manifest output has an invalid name")

    entries = scan_tree(
        artifact_dir, mode="generate", allowed_temp_name=output_name
    )
    held = acquire_leases(entries)
    try:
        manifest = render_manifest(held)
        output_entry = entries[output_name]
        write_output(output_path, output_entry, manifest)
        validate_after_hash(
            artifact_dir,
            entries,
            held,
            mode="generate",
            allowed_temp_name=output_name,
        )
    finally:
        close_held_files(held)


def verify(artifact_dir: bytes) -> None:
    entries = scan_tree(artifact_dir, mode="verify", allowed_temp_name=None)
    held = acquire_leases(entries)
    try:
        expected = render_manifest(held)
        manifest_item = next(
            item for item in held if item.entry.kind == "manifest"
        )
        actual = read_descriptor(manifest_item.descriptor, len(expected))
        if actual != expected:
            raise AuditError(
                "artifact evidence does not match the finalized SHA-256 manifest"
            )
        validate_after_hash(
            artifact_dir,
            entries,
            held,
            mode="verify",
            allowed_temp_name=None,
        )
    finally:
        close_held_files(held)


def canonical_directory(value: str) -> bytes:
    path = Path(value)
    resolved = path.resolve(strict=True)
    if not resolved.is_dir():
        raise AuditError(f"artifact path is not a directory: {resolved}")
    return os.fsencode(resolved)


def main(arguments: list[str]) -> int:
    if len(arguments) not in (3, 4) or arguments[1] not in ("generate", "verify"):
        print(
            "Usage: audit_artifact_manifest.py "
            "generate ARTIFACT_DIR OUTPUT_PATH | verify ARTIFACT_DIR",
            file=sys.stderr,
        )
        return 2
    try:
        for attribute in ("F_SETLEASE", "F_GETLEASE", "F_SETOWN"):
            if not hasattr(fcntl, attribute):
                raise AuditError(f"Linux file leases are unavailable: {attribute}")
        signal.signal(signal.SIGIO, handle_lease_break)
        artifact_dir = canonical_directory(arguments[2])
        if arguments[1] == "generate":
            if len(arguments) != 4:
                raise AuditError("generate requires an output path")
            output_path = os.fsencode(os.path.abspath(arguments[3]))
            generate(artifact_dir, output_path)
        else:
            if len(arguments) != 3:
                raise AuditError("verify does not accept an output path")
            verify(artifact_dir)
    except (AuditError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
