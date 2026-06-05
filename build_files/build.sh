#!/bin/bash

set -ouex pipefail

###  Helper functions

# Copy a bundled `.repo` file into place, then install one or more packages.
#
# Usage: `install_from_repo <repo_name> [dnf5-flags...] -- <package...>`
#
# Any arguments before "`--`" are passed as extra flags to dnf5 install.
# The repo file is expected at `/ctx/fs/etc/yum.repos.d/<repo_name>.repo`.
#
# Examples:
#   install_from_repo vscode              -- code
#   install_from_repo terra --nogpgcheck  -- terra-release terra-gpg-keys
install_from_repo() {
	local repo_name="$1"
	shift

	local dnf_flags=()
	local packages=()
	local past_separator=0

	for arg in "$@"; do
		if ((past_separator)); then
			packages+=("$arg")
		elif [[ "$arg" == "--" ]]; then
			past_separator=1
		else
			dnf_flags+=("$arg")
		fi
	done

	cp "/ctx/fs/etc/yum.repos.d/${repo_name}.repo" \
		"/etc/yum.repos.d/${repo_name}.repo"

	dnf5 install -y "${dnf_flags[@]+"${dnf_flags[@]}"}" "${packages[@]}"
}

###  Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images.
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/43/x86_64/repoview/index.html&protocol=https&redirect=1

# NetBird's %post scriptlet tries to start the service during install,
# which fails in a container build (no systemd). Skip scriptlets here.
install_netbird() {
	install_from_repo netbird --setopt=tsflags=noscripts -- netbird netbird-ui
	# The skipped %post runs `netbird service install` to write the systemd
	# unit file. Call it manually; daemon-reload will fail (no systemd bus
	# in container) but the unit file is written before that.
	netbird service install || true
}

install_fedora_packages() {
	dnf5 install -y tmux zed

	install_from_repo vscode -- code

	# install_from_repo terra --nogpgcheck -- terra-release terra-gpg-keys
	# dnf5 install -y zed

	install_netbird
}


enable_services() {
	systemctl enable podman.socket
	systemctl enable netbird.service
}

# Configure container signature verification
configure_signatures() {
	jq '.transports.docker["ghcr.io/superkisa"] = [
        {
            "type": "sigstoreSigned",
            "keyPath": "/etc/pki/containers/superkisa.pub",
            "signedIdentity": {"type": "matchRepository"}
        }
    ]' /etc/containers/policy.json >/tmp/policy.json
	mv /tmp/policy.json /etc/containers/policy.json

	cp /ctx/fs/etc/containers/registries.d/ghcr.io-superkisa.yaml \
		/etc/containers/registries.d/ghcr.io-superkisa.yaml
}

###  Main

install_fedora_packages
enable_services
configure_signatures
