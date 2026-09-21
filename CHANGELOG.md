# Changelog

Notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- Explicit single-remote `configure` and remote-to-unit `list` commands.
- Readable, bounded `rclone@<remote>-<id>.service` names with automatic
  migration from the previous opaque unit names while retaining cache paths.
- Post-stop FUSE verification with normal and lazy-unmount cleanup fallbacks.
- Per-mount subdirectory, mountpoint, read-only and VFS cache options.
- Explicit isolated cache directories for every generated service.
- FUSE availability checks and safe orphaned-unit cleanup with `--prune`.
- Bounded shutdown waiting for queued VFS uploads, with pending writes retained
  for upload after the next start when the wait cannot finish.
- SHA-256 verification for official DEB/RPM downloads.
- GitHub Actions checks for Bash syntax, ShellCheck, unit tests and generated
  systemd unit validation.

### Changed

- Stop handling now explicitly signals Rclone after the VFS queue drains and
  verifies that the FUSE mount actually disappeared.
- Rclone output is written only to journald; unmanaged `/tmp` log files are no
  longer created.
- Services rely on Rclone's foreground SIGTERM handling instead of a hard-coded
  `fusermount` `ExecStop` path.
- Per-remote startup errors now identify the failed unit and the relevant
  journal command.
- Empty values passed explicitly to `--mountpoint` are rejected.

## 2026-09-21

### Added

- Official DEB/RPM installation with upstream-script fallback.
- Preservation of argv[0]-dispatching Rclone launcher symlinks.
- Safe remote discovery through `rclone listremotes --source file`.
- Interactive, explicit and `--all` remote selection.
- Config-scoped concrete systemd services with bounded identifiers.

### Removed

- Direct parsing, renaming and rewriting of entries in `rclone.conf`.
