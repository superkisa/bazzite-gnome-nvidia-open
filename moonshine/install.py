"""Prepare, validate and transactionally switch a per-user Moonshine runtime."""

import copy
import datetime
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import tomllib
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

SERVER = "moonshine-server.service"
LEGACY = "moonshine-tablet.service"
SCRIPT_DIR = Path(__file__).resolve().parent


def systemctl(*args, check=True):
    return subprocess.run(
        ["systemctl", "--user", *args], check=check, text=True, capture_output=True
    )


def property_value(unit, prop):
    return systemctl("show", unit, f"--property={prop}", "--value").stdout.strip()


def check_environment(config_home, data_home):
    """Games are launched by the user manager, not by the server's environment."""
    manager = dict(
        item.split("=", 1)
        for item in shlex.split(systemctl("show-environment").stdout)
        if "=" in item
    )
    for key, actual, fallback in (
        ("XDG_CONFIG_HOME", config_home, Path.home() / ".config"),
        ("XDG_DATA_HOME", data_home, Path.home() / ".local/share"),
    ):
        expected = Path(manager.get(key) or fallback)
        if not actual.is_absolute() or actual.resolve() != expected.resolve():
            raise ValueError(
                f"{key} differs from the systemd user manager ({expected}). "
                "Use the graphical session's XDG paths, or configure them in "
                "the login environment and log in again before installing/removing."
            )


def toml_string(value):
    # JSON's surrogate-pair escapes are invalid TOML; keep Unicode characters.
    return json.dumps(str(value), ensure_ascii=False).replace("\x7f", "\\u007f")


