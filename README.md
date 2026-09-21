# Rclone Mount Service

A small Bash installer that creates persistent
[Rclone](https://rclone.org/) mounts as systemd user services. It discovers
remotes through Rclone itself, never rewrites `rclone.conf`, and supports remote
names containing spaces, Unicode and other systemd-special characters.

Contributions and suggestions for portable mount defaults are welcome.

## Features

- Interactive, explicit or `--all` remote selection.
- One isolated service and VFS cache per config-path/remote pair.
- Optional subdirectory, custom mountpoint, read-only mode and VFS settings.
- Readable `rclone@...` unit names and a `list` command mapping them to remotes.
- Bounded shutdown wait for queued VFS uploads, with restart-safe recovery.
- FUSE cleanup after stop, including a lazy-unmount fallback for stuck mounts.
- Logs in journald instead of unmanaged files under `/tmp`.
- Safe cleanup of managed services whose remotes were deleted.
- Official DEB/RPM installation with SHA-256 verification when Rclone is absent.
- Upstream `install.sh` fallback when no supported package route exists.

## Requirements

- Linux with a running systemd user manager.
- Bash, `sha256sum` and Python 3 for the test suite.
- FUSE through `/dev/fuse`, plus `fusermount3` or `fusermount` under `/usr/bin`
  or `/bin`; `mountpoint` and `systemd-escape` from the system utilities.
- Rclone 1.68 or newer, supporting `listremotes --source file`, the VFS queue
  remote-control call and RC Unix sockets.
- `curl` or `wget` and `sudo` only when the script must install Rclone.

Run the script as a regular user, never with `sudo`.

## Quick start

Select one or more remotes interactively:

```sh
./rclone-mount-service.sh
```

Pass exact remote names for unattended use, or explicitly select all remotes:

```sh
./rclone-mount-service.sh "Google Drive" Encrypted:
./rclone-mount-service.sh --all
```

Names may be written with or without the trailing colon shown by Rclone. Use
`--` before a remote whose name begins with a dash:

```sh
./rclone-mount-service.sh -- -backup
```

Redirected/non-interactive input requires remote arguments or `--all`; it never
silently mounts everything.

## Per-mount options

Options supplied during a run are stored in the generated service. Use the
explicit `configure` command once for each remote that needs different settings.
It accepts exactly one remote and restarts only that remote. Omitted options are
reset to the defaults shown below.

```sh
./rclone-mount-service.sh configure \
  --subdir "Photos/Library" \
  --mountpoint "$HOME/mnt/photos" \
  --read-only \
  --vfs-cache-mode writes \
  --vfs-cache-max-size 10G \
  --shutdown-timeout 2h \
  "Google Drive"

./rclone-mount-service.sh configure \
  --mountpoint "$HOME/mnt/archive" \
  --read-only \
  Archive:
```

| Option | Meaning |
| --- | --- |
| `--all` | Select every file-defined remote. |
| `--mountpoint ABSOLUTE_PATH` | Use a custom path; exactly one remote must be selected. |
| `--subdir PATH` | Mount a path below each selected remote. |
| `--read-only` | Prevent writes through the mount. |
| `--vfs-cache-mode MODE` | `off`, `minimal`, `writes` or `full`; default is `full`. |
| `--vfs-cache-max-size SIZE` | Per-service VFS cache limit; default is `1G`. |
| `--shutdown-timeout DURATION` | Maximum stop/restart wait for queued uploads; default is `30m`. |
| `--prune` | Remove this config's managed services for remotes that no longer exist. |

The default mountpoint is `~/mnt/rclone-<24-hex-id>`. A custom mountpoint is
absolute and is embedded in the unit; shell shortcuts such as `~` are therefore
not expanded unless your shell expands them before invocation.

## Configs, services and caches

Remotes are read with `rclone listremotes --source file` from `RCLONE_CONFIG` or
the default XDG Rclone config. Environment-only remotes are intentionally
excluded because their environment would not automatically exist in the user
service.

The script creates one concrete unit for each absolute config-path/remote pair
under `~/.config/systemd/user`. Normal names keep the familiar instance-unit
form and include the escaped remote name, for example
`rclone@Google\x20Drive-0123456789ab.service`. The short suffix is derived from
both the config path and remote, so identically named remotes in different
configs remain separate. Exceptionally long escaped names use a bounded hashed
fallback. Consequently:

- separate config files cannot overwrite each other's services;
- very long and Unicode remote names remain valid;
- changing options for a remote updates the same predictable unit;
- each service receives an explicit absolute `--config` path.

Each unit also receives an explicit isolated cache directory under
`$XDG_CACHE_HOME/rclone-mount-service/`, or `~/.cache/rclone-mount-service/`
when that variable is unset. Separate caches matter
because Rclone warns that concurrent VFS instances using overlapping remotes
must not share a cache hierarchy.

To remove services for remotes deleted from the current config:

```sh
./rclone-mount-service.sh --prune
```

Only files carrying this project's management marker and the matching config
digest are considered. Unrelated systemd units and services belonging to other
Rclone configs are left untouched.

## Service operation and logs

Show the exact mapping between configured remotes, installed units, state and
mountpoints:

```sh
./rclone-mount-service.sh list
```

The script also prints the exact service name and mountpoint after every
successful start. Common commands are:

```sh
systemctl --user status 'rclone@Google\x20Drive-0123456789ab.service'
journalctl --user-unit='rclone@Google\x20Drive-0123456789ab.service' -f
systemctl --user restart 'rclone@Google\x20Drive-0123456789ab.service'
systemctl --user disable --now 'rclone@Google\x20Drive-0123456789ab.service'
```

Rclone runs in the foreground with `Type=notify`; systemd waits until the mount
is ready. The installer checks `/dev/fuse` access and the presence of
`fusermount3`/`fusermount` before writing services.

### Pending writes during shutdown

With VFS cache mode `writes` or `full`, an application can finish a local copy
while Rclone is still uploading the closed file. Each service exposes only its
VFS queue through an RC Unix socket inside the user's runtime directory. Before
a stop, restart or normal shutdown, `ExecStop` waits for that queue to remain
empty, then explicitly sends SIGTERM to Rclone. `--shutdown-timeout` bounds the
whole stop operation; the default is `30m`.

Foreground Rclone normally removes its FUSE mount when it receives SIGTERM, but
upstream notes that unmount can fail when a mountpoint is busy. `ExecStopPost`
therefore checks the mount table after Rclone exits, tries a normal
`fusermount3 -u`/`fusermount -u`, and finally performs a lazy detach if the
normal unmount fails. A lazy detach immediately removes the path from the mount
namespace while the kernel releases any remaining references later.

If the timeout expires, the network fails or power is lost, Rclone's persistent
isolated cache is retained. According to the
[Rclone VFS documentation](https://rclone.org/commands/rclone_mount/#vfs-file-caching),
pending cached files are uploaded when Rclone starts again with the same cache
settings. Do not manually delete a service's cache while it may contain pending
writes.

This protects files that the writing application has closed. It cannot complete
bytes that an application had not yet written when that application was killed;
finish the local copy before shutting down when the whole file matters. A hard
power loss also cannot wait, so recovery then depends on the local cache and
filesystem remaining intact.

## Installing Rclone

An existing working Rclone executable is reused and is not automatically
upgraded. Its absolute command path is saved without dereferencing the final
symlink, preserving argv[0]-dispatching launchers.

When Rclone is absent, the script offers the latest stable official package:

| Distribution family | Installer | Package format |
| --- | --- | --- |
| Debian / Ubuntu and derivatives | `sudo apt install` | DEB |
| Fedora / RHEL and derivatives | `sudo dnf install` | RPM |
| openSUSE / SUSE | `sudo zypper install` | RPM |

The package architecture comes from `dpkg` or RPM rather than the kernel, so a
32-bit userspace on a 64-bit kernel receives the correct build. Derivatives are
detected through `ID_LIKE` in `/etc/os-release`.

The installer reads the current version from the permanent official endpoint,
downloads the corresponding versioned package and `SHA256SUMS`, and verifies
the package before invoking `sudo`. The sums file is obtained over HTTPS; this
script does not perform the optional upstream PGP signature verification.

If no supported package manager/architecture route exists, the script offers
the official [`install.sh`](https://rclone.org/install/#script-installation)
fallback. It is fully downloaded before `sudo bash` is invoked. A failed
download, checksum mismatch, rejected package transaction or cancelled prompt
stops the process and never silently switches to another installer. The
fallback also refuses to overwrite an installed DEB/RPM package whose executable
is missing from `PATH`.

Installing a package from a URL does not add an upstream APT/RPM repository, so
future Rclone updates are not configured automatically.

## Supported systems

The service generator targets systemd-based Linux distributions. Automatic
Rclone package installation is tested for Debian/Ubuntu, Fedora/RHEL and
openSUSE/SUSE families on the architectures listed in the package-selection
tests. Other systemd distributions can use an already-installed Rclone or the
confirmed upstream script fallback.

Snap Rclone is unsuitable for this project because its strict confinement does
not support `rclone mount`, as documented by upstream.

## Tests

```sh
bash -n rclone-mount-service.sh
shellcheck rclone-mount-service.sh
python3 -m unittest discover -s tests -v
```

The tests mock downloads, privilege escalation, package managers and
`systemctl`. They do not install packages, contact the network or start user
services. Generated units are checked with `systemd-analyze verify`.

See [CHANGELOG.md](CHANGELOG.md) for notable changes.

## License

This project is available under the [MIT License](LICENSE).
