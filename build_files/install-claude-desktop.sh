#!/bin/bash
#cspell:words gpgv dearmor hicolor postinst userns lintian zstd

set -ouex pipefail

# Claude Desktop (Linux beta) ships only as a .deb from Anthropic's apt
# repository; there is no RPM or dnf repo yet. The payload is a self-contained
# Electron app under /usr (nothing in /opt), so unpack it straight into the
# image. Once an RPM exists, delete this script and its keyring, install the
# package with dnf5 instead, and drop the Claude checks in build.sh's
# rebuild_desktop_caches.
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
# The icon and MIME caches are rebuilt at the end of build.sh, not here.

repo=https://downloads.claude.ai/claude-desktop/apt/stable
suite=stable
arch=amd64
# Matches https://downloads.claude.ai/claude-desktop/key.asc and Anthropic's
# install docs. If the key is ever rotated, replace the .asc and this together.
fingerprint=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
keyring="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-desktop-archive-keyring.asc"
app=/usr/lib/claude-desktop

fail() {
	echo "install-claude-desktop: $*" >&2
	exit 1
}

for tool in ar tar gpg gpgv curl sha256sum; do
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

curl -fsSL --retry 3 -o InRelease "$repo/dists/$suite/InRelease"
gpgv --keyring "$work/keyring.gpg" --output Release InRelease ||
	fail "InRelease signature does not verify against the pinned key"

# The key also signs Anthropic's other repos, so a validly signed index is not
# enough: like apt, insist that it is the suite that was asked for.
release_suite=$(sed -n 's/^Suite: //p' Release)
[ "$release_suite" = "$suite" ] || fail "Release is for suite '$release_suite', not '$suite'"

# apt refuses an expired Release; so does this, so a frozen mirror cannot pin
# an old build forever.
valid_until=$(sed -n 's/^Valid-Until: //p' Release)
[ -n "$valid_until" ] || fail "Release has no Valid-Until"
valid_until_s=$(date -u -d "$valid_until" +%s) || fail "cannot parse Valid-Until: $valid_until"
[ "$valid_until_s" -gt "$(date -u +%s)" ] || fail "Release expired at $valid_until"

packages_sha=$(awk -v f="main/binary-$arch/Packages" '
	/^SHA256:/ { s = 1; next }
	/^[^ ]/    { s = 0 }
	s && $3 == f { print $1 }
' Release)
[[ "$packages_sha" =~ ^[0-9a-f]{64}$ ]] || fail "Release lists no SHA256 for main/binary-$arch/Packages"
# Fetch by hash when the repo offers it: the fixed path is republished (and
# CDN-cached) independently of InRelease, so right after a publish it can come
# from a different generation and fail the checksum.
if grep -qx 'Acquire-By-Hash: yes' Release; then
	packages_url="$repo/dists/$suite/main/binary-$arch/by-hash/SHA256/$packages_sha"
else
	packages_url="$repo/dists/$suite/main/binary-$arch/Packages"
fi
curl -fsSL --retry 3 -o Packages "$packages_url"
echo "$packages_sha  Packages" | sha256sum --quiet -c - || fail "Packages checksum mismatch"

# One "version filename sha256" line per claude-desktop stanza.
candidates=$(awk '
	/^Package: /  { p = $2; v = f = h = "" }
	/^Version: /  { v = $2 }
	/^Filename: / { f = $2 }
	/^SHA256: /   { h = $2 }
	/^$/          { if (p == "claude-desktop" && v && f && h) print v, f, h; p = "" }
	END           { if (p == "claude-desktop" && v && f && h) print v, f, h }
' Packages)
[ -n "$candidates" ] || fail "no claude-desktop package in the $arch index"
# sort -V follows Debian ordering (tilde included) except for epochs, which it
# would misorder; stop rather than install the wrong "newest" version.
case "$candidates" in
*:*) fail "a claude-desktop version has an epoch, which sort -V cannot order" ;;
esac
read -r version filename deb_sha <<<"$(sort -V -k1,1 <<<"$candidates" | tail -n 1)"
case "$filename" in
pool/main/c/claude-desktop/claude-desktop_*_"$arch".deb) ;;
*) fail "unexpected package path: $filename" ;;
esac

echo "install-claude-desktop: installing $version"
curl -fsSL --retry 3 -o claude-desktop.deb "$repo/$filename"
echo "$deb_sha  claude-desktop.deb" | sha256sum --quiet -c - || fail ".deb checksum mismatch"

# dpkg-deb may compress the payload with xz, zstd or gzip. Stream it out of the
# .deb and drop the .deb right after, to keep the tmpfs peak down.
member=$(ar t claude-desktop.deb | grep -xE 'data\.tar(\.(xz|zst|gz))?') ||
	fail "the .deb has no supported data.tar member"
case "$member" in
*.xz) decompress=(--xz) ;;
*.zst) decompress=(--zstd) ;;
*.gz) decompress=(--gzip) ;;
*) decompress=() ;;
esac
mkdir data
ar p claude-desktop.deb "$member" | tar -x "${decompress[@]}" -p --no-same-owner -C data
rm claude-desktop.deb

# Every file in the package must be one this script installs (or knowingly
# skips), so a new file in a future release fails the build instead of being
# silently dropped. This also keeps everything out of /opt and /usr/local,
# which are /var symlinks on an atomic image and would not be deployed.
(cd data && find . ! -type d -printf '%P\n') | awk '
	$0 ~ /^usr\/bin\/claude-desktop$/ { next }
	$0 ~ /^usr\/lib\/claude-desktop\// { next }
	$0 ~ /^usr\/share\/applications\/com\.anthropic\.Claude\.desktop$/ { next }
	$0 ~ /^usr\/share\/icons\/hicolor\/[^\/]+\/apps\/claude-desktop\.(png|svg)$/ { next }
	$0 ~ /^usr\/share\/doc\/claude-desktop\/copyright$/ { next }
	$0 ~ /^usr\/share\/lintian\/overrides\/claude-desktop$/ { next } # Debian-only
	{ print "install-claude-desktop: unhandled file in the .deb: " $0 > "/dev/stderr"; bad = 1 }
	END { exit bad }
' || fail "the .deb ships files this script does not install"
[ -x data/usr/lib/claude-desktop/claude-desktop ] || fail "the .deb has no usr/lib/claude-desktop/claude-desktop"

rm -rf "$app"
cp -a data/usr/lib/claude-desktop "$app"
# A relative symlink into $app; the .desktop file runs the bare name.
cp -a data/usr/bin/claude-desktop /usr/bin/claude-desktop
[ -x /usr/bin/claude-desktop ] || fail "/usr/bin/claude-desktop does not resolve to the app"
install -Dm0644 data/usr/share/applications/com.anthropic.Claude.desktop \
	/usr/share/applications/com.anthropic.Claude.desktop
# File by file, so the base image's hicolor directories and index.theme are
# never touched. An unmatched glob stays literal and fails install.
for icon in data/usr/share/icons/hicolor/*/apps/claude-desktop.*; do
	install -Dm0644 "$icon" "/${icon#data/}"
done
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
