"""Installer regression tests: no network access, sudo, or package changes.

Run with: python3 -m unittest discover -s tests -v
"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "rclone-mount-service.sh"
MOCKS = r'''
source "$SCRIPT"
distribution_ids() { printf '%s\n' "$DISTRO"; }
command() {
    if [[ "$1" == -v ]]; then
        case "$2" in
            apt|dpkg|dnf|rpm|zypper|sudo|curl|wget|dpkg-query)
                [[ " $AVAILABLE " == *" $2 "* ]]; return ;;
            rclone)
                [[ "$EXISTING" == yes ]] || [[ -e "$STATE/installed" ]]; return ;;
        esac
    fi
    builtin command "$@"
}
dpkg() { printf '%s\n' "$ARCH"; }
rpm() {
    if [[ "$1" == -q ]]; then
        [[ "$PACKAGE_INSTALLED" == yes ]]
    else
        printf '%s\n' "$ARCH"
    fi
}
dpkg-query() {
    [[ "$PACKAGE_INSTALLED" == yes ]] || return 1
    printf 'install ok installed'
}
curl() {
    printf 'curl %s\n' "$*" >> "$STATE/events"
    while [[ "$1" != --output ]]; do shift; done
    printf 'downloaded content\n' > "$2"
    return "$DOWNLOAD_STATUS"
}
wget() {
    printf 'wget %s\n' "$*" >> "$STATE/events"
    printf 'downloaded content\n' > "${1#--output-document=}"
    return "$DOWNLOAD_STATUS"
}
sudo() {
    printf 'sudo %s\n' "$*" >> "$STATE/events"
    [[ -s "${!#}" ]] || return 98
    if [[ "$INSTALL_STATUS" == 0 && "$CREATE_BINARY" == yes ]]; then
        cat > "$STATE/bin/rclone" <<'BINARY'
#!/bin/bash
if [[ "$1" == version ]]; then
    echo 'rclone test binary'
    exit "${VERSION_STATUS:-0}"
fi
exit "${MOUNT_STATUS:-0}"
BINARY
        chmod +x "$STATE/bin/rclone"
        touch "$STATE/installed"
    fi
    return "$INSTALL_STATUS"
}
'''


class InstallationTests(unittest.TestCase):
    def run_shell(self, code, answer="y\n", **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tmp").mkdir()
            (root / "bin").mkdir()
            env = dict(os.environ, SCRIPT=str(SCRIPT), STATE=directory,
                       TMPDIR=str(root / "tmp"), DISTRO="ubuntu debian",
                       AVAILABLE="apt dpkg sudo curl", ARCH="amd64",
                       DOWNLOAD_STATUS="0", INSTALL_STATUS="0",
                       PACKAGE_INSTALLED="no", EXISTING="no",
                       CREATE_BINARY="yes", VERSION_STATUS="0", MOUNT_STATUS="0")
            env.update(overrides)
            env["PATH"] = str(root / "bin") + os.pathsep + os.environ["PATH"]
            if env["EXISTING"] == "yes":
                binary = root / "bin/rclone"
                binary.write_text('#!/bin/bash\nif [[ "$1" == version ]]; then\n'
                                  'exit "$VERSION_STATUS"\nfi\nexit "$MOUNT_STATUS"\n')
                binary.chmod(0o755)
            result = subprocess.run(["bash", "-c", MOCKS + "\n" + code],
                                    env=env, input=answer, text=True,
                                    capture_output=True, timeout=10)
            events = (root / "events").read_text() if (root / "events").exists() else ""
            self.assertEqual(list((root / "tmp").iterdir()), [], "Temporary files leaked")
            return result, events

    def test_architecture_and_distribution_mapping(self):
        cases = [
            ("ubuntu debian", "apt dpkg", "amd64", "apt deb amd64"),
            ("linuxmint ubuntu debian", "apt dpkg", "arm64", "apt deb arm64"),
            ("debian", "apt dpkg", "i386", "apt deb 386"),
            ("raspbian debian", "apt dpkg", "armhf", "apt deb arm-v6"),
            ("debian", "apt dpkg", "armel", "apt deb arm"),
            ("fedora", "dnf rpm", "x86_64", "dnf rpm amd64"),
            ("rocky rhel centos fedora", "dnf rpm", "aarch64", "dnf rpm arm64"),
            ("fedora", "dnf rpm", "i686", "dnf rpm 386"),
            ("fedora", "dnf rpm", "armv7hl", "dnf rpm arm-v7"),
            ("fedora", "dnf rpm", "armv6hl", "dnf rpm arm-v6"),
            ("opensuse-tumbleweed opensuse suse", "zypper rpm", "x86_64", "zypper rpm amd64"),
        ]
        for distro, available, arch, expected in cases:
            with self.subTest(distro=distro, arch=arch):
                result, events = self.run_shell("rclone_package", DISTRO=distro,
                                                AVAILABLE=available, ARCH=arch)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
                self.assertEqual(events, "")

    def test_native_package_installation(self):
        for distro, tools, arch, manager, filename in [
            ("debian", "apt dpkg", "amd64", "apt", "rclone-current-linux-amd64.deb"),
            ("fedora", "dnf rpm", "aarch64", "dnf", "rclone-current-linux-arm64.rpm"),
            ("opensuse", "zypper rpm", "x86_64", "zypper", "rclone-current-linux-amd64.rpm"),
        ]:
            with self.subTest(manager=manager):
                result, events = self.run_shell("ensure_rclone", DISTRO=distro,
                                                AVAILABLE=tools + " sudo curl", ARCH=arch)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("https://downloads.rclone.org/" + filename, events)
                self.assertIn("sudo " + manager + " install ", events)
                self.assertNotIn("sudo bash", events)

    def test_wget_without_curl(self):
        result, events = self.run_shell("install_rclone", AVAILABLE="apt dpkg sudo wget")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("wget --output-document=", events)
        self.assertIn("sudo apt install", events)

    def test_script_fallback(self):
        for overrides in [dict(DISTRO="arch"), dict(ARCH="riscv64"),
                          dict(AVAILABLE="sudo wget")]:
            with self.subTest(overrides=overrides):
                result, events = self.run_shell("ensure_rclone", **overrides)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("https://rclone.org/install.sh", events)
                self.assertIn("sudo bash ", events)
                self.assertNotIn("sudo apt", events)

    def test_package_error_or_cancellation_never_falls_back(self):
        for status in ["1", "100", "130"]:
            with self.subTest(status=status):
                result, events = self.run_shell("install_rclone", INSTALL_STATUS=status)
                self.assertEqual(result.returncode, int(status))
                self.assertEqual(events.count("sudo "), 1)
                self.assertNotIn("install.sh", events)
                self.assertIn("No alternative installer", result.stderr)

    def test_failed_or_partial_download_never_executes(self):
        for distro in ["debian", "arch"]:
            for downloader in ["curl", "wget"]:
                with self.subTest(distro=distro, downloader=downloader):
                    result, events = self.run_shell(
                        "install_rclone", DISTRO=distro, DOWNLOAD_STATUS="22",
                        AVAILABLE="apt dpkg sudo " + downloader)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("sudo ", events)

    def test_decline_and_eof_do_nothing(self):
        for answer in ["n\n", "\n", ""]:
            with self.subTest(answer=answer):
                result, events = self.run_shell("install_rclone", answer=answer)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, "")

    def test_missing_downloader_or_sudo(self):
        for available in ["apt dpkg sudo", "apt dpkg curl"]:
            with self.subTest(available=available):
                result, events = self.run_shell("install_rclone", AVAILABLE=available)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, "")

    def test_fallback_cannot_overwrite_package_owned_binary(self):
        for database in ["rpm", "dpkg-query"]:
            with self.subTest(database=database):
                result, events = self.run_shell("install_rclone", DISTRO="unknown",
                                                AVAILABLE="sudo curl " + database,
                                                PACKAGE_INSTALLED="yes")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("package-managed", result.stderr)
                self.assertEqual(events, "")

    def test_existing_binary_is_reused(self):
        result, events = self.run_shell('ensure_rclone && printf "%s" "$RCLONE_BIN"',
                                        EXISTING="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.endswith("/bin/rclone"))
        self.assertEqual(events, "")

    def test_unusable_existing_binary_is_reported(self):
        for overrides in [dict(VERSION_STATUS="1"), dict(MOUNT_STATUS="1")]:
            with self.subTest(overrides=overrides):
                result, events = self.run_shell("ensure_rclone", EXISTING="yes", **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, "")

    def test_dispatching_symlink_preserves_command_name_and_absolute_path(self):
        for path_entry in ["absolute", "launchers", "launchers with spaces", ".", ""]:
            with self.subTest(path_entry=path_entry), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                launcher_dir = root / "launchers with spaces"
                launcher_dir.mkdir()
                dispatcher = root / "dispatcher"
                dispatcher.write_text(
                    '#!/bin/bash\n'
                    '[[ "${0##*/}" == rclone ]] || exit 64\n'
                    'printf "%s\\n" "$*" >> "$CALLS"\n'
                )
                dispatcher.chmod(0o755)
                launcher = launcher_dir / "rclone"
                launcher.symlink_to(dispatcher)
                # Also exercise a symlinked PATH directory, without replacing
                # the final command symlink with its dispatcher target.
                (root / "launchers").symlink_to(launcher_dir, target_is_directory=True)
                cwd = launcher_dir if path_entry in [".", ""] else root
                entry = str(launcher_dir) if path_entry == "absolute" else path_entry
                env = dict(os.environ, SCRIPT=str(SCRIPT), CALLS=str(root / "calls"),
                           PATH=entry + os.pathsep + os.environ["PATH"])
                result = subprocess.run(
                    ["/bin/bash", "-c", '''
source "$SCRIPT"
install_rclone() { echo "Unexpected installation" >&2; return 99; }
ensure_rclone || exit "$?"
[[ "$RCLONE_BIN" == /* && -L "$RCLONE_BIN" ]] || exit 65
# systemd may launch the saved executable from a different directory.
cd / || exit
"$RCLONE_BIN" mount --help || exit "$?"
printf '%s' "$RCLONE_BIN"
'''], cwd=cwd, env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(Path(result.stdout).name, "rclone")
                if path_entry == "absolute":
                    self.assertEqual(result.stdout, str(launcher))
                self.assertEqual((root / "calls").read_text().splitlines(),
                                 ["version", "mount --help", "mount --help"])

    def test_installer_success_without_binary_is_rejected(self):
        result, _ = self.run_shell("ensure_rclone", CREATE_BINARY="no")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not found after installation", result.stderr)

    def test_sourcing_does_not_run_main(self):
        result, events = self.run_shell(":")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(events, "")


if __name__ == "__main__":
    unittest.main()
