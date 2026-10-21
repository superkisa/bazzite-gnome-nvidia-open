"""Installer failure and lifecycle regressions; no live systemd/GPU access."""

import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("moonshine_install", ROOT / "install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="moonshine-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config_home = self.root / "config-$dollar-%-😀"
        self.data_home = self.root / "data-${literal}-%-😀"
        self.config = self.config_home / "moonshine/config.toml"
        self.config.parent.mkdir(parents=True)
        self.unit_dir = self.config_home / "systemd/user"
        self.unit_dir.mkdir(parents=True)
        self.runtime = self.data_home / "moonshine/runtime/0.16.1"
        self.runtime.mkdir(parents=True)
        (self.runtime / "moonshine").write_text("previous runtime")
        self.older = self.runtime.with_name("0.15.0")
        self.older.mkdir()
        (self.older / "moonshine").write_text("older runtime")
        self.state = self.data_home / "moonshine/state.toml"
        self.state.write_text("pairing sentinel")
        (self.config.parent / "key.pem").write_text("private key sentinel")
        self.legacy = self.config.with_name("tablet.toml")
        self.legacy.write_text('''name = "Test host"
[[application]]
title = "Steam (Tablet)"
command = ["steam", "-bigpicture"]
[[application_scanner]]
type = "steam"
library = "$HOME/.local/share/Steam"
command = ["steam", "steam://rungameid/{game_id}"]
''')
        (self.unit_dir / installer.LEGACY).write_text("previous unit")
        self.package = self.root / "package"
        for name in (
            "usr/bin/moonshine",
            "usr/lib/moonshine/vulkan-layers/libmoonshine_wsi.so",
            "usr/share/licenses/moonshine/LICENSE",
        ):
            target = self.package / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("new runtime asset")
        layer = self.package / "usr/share/vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json"
        layer.parent.mkdir(parents=True)
        layer.write_text(json.dumps({"layer": {"library_path": "placeholder"}}))
        self.units = {
            installer.SERVER: {"LoadState": "not-found", "ActiveState": "inactive", "enabled": False},
            installer.LEGACY: {"LoadState": "loaded", "ActiveState": "active", "enabled": True},
        }
        self.calls = []
        self.health_calls = []
        self.fail_health = None
        self.fail_ready = False
        self.addCleanup(patch.stopall)
        patch.object(installer, "systemctl", side_effect=self.systemctl).start()
        patch.object(installer.subprocess, "run", side_effect=self.healthcheck).start()
        patch.object(installer, "wait_ready", side_effect=self.ready).start()

    def systemctl(self, *args, check=True):
        self.calls.append(args)
        action = args[0]
        output = ""
        if action == "show-environment":
            output = "\n".join(shlex.quote(k + "=" + str(v)) for k, v in (
                ("XDG_CONFIG_HOME", self.config_home), ("XDG_DATA_HOME", self.data_home)
            ))
        elif action in ("show", "is-enabled"):
            state = self.units.get(args[1], {"LoadState": "not-found", "ActiveState": "inactive", "enabled": False})
            if action == "show":
                output = state[args[2].split("=", 1)[1]]
            else:
                output = "enabled" if state["enabled"] else "disabled"
        elif action in ("enable", "disable", "start", "stop"):
            unit = args[-1]
            state = self.units[unit]
            if action in ("enable", "disable"):
                state["enabled"] = action == "enable"
            if action in ("start", "stop") or "--now" in args:
                state["ActiveState"] = "inactive" if action == "stop" else "active"
            if action == "enable":
                state["LoadState"] = "loaded"
        return subprocess.CompletedProcess(args, 0, output + "\n", "")

    def healthcheck(self, command, **kwargs):
        config = tomllib.loads(Path(command[1]).read_text())
        self.health_calls.append(config)
        if self.fail_health == len(self.health_calls):
            raise subprocess.CalledProcessError(1, command)
        return subprocess.CompletedProcess(command, 0)

    def ready(self, parsed):
        if self.fail_ready:
            raise RuntimeError("simulated failed activation")

    def install(self):
        installer.install(self.package, "0.16.1", self.config_home, self.data_home)

    def assert_restored(self):
        self.assertTrue(self.legacy.exists())
        self.assertFalse(self.config.exists())
        self.assertEqual((self.runtime / "moonshine").read_text(), "previous runtime")
        self.assertEqual((self.unit_dir / installer.LEGACY).read_text(), "previous unit")
        self.assertFalse((self.unit_dir / installer.SERVER).exists())
        self.assertEqual(self.state.read_text(), "pairing sentinel")
        self.assertEqual((self.config.parent / "key.pem").read_text(), "private key sentinel")
        self.assertEqual(self.units[installer.LEGACY]["ActiveState"], "active")
        self.assertTrue(self.units[installer.LEGACY]["enabled"])
        self.assertTrue(self.older.exists())

    def test_invalid_config_does_not_stop_server(self):
        self.legacy.write_text("invalid = [")
        with self.assertRaises(tomllib.TOMLDecodeError):
            self.install()
        self.assertEqual(self.calls, [])
        self.assert_restored()

    def test_backup_collision_does_not_stop_server(self):
        self.config.write_text('name = "other"')
        self.config.with_name("config.toml.before-migration").write_text("previous backup")
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(self.calls, [])

    def test_staged_health_failure_preserves_running_install(self):
        self.fail_health = 1
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assertFalse(any(c[0] in ("stop", "disable", "enable") for c in self.calls))
        self.assert_restored()

    def test_actual_port_conflict_restores_old_install(self):
        self.fail_health = 2
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assert_restored()

    def test_failed_readiness_restores_old_install(self):
        self.fail_ready = True
        with self.assertRaises(RuntimeError):
            self.install()
        self.assert_restored()

    def test_success_preserves_titles_scanner_and_pairings_and_prunes_versions(self):
        expected = tomllib.loads(self.legacy.read_text())
        self.install()
        actual = tomllib.loads(self.config.read_text())
        self.assertEqual(actual["application"], expected["application"])
        self.assertEqual(actual["application_scanner"], expected["application_scanner"])
        self.assertFalse(self.legacy.exists())
        self.assertFalse((self.unit_dir / installer.LEGACY).exists())
        self.assertFalse(self.older.exists())
        self.assertEqual(self.state.read_text(), "pairing sentinel")
        self.assertTrue(self.units[installer.SERVER]["enabled"])
        self.assertEqual(self.health_calls[0]["webserver"]["port"], 0)
        self.assertEqual(self.health_calls[0]["stream"]["port"], 0)
        self.assertEqual(self.health_calls[0]["application"], expected["application"])
        self.assertEqual(self.health_calls[0]["application_scanner"], expected["application_scanner"])
        self.assertNotIn("port", self.health_calls[1]["webserver"])
        unit = (self.unit_dir / installer.SERVER).read_text()
        self.assertIn("ExecStart=:", unit)
        self.assertIn("${literal}", unit)
        self.assertIn("%%", unit)
        self.assertIn("😀", unit)

    def test_fresh_config_has_explicit_xdg_certificate_paths(self):
        self.legacy.unlink()
        text, parsed, migrating = installer.prepare_config(self.config_home, self.data_home)
        self.assertFalse(migrating)
        self.assertIn("😀", text)
        self.assertEqual(parsed["webserver"]["certificate"], "${XDG_CONFIG_HOME}/moonshine/cert.pem")
        self.assertEqual(parsed["webserver"]["private_key"], "${XDG_CONFIG_HOME}/moonshine/key.pem")

    def test_config_with_existing_webserver_retains_settings(self):
        self.legacy.write_text('[webserver]\nport = 12345\n[compositor]\nhdr = false\n')
        _, parsed, _ = installer.prepare_config(self.config_home, self.data_home)
        self.assertEqual(parsed["webserver"]["port"], 12345)
        self.assertFalse(parsed["compositor"]["hdr"])
        self.assertIn("private_key", parsed["webserver"])

    def test_divergent_xdg_manager_environment_rejected(self):
        installer.check_environment(self.config_home, self.data_home)
        with self.assertRaises(ValueError):
            installer.check_environment(self.root / "different-config", self.data_home)
        self.assertFalse(any(c[0] in ("stop", "disable", "enable") for c in self.calls))


class CommandTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("just"), "invocation-directory test requires Just")
    def test_relative_rpm_from_different_invocation_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "image/moonshine"
            source.mkdir(parents=True)
            shutil.copy2(ROOT / "recipes.just", source)
            (source / "install.sh").write_text('test -f "$1"\n')
            justfile = root / "image/justfile"
            justfile.write_text('import "moonshine/recipes.just"\n')
            downloads = root / "downloads"
            downloads.mkdir()
            (downloads / "package.rpm").touch()
            subprocess.run(["just", "--tempdir", "/tmp", "-f", str(justfile), "moonshine-install", "package.rpm"], cwd=downloads, check=True, capture_output=True)

    def test_failed_steam_shutdown_still_waits_for_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            steam = root / "steam"
            steam.write_text("#!/bin/bash\nexit 7\n")
            steam.chmod(0o755)
            pgrep = root / "pgrep"
            pgrep.write_text('#!/bin/bash\nif test -f "$TEST_STATE"; then exit 1; fi\ntouch "$TEST_STATE"\n')
            pgrep.chmod(0o755)
            script = root / "prepare.sh"
            script.write_text((ROOT / "prepare-steam.sh").read_text().replace("/usr/bin/steam", shlex.quote(str(steam))))
            env = dict(os.environ, PATH=str(root) + ":" + os.environ["PATH"], TEST_STATE=str(root / "state"))
            subprocess.run(["bash", str(script)], env=env, check=True, capture_output=True)

    def test_active_missing_unit_is_stopped_by_uninstall_helper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tool = root / "systemctl"
            tool.write_text('''#!/bin/bash
if [[ $2 == show ]]; then
  if [[ $4 == --property=LoadState ]]; then echo not-found
  elif [[ $3 == moonshine-tablet.service ]]; then echo active
  else echo inactive; fi
else echo "$*" >> "$TEST_LOG"; fi
''')
            tool.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + ":" + os.environ["PATH"], TEST_LOG=str(root / "log"))
            subprocess.run(["bash", "-c", 'source "$1"; stop_servers', "test", str(ROOT / "common.sh")], env=env, check=True, capture_output=True)
            log = (root / "log").read_text()
            self.assertIn("stop moonshine-tablet.service", log)
            self.assertNotIn("disable", log)

    def test_uninstall_preserves_and_purge_removes_custom_xdg_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_home, data_home = root / "cfg", root / "data"
            config = config_home / "moonshine"
            data = data_home / "moonshine"
            config.mkdir(parents=True)
            (data / "runtime/0.16.1").mkdir(parents=True)
            for name in ("config.toml", "cert.pem", "key.pem"):
                (config / name).write_text(name)
            (data / "state.toml").write_text("pairing sentinel")
            manifest = data_home / "vulkan/implicit_layer.d"
            manifest.mkdir(parents=True)
            (manifest / "VkLayer_moonshine_wsi.json").touch()
            unrelated = manifest / "other.json"
            unrelated.write_text("unrelated sentinel")
            bindir = root / "bin"
            bindir.mkdir()
            tool = bindir / "systemctl"
            tool.write_text('''#!/bin/bash
if [[ $2 == show-environment ]]; then
  echo "XDG_CONFIG_HOME=$XDG_CONFIG_HOME"
  echo "XDG_DATA_HOME=$XDG_DATA_HOME"
elif [[ $2 == show ]]; then
  if [[ $4 == --property=LoadState ]]; then echo not-found; else echo inactive; fi
fi
''')
            tool.chmod(0o755)
            env = dict(os.environ, XDG_CONFIG_HOME=str(config_home), XDG_DATA_HOME=str(data_home), PATH=str(bindir) + ":" + os.environ["PATH"])
            command = ["bash", str(ROOT / "uninstall.sh")]
            subprocess.run(command, env=env, check=True, capture_output=True)
            self.assertTrue((config / "key.pem").exists())
            self.assertTrue((config / "cert.pem").exists())
            self.assertTrue((data / "state.toml").exists())
            self.assertFalse((data / "runtime").exists())
            self.assertFalse((manifest / "VkLayer_moonshine_wsi.json").exists())
            subprocess.run(command + ["--purge"], env=env, check=True, capture_output=True)
            self.assertFalse(config.exists())
            self.assertFalse(data.exists())
            self.assertEqual(unrelated.read_text(), "unrelated sentinel")


if __name__ == "__main__":
    unittest.main()