def toml_value(value):
    """Serialize parsed TOML for the disposable preflight config only."""
    if isinstance(value, str):
        return toml_string(value)
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, (datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{ " + ", ".join(toml_string(key) + " = " + toml_value(item) for key, item in value.items()) + " }"
    raise ValueError(f"Unsupported TOML value: {type(value).__name__}")


def unit_arg(value):
    value = str(value)
    if any(ord(c) < 32 for c in value):
        raise ValueError("Control characters in systemd paths are unsupported")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"'


def prepare_config(config_home, data_home):
    config = config_home / "moonshine/config.toml"
    legacy = config.with_name("tablet.toml")
    backup = config.with_name("config.toml.before-migration")
    if legacy.exists() and config.exists() and backup.exists():
        raise ValueError(f"Refusing to overwrite migration backup: {backup}")
    source = legacy if legacy.exists() else config
    if source.exists():
        text = source.read_text()
    else:
        text = f'''# Resolution, refresh rate and HDR/SDR are requested by the client.
name = {toml_string(socket.gethostname())}
address = "0.0.0.0"
inhibit_sleep = true

[compositor]
hdr = true
steam_mode = true

[[application]]
title = "Steam (Big Picture)"
command = ["/usr/bin/steam", "-bigpicture"]
pre_command = [[{toml_string(data_home / 'moonshine/prepare-steam.sh')}]]
stdout = "journal"
stderr = "journal"
launch_timeout_secs = 10
'''
    parsed = tomllib.loads(text)
    expected = copy.deepcopy(parsed)
    web = expected.setdefault("webserver", {})
    if not isinstance(web, dict):
        raise ValueError("[webserver] must be a table")
    missing = {
        key: value
        for key, value in {
            "certificate": "${XDG_CONFIG_HOME}/moonshine/cert.pem",
            "private_key": "${XDG_CONFIG_HOME}/moonshine/key.pem",
        }.items()
        if key not in web
    }
    if missing:
        lines = "\n".join(f"{key} = {toml_string(value)}" for key, value in missing.items())
        if "webserver" not in parsed:
            text += "\n[webserver]\n" + lines + "\n"
        else:
            # Preserve user formatting/comments. Verify the semantic result below
            # so a header-like line inside a multiline string cannot be edited.
            text, count = re.subn(
                r"(?m)^\[webserver\][ \t]*(?:#.*)?$",
                lambda match: match.group() + "\n" + lines,
                text, count=1,
            )
            if not count:
                raise ValueError("Set certificate/private_key explicitly in [webserver] before installing")
        web.update(missing)
    if tomllib.loads(text) != expected:
        raise ValueError("Could not safely add webserver paths; set them explicitly before installing")
    # Existing titles are intentionally retained: Moonshine hashes them into app IDs.
    return text, expected, legacy.exists()


def health_config(parsed):
    """Validate the entire config/schema with ephemeral, nonconflicting ports."""
    probe = copy.deepcopy(parsed)
    probe["webserver"].update(port=0, port_https=0)
    stream = probe.setdefault("stream", {})
    stream["port"] = 0
    for name in ("video", "audio", "control"):
        stream.setdefault(name, {})["port"] = 0
    text = "\n".join(toml_string(key) + " = " + toml_value(value) for key, value in probe.items())
    tomllib.loads(text)
    return text


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


class Snapshot:
    def __init__(self, root, paths):
        self.entries = []
        for index, path in enumerate(paths):
            saved = root / str(index)
            exists = path.exists() or path.is_symlink()
            if exists:
                self.copy(path, saved)
            self.entries.append((path, saved, exists))

    @staticmethod
    def copy(source, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir() and not source.is_symlink():
            shutil.copytree(source, destination, symlinks=True)
        else:
            shutil.copy2(source, destination, follow_symlinks=False)

    def restore(self):
        for path, saved, existed in self.entries:
            remove(path)
            if existed:
                self.copy(saved, path)


def wait_ready(parsed, timeout=30):
    address = parsed.get("address", "0.0.0.0")
    if address in ("0.0.0.0", "::"):
        address = "127.0.0.1" if address == "0.0.0.0" else "::1"
    if ":" in address:
        address = f"[{address}]"
    port = parsed["webserver"].get("port", 47989)
    url = f"http://{address}:{port}/serverinfo?uniqueid=installer"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if property_value(SERVER, "ActiveState") == "failed":
            break
        try:
            with opener.open(url, timeout=1) as response:
                info = ET.fromstring(response.read())
            if info.get("status_code") == "200" and info.findtext("hostname") == parsed.get("name", "Moonshine"):
                return
        except (OSError, ET.ParseError):
            pass
        time.sleep(0.25)
    raise RuntimeError("New server did not become ready; inspect its journal")


def install(package, version, config_home, data_home):
    text, parsed, migrating = prepare_config(config_home, data_home)
    runtime = data_home / "moonshine/runtime" / version
    config = config_home / "moonshine/config.toml"
    legacy_config = config.with_name("tablet.toml")
    unit_dir = config_home / "systemd/user"
    service = unit_dir / SERVER
    legacy_service = unit_dir / LEGACY
    manifest = data_home / "vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json"
    helper = data_home / "moonshine/prepare-steam.sh"
    env = dict(os.environ, XDG_CONFIG_HOME=str(config_home), XDG_DATA_HOME=str(data_home))
    states = {
        unit: {
            "active": property_value(unit, "ActiveState") not in ("inactive", "failed", ""),
            "enabled": systemctl("is-enabled", unit, check=False).stdout.strip() == "enabled",
        }
        for unit in (SERVER, LEGACY)
    }
    for unit, state in states.items():
        if state["active"] and property_value(unit, "LoadState") == "not-found":
            raise ValueError(f"Restore {unit}'s missing unit file, or run moonshine-uninstall, before reinstalling")

    with tempfile.TemporaryDirectory(prefix="moonshine-install-") as directory:
        work = Path(directory)
        stage = work / "runtime"
        stage.mkdir()
        for source, name in (
            (package / "usr/bin/moonshine", "moonshine"),
            (package / "usr/lib/moonshine/vulkan-layers/libmoonshine_wsi.so", "libmoonshine_wsi.so"),
            (package / "usr/share/licenses/moonshine/LICENSE", "LICENSE"),
        ):
            shutil.copy2(source, stage / name)
        probe = work / "health.toml"
        probe.write_text(health_config(parsed))
        # Validate libraries/GPU/config before touching any installed files or units.
        subprocess.run([str(stage / "moonshine"), str(probe), "healthcheck"], env=env, check=True)
        snapshot = Snapshot(work / "backup", [
            config_home / "moonshine", runtime, service, legacy_service, manifest,
            helper, data_home / "moonshine/state.toml",
        ])
        try:
            # Stop without disabling. The old boot configuration remains intact
            # until the replacement passes its real-port check and becomes ready.
            for unit, state in states.items():
                if state["active"]:
                    systemctl("stop", unit)
            if property_value("moonshine-session.service", "ActiveState") not in ("inactive", "failed", ""):
                systemctl("stop", "moonshine-session.service")
            remove(runtime)
            Snapshot.copy(stage, runtime)
            for path in (config, service, manifest, helper):
                path.parent.mkdir(parents=True, exist_ok=True)
            if migrating and config.exists():
                shutil.copy2(config, config.with_name("config.toml.before-migration"))
            config.write_text(text)
            shutil.copy2(SCRIPT_DIR / "prepare-steam.sh", helper)
            helper.chmod(0o755)
            layer = json.loads((package / "usr/share/vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json").read_text())
            layer["layer"]["library_path"] = str(runtime / "libmoonshine_wsi.so")
            manifest.write_text(json.dumps(layer, ensure_ascii=False, indent=2) + "\n")
            service.write_text(f'''[Unit]
Description=Moonshine streaming server
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=exec
# ':' disables dollar expansion; '%' is escaped separately in unit_arg.
ExecStart=:{unit_arg(runtime / 'moonshine')} {unit_arg(config)}
Environment={unit_arg('XDG_CONFIG_HOME=' + str(config_home))}
Environment={unit_arg('XDG_DATA_HOME=' + str(data_home))}
Environment=MOONSHINE_LOG=moonshine=info,moonshine_core=info
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=graphical-session.target
''')
            subprocess.run([str(runtime / "moonshine"), str(config), "healthcheck"], env=env, check=True)
            systemctl("daemon-reload")
            systemctl("enable", "--now", SERVER)
            wait_ready(parsed)
            if legacy_service.exists():
                systemctl("disable", LEGACY)
                legacy_service.unlink()
            if migrating:
                legacy_config.unlink()
            systemctl("daemon-reload")
        except BaseException:
            print("Installation failed; restoring previous files and server state.", file=sys.stderr)
            systemctl("stop", SERVER, check=False)
            systemctl("disable", SERVER, check=False)
            snapshot.restore()
            systemctl("daemon-reload")
            for unit, state in states.items():
                if state["enabled"]:
                    systemctl("enable", unit)
                if state["active"]:
                    systemctl("reset-failed", unit, check=False)
                    systemctl("start", unit)
            raise

    # Only prune versions after readiness. Never remove an older rollback runtime
    # on failed validation, failed activation or a failed migration.
    for sibling in runtime.parent.iterdir():
        if sibling != runtime and sibling.is_dir() and not sibling.is_symlink():
            shutil.rmtree(sibling)
    print(f"Moonshine server ready: {config}")


def main():
    if sys.argv[1] == "check-environment":
        check_environment(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        install(Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]), Path(sys.argv[5]))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
