#!/bin/bash

set -ouex pipefail

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/43/x86_64/repoview/index.html&protocol=https&redirect=1

# this installs a package from fedora repos
dnf5 install -y tmux 

# VS Code — add Microsoft's RPM repo
cp /ctx/yum.repos.d/vscode.repo /etc/yum.repos.d/vscode.repo
dnf5 install -y code

# NetBird — add NetBird RPM repo
cp /ctx/yum.repos.d/netbird.repo /etc/yum.repos.d/netbird.repo
# NetBird's %post scriptlet tries to start the service during install,
# which fails in a container build (no systemd). Skip scriptlets here.
dnf5 install -y --setopt=tsflags=noscripts netbird netbird-ui

# The skipped %post runs `netbird service install` to write the systemd unit
# file. Call it manually; daemon-reload will fail (no systemd bus in container)
# but the unit file is written before that, so we swallow the error.
netbird service install || true

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

#### Example for enabling a System Unit File

systemctl enable podman.socket
systemctl enable netbird.service
