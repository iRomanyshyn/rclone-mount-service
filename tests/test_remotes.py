"""Remote discovery, selection and systemd unit regression tests."""

import hashlib
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "rclone-mount-service.sh"


def run_bash(code, *, args=(), env=None, input_text=None, cwd=None):
    command = ["bash", "-c", 'source "$SCRIPT"\n' + code, "test"]
    command.extend(args)
    merged_env = dict(os.environ, SCRIPT=str(SCRIPT))
    if env:
        merged_env.update(env)
    return subprocess.run(command, env=merged_env, cwd=cwd, input=input_text,
                          text=True, capture_output=True, timeout=10)


class RemoteTests(unittest.TestCase):
    def test_load_remotes_uses_rclone_and_does_not_modify_config(self):
        names = ["Google Drive", "foo.bar", "foo/bar", "foo-bar", "юнікод"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config with spaces.conf"
            original = "[foo.bar]\ntype = alias\nremote = Google Drive:\n"
            config.write_text(original)
            calls = root / "calls"
            rclone = root / "rclone"
            rclone.write_text(
                "#!/bin/bash\n"
                'printf \'%s\\n\' "$*" >> "$CALLS"\n'
                "printf '%s\\n' 'Google Drive:' 'foo.bar:' 'foo/bar:' "
                "'foo-bar:' 'юнікод:'\n"
            )
            rclone.chmod(0o755)
            result = run_bash(
                'RCLONE_BIN="$1"; CONFIG_PATH="$2"; load_remotes || exit; '
                'printf \'<%s>\\n\' "${AVAILABLE_REMOTES[@]}"',
                args=(str(rclone), str(config)), env={"CALLS": str(calls)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [f"<{name}>" for name in names])
            self.assertEqual(config.read_text(), original)
            self.assertEqual(
                calls.read_text().strip(),
                f"listremotes --config {config} --source file",
            )

    def test_load_remotes_propagates_rclone_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "rclone.conf"
            config.touch()
            rclone = root / "rclone"
            rclone.write_text("#!/bin/bash\nexit 23\n")
            rclone.chmod(0o755)
            result = run_bash(
                'RCLONE_BIN="$1"; CONFIG_PATH="$2"; load_remotes',
                args=(str(rclone), str(config)))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Failed to list", result.stderr)

    def test_explicit_selection_accepts_special_names_and_deduplicates(self):
        result = run_bash(
            'AVAILABLE_REMOTES=("Google Drive" "foo.bar" "foo/bar" "foo-bar" "--all"); '
            'select_remotes "$@" || exit; printf \'<%s>\\n\' "${SELECTED_REMOTES[@]}"',
            args=("Google Drive:", "foo/bar", "Google Drive"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["<Google Drive>", "<foo/bar>"])

        escaped = run_bash(
            'AVAILABLE_REMOTES=("--all"); select_remotes "$@" || exit; '
            'printf \'<%s>\\n\' "${SELECTED_REMOTES[@]}"',
            args=("--", "--all"))
        self.assertEqual(escaped.returncode, 0, escaped.stderr)
        self.assertEqual(escaped.stdout.strip(), "<--all>")

    def test_all_and_interactive_selection(self):
        all_result = run_bash(
            'AVAILABLE_REMOTES=(one "two words" three); select_remotes --all || exit; '
            'printf \'<%s>\\n\' "${SELECTED_REMOTES[@]}"')
        self.assertEqual(all_result.returncode, 0, all_result.stderr)
        self.assertEqual(all_result.stdout.splitlines(), ["<one>", "<two words>", "<three>"])

        interactive = run_bash(
            'stdin_is_terminal() { return 0; }; '
            'AVAILABLE_REMOTES=(one "two words" three); select_remotes || exit; '
            'printf \'<%s>\\n\' "${SELECTED_REMOTES[@]}"',
            input_text="2 3 2\n")
        self.assertEqual(interactive.returncode, 0, interactive.stderr)
        self.assertEqual(interactive.stdout.splitlines()[-2:], ["<two words>", "<three>"])

        decimal = run_bash(
            'stdin_is_terminal() { return 0; }; '
            'AVAILABLE_REMOTES=(one two three four five six seven eight nine ten); '
            'select_remotes || exit; printf \'<%s>\\n\' "${SELECTED_REMOTES[@]}"',
            input_text="08 010\n")
        self.assertEqual(decimal.returncode, 0, decimal.stderr)
        self.assertEqual(decimal.stdout.splitlines()[-2:], ["<eight>", "<ten>"])

    def test_invalid_and_noninteractive_selection_fails(self):
        for args in [("missing",), ("--all", "one"), ("--",), ("--help", "one")]:
            with self.subTest(args=args):
                result = run_bash(
                    'AVAILABLE_REMOTES=(one two); select_remotes "$@"', args=args)
                self.assertNotEqual(result.returncode, 0)

        result = run_bash('AVAILABLE_REMOTES=(one two); select_remotes')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-interactive", result.stderr)

    def test_config_path_becomes_absolute_without_dereferencing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            real = root / "real.conf"
            real.touch()
            link = root / "rclone.conf"
            link.symlink_to(real)
            result = run_bash(
                'RCLONE_CONFIG=rclone.conf; resolve_config_path || exit; '
                'printf \'%s\n\' "$CONFIG_PATH"; [ -L "$CONFIG_PATH" ]',
                cwd=root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(link))

    def test_unit_embeds_remote_and_uses_stable_user_unit_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_home = root / "config home"
            config = root / "rclone $config%.conf"
            config.touch()
            rclone = root / 'bin $with%quotes"' / "rclone"
            rclone.parent.mkdir()
            rclone.touch()
            remote = "-Google $Drive%"
            env = {
                "HOME": str(root / "home"),
                "XDG_CONFIG_HOME": str(config_home),
            }
            result = run_bash(
                'RCLONE_BIN="$1"; CONFIG_PATH="$2"; '
                'unit=$(service_unit "$3") || exit; '
                'write_unit_file "$3" "$unit" || exit; printf \'%s\\n\' "$unit"',
                args=(str(rclone), str(config), remote), env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            unit_name = result.stdout.strip()
            self.assertEqual(len(unit_name), len("rclone-") + 24 + len(".service"))
            unit = Path(env["HOME"]) / ".config/systemd/user" / unit_name
            self.assertTrue(unit.is_file())
            self.assertFalse((config_home / "systemd/user" / unit_name).exists())
            contents = unit.read_text()
            self.assertIn(f'Description=Rclone remote mount {unit_name[:-8]}', contents)
            self.assertIn('-- "-Google $$Drive%%:"', contents)
            self.assertIn('--config "', contents)
            self.assertIn(f'"%h/mnt/{unit_name[:-8]}"', contents)
            verify = subprocess.run(
                ["systemd-analyze", "verify", str(unit)], text=True,
                capture_output=True, timeout=10)
            self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_config_and_remote_are_scoped_to_distinct_units(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "home"
            rclone = root / "rclone"
            rclone.touch()
            configs = [root / "one.conf", root / "two.conf"]
            for config in configs:
                config.touch()
            result = run_bash(
                'RCLONE_BIN="$1"; remote=same; '
                'CONFIG_PATH="$2"; first=$(service_unit "$remote") || exit; '
                'write_unit_file "$remote" "$first" || exit; '
                'CONFIG_PATH="$3"; second=$(service_unit "$remote") || exit; '
                'write_unit_file "$remote" "$second" || exit; '
                'printf \'%s\\n%s\\n\' "$first" "$second"',
                args=(str(rclone), *(str(path) for path in configs)),
                env={"HOME": str(home)})
            self.assertEqual(result.returncode, 0, result.stderr)
            units = result.stdout.splitlines()
            self.assertEqual(len(set(units)), 2)
            unit_dir = home / ".config/systemd/user"
            for unit_name, config in zip(units, configs):
                self.assertIn(str(config), (unit_dir / unit_name).read_text())

    def test_long_remote_uses_bounded_unit_name(self):
        long_remote = "remote-" + "ю" * 300
        result = run_bash(
            'CONFIG_PATH=/tmp/rclone.conf; service_unit "$1"',
            args=(long_remote,))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.strip()), len("rclone-") + 24 + len(".service"))

    def test_enable_uses_stable_units_and_restarts_them(self):
        names = ["Google Drive", "foo.bar", "foo/bar", "foo-bar", "юнікод",
                 "remote-" + "x" * 300]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "rclone.conf"
            calls = root / "systemctl.calls"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            systemctl = fake_bin / "systemctl"
            systemctl.write_text('#!/bin/bash\nprintf \'%s\\n\' "$*" >> "$CALLS"\n')
            systemctl.chmod(0o755)
            env = {
                "CALLS": str(calls),
                "PATH": str(fake_bin) + os.pathsep + os.environ["PATH"],
                "HOME": str(root / "home"),
            }
            array = " ".join(shlex.quote(name) for name in names)
            result = run_bash(
                f'CONFIG_PATH={shlex.quote(str(config))}; '
                f"SELECTED_REMOTES=({array}); enable_selected_remotes",
                env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            actual = calls.read_text().splitlines()
            expected = ["--user daemon-reload"]
            for name in names:
                payload = str(config).encode() + b"\0" + name.encode() + b"\0"
                unit = f"rclone-{hashlib.sha256(payload).hexdigest()[:24]}.service"
                expected.append(f"--user enable {unit}")
                expected.append(f"--user restart {unit}")
            self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
