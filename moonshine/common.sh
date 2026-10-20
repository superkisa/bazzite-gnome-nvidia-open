#!/bin/bash
set -ouex pipefail

if [[ $EUID -eq 0 ]]; then
	echo 'Run this as your desktop user, without sudo.' >&2
	exit 1
fi
data_home=${XDG_DATA_HOME:-$HOME/.local/share}
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
if [[ $data_home != /* || $config_home != /* ]]; then
	echo 'XDG_DATA_HOME and XDG_CONFIG_HOME must be absolute paths.' >&2
	exit 1
fi
server_service=moonshine-server.service
legacy_service=moonshine-tablet.service
# Shared paths consumed by the lifecycle entry points.
# shellcheck disable=SC2034
config="$config_home/moonshine/config.toml"
# shellcheck disable=SC2034
service="$config_home/systemd/user/$server_service"

unit_exists() {
	[[ $(systemctl --user show "$1" --property=LoadState --value) != not-found ]]
}

stop_servers() {
	local unit
	for unit in "$server_service" "$legacy_service"; do
		if unit_exists "$unit"; then
			systemctl --user disable --now "$unit"
		fi
	done
	if unit_exists moonshine-session.service; then
		systemctl --user stop moonshine-session.service
	fi
}
