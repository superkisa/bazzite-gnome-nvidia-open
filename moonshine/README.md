# Moonshine server

[Moonshine](https://github.com/hgaiser/moonshine) serves games to Moonlight
clients using a separate virtual gaming display. Each connection requests its
own resolution, frame rate and HDR/SDR mode. The host's physical display can
remain at 1920 × 1080 / 75 Hz / SDR. No dummy plug, EDID override or reboot is
needed for this GNOME Wayland / RTX 3060 setup.

## Install, reinstall, uninstall and purge

Run as the logged-in desktop user, without sudo. End any stream first;
installation and removal stop the server and its gaming session.

From this repository:

```bash
just moonshine-install
# Reuse a previously downloaded, checksum-verified RPM:
just moonshine-install /tmp/moonshine-0.16.1-1.x86_64.rpm
just moonshine-uninstall
just moonshine-purge
```

Images built from this repository also expose the same commands globally:

```bash
ujust moonshine-install
ujust moonshine-uninstall
ujust moonshine-purge
```

`moonshine-install` installs or reinstalls pinned v0.16.1, preserves existing
configuration and pairings, and enables/starts `moonshine-server.service`.
It verifies the official release RPM's SHA-256 against the pinned GitHub asset
digest and extracts its executable, WSI library and license. It does not install
an RPM or run its scriptlets. Runtime files live under the user's data directory,
so OS updates preserve them. The image explicitly installs the RPM's runtime
dependencies, Vulkan loader, virtual-input module defaults, and upstream udev
rules. Preserving files does not guarantee compatibility with future library or
driver changes; the installer checks the candidate runtime before switching.
To update the runtime version, review the new release
and update the version and digest in `install.sh`.

The candidate config and runtime are validated before stopping the old server.
The first health check uses ephemeral ports so it can run alongside an existing
server. After stopping the old server, the installer rechecks the actual ports
and waits for the new server to respond. Failure restores previous files and
the server's enabled/running state. An interrupted game session cannot be restored.
Old runtime versions are pruned only after successful activation.
If an active server's unit file was manually deleted, restore that file or run
uninstall first; the installer refuses to stop a server it could not restart
during rollback. Uninstall still stops such orphaned units.

`moonshine-uninstall` stops/disables the server and removes its unit, runtime,
Vulkan layer manifest and Steam preparation helper. It preserves configuration,
certificates and pairing state, including `~/.local/share/moonshine/state.toml`.

`moonshine-purge` also deletes the complete `~/.config/moonshine` and
`~/.local/share/moonshine` directories. Reinstallation then requires fresh pairing.
The management recipes remain in the repository/image so you can reinstall.
Neither removal command changes the host's firewall or other Vulkan layers.
Custom certificate/key locations outside the managed Moonshine directories are
preserved; remove those separately if desired.

The installer migrates the previous `tablet.toml` to `config.toml`, preserves
user-added application scanners, and removes the previous
`moonshine-tablet.service`. If `config.toml` already exists during that migration,
it is saved as `config.toml.before-migration` before the active config is moved.
Existing application titles are preserved because Moonshine derives app IDs
from them; changing a title can invalidate client shortcuts.

## Files and configuration

| Path | Purpose |
| --- | --- |
| `~/.config/moonshine/config.toml` | Active server configuration |
| `~/.config/moonshine/cert.pem`, `key.pem` | Server certificate and private key |
| `~/.local/share/moonshine/state.toml` | Server identity and client pairings |
| `~/.local/share/moonshine/runtime/0.16.1/` | Executable, WSI library and license |
| `~/.local/share/moonshine/prepare-steam.sh` | Closes existing Steam before starting it in the virtual display |
| `~/.local/share/vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json` | Registers Moonshine's Vulkan WSI layer |
| `~/.config/systemd/user/moonshine-server.service` | User service, started with the graphical login session |

The paths follow `XDG_CONFIG_HOME` / `XDG_DATA_HOME` overrides when set. Install
and removal require those paths to match the systemd user manager's graphical
session environment, because it also launches the streamed games. Divergent
shell-only overrides are rejected before changing files or services. New configs
explicitly set certificate/key paths under `${XDG_CONFIG_HOME}/moonshine`, and
the unit pins both XDG variables. Existing explicit certificate paths are kept.
Unused TOML backups are not loaded or merged into `config.toml`.

The server name defaults to the hostname (`TowerBazzite` here). `hdr = true`
allows HDR when requested by a capable client; SDR clients still receive SDR.
Resolution and frame rate come from the client, so no per-device server config
is necessary. This version supports one active stream at a time.

The default application is **Steam (Big Picture)**. Steam is single-instance per
user: an already-running desktop Steam would open Big Picture on GNOME's display.
The helper closes it, then Moonshine starts Steam with its virtual display,
audio and HDR environment. Finish local games before starting a stream.

An optional `[[application_scanner]]` can expose installed games directly in
Moonlight. Include the same `pre_command` on the scanner; scanned entries do not
inherit it from the Big Picture application. The installer preserves existing
scanners and other config edits.

## Client setup

Use a current Moonlight client (6.0 or newer). Add the host by discovery or its
LAN IP, then enter the client's PIN at <http://localhost:47989/pin> on the host.
The current LAN IP is `192.168.31.201`; it is DHCP-assigned and may change.

These are starting settings; tune bitrate using Moonlight's statistics overlay:

| Client | Resolution | Frame rate | HDR | Codec | Starting bitrate |
| --- | --- | --- | --- | --- | --- |
| Honor MagicPad 2 | 3000 × 1920 | 144 fps | On | HEVC | 60 Mbps |
| Steam Deck OLED | 1280 × 800 | 90 fps | On | HEVC | 20 Mbps |
| Windows laptop, older Intel iGPU | 1920 × 1080 | 60 fps | Off | H.264 | 20 Mbps |

On the Android tablet, enable high refresh rate in system display settings and
unlock additional frame rates in Moonlight if needed. For Deck HDR, use Moonlight
in SteamOS Gaming Mode. On the Windows laptop, enable hardware decoding; H.264
is the conservative starting choice while its exact iGPU generation is unknown.
The RTX 3060 host supports H.264 and HEVC encoding, including HEVC Main10 for
HDR; it cannot encode AV1. No host codec change is needed when switching clients.
See [Moonlight's setup guide](https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide)
for client decoding and HDR requirements.

Launch Big Picture or a scanned game. Select the client's resolution in the game
and enable HDR for HDR clients in supported games. Moonshine sets `DXVK_HDR=1`
and activates its WSI layer for HDR sessions. Existing launch options that force
another display or disable HDR can interfere. Use **Quit Session** in Moonlight
when finished. Actual frame rate depends on the game, encoder, network and client.

The service requires a desktop login. The image ships the upstream Moonshine
udev rules for virtual gamepads, including gyro/touchpad evdev and uhid hidraw
nodes that Bazzite's generic joystick rules do not cover. These additions take
effect when booting the rebuilt image. Headless login/group setup is not
configured by these recipes.

## Diagnostics and config changes

```bash
systemctl --user status moonshine-server.service
systemctl --user restart moonshine-server.service
journalctl --user -b -u moonshine-server.service -u moonshine-session.service
curl 'http://localhost:47989/serverinfo?uniqueid=diagnostic'
```

`moonshine-server.service` is the persistent server. `moonshine-session.service`
is the transient Steam/game session and may be absent when idle. Add `-f` to
`journalctl` to follow logs live. Restart the server after editing `config.toml`
or to rescan newly installed games. Restarting disconnects an active stream.
`systemctl --user daemon-reload` is only needed after changing the service unit.

Validate actual playback with the client statistics and host session logs:
resolution, frame rate, codec and HDR/SDR. The MagicPad 2 has reached Big Picture;
sustained HDR gaming performance and the other clients still need verification.

## LAN firewall

The current `FedoraWorkstation` LAN zone already allows the required ports, so
no firewall change was made. On a stricter LAN zone, allow these default ports:

```bash
sudo firewall-cmd --zone=FedoraWorkstation --add-port=47984/tcp --add-port=47989/tcp --add-port=48010/tcp --add-port=47998-48000/udp
sudo firewall-cmd --permanent --zone=FedoraWorkstation --add-port=47984/tcp --add-port=47989/tcp --add-port=48010/tcp --add-port=47998-48000/udp
```

No router forwarding is required for LAN streaming. The pairing page uses
47989; Sunshine's management port 47990 is not used here.

## Regression checks

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s moonshine/tests -v
just lint
just check
```

The lifecycle tests use isolated directories and simulated systemd/GPU checks;
they do not stop the host's running Moonshine service.
