#!/usr/bin/env python3
"""Install one reviewed Mesh Monitor build transactionally; never launch or stop apps.

Requires the exact build receipt SHA-256 and --apps-stopped. Review the receipt and
stop both voice apps before invoking this script. A failed transaction attempts
exclusive, non-overwriting rollback; its durable journal preserves recovery paths
if external changes, process termination or disk failure prevent restoration.
"""
from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import pwd
import re
import signal
import stat
import subprocess
import sys
import uuid

APP_NAME = "Mesh Monitor.app"
LEGACY_NAME = "M4LocalVoiceNotch.app"
BUNDLE_ID = "com.devansh.m4-local-voice-notch"
UID = os.getuid()
RENAME_EXCL = 0x00000004  # macOS SDK usr/include/sys/stdio.h


class InstallError(RuntimeError):
    pass


def absolute_path(path: Path) -> Path:
    return Path(os.path.abspath(os.path.expanduser(str(path))))


def reject_symlink_ancestors(path: Path) -> None:
    for component in [*reversed(path.parents), path]:
        try:
            info = component.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise InstallError(f"Refusing a symlink: {component}")
        if component != path and not stat.S_ISDIR(info.st_mode):
            raise InstallError(f"Parent is not a directory: {component}")


def owned_directory(path: Path) -> os.stat_result:
    reject_symlink_ancestors(path)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != UID:
        raise InstallError(f"Expected a user-owned directory: {path}")
    if info.st_mode & (stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX):
        raise InstallError(f"Refusing special directory permissions: {path}")
    return info


def ensure_owned_directory(path: Path, home: Path) -> None:
    if not path.is_relative_to(home):
        raise InstallError("Installer directories must be inside the current user's home.")
    owned_directory(home)
    current = home
    for part in path.relative_to(home).parts:
        current = current / part
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            pass
        owned_directory(current)


def regular_file(path: Path) -> os.stat_result:
    reject_symlink_ancestors(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != UID:
        raise InstallError(f"Expected a user-owned regular file: {path}")
    if info.st_mode & (stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX):
        raise InstallError(f"Refusing special file permissions: {path}")
    return info


def digest(path: Path) -> str:
    regular_file(path)
    sha = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def tree_files(app: Path) -> dict[str, Path]:
    owned_directory(app)
    result: dict[str, Path] = {}
    for directory, subdirectories, filenames in os.walk(app, followlinks=False):
        parent = Path(directory)
        owned_directory(parent)
        for name in subdirectories:
            owned_directory(parent / name)
        for name in filenames:
            path = parent / name
            regular_file(path)
            result[path.relative_to(app).as_posix()] = path
    return result


def file_manifest(app: Path) -> list[dict]:
    return [
        {"path": relative, "sha256": digest(path), "bytes": path.stat().st_size,
         "mode": oct(stat.S_IMODE(path.stat().st_mode))}
        for relative, path in sorted(tree_files(app).items())
    ]


def expected_manifest(receipt: dict) -> dict[str, dict]:
    entries = receipt.get("files")
    if not isinstance(entries, list) or not entries or len(entries) > 10000:
        raise InstallError("Build receipt has no bounded file manifest.")
    expected: dict[str, dict] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise InstallError("Build receipt contains a non-object file record.")
        value = entry.get("path", "")
        if not isinstance(value, str):
            raise InstallError("Build receipt contains a non-string file path.")
        path = PurePosixPath(value)
        if (str(path) != value or path.is_absolute()
                or len(path.parts) < 2 or path.parts[0] != APP_NAME
                or any(part in (".", "..") for part in path.parts) or "\\" in value):
            raise InstallError("Build receipt contains an invalid app-relative path.")
        relative = PurePosixPath(*path.parts[1:]).as_posix()
        if relative in expected or not re.fullmatch(r"[0-9a-f]{64}", entry.get("sha256", "")):
            raise InstallError("Build receipt contains duplicate paths or invalid hashes.")
        if not isinstance(entry.get("bytes"), int) or entry["bytes"] < 0:
            raise InstallError("Build receipt contains an invalid file size.")
        expected[relative] = entry
    return expected


def verify_hashes(app: Path, expected: dict[str, dict]) -> list[dict]:
    files = tree_files(app)
    if set(files) != set(expected):
        raise InstallError("App file inventory does not exactly match the reviewed build receipt.")
    verified = []
    for relative, path in sorted(files.items()):
        actual = digest(path)
        if path.stat().st_size != expected[relative]["bytes"] or actual != expected[relative]["sha256"]:
            raise InstallError(f"App file differs from the reviewed build: {relative}")
        verified.append({"path": relative, "sha256": actual, "bytes": path.stat().st_size,
                         "mode": oct(stat.S_IMODE(path.stat().st_mode))})
    return verified


def app_identity(app: Path, receipt: dict | None = None) -> dict:
    regular_file(app / "Contents/Info.plist")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise InstallError(f"Unexpected application identifier at {app}")
    if receipt is not None:
        if (info.get("CFBundleShortVersionString") != receipt.get("version")
                or info.get("CFBundleVersion") != receipt.get("build")
                or info.get("CFBundleExecutable") != "MeshMonitor"):
            raise InstallError("Bundle identity/version does not match the reviewed build receipt.")
    return {key: info.get(key) for key in (
        "CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion")}


def verify_signature(app: Path) -> None:
    result = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
        text=True, capture_output=True, timeout=30,
    )
    if result.returncode:
        raise InstallError(f"Code signature verification failed for {app}: {result.stderr.strip()}")


