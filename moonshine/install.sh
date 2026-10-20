#!/bin/bash
# Install a pinned, per-user Moonshine runtime without layering the bootc image.
set -ouex pipefail

version=0.16.1
rpm_sha256=9540ae5b88828bb3b8c442eb4794644aceb66fa4b623afc65ea0f29146fae267
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$script_dir/common.sh"
runtime="$data_home/moonshine/runtime/$version"

if [[ $(uname -m) != x86_64 ]]; then
	echo 'This pinned runtime is for x86_64 hosts.' >&2
	exit 1
fi
for tool in curl sha256sum rpm2cpio cpio python3 systemctl; do
	command -v "$tool" >/dev/null
done
systemctl --user show-environment >/dev/null

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
rpm_file=${1:-}
if [[ -z $rpm_file ]]; then
	rpm_file="$work_dir/moonshine.rpm"
	curl -fL --retry 3 -o "$rpm_file" \
		"https://github.com/hgaiser/moonshine/releases/download/v$version/moonshine-$version-1.x86_64.rpm"
fi
printf '%s  %s\n' "$rpm_sha256" "$rpm_file" | sha256sum --check -
mkdir -p "$work_dir/package"
rpm2cpio "$rpm_file" | cpio -idm --quiet -D "$work_dir/package"
stop_servers
install -D -m 755 "$work_dir/package/usr/bin/moonshine" "$runtime/moonshine"
install -D -m 755 \
	"$work_dir/package/usr/lib/moonshine/vulkan-layers/libmoonshine_wsi.so" \
	"$runtime/libmoonshine_wsi.so"
install -D -m 644 "$work_dir/package/usr/share/licenses/moonshine/LICENSE" "$runtime/LICENSE"

mkdir -p "$config_home/moonshine" "$data_home/vulkan/implicit_layer.d" "$(dirname -- "$service")"
install -D -m 755 "$script_dir/prepare-steam.sh" "$data_home/moonshine/prepare-steam.sh"

# Use JSON quoting for TOML strings and escape systemd's specifier syntax in paths.
python3 - "$work_dir/package" "$runtime" "$config" "$service" "$data_home" <<'PY'
import json
import pathlib
import re
import shutil
import socket
import sys
import tomllib

package, runtime, config, service, data_home = map(pathlib.Path, sys.argv[1:])
manifest = json.loads((package / 'usr/share/vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json').read_text())
manifest['layer']['library_path'] = str(runtime / 'libmoonshine_wsi.so')
(data_home / 'vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json').write_text(json.dumps(manifest, indent=2) + '\n')

# The old service explicitly used tablet.toml; preserve that active config,
# including any application scanners added by the user.
legacy_config = config.with_name('tablet.toml')
if legacy_config.exists():
    text = legacy_config.read_text()
    tomllib.loads(text)
    if config.exists():
        backup = config.with_name('config.toml.before-migration')
        if backup.exists():
            raise SystemExit(f'Refusing to overwrite existing migration backup: {backup}')
        shutil.copy2(config, backup)
    text = re.sub(r'(?m)^title = "Steam \(Tablet\)"$', 'title = "Steam (Big Picture)"', text)
    config.write_text(text)
    legacy_config.unlink()

if not config.exists():
    prepare = json.dumps(str(data_home / 'moonshine/prepare-steam.sh'))
    hostname = json.dumps(socket.gethostname())
    config.write_text(f'''# The virtual display follows Moonlight's requested resolution and frame rate.
name = {hostname}
address = "0.0.0.0"
inhibit_sleep = true

[compositor]
hdr = true
steam_mode = true

[[application]]
title = "Steam (Big Picture)"
command = ["/usr/bin/steam", "-bigpicture"]
pre_command = [[{prepare}]]
stdout = "journal"
stderr = "journal"
launch_timeout_secs = 10
''')

tomllib.loads(config.read_text())

def unit_arg(path):
    return '"' + str(path).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'

service.write_text(f'''[Unit]
Description=Moonshine streaming server
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart={unit_arg(runtime / 'moonshine')} {unit_arg(config)}
Environment=MOONSHINE_LOG=moonshine=info,moonshine_core=info
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=graphical-session.target
''')
PY

# The stock Bazzite uaccess rules already grant the logged-in desktop user
# uinput/uhid access. Deliberately leave headless login/group setup to the user.
"$runtime/moonshine" "$config" healthcheck
rm -f -- "$config_home/systemd/user/$legacy_service"
systemctl --user daemon-reload
systemctl --user enable --now "$server_service"
systemctl --user --no-pager status "$server_service"
echo 'Pair from Moonlight, then enter its PIN at http://localhost:47989/pin'
echo 'See moonshine/README.md for server management and client settings.'
