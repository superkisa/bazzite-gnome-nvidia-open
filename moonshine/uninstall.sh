#!/bin/bash
set -ouex pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$script_dir/common.sh"

if [[ $# -gt 1 || ($# -eq 1 && $1 != --purge) ]]; then
	echo 'Usage: uninstall.sh [--purge]' >&2
	exit 1
fi

systemctl --user show-environment >/dev/null
stop_servers
rm -f -- "$service" "$config_home/systemd/user/$legacy_service" \
	"$data_home/vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json" \
	"$data_home/moonshine/prepare-steam.sh"
rm -rf -- "$data_home/moonshine/runtime"
if [[ ${1:-} == --purge ]]; then
	rm -rf -- "$config_home/moonshine" "$data_home/moonshine"
	rm -rf -- "$config_home/systemd/user/$server_service.d" \
		"$config_home/systemd/user/$legacy_service.d"
	echo 'Moonshine removed, including configuration, certificates and pairings.'
else
	echo 'Moonshine removed. Configuration, certificates and pairings preserved.'
fi
systemctl --user daemon-reload
