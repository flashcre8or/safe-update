# safe-update

A hardened rolling-update script for Arch Linux that replaces bare `yay -Su` with layered supply-chain safeguards. Built in direct response to the June 2026 **Atomic Arch** AUR supply-chain attack.

---

## Why this exists

In June 2026, attackers adopted hundreds of orphaned AUR packages through AUR's legitimate maintainer-adoption process, then injected malicious build steps (`npm install atomic-lockfile`, `bun install js-digest`) into `PKGBUILD` files. The payload was a Rust infostealer paired with an eBPF rootkit targeting developer credentials, browser sessions, and SSH keys. Over 1,500 packages were eventually confirmed compromised.

The standard `yay -Su` workflow has no protection against this class of attack. This script adds multiple independent layers so that no single failure results in a compromised build.

---

## Features

| Safeguard | What it catches |
|---|---|
| Compromised list cross-reference | Packages confirmed malicious by community detection (multi-source) |
| 72-hour age gate | Packages modified too recently for community detection to have fired |
| Devel package age gate | `-git`/`-svn`/`-bzr` packages with freshly-modified PKGBUILDs |
| AUR `OutOfDate` flag | Packages flagged broken or abandoned by the community |
| Maintainer transfer review | Explicit per-package prompt on ownership change; orphan adoptions flagged separately; approved transfers proceed to PKGBUILD review |
| PKGBUILD diff review | Shows only what changed since your last approved review |
| Static PKGBUILD scanner | Nine suspicious patterns: package manager installs, pipe-to-shell, eval, base64 decode, bare IP downloads, home directory writes, systemd persistence, background processes |
| `.install` script review | Post-install hooks that run as root are shown and scanned separately |
| Chroot builds via `makechrootpkg` | Build process runs as an isolated `builduser` with no access to `$HOME`, SSH keys, browser profiles, or vault tokens |
| Package cache pruning | `paccache` keeps the last 3 versions; applied to both `/var/cache/pacman/pkg/` and `~/Aur-Update-Tarballs/` |

---

## How each safeguard works

### Age gate
Uses the AUR RPC API (`/rpc/v5/info`) to read `LastModified` — the timestamp of the last PKGBUILD commit — not the package version date. Official repo packages use `expac` to read the build timestamp from the sync database. The default window is 72 hours, covering a full weekend plus a working day. This means any freshly-poisoned package will be held until the community has had time to detect and report it.

Devel packages (`-git`, `-svn`, `-bzr`, etc.) use the same window. The age gate tracks PKGBUILD modification, not upstream source commits, so the attack surface is identical to regular packages.

### Compromised list
Fetches one or more community-maintained plain-text package lists at runtime and takes their union. Compromised packages are routed to a hard block before any age classification — they cannot appear in any "safe" or "skip" bucket. If the fetch fails, a warning is shown and the run continues with the age gate as the primary backstop.

To add sources, edit `COMPROMISED_LIST_URLS` near the top of the script. Each URL must serve a plain-text list with one package name per line. Blank lines and `#` comments are ignored.

### Maintainer transfer review
On every run, the AUR `Maintainer` field for each pending package is recorded to `~/.local/share/safe-update/maintainers.tsv`. The first run populates the baseline silently; detection activates from the second run onward.

When a change is detected — including `null → someone` (orphan adoption) and `alice → bob` (transfer) — the script presents an explicit per-package prompt before proceeding. Orphan adoptions are called out separately since they represent a previously unmaintained package gaining a new owner. Approving a transfer sends the package to the PKGBUILD review queue so you can inspect the new maintainer's changes before anything is built. Declining skips it for the current run without affecting other packages.

### PKGBUILD diff review
All AUR packages are cloned from AUR git before the review prompt is shown. The PKGBUILD and `.install` file displayed during review are read directly from the cloned directory — the same bytes that `makechrootpkg` will build.

Approved content is stored in `~/.local/share/safe-update/pkgbuilds/`. On each subsequent update, only the diff is shown rather than the full file, using `bat --language=diff` if available, falling back to `diff --color | less -R`. At the review prompt:

- `Y` (or Enter) — approve and save for future diffs; update proceeds
- `n` — skip this package; any existing tarballs for this package are removed from `~/Aur-Update-Tarballs/` so they cannot be accidentally installed
- `a` — abort everything; all cloned temp directories are cleaned up

When a package is declined, tarball removal uses the `pkgname` array parsed from the PKGBUILD rather than the AUR package name, so split packages whose tarballs have different names from the repo are handled correctly.

### Chroot builds
All AUR packages are cloned upfront (before review) into temp directories under `/tmp/`. A `trap EXIT` handler ensures they are removed on every exit path — normal completion, user abort, or unexpected failure. For each approved package:

