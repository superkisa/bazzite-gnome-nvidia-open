# Custom Bazzite Bootc Image

Custom bootable container image based on [Universal Blue](https://universal-blue.org/)'s Bazzite GNOME + NVIDIA open drivers (`ghcr.io/ublue-os/bazzite-gnome-nvidia-open:stable`).

## Build Commands

All tasks use [`just`](https://just.systems/). Run on a Linux system with Podman.

```bash
just build                    # Build the container image with Podman
just build-qcow2              # Build QCOW2 disk image via bootc-image-builder
just rebuild-qcow2            # Rebuild container + QCOW2 in one step
just run-vm-qcow2             # Run the QCOW2 image in a VM
just spawn-vm                 # Run VM via systemd-vmspawn
just lint                     # shellcheck all *.sh files
just format                   # shfmt all *.sh files
just check                    # Validate Justfile syntax
just clean                    # Remove build artifacts
```

## Architecture

- **`Containerfile`** — Multi-stage build: copies `build_files/` into a scratch stage, then runs `build.sh` from the base Bazzite image. Ends with `bootc container lint`.
- **`build_files/build.sh`** — All package installations and system customizations go here. Runs during image build inside the container.
- **`disk_config/`** — TOML configs for disk image generation (ISO, QCOW2, RAW). Edit `iso-gnome.toml` kickstart to point at your image for ISO installs.
- **`Justfile`** — Task runner for local builds, VM creation, and development utilities.
- **`.github/workflows/`** — CI: `build.yml` (container build + sign + push to GHCR), `build-disk.yml` (disk images via bootc-image-builder).

## Conventions

- **Package manager**: Use `dnf5` (not `dnf`). RPMFusion repos are available by default.
- **Strict shell**: Always use `set -ouex pipefail` in shell scripts.
- **COPR pattern**: When adding COPR repos, enable → install → disable in the same `RUN` to avoid leaking COPRs into the final image. See examples in `build.sh`.
- **Lint gate**: `bootc container lint` runs at the end of the Containerfile — the build fails if the image isn't bootc-compatible.
- **Signing**: All images are signed with Cosign. The private key is stored as the `SIGNING_SECRET` GitHub secret; `cosign.pub` is the public key in this repo.
- **Root filesystem**: Disk images use Btrfs (`--rootfs=btrfs`), 64 GiB minimum root partition (must fit the OS plus the 32G hibernation swapfile under `/var`).

## Key Files to Edit

| Goal | File |
|------|------|
| Add/remove packages or enable services | `build_files/build.sh` |
| Change base image | `Containerfile` (`FROM` line) |
| Change image name | `Justfile` (first line, `image_name`) |
| Configure ISO installer | `disk_config/iso-gnome.toml` or `iso-kde.toml` |
| Configure disk partitions | `disk_config/disk.toml` |
| Adjust CI/CD behavior | `.github/workflows/build.yml` |
| Update signing public key | `cosign.pub` |

## CI/CD

- **Container builds** trigger on push to `main`, daily cron, and manual dispatch. PRs build but don't push.
- **Disk image builds** trigger manually or on changes to `disk_config/`. Outputs to GitHub Artifacts or S3.
- **Renovate** manages dependency updates (auto-merges pin/digest updates).
