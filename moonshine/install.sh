#!/bin/bash
# Install a pinned, per-user runtime; image dependencies are in build.sh.
set -ouex pipefail

version=0.16.1
rpm_sha256=9540ae5b88828bb3b8c442eb4794644aceb66fa4b623afc65ea0f29146fae267
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$script_dir/common.sh"

if [[ $(uname -m) != x86_64 || $# -gt 1 ]]; then
	echo 'Usage: moonshine-install [RPM]; this runtime requires x86_64.' >&2
	exit 1
fi
for tool in curl sha256sum rpm2cpio cpio python3 systemctl; do
	command -v "$tool" >/dev/null
done
check_environment

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
python3 "$script_dir/install.py" install "$work_dir/package" "$version" \
	"$config_home" "$data_home"
echo "See $script_dir/README.md for server management and client settings."