1. `makechrootpkg -c -r /var/lib/archbuild` builds from the pre-cloned directory
2. The resulting `.pkg.tar.zst` is copied to `~/Aur-Update-Tarballs/`
3. Installed with `sudo pacman -U`

The `-c` flag wipes the working chroot overlay after each build. The chroot `builduser` cannot access your home directory. If the chroot baseline is not set up, the script falls back to `yay -Su` with a warning.

---

## Prerequisites

```bash
sudo pacman -S devtools pacman-contrib
```

`devtools` provides `makechrootpkg` and `mkarchroot`. `pacman-contrib` provides `paccache`.

`jq`, `git`, `curl`, `expac`, and `yay` are assumed to be present on a typical Arch/CachyOS system. `yay` is required both for update discovery (`yay -Qu`) and as the fallback updater when the chroot is not set up.

---

## Setup

### 1. Install the script

```bash
install -m 755 safe-update ~/.local/bin/safe-update
```

Ensure `~/.local/bin` is on your `$PATH`.

### 2. Initialize the chroot

```bash
sudo mkdir -p /var/lib/archbuild
sudo mkarchroot /var/lib/archbuild/root base-devel
```

This creates an ~800 MB clean Arch `base-devel` environment that persists between builds and is refreshed automatically by `makechrootpkg`.

### 3. First run

```bash
safe-update
```

The first run populates the maintainer ownership baseline. No ownership flags will fire on this run — they activate from the second run onward. `~/Aur-Update-Tarballs/` is created automatically if it doesn't exist.

---

## Usage

```
Usage: safe-update [-y] [min_age_hours]
  -y              Skip final update confirmation
  min_age_hours   Minimum package age in hours (default: 72)

Examples:
  safe-update              Default 72h window
  safe-update 24           Shorten window — use when applying a verified CVE patch urgently
  safe-update 168          Extend to one week for extra caution
  safe-update -y           Non-interactive (PKGBUILD review still prompts)

Environment:
  SAFE_UPDATE_AGE          Same as min_age_hours argument
```

The age override is a conscious tradeoff, not a convenience shortcut. If you shorten the window for a CVE, you have presumably already read the advisory and trust the source.

---

## Data directories

| Path | Contents |
|---|---|
| `~/.local/share/safe-update/pkgbuilds/` | Approved PKGBUILD snapshots (`pkg.PKGBUILD`, `pkg.install`) |
| `~/.local/share/safe-update/maintainers.tsv` | Ownership baseline: package, maintainer, last-seen timestamp |
| `~/Aur-Update-Tarballs/` | Built `.pkg.tar.zst` files; `paccache` keeps last 3 versions |
| `/var/lib/archbuild/root` | Persistent clean chroot baseline (~800 MB) |

---

## Privilege model

| Step | Runs as |
|---|---|
| Age check, AUR clone, PKGBUILD review, scan | Current user |
| `makechrootpkg` build | Isolated `builduser` inside chroot (no `$HOME` access) |
| `sudo pacman -Su` (official repos) | root |
| `sudo pacman -U` (AUR tarballs) | root |
| `.install` hooks | root (same as standard `yay` workflow) |

The chroot build step is strictly safer than `yay`, which builds as your user with full access to your home directory. The install step is equivalent to what `yay` does.

---

## Known limitations

- **Network isolation during build** is not enforced. `makechrootpkg` does not block outbound connections by default. The PKGBUILD scanner is the primary defense against build-time exfiltration. A future improvement is wrapping the build with `unshare --net` as an opt-in flag for packages that do not fetch at build time.
- **XZ-class attacks** (long-term upstream infiltration by a trusted contributor) are not detectable through package management hygiene.
- **`.install` hooks run as root** and are reviewed but not sandboxed. Read them carefully.
- The compromised list is only as current as the upstream source. The age gate is the backstop when lists lag behind new compromises.

---

## Background: the Atomic Arch attack

- **Dates:** June 9–12, 2026 (ongoing at time of initial development)
- **Method:** Legitimate orphan adoption of unmaintained AUR packages, followed by injection of `npm install atomic-lockfile` / `bun install js-digest` into `build()` functions
- **Payload:** Rust-based infostealer + eBPF rootkit
- **Targets:** SSH keys, browser session cookies, API tokens, developer credentials
- **Scale:** ~408 packages in the first wave, growing to 1,500–1,900+
- **Community detection:** https://github.com/lenucksi/aur-malware-check
- **Write-up:** https://www.truesec.com/hub/blog/supply-chain-attack-compromising-arch-linux-aur-packages-infostealer-rootkit
