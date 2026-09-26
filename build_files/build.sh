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

install_chatgpt() {
	install -D -m 644 \
		/ctx/fs/etc/pki/rpm-gpg/RPM-GPG-KEY-chatgpt-3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4.asc \
		/etc/pki/rpm-gpg/RPM-GPG-KEY-chatgpt-3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4.asc
	install_yum_repo chatgpt
	dnf5 install -y chatgpt
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
	dnf5 install -y chezmoi fish git keepassxc kitty socat syncthing xpra
	dnf5 install -y podman podman-docker docker-compose
	# Claude Desktop's Cowork VM (pulls in edk2-ovmf, whose OVMF_CODE.fd it uses)
	dnf5 install -y qemu-system-x86-core virtiofsd

	dnf5 copr enable -y jdxcode/mise
	dnf5 install -y mise
	dnf5 copr disable -y jdxcode/mise

	install_yum_repo vscode
	dnf5 install -y code

	install_yum_repo terra
	dnf5 install -y --nogpgcheck terra-release terra-gpg-keys
	dnf5 install -y zed ghostty

	install_chatgpt
	install_netbird
}

# Unpacks Anthropic's signed .deb (there is no RPM yet).
install_claude_desktop() {
	bash /ctx/install-claude-desktop.sh
}

enable_services() {
	systemctl enable podman.socket
	systemctl enable netbird.service
	systemctl enable hibernate-swap.service
}

configure_hibernation() {
	install -D -m 644 /ctx/fs/etc/default/hibernate-swap \
		/etc/default/hibernate-swap
	install -D -m 644 /ctx/fs/usr/lib/systemd/system/hibernate-swap.service \
		/usr/lib/systemd/system/hibernate-swap.service
	install -D -m 755 /ctx/fs/usr/libexec/configure-hibernate-swap \
		/usr/libexec/configure-hibernate-swap
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

	install -m 644 /ctx/fs/etc/pki/containers/superkisa.pub /etc/pki/containers/superkisa.pub
}

# GNOME reads icon-theme.cache and mimeinfo.cache, not the directories. RPM
# file triggers regenerate both on every dnf5 install, but files copied in
# outside dnf (Claude Desktop) only reach them through this rebuild. On an
# ostree image every mtime is epoch 0, so GTK can't tell a cache is stale and
# trusts it. Run this after the last file is copied in, then check that the
# manually installed entries landed.
rebuild_desktop_caches() {
	gtk-update-icon-cache --force --quiet /usr/share/icons/hicolor
	update-desktop-database /usr/share/applications

	# The cache is binary and `strings` can glue a preceding byte onto the
	# name, so anchor only the end of the line.
	grep -qE 'claude-desktop$' < <(strings /usr/share/icons/hicolor/icon-theme.cache) || {
		echo "claude-desktop is missing from the hicolor icon cache" >&2
		exit 1
	}
	grep -q '^x-scheme-handler/claude=.*com\.anthropic\.Claude\.desktop' \
		/usr/share/applications/mimeinfo.cache || {
		echo "claude:// has no handler in mimeinfo.cache" >&2
		exit 1
	}
}

###  Main

install_fedora_packages
install_claude_desktop
configure_hibernation
enable_services
configure_signatures
rebuild_desktop_caches
