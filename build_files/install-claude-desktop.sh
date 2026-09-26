#!/bin/bash
#cspell:words gpgv dearmor hicolor postinst userns

set -ouex pipefail

# Claude Desktop (Linux beta) ships only as a .deb from Anthropic's apt
# repository; there is no RPM or dnf repo yet. The payload is a self-contained
# Electron app under /usr (nothing in /opt), so unpack it straight into the
# image. Once an RPM exists, delete this script and its keyring and install the
# package with dnf5 instead.
#
# Trust chain, same as apt's: the pinned signing key verifies InRelease, whose
# SHA256 covers Packages, whose SHA256 covers the .deb. Each step fails the
# build on a mismatch. The newest version is picked on every build, so the
# daily rebuild is the update mechanism (the app never self-updates on Linux).
#
# The package's maintainer scripts are NOT run. They write an AppArmor profile
# (irrelevant on SELinux), register the apt repo (no apt here) and install the
# GNOME search provider, which is replicated below.
#
# Must run after every dnf5 install: see the cache rebuild at the end.

repo=https://downloads.claude.ai/claude-desktop/apt/stable
arch=amd64
# Matches https://downloads.claude.ai/claude-desktop/key.asc and Anthropic's
# install docs. If the key is ever rotated, replace the .asc and this together.
fingerprint=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
keyring=/ctx/claude-desktop-archive-keyring.asc
app=/usr/lib/claude-desktop

fail() {
	echo "install-claude-desktop: $*" >&2
	exit 1
}

for tool in ar gpg gpgv curl sha256sum strings xz gtk-update-icon-cache update-desktop-database; do
	command -v "$tool" >/dev/null || fail "$tool is missing from the build image"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

# gpgv needs a binary keyring, and the pinned file must hold exactly the
# expected key.
export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"
gpg --batch --quiet --dearmor -o keyring.gpg "$keyring"
[ "$(gpg --batch --show-keys --with-colons keyring.gpg | awk -F: '/^fpr/ { print $10 }')" = "$fingerprint" ] ||
	fail "pinned key does not have fingerprint $fingerprint"

curl -fsSL --retry 3 -o InRelease "$repo/dists/stable/InRelease"
gpgv --keyring "$work/keyring.gpg" --output Release InRelease ||
	fail "InRelease signature does not verify against the pinned key"

# apt refuses an expired Release; so does this, so a frozen mirror cannot pin
# an old build forever.
valid_until=$(sed -n 's/^Valid-Until: //p' Release)
[ -n "$valid_until" ] || fail "Release has no Valid-Until"
[ "$(date -u -d "$valid_until" +%s)" -gt "$(date -u +%s)" ] ||
	fail "Release expired at $valid_until"

packages_sha=$(awk -v f="main/binary-$arch/Packages" '
	/^SHA256:/ { s = 1; next }
	/^[^ ]/    { s = 0 }
	s && $3 == f { print $1 }
' Release)
[ -n "$packages_sha" ] || fail "Release lists no SHA256 for main/binary-$arch/Packages"
curl -fsSL --retry 3 -o Packages "$repo/dists/stable/main/binary-$arch/Packages"
echo "$packages_sha  Packages" | sha256sum --quiet -c - || fail "Packages checksum mismatch"

# One "version filename sha256" line per claude-desktop stanza; keep the newest.
read -r version filename deb_sha < <(awk '
	/^Package: /  { p = $2; v = f = h = "" }
	/^Version: /  { v = $2 }
	/^Filename: / { f = $2 }
	/^SHA256: /   { h = $2 }
	/^$/          { if (p == "claude-desktop" && v && f && h) print v, f, h; p = "" }
	END           { if (p == "claude-desktop" && v && f && h) print v, f, h }
' Packages | sort -V -k1,1 | tail -n 1)
[ -n "${version:-}" ] || fail "no claude-desktop package in the $arch index"
case "$filename" in
pool/main/c/claude-desktop/claude-desktop_*_"$arch".deb) ;;
*) fail "unexpected package path: $filename" ;;
esac

echo "install-claude-desktop: installing $version"
curl -fsSL --retry 3 -o claude-desktop.deb "$repo/$filename"
echo "$deb_sha  claude-desktop.deb" | sha256sum --quiet -c - || fail ".deb checksum mismatch"

ar x claude-desktop.deb data.tar.xz
mkdir data
tar -xpJf data.tar.xz -C data --no-same-owner

# Everything must stay under /usr: /opt and /usr/local are /var symlinks on an
# atomic image and would not be part of the deployment.
stray=$(cd data && find . -mindepth 1 -maxdepth 1 ! -name usr)
[ -z "$stray" ] || fail "package installs outside /usr: $stray"
[ -x data/usr/lib/claude-desktop/claude-desktop ] || fail "the .deb has no usr/lib/claude-desktop/claude-desktop"

rm -rf "$app"
cp -a data/usr/lib/claude-desktop "$app"
# A relative symlink into $app; the .desktop file runs the bare name.
cp -a data/usr/bin/claude-desktop /usr/bin/claude-desktop
[ -x /usr/bin/claude-desktop ] || fail "/usr/bin/claude-desktop does not resolve to the app"
cp -a data/usr/share/applications/com.anthropic.Claude.desktop /usr/share/applications/
cp -a data/usr/share/icons/hicolor/. /usr/share/icons/hicolor/
install -Dm0644 data/usr/share/doc/claude-desktop/copyright /usr/share/doc/claude-desktop/copyright

# Chromium's user-namespace sandbox works on Bazzite, so the SUID fallback
# helper is not needed; drop the bit to keep one fewer setuid-root binary. If
# the app ever fails with "No usable sandbox", restore 4755 here rather than
# launching with --no-sandbox.
chmod 0755 "$app/chrome-sandbox"

# GNOME Shell search provider, which the .deb's postinst registers.
provider="$app/resources/gnome-search-provider"
install -Dm0644 "$provider/com.anthropic.Claude.search-provider.ini" \
	/usr/share/gnome-shell/search-providers/com.anthropic.Claude.search-provider.ini
install -Dm0644 "$provider/com.anthropic.Claude.SearchProvider.service" \
	/usr/share/dbus-1/services/com.anthropic.Claude.SearchProvider.service

# GNOME reads icon-theme.cache and mimeinfo.cache, not the directories. RPM
# scriptlets regenerate both during dnf5 installs, so anything dropped here
# afterwards is invisible: a blank app-grid icon and no claude:// handler. On
# an ostree image every mtime is epoch 0, so GTK can't tell the cache is stale
# and trusts it. Rebuild both and check the new entries landed.
gtk-update-icon-cache --force --quiet /usr/share/icons/hicolor
# The cache is binary and `strings` can glue a preceding byte onto the name, so
# anchor only the end of the line.
grep -qE 'claude-desktop$' < <(strings /usr/share/icons/hicolor/icon-theme.cache) ||
	fail "claude-desktop is missing from the hicolor icon cache"

update-desktop-database /usr/share/applications
grep -q '^x-scheme-handler/claude=.*com\.anthropic\.Claude\.desktop' \
	/usr/share/applications/mimeinfo.cache ||
	fail "claude:// has no handler in mimeinfo.cache"
