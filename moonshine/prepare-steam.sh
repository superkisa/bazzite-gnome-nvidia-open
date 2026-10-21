#!/bin/bash
# Steam is single-instance: stop the desktop instance before streaming starts.
set -ouex pipefail

if pgrep -u "$UID" -x steam >/dev/null; then
	/usr/bin/steam -shutdown || true
	for ((attempt = 0; attempt < 30; attempt++)); do
		if ! pgrep -u "$UID" -x steam >/dev/null; then
			exit 0
		fi
		sleep 1
	done
	echo 'Steam is still running. Close Steam and its games, then reconnect.' >&2
	exit 1
fi
