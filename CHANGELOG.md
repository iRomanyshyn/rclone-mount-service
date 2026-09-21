# Changelog

Notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- Per-mount subdirectory, mountpoint, read-only and VFS cache options.
- Explicit isolated cache directories for every generated service.
- FUSE availability checks and safe orphaned-unit cleanup with `--prune`.
- SHA-256 verification for official DEB/RPM downloads.
- GitHub Actions checks for Bash syntax, ShellCheck, unit tests and generated
  systemd unit validation.

### Changed

- Rclone output is written only to journald; unmanaged `/tmp` log files are no
  longer created.
- Services rely on Rclone's foreground SIGTERM handling instead of a hard-coded
  `fusermount` `ExecStop` path.
- Per-remote startup errors now identify the failed unit and the relevant
  journal command.

## 2026-09-21

### Added

- Official DEB/RPM installation with upstream-script fallback.
- Preservation of argv[0]-dispatching Rclone launcher symlinks.
- Safe remote discovery through `rclone listremotes --source file`.
- Interactive, explicit and `--all` remote selection.
- Config-scoped concrete systemd services with bounded identifiers.

### Removed

- Direct parsing, renaming and rewriting of entries in `rclone.conf`.