def rename_exclusive(source: Path, destination: Path) -> None:
    """Atomic macOS rename that can never replace an existing destination."""
    reject_symlink_ancestors(source)
    reject_symlink_ancestors(destination)
    library = ctypes.CDLL(None, use_errno=True)
    operation = library.renamex_np
    operation.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    operation.restype = ctypes.c_int
    if operation(os.fsencode(source), os.fsencode(destination), RENAME_EXCL) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def copy_tree_bytes_and_modes(source: Path, destination: Path) -> None:
    # The destination already exists because this process created it exclusively.
    # Avoid copy2/copytree: extended attributes and Finder metadata must not cross.
    owned_directory(destination)
    directories = [(source, destination)]
    for directory, subdirectories, filenames in os.walk(source, followlinks=False):
        original_parent = Path(directory)
        owned_directory(original_parent)
        copied_parent = destination / original_parent.relative_to(source)
        for name in subdirectories:
            original = original_parent / name
            owned_directory(original)
            copied = copied_parent / name
            copied.mkdir(mode=0o700)  # exclusive; never merges an existing directory
            directories.append((original, copied))
        for name in filenames:
            original = original_parent / name
            original_info = regular_file(original)
            source_fd = os.open(original, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                target_fd = os.open(copied_parent / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            except BaseException:
                os.close(source_fd)
                raise
            with os.fdopen(source_fd, "rb") as reader, os.fdopen(target_fd, "wb") as writer:
                for chunk in iter(lambda: reader.read(1024 * 1024), b""):
                    writer.write(chunk)
                writer.flush()
                os.fchmod(writer.fileno(), stat.S_IMODE(original_info.st_mode))
                os.fsync(writer.fileno())
    for original, copied in reversed(directories):
        copied.chmod(stat.S_IMODE(original.stat().st_mode))


def write_new_file(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def append_journal(path: Path, event: dict) -> None:
    # Existing journal was exclusively created by this transaction.
    regular_file(path)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
    with os.fdopen(fd, "ab") as stream:
        stream.write((json.dumps({"at": datetime.now(timezone.utc).isoformat(), **event}, sort_keys=True) + "\n").encode())
        stream.flush()
        os.fsync(stream.fileno())


def install(receipt_path: Path, receipt_sha256: str, *, apps_stopped: bool) -> Path:
    if sys.platform != "darwin":
        raise InstallError("This installer requires macOS exclusive-rename support.")
    if not apps_stopped:
        raise InstallError("Caller must stop the legacy and new apps before using --apps-stopped.")
    receipt_path = absolute_path(receipt_path)
    regular_file(receipt_path)
    if not re.fullmatch(r"[0-9a-f]{64}", receipt_sha256) or digest(receipt_path) != receipt_sha256:
        raise InstallError("Build receipt SHA-256 does not match the explicitly reviewed receipt.")
    if receipt_path.stat().st_size > 4 * 1024 * 1024:
        raise InstallError("Build receipt exceeds the allowed size.")
    receipt_bytes = receipt_path.read_bytes()
    if hashlib.sha256(receipt_bytes).hexdigest() != receipt_sha256:
        raise InstallError("Build receipt changed during verification.")
    receipt = json.loads(receipt_bytes)
    if not isinstance(receipt, dict):
        raise InstallError("Build receipt must be a JSON object.")
    if (receipt.get("schema_version") != "mesh-monitor-build.v1"
            or receipt.get("bundle_id") != BUNDLE_ID or receipt.get("app") != APP_NAME):
        raise InstallError("Not a Mesh Monitor build receipt.")
    canonical = receipt.get("verified_staging_app")
    if not isinstance(canonical, str):
        raise InstallError("Receipt must name its canonical verified staging app.")
    source = absolute_path(Path(canonical))
    if (str(source) != canonical or source.name != APP_NAME
            or source.parent.parent != Path("/private/tmp")
            or not source.parent.name.startswith("mesh-monitor-sign-")):
        raise InstallError("Use the builder's canonical /private/tmp staging app, not the Desktop copy.")
    owned_directory(source.parent)
    expected = expected_manifest(receipt)
    verified_files = verify_hashes(source, expected)
    app_identity(source, receipt)
    verify_signature(source)

    # Use the real account home rather than a caller-modified HOME environment.
    home = absolute_path(Path(pwd.getpwuid(UID).pw_dir))
    applications = home / "Applications"
    rollback_root = home / "Library/Application Support/MeshMonitor/rollback"
    ensure_owned_directory(applications, home)
    ensure_owned_directory(rollback_root, home)
    if applications.stat().st_dev != rollback_root.stat().st_dev:
        raise InstallError("Applications and rollback directories must share a filesystem for atomic moves.")
    transaction_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex
    stage = applications / (".MeshMonitor-install-" + transaction_id)
    rollback = rollback_root / transaction_id
    final = applications / APP_NAME
    legacy = applications / LEGACY_NAME
    lock = applications / ".MeshMonitor-install.lock"
    lock_fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    lock_identity = os.fstat(lock_fd)
    journal: Path | None = None
    moved: list[dict] = []
    promoted = False
    promotion_attempted = False
    stage_identity: os.stat_result | None = None
    completed = False
    old_term_handler = signal.getsignal(signal.SIGTERM)
    old_int_handler = signal.getsignal(signal.SIGINT)

    def interrupted(_signal: int, _frame: object) -> None:
        raise InstallError("Installation interrupted; restoring prior apps.")

    signal.signal(signal.SIGTERM, interrupted)
    try:
        os.write(lock_fd, json.dumps({"pid": os.getpid(), "transaction": transaction_id}).encode())
        os.fsync(lock_fd)
        rollback.mkdir(mode=0o700)
        journal = rollback / "TRANSACTION.jsonl"
        write_new_file(journal, b"")
        write_new_file(rollback / "SOURCE-BUILD-RECEIPT.json", receipt_bytes)
        append_journal(journal, {"event": "prepared", "source_receipt": str(receipt_path),
                               "source_receipt_sha256": receipt_sha256, "source_app": str(source),
                               "stage": str(stage), "destination": str(final)})
        stage.mkdir(mode=0o700)
        stage_identity = stage.lstat()
        copy_tree_bytes_and_modes(source, stage)
        staged_files = verify_hashes(stage, expected)
        app_identity(stage, receipt)
        verify_signature(stage)
        # Content and executable permissions are both preserved by the staging copy.
        if staged_files != verified_files:
            raise InstallError("Staged app file modes differ from verified source.")
        append_journal(journal, {"event": "staging_verified"})
        planned_backups = []
        for original in (legacy, final):
            if not os.path.lexists(original):
                continue
            owned_directory(original)
            identity = app_identity(original)
            prior_files = file_manifest(original)
            backup = rollback / (original.name + ".rollback")
            entry = {"original": str(original), "backup": str(backup),
                     "identity": identity, "files": prior_files}
            planned_backups.append(entry)
        for entry in planned_backups:
            original, backup = Path(entry["original"]), Path(entry["backup"])
            append_journal(journal, {"event": "backup_planned", **entry})
            # Register before rename: a signal immediately after the syscall must
            # still leave this original visible to the rollback path.
            moved.append(entry)
            rename_exclusive(original, backup)
            append_journal(journal, {"event": "backup_complete", "original": str(original), "backup": str(backup)})
        append_journal(journal, {"event": "promotion_planned", "from": str(stage), "to": str(final)})
        promotion_attempted = True
        rename_exclusive(stage, final)
        promoted = True
        installed_files = verify_hashes(final, expected)
        app_identity(final, receipt)
        verify_signature(final)
        install_receipt = rollback / "INSTALL-RECEIPT.json"
        payload = {
            "schema_version": "mesh-monitor-install.v1", "installed_at": datetime.now(timezone.utc).isoformat(),
            "transaction_id": transaction_id, "bundle_id": BUNDLE_ID,
            "version": receipt.get("version"), "build": receipt.get("build"),
            "source_receipt": str(receipt_path), "source_receipt_sha256": receipt_sha256,
            "source_revision": receipt.get("source_revision"), "source_branch": receipt.get("source_branch"),
            "source_app": str(source), "installed_app": str(final), "files": installed_files,
            "backups": moved, "launched": False, "processes_stopped_by_installer": False,
            "login_items_changed": False,
        }
        write_new_file(install_receipt, (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode())
        append_journal(journal, {"event": "installed", "receipt": str(install_receipt)})
        completed = True
        return install_receipt
    except BaseException as failure:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        # Preserve the rejected new bundle instead of deleting anything. Existing
        # apps are restored exclusively; an external replacement is never erased.
        recovery_errors: list[str] = []
        if promoted or (promotion_attempted and not os.path.lexists(stage) and os.path.lexists(final)):
            try:
                # Match the staged directory inode, not its file hashes: corrupt
                # new contents are a reason to retain it and restore the old app.
                # This also covers interruption just after the rename syscall.
                current = owned_directory(final)
                if (stage_identity is None or current.st_ino != stage_identity.st_ino
                        or current.st_dev != stage_identity.st_dev):
                    raise InstallError("Destination was replaced externally; refusing to move it.")
                rejected = rollback / (APP_NAME + ".failed-install")
                rename_exclusive(final, rejected)
                if journal: append_journal(journal, {"event": "new_bundle_retained", "path": str(rejected)})
            except BaseException as error:
                recovery_errors.append(f"Could not retain failed new app: {error}")
        for entry in reversed(moved):
            try:
                backup, original = Path(entry["backup"]), Path(entry["original"])
                if not os.path.lexists(backup):
                    # Planned rename did not happen; the original must still match.
                    if file_manifest(original) != entry["files"]:
                        raise InstallError("Original changed before backup completed.")
                    continue
                if file_manifest(backup) != entry["files"]:
                    raise InstallError("Rollback backup changed; preserved for review.")
                rename_exclusive(backup, original)
                if journal: append_journal(journal, {"event": "restored", "path": entry["original"]})
            except BaseException as error:
                recovery_errors.append(f"Could not restore {entry['original']}: {error}")
        if journal:
            try:
                append_journal(journal, {"event": "failed", "error": str(failure),
                                       "recovery_errors": recovery_errors, "remaining_stage": str(stage)})
            except BaseException as error:
                recovery_errors.append(f"Could not record rollback status: {error}")
        if recovery_errors:
            raise InstallError(f"Installation failed; preserved recovery data at {rollback}. " + "; ".join(recovery_errors)) from failure
        raise
    finally:
        signal.signal(signal.SIGTERM, old_term_handler)
        signal.signal(signal.SIGINT, old_int_handler)
        os.close(lock_fd)
        try:
            current_lock = lock.lstat()
            if (current_lock.st_ino == lock_identity.st_ino and current_lock.st_dev == lock_identity.st_dev
                    and stat.S_ISREG(current_lock.st_mode) and current_lock.st_uid == UID):
                lock.unlink()
        except FileNotFoundError:
            pass
        except OSError as error:
            # A committed install must not be reported as rolled back merely
            # because lock cleanup failed. Leave an explicit recovery record.
            if journal:
                try: append_journal(journal, {"event": "lock_cleanup_failed", "installed": completed, "error": str(error)})
                except OSError: pass
        # Do not delete a failed staged copy or backups. They remain reviewable
        # with the transaction journal and can be cleaned up deliberately later.


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--receipt-sha256", required=True, help="SHA-256 of the exact build receipt reviewed before installation.")
    parser.add_argument("--apps-stopped", action="store_true", help="Caller has stopped the old and new app; installer never kills or launches processes.")
    args = parser.parse_args()
    receipt = install(args.receipt, args.receipt_sha256, apps_stopped=args.apps_stopped)
    print(json.dumps({"status": "installed_not_launched", "install_receipt": str(receipt)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
