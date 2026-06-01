---
description: "Add a dnf package to build.sh with optional COPR repo support. Use when installing new packages in the custom Bazzite image."
name: "add-dnf-package"
argument-hint: "<package-name>"
agent: "agent"
---

Add a package to the custom Bazzite bootc image.

**Package**: ${input}

## Instructions

1. Read [build.sh](build_files/build.sh) to understand the current structure and existing packages.
2. Determine if the package requires a COPR repo:
   - If the user specified a COPR repo, or if you know the package lives in a COPR, use the COPR pattern below.
   - Otherwise, add a plain `dnf5 install -y` line in the "Install packages" section.
3. Edit `build_files/build.sh` — preserve the existing `set -ouex pipefail` header and shebang.

### Plain package pattern

Add a comment above the install line explaining what the package is for:

```bash
# <short description of the package>
dnf5 install -y <package-name>
```

### COPR package pattern

When a COPR repo is needed, use the enable → install → disable pattern to avoid leaking COPRs into the final image:

```bash
# <short description of the package>
dnf5 -y copr enable <owner>/<repo>
dnf5 -y install <package-name>
dnf5 -y copr disable <owner>/<repo>
```

### Rules

- Always use `dnf5` (not `dnf`).
- Group related packages together. If installing multiple packages from the same source, use a single `dnf5 install -y pkg1 pkg2 ...` line.
- Place COPR-based installs after the plain package installs section, before any `systemctl enable` lines.
- Do **not** remove or reorder existing content unless the user asks.
