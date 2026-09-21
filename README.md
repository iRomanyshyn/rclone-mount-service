# Rclone mount systemd service installation script
Of course, it was not my idea but someone needs to get the thing done till the final "product". I hate to manually create the systemd service for mounting every Rclone remote, so I made the installation script to automate this routine. As I hate bash scripts, I have utilized the OpenAI ChatGPT and Claude to do the job but those services are still pretty dumb, so I had a lot of frustration when it added something and ruined other things.

**Please, share any thoughts on making this script better! Especially in the part of remotes names handling, a proper mount options for any remote (as I want to make a "universal" systemd unit file).**

## Installing Rclone

Run `./rclone-mount-service.sh` as your regular user. The script reuses an existing
Rclone executable and checks that it runs and provides the `mount` command.
It does not automatically upgrade an existing installation.

If Rclone is missing, the script offers to install the latest stable official
Rclone package from the permanent URLs documented under
[Downloads for scripting](https://rclone.org/downloads/#downloads-for-scripting):

| Distribution family | Installer | Package URL pattern |
| --- | --- | --- |
| Debian / Ubuntu and derivatives | `sudo apt install` | `https://downloads.rclone.org/rclone-current-linux-ARCH.deb` |
| Fedora / RHEL and derivatives with DNF | `sudo dnf install` | `https://downloads.rclone.org/rclone-current-linux-ARCH.rpm` |
| openSUSE / SUSE with Zypper | `sudo zypper install` | `https://downloads.rclone.org/rclone-current-linux-ARCH.rpm` |

`ARCH` is selected from the native package architecture, including x86-64,
32-bit x86, ARM64 and supported 32-bit ARM variants. Debian `armhf` uses the
ARMv6 hard-float build for compatibility with ARMv6 userspace distributions.
Distribution derivatives are detected using `ID_LIKE` in `/etc/os-release`.

When there is no supported package route for the distribution, available
package manager or architecture, the script offers the official
[`install.sh`](https://rclone.org/install/#script-installation) as a fallback.
That installer must itself support the machine's architecture. Both packages
and the fallback script are fully downloaded with `curl` or `wget` to a temporary
directory before execution. Temporary downloads are removed on completion or
failure. Only the installation step uses `sudo`; configuration of user services
continues as the regular user.

A failed download, rejected package transaction, missing `sudo`, or cancelled
installation stops the process. These failures do **not** trigger a second
installation method. The fallback also refuses to overwrite an installed
RPM/DEB package whose executable is missing from `PATH`.

After installation, the script verifies Rclone and uses its absolute command
path in the generated service, preserving symlinks used by multicall launchers.
Relative PATH entries are made absolute without resolving the command symlink.
Installing an official package from a
URL does not add an upstream APT/RPM repository or automatically configure
future upstream updates. FUSE is still required for mounting.

## Selecting and mounting remotes

Run the script without arguments to select one or more configured remotes from
an interactive numbered list:

```sh
./rclone-mount-service.sh
```

For unattended use, pass exact remote names or explicitly request every remote:

```sh
./rclone-mount-service.sh "Google Drive" Encrypted:
./rclone-mount-service.sh --all
```

Names may be written with or without their trailing colon. Use `--` before a
remote whose name begins with a dash. With redirected input, a selection is
required; the script will not silently mount every configured remote.

Remotes are discovered with `rclone listremotes --source file`, using the exact
configuration selected by `RCLONE_CONFIG` or the default XDG configuration
path. Environment-only remotes are excluded because their environment would not
automatically exist in the user service. The absolute configuration path is
written into the unit as `--config`, so a non-default configuration continues to
work after the invoking shell exits.

The script never edits or renames entries in `rclone.conf`. Remote names are
encoded reversibly with `systemd-escape` for the unit instance. The unit receives
the original name through `%I`, while the mount directory uses the escaped `%i`
value to remain safe and collision-free. Ordinary names therefore mount at the
familiar path, for example `GoogleDrive` at `~/mnt/GoogleDrive`; special names
may produce paths such as `~/mnt/Google\x20Drive`.

Each selected remote is enabled and started as a user service. For example:

```sh
systemctl --user status 'rclone@GoogleDrive.service'
```

## Tests

Run the installer regression tests with Python 3 and Bash:

```sh
bash -n rclone-mount-service.sh
python3 -m unittest discover -s tests -v
```

The tests mock downloads, privilege escalation, package managers and systemctl.
They do not install packages, contact the network or start user services. They
cover package and architecture selection, script fallback, cancellation,
download/installation failures, temporary-file cleanup, executable validation,
remote discovery and selection, special remote names, systemd escaping and unit
syntax validation.
