# Pop!_OS 24.04 LTS — verified platform facts (researched 2026-08-18)

## Release
- **Stable since 2025-12-11.** Based on Ubuntu 24.04 LTS (`noble`), 5-year support.
- Current ISO build as of Aug 2026: **build 27** (`pop-os_24.04_amd64_generic_27.iso`).
  Scriptable: `curl -s https://api.pop-os.org/builds/24.04/generic | jq -r .url`
- **COSMIC is the default and only Pop-built DE.** `pop-desktop` `Pre-Depends: pop-de-cosmic`.
  Vanilla GNOME is installable from the Ubuntu repos (`apt install gnome-session`) but is not a Pop flavour.
- **Flatpak/Flathub, not snapd.** Any "disable snap refresh" tuning advice is a no-op here.

## Kernel
- Shipped at GA: **6.17.9**. System76 ships its own mainline-tracking kernel via the
  **`linux-system76`** meta-package — *not* Ubuntu HWE. Version strings observed in
  2026: `6.18.7-76061807-generic`, `7.0.9-76070009-generic`, changelog entries at `7.0.11`.
- Check on the box: `apt-cache policy linux-system76; uname -r`
- ⚠️ Not officially documented by System76. Strongly evidenced, treat as such.

## Bootloader — the single most important scripting fact
- **UEFI → systemd-boot, managed by `kernelstub`.** LUKS/FDE does not change this.
- **Legacy BIOS → GRUB.**
- `update-grub` does nothing on a normal Pop!_OS UEFI install. This is why copy-pasted
  Ubuntu tuning guides silently fail to change the kernel command line.

```bash
sudo kernelstub -a "amd_pstate=active"   # add (idempotent per option)
sudo kernelstub -d "amd_pstate=active"   # remove
sudo kernelstub -o "quiet loglevel=0 splash"   # replace whole cmdline
sudo kernelstub -p                       # print
```
Paths: `/etc/kernelstub/configuration` (live JSON), `/var/log/kernelstub.log`,
boot entry `/boot/efi/loader/entries/Pop_OS-current.conf`.
Exit codes: 0 ok, 168 no options, 169 malformed config, 176 not root.

## Power management
- `system76-power` is installed by default (`pop-desktop` Recommends it) and
  **hard-conflicts with `power-profiles-daemon`** at the dpkg level
  (`Conflicts/Provides/Replaces`). `tlp` is not installed and not declared as a
  conflict, but overlaps functionally — do not run both.
- Unit: `com.system76.PowerDaemon.service`. CLI:
  `system76-power profile battery|balanced|performance`,
  `system76-power charge-thresholds --profile balanced`.
- COSMIC settings tries the System76 D-Bus proxy first and falls back to PPD.

## Scheduler
- `system76-scheduler` is Recommended by `pop-desktop`. Unit `com.system76.Scheduler.service`.
- Config: `/etc/system76-scheduler/config.kdl`, extra rules in
  `/etc/system76-scheduler/process-scheduler/*.kdl`. Reload: `system76-scheduler daemon reload`.
- **Important caveat:** the *CFS-latency* half of the daemon is effectively dead on
  24.04's kernel — it probes `/sys/kernel/debug/sched/latency_ns` and
  `/proc/sys/kernel/sched_latency_ns`, both removed by EEVDF (kernel ≥ 6.6). The
  *process-priority* half still works and is genuinely useful for keeping the
  desktop responsive during builds.

## Packages
- deb822 `.sources` files in `/etc/apt/sources.list.d/`:
  `system.sources` (→ `apt.pop-os.org/ubuntu`, **not** `archive.ubuntu.com`),
  `pop-os-release.sources`, `pop-os-apps.sources`.
- **Pinning gotcha:** `/etc/apt/preferences.d/pop-default-settings` pins
  `o=pop-os-release` at **priority 1001** — Pop's release repo overrides everything,
  including downgrades.
- `nala` is available (noble universe, 0.15.1).
- Pop's repo tool is `apt-manage` (from `python3-repolib`); GUI is Repoman.
- `pop-upgrade` rewrites codenames inside third-party `.list` files on release
  upgrade; System76 removed PPAs entirely for the 22.04→24.04 path.

## zram / swap defaults
- **zram is on by default** via `pop-default-settings-zram` →
  `/usr/bin/pop-zram-config`, configured in `/etc/default/pop-zram`:
  `MAX_SIZE=16384` (MiB), `PORTION=100`, `ALGO=zstd`, `SWAPPINESS=180`.
  The unit sets `vm.swappiness=180` and `vm.page-cluster=0` at runtime.
- Static sysctl `/etc/sysctl.d/10-pop-default-settings.conf` sets
  `vm.swappiness=10` — the zram unit overrides it at boot. Both exist; the unit wins.
- Encrypted clean install creates a 4096 MiB swap partition with a **random per-boot
  key**, so hibernation is not possible without reconfiguration.

## Known AMD-laptop issues on COSMIC 24.04
- COSMIC is **Wayland-only** (no Xorg session).
- **Suspend/resume is the #1 open problem on AMD.** cosmic-comp#2444 (Radeon 890M,
  no resume, hard power-off required), #2191 (Radeon 780M, black screen after
  resume — workaround `systemctl restart cosmic-greeter`), #2495 (page-flip commit
  failures under XWayland). Practical workaround: disable automatic suspend.
- Fractional scaling double-scales older Electron/Chromium apps on secondary
  monitors — fix with `ELECTRON_OZONE_PLATFORM_HINT=auto`.

## Upgrades
- `pop-upgrade` is the mechanism; `do-release-upgrade` is deliberately stubbed out.
- `pop-upgrade recovery upgrade from-release` **before** `pop-upgrade release upgrade`.
- Recovery partition (4 GiB FAT32, label `recovery`) only exists if created at install.
  Refresh Install = hold **Space** at boot.

## Not verified
Official System76 kernel-update policy; exact `linux-system76` version in the repo
today; zswap default state on the Pop kernel; whether kernelstub is auto-invoked by
dpkg triggers on kernel install.

## Sources
- https://www.omgubuntu.co.uk/2025/12/pop_os-24-04-lts-stable-release
- https://www.phoronix.com/news/System76-Ships-Pop-OS-24.04
- https://system76.com/support/kernelstub · https://github.com/pop-os/kernelstub
- https://github.com/pop-os/system76-power · https://github.com/pop-os/system76-scheduler
- https://github.com/pop-os/default-settings · https://github.com/pop-os/desktop
- https://system76.com/support/upgrade-pop · https://github.com/pop-os/upgrade
- https://github.com/pop-os/cosmic-comp/issues/2444 · /2191 · /2495
- https://github.com/pop-os/pop/issues/3234 (system76-power vs power-profiles-daemon)
