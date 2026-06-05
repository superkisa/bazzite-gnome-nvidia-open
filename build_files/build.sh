#!/bin/bash
#cspell:words ouex noscripts tsflags nogpgcheck

set -ouex pipefail

# Copy a bundled `.repo` file into place, then install one or more packages.
# The repo file is expected at `/ctx/fs/etc/yum.repos.d/<repo_name>.repo`.
function install_yum_repo() {
	local repo_name="$1"
	cp "/ctx/fs/etc/yum.repos.d/${repo_name}.repo" \
		"/etc/yum.repos.d/${repo_name}.repo"
}

###  Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images.
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/43/x86_64/repoview/index.html&protocol=https&redirect=1

# NetBird's %post scriptlet tries to start the service during install,
# which fails in a container build (no systemd). Skip scriptlets here.
install_netbird() {
	install_yum_repo netbird
	dnf5 install -y --setopt=tsflags=noscripts netbird netbird-ui
	# The skipped %post runs `netbird service install` to write the systemd
	# unit file. Call it manually; daemon-reload will fail (no systemd bus
	# in container) but the unit file is written before that.
	netbird service install || true
}

install_fedora_packages() {
	dnf5 install -y tmux

	install_yum_repo vscode
	dnf5 install -y code

	install_yum_repo terra
	dnf5 install -y --nogpgcheck terra-release terra-gpg-keys
	dnf5 install -y zed

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
