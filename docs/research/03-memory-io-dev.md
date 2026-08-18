
# Linux Tuning Report: 32 GB DDR5 / 1 TB PCIe 4.0 NVMe / Pop!_OS (Ubuntu 24.04 base) for Sustained AI-Agentic Development

**Important platform correction up front:** Pop!_OS 24.04 LTS shipped 2025-12-11 with **kernel 6.17**, not 6.8, and uses **systemd-boot + `kernelstub`**, not GRUB. Any kernel-parameter step in your script must branch on that. Pop!_OS also ships **Flatpak/Flathub, not snapd**, so snapd tuning is a no-op there. ([OMG!Ubuntu](https://www.omgubuntu.co.uk/2025/12/pop_os-24-04-lts-stable-release), [System76 kernelstub](https://system76.com/support/articles/kernelstub/))

```bash
# Pop!_OS kernel params (NOT grub-mkconfig)
sudo kernelstub -a "nvme_core.default_ps_max_latency_us=5500"
sudo kernelstub -p          # print/verify
sudo kernelstub -d "param"  # remove
# Ubuntu-proper fallback:
# edit /etc/default/grub GRUB_CMDLINE_LINUX_DEFAULT; sudo update-grub
```

---

## 1. zram vs zswap vs disk swapfile

### Verdict for 32 GB in 2026
**zram as primary swap + a low-priority disk swapfile only if you want hibernate. Do not run zswap at the same time.**

- zram = compressed block device *in RAM*, used as a swap device. No disk I/O, latency ~µs.
- zswap = compressed *writeback cache in front of* a real disk swap device. Only makes sense when you have real disk swap you actually want to use.
- Running both is a documented anti-pattern — zswap will sit in front of zram and double-compress. ([Enrico Pesce](https://www.enricopesce.it/zram-zswap-linux-swap-configuration/))

zswap's on/off state is a build-time Kconfig (`CONFIG_ZSWAP_DEFAULT_ON`) overridable by `zswap.enabled=0|1`; runtime knobs live at `/sys/module/zswap/parameters/`. ([kernel docs](https://docs.kernel.org/admin-guide/mm/zswap.html)) Script should assert:

```bash
cat /sys/module/zswap/parameters/enabled   # want N when using zram
# if Y: sudo kernelstub -a "zswap.enabled=0"
```

### Package and config path
Package: **`systemd-zram-generator`** (universe on Ubuntu noble; it is the Debian/Ubuntu name for the `systemd/zram-generator` project). The legacy Ubuntu `zram-config` package is a shell-script/initscript approach and should not be used on a systemd-native 24.04 box.

Config search order (first found wins; `.conf.d/` drop-ins override):
```
/run/systemd/zram-generator.conf
/etc/systemd/zram-generator.conf      <-- use this one
/usr/local/lib/systemd/zram-generator.conf
/usr/lib/systemd/zram-generator.conf
```
([zram-generator README](https://github.com/systemd/zram-generator), [zram-generator.conf(5)](https://manpages.ubuntu.com/manpages/noble/man5/zram-generator.conf.5.html))

### Recommended config
```ini
# /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = lz4 zstd
swap-priority = 100
fs-type = swap
```

Rationale:
- `zram-size` is the **uncompressed** capacity of the device, not RAM consumed. `ram / 2` = 16 GiB of logical swap; at a realistic 2.5–3:1 ratio on your workload that costs ≤ 6 GiB of real RAM only if completely filled. Generator default is `min(ram / 2, 4096)` — the 4 GiB cap is far too small here, which is why you must override.
- `compression-algorithm` takes a **whitespace-separated list**: the first is the primary, subsequent ones are *recompression* algorithms (kernel ≥ 6.2, `CONFIG_ZRAM_MULTI_COMP`). Parameters go in parentheses, e.g. `lz4 zstd(level=9)`. So `lz4 zstd` = compress hot pages fast with lz4, recompress idle/huge pages with zstd. ([zram-generator.conf(5) Arch](https://man.archlinux.org/man/zram-generator.conf.5), [kernel zram docs](https://docs.kernel.org/admin-guide/blockdev/zram.html))

### lz4 vs zstd — pick lz4 primary
Reported figures: zstd ≈ 4:1 ratio, lz4 ≈ 2.6:1, but **zstd dropped IOPS/throughput by 2–4× vs lz4** under heavy memory pressure even on server hardware. ([BigGo summary of the debate](https://biggo.com/news/202510241923_zram-compression-debate-zstd-performance))

For your profile this matters more than usual: you are *already* CPU-saturated (containers + builds + llama.cpp inference pinning every core). Stealing cores for zstd compression during a swap storm is exactly when you can least afford it. lz4 primary + zstd recompression of idle pages is the best of both. On 32 GB you are rarely deeply swapping anyway — you want the *latency* profile, not the ratio.

Also note: quantized GGUF weights and container layer blobs are already compressed and will land in zram as "huge"/incompressible pages, wasting CPU. Two mitigations:
- These are usually **file-backed mmap pages** (page cache), not anon, so they get reclaimed by page-cache eviction rather than swapped — largely a non-issue for `mmap`'d models.
- If you see high `huge_pages` in `/sys/block/zram0/mm_stat`, add a `writeback-device` so incompressible pages spill to NVMe.

Apply/verify:
```bash
sudo systemctl daemon-reload
sudo systemctl restart systemd-zram-setup@zram0.service
zramctl; swapon --show
cat /sys/block/zram0/mm_stat   # orig_data / compr_data / mem_used_total / ... / huge_pages
```

### Hibernate interaction — the hard constraint
**zram cannot host a hibernation image.** The image is written to a swap device that survives power-off; zram is RAM. If zram is your only swap, `systemctl hibernate` fails. ([Gentoo wiki](https://wiki.gentoo.org/wiki/Suspend_and_hibernate))

If you want hibernate, keep a disk swapfile *in addition*, at **lower priority** so zram is preferred:

```bash
# /etc/fstab
/swapfile none swap sw,pri=-2 0 0
# kernel params (Pop!_OS):
sudo kernelstub -a "resume=UUID=<root-fs-uuid> resume_offset=<N>"
# compute N:
sudo filefrag -v /swapfile | awk '$1=="0:"{gsub(/\./,"",$4); print $4}'
```

Two caveats:
- zram-resident pages are decompressed back into RAM before the image is written, so hibernation image size is driven by total anon footprint, not by how much is in zram. Size the swapfile ≥ RAM to be safe.
- **Unverified for Pop!_OS:** Ubuntu-lineage kernels enable kernel lockdown under Secure Boot, and lockdown `integrity` mode blocks hibernation. System76 kernels may differ. Script should test `cat /sys/kernel/security/lockdown` and warn rather than assume.

---

## 2. sysctl VM tuning

```ini
# /etc/sysctl.d/99-devbox-vm.conf
# --- swap / reclaim (assumes zram is primary swap) ---
vm.swappiness = 150
vm.page-cluster = 0
vm.watermark_scale_factor = 125
vm.watermark_boost_factor = 0
vm.vfs_cache_pressure = 50

# --- writeback (PCIe 4.0 NVMe, 32 GB RAM) ---
vm.dirty_background_bytes = 268435456      # 256 MiB
vm.dirty_bytes           = 1610612736      # 1.5 GiB
vm.dirty_expire_centisecs = 1500           # 15s
vm.dirty_writeback_centisecs = 500         # 5s (default, keep)

# --- address space ---
vm.max_map_count = 1048576
vm.overcommit_memory = 0
vm.min_free_kbytes = 262144                # 256 MiB
```

### `vm.swappiness` — yes, the old "10" advice is now wrong
Kernel documentation was updated to state the range is **0–200** (default 60) and explicitly: *"For in-memory swap, like zram or zswap, as well as hybrid setups that have swap on faster devices than the filesystem, values beyond 100 can be considered."* ([kernel vm sysctl docs](https://docs.kernel.org/admin-guide/sysctl/vm.html))

Why `10` was right and now isn't: swappiness is a **ratio knob** biasing anon-page reclaim vs file-page reclaim. It does not cause swapping in the absence of memory pressure. With spinning-rust or even SATA swap, swapping in an anon page cost ~10 ms, so you biased hard toward dropping page cache. With zram, a swap-in is a memcpy + lz4 decompress — cheaper than re-reading a header file from NVMe and *far* cheaper than re-reading it through the page cache miss path. Setting swappiness low with zram actively hurts you: the kernel evicts your build's page cache (headers, git objects, node_modules stats) instead of compressing an idle Electron heap, so your next `tsc`/`cargo`/`cc` run re-reads everything from disk.

150 is the sweet spot cited in practice (100–133 range in the Enrico Pesce writeup, higher tolerable). Do **not** use 200 — you leave no headroom to bias back. Do **not** use 0 — that disables anon reclaim until near-OOM and is a documented mistake.

### `vm.page-cluster = 0`
Default is 3 = 8 pages read per swap-in fault. That readahead exists to amortize disk seeks. On zram there is no seek, and every extra page is a wasted decompress. Setting 0 disables swap readahead. ([kernel docs](https://docs.kernel.org/admin-guide/sysctl/vm.html)) This is the single highest-value zram companion setting after swappiness.

### `vm.vfs_cache_pressure = 50`
Default 100. Lower = kernel retains dentry/inode caches longer. Large git repos, `node_modules` (hundreds of thousands of tiny files), and container layer trees are dentry-cache-dominated; `git status` on a big repo is essentially a dentry/inode benchmark. 50 halves reclaim pressure on those slabs. Do not go to 0 — kernel docs warn that at 0 *"the kernel will never reclaim dentries and inodes due to memory pressure,"* which is an OOM trigger. Monitor with `slabtop -s c` (SUSE's recommendation).

### dirty ratios — use `_bytes`, not `_ratio`, on a 32 GB box
Defaults are `dirty_ratio=20`, `dirty_background_ratio=10`, `dirty_expire_centisecs=3000`. On 32 GB that's ~6.4 GiB of dirty pages before a writer is throttled and ~3.2 GiB before background flush starts. Even at ~5 GB/s that is a >1 s stall wall, and it lands on you at exactly the wrong moment — `git checkout` of a big branch, `docker build` layer commit, an `fsync()` from SQLite/Postgres in a dev container.

`vm.dirty_bytes` / `vm.dirty_background_bytes` are the byte-valued counterparts and are **mutually exclusive** with the ratio versions — writing one zeroes the other. ([SUSE tuning guide](https://documentation.suse.com/sles/15-SP7/html/SLES-all/cha-tuning-memory.html), [kernel docs](https://docs.kernel.org/admin-guide/sysctl/vm.html)) Your script must not set both. 256 MiB background / 1.5 GiB hard keeps the writeback pipeline continuously fed instead of bursty, at essentially zero throughput cost on a drive this fast. `dirty_expire_centisecs=1500` (15 s) gets cold dirty data out earlier so a `sync` or a hibernate doesn't have 30 s of backlog.

Trade-off to be honest about: smaller dirty limits mean short-lived temp files (build intermediates) are more likely to actually hit the disk instead of being deleted while still dirty. On a 1 TB TLC drive with typical dev write volumes this is not a wear concern, but if you do heavy video encoding to scratch files, put scratch on tmpfs.

### `vm.max_map_count` — probably already correct
Kernel default is **65530**. Ubuntu 24.04 already ships **1048576** via `procps` (2:4.0.4-4ubuntu2), matching Fedora and (since 2024-04) Arch. ([GamingOnLinux on Ubuntu](https://www.gamingonlinux.com/2024/03/ubuntu-2404-increases-vm-max-map-count-for-smoother-linux-gaming/), [Arch news](https://archlinux.org/news/increasing-the-default-vmmax_map_count-value/), [Fedora change](https://fedoraproject.org/wiki/Changes/IncreaseVmMaxMapCount))

Verified on a stock 6.18 kernel here: still 65530 upstream. So the distro override is doing the work. Your script should **check and set idempotently** rather than assume:
```bash
[ "$(sysctl -n vm.max_map_count)" -lt 1048576 ] && echo "vm.max_map_count = 1048576" >> /etc/sysctl.d/99-devbox-vm.conf
```
Who needs it: Electron/VS Code, Chromium, Java/JVM (Elasticsearch mandates 262144 minimum), PyTorch/CUDA allocators, Wine/Proton, and anything with many mmap'd shards. No documented downside; each VMA is ~200 bytes of kernel memory, only allocated on use.

### `vm.overcommit_memory = 0` — leave it
- `0` (heuristic, default): correct.
- `1` (always overcommit): what Redis asks for; safe-ish but removes your last guardrail against a runaway allocation.
- `2` (never overcommit, CommitLimit = swap + `overcommit_ratio`% of RAM): **do not use.** It breaks `fork()`-heavy workloads (Node cluster, make -j, Redis BGSAVE), breaks CUDA/PyTorch which reserve large virtual arenas, and interacts badly with zram since zram capacity counts as swap for CommitLimit while consuming RAM. ([kernel docs](https://docs.kernel.org/admin-guide/sysctl/vm.html))

### `watermark_scale_factor` / `watermark_boost_factor`
Defaults: `watermark_scale_factor=10` (0.1 % of memory, max 3000) and `watermark_boost_factor=15000` (fractions of 10000 → 150 % of high watermark). ([kernel docs](https://docs.kernel.org/admin-guide/sysctl/vm.html))

Raising scale factor to ~125 makes kswapd wake earlier and reclaim in the background, so allocations hit *background* reclaim rather than **direct reclaim** — direct reclaim is a synchronous stall in your process and is what "the whole desktop froze for 4 seconds" actually is. Setting boost factor to 0 disables the fragmentation-triggered extra reclaim, which fires spuriously on systems with heavy container churn and no need for high-order allocations (you're on `madvise` THP, see §3). These two are the standard zram-companion pair.

### `vm.min_free_kbytes`
Default on 32 GB is ~90 MB. 256 MiB gives the atomic/GFP_ATOMIC pool room during NVMe + network + container-bridge bursts. Kernel docs warn only against going *below* 1024 KB. Don't go above ~512 MiB — it's memory you can't use.

---

## 3. Transparent Huge Pages

**Ubuntu/Pop!_OS default: `madvise`. Keep it.**

Verify: `cat /sys/kernel/mm/transparent_hugepage/enabled` → `always [madvise] never` (brackets = active). Observed `[madvise]` on a stock 6.18 kernel here. *Flag: confirm on the actual target — this is a kernel Kconfig (`CONFIG_TRANSPARENT_HUGEPAGE_MADVISE`) and System76 could differ.*

Evidence from the most recent large-scale comparison (Linux 6.18 LTS, `madvise` vs `always`): ClickHouse and Pogocache showed **no real difference**; Blender and GPAW favored `always`; **llama.cpp CPU inference was slightly faster with `madvise`**; nginx HTTPS static favored `madvise`. ([Phoronix THP madvise vs always](https://www.phoronix.com/review/thp-madvise-always))

Why `madvise` is right for *your* mix specifically:
- `always` means khugepaged continuously scans and collapses 4 K pages into 2 M pages system-wide. With dozens of containers starting/stopping, memory is fragmented, so collapse attempts trigger **compaction and direct reclaim** — latency spikes, exactly what kills interactive dev feel.
- `always` inflates RSS: a process touching 4 KB of a region gets 2 MB charged. Multiply by 200 container processes and Node workers and you waste real GB.
- Databases universally document `never` or `madvise` (MongoDB, Redis, Oracle). If you run Postgres/Mongo/Redis in dev containers, `always` is a documented latency hazard.
- For ML: the win comes from TLB pressure on huge contiguous tensors — and those allocators (PyTorch caching allocator, llama.cpp) can call `madvise(MADV_HUGEPAGE)` themselves. `madvise` mode gives them huge pages on request without taxing everything else. Kernel docs also note mTHP (multi-size THP) delivers benefits "with much less prominent latency spikes." ([kernel transhuge docs](https://docs.kernel.org/admin-guide/mm/transhuge.html))

Do **not** set `never` — that would block the ML processes that legitimately want it. (Note: `MADV_COLLAPSE` still works even under `never` on modern kernels.)

Leave `defrag` at its default `madvise` (options: `always`, `defer`, `defer+madvise`, `madvise`, `never`). If you observe compaction stalls in `/proc/vmstat` (`compact_stall`), move to `defer+madvise`.

Paths your script may want to read/set (boot param `transparent_hugepage=always|madvise|never`):
```
/sys/kernel/mm/transparent_hugepage/enabled
/sys/kernel/mm/transparent_hugepage/defrag
/sys/kernel/mm/transparent_hugepage/shmem_enabled
/sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled
```

---

## 4. NVMe

### I/O scheduler: `none`
Phoronix's NVMe scheduler comparison (on a Corsair MP600 1 TB PCIe 4.0 — essentially your class of drive) concluded *"using no I/O scheduler still tends to perform the best overall for this speedy storage medium,"* despite some distros defaulting to mq-deadline or kyber. ([Phoronix](https://www.phoronix.com/review/linux-56-nvme)) This has not been overturned: NVMe has deep hardware queues and no seek cost, so software reordering only adds CPU and latency. `mq-deadline` is for SATA SSDs, `bfq` for spinning rust or when you need per-cgroup I/O fairness, `kyber` is a latency-targeting middle ground that is rarely a win on consumer NVMe.

Modern kernels already select `none` for multi-queue NVMe. **Check before you fight it:**
```bash
cat /sys/block/nvme0n1/queue/scheduler   # expect: [none] mq-deadline kyber bfq
```

Persistent udev rule:
```
# /etc/udev/rules.d/60-ioschedulers.rules
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="nvme*", ATTR{queue/scheduler}="none"
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
```
```bash
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=block
```
I deliberately use `SUBSYSTEM=="block", ENV{DEVTYPE}=="disk"` instead of the commonly-copied `KERNEL=="nvme[0-9]n[0-9]"`. The narrow glob misses `nvme0n10+`, and a broader `nvme*` without the DEVTYPE guard matches partitions (`nvme0n1p1`) which have no `queue/` directory, producing "No such file or directory" spam in your boot log. ([rule form per](https://blog.timotebrusson.fr/2025/06/17/A-week-into-linux-storage-performances-Day-2-Device-optimization-and-scheduler/)) **If you use LUKS full-disk encryption, the `dm-*` device has its own scheduler** — check `/sys/block/dm-0/queue/scheduler` separately.

### APST — `nvme_core.default_ps_max_latency_us`
The bug: some consumer NVMe controllers (SK hynix, certain WD/SanDisk, various Phison/SMI budget drives, and many OEM laptop drives) implement Autonomous Power State Transition badly and hang coming out of the deepest low-power state. Symptom is a hard I/O freeze, often minutes after boot during an idle period. ([writeup](https://mbaraa.com/blog/fixing-nvme-ssd-problems-on-linux); ongoing upstream reports e.g. [SK hynix in Lenovo IdeaPad](https://lkml.iu.edu/hypermail/linux/kernel/2511.2/07277.html), [WD quirk patch](https://lkml.iu.edu/hypermail/linux/kernel/2501.2/02341.html))

dmesg strings your script should grep for:
```bash
journalctl -k --no-pager | grep -Ei 'nvme.*(controller is down|will reset|I/O .*timeout|Device not ready|abort)'
```

Kernel default is `100000` (100 000 µs = 100 ms, permitting the deepest states). Three tiers:
- `nvme_core.default_ps_max_latency_us=5500` — allows shallow power states (PS0–PS3 on most drives), forbids the deepest. **Start here.** Costs very little battery and fixes the majority of cases.
- `=0` — disables APST entirely. Reliable but a real battery/thermal cost on a laptop; the drive idles hot.
- Leave default if `nvme id-ctrl` shows a well-known-good controller and you see no timeouts.

Verify: `cat /sys/module/nvme_core/parameters/default_ps_max_latency_us`.

Inspect the drive's actual power states before deciding:
```bash
sudo nvme id-ctrl /dev/nvme0 | grep -E '^(mn|fr|sn)'
sudo nvme get-feature -f 0x0c -H /dev/nvme0    # APST config
```

### `read_ahead_kb`
Default is **128 KB**. Guidance: sequential streaming (video encode reads, backups, ETL) benefits from 2–8 MB; random/database I/O benefits from lower or 0; **NVMe shows much less dramatic difference than HDD**. ([OneUptime](https://oneuptime.com/blog/post/2026-03-02-how-to-configure-readahead-settings-for-disk-performance-on-ubuntu/view))

For your mixed profile: **leave it at 128, or go to 256 at most.** Raising it hurts you — your dominant pattern is random small-file reads (git objects, `node_modules`, container layers, Python site-packages) where readahead is pure wasted bandwidth and page-cache pollution. The video-encode case is throughput-bound on CPU, not on readahead. If you have a *separate* scratch volume purely for media, set that one higher.

```
# /etc/udev/rules.d/62-readahead.rules   (only if you actually want to change it)
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="nvme*", ATTR{bdi/read_ahead_kb}="256"
```
**Flag / verify at runtime:** `queue/read_ahead_kb` is a symlink into the `bdi` object; some udev/kernel combinations only accept `ATTR{bdi/read_ahead_kb}`, others `ATTR{queue/read_ahead_kb}`. Have your script test-write both and keep whichever sticks, or fall back to a `RUN+="/sbin/blockdev --setra 512 /dev/%k"` (note: `blockdev --setra` takes **512-byte sectors**, so 512 KB = `1024`).

**`nr_requests`:** I found a recommendation to set this to 8 on NVMe. I do not trust it and would **not** put it in your script — with `scheduler=none` the queue depth is governed by hardware submission queues and `nr_requests` is largely inert; artificially clamping it to 8 would serialize your parallel build I/O. Leave default.

### `discard` mount option vs `fstrim.timer` — use the timer
**Periodic TRIM via `fstrim.timer` is preferred; do not put `discard` in fstab.** The mechanism: inline discard issues a TRIM on every delete/truncate, and many devices must **drain all outstanding I/O before servicing the discard**, stalling the queue. That produces unpredictable latency spikes, which is intolerable for a machine doing continuous container layer churn and build-artifact deletion. XFS documentation explicitly warns against inline discard in production. ([Rocky Linux TRIM guide](https://docs.rockylinux.org/10/guides/filesystems/configuring_trim/))

Ubuntu enables `fstrim.timer` (weekly) by default via `util-linux`. Verify and harden:
```bash
systemctl status fstrim.timer
sudo systemctl enable --now fstrim.timer
lsblk -D                 # DISC-GRAN/DISC-MAX nonzero => TRIM supported
sudo fstrim -av          # one-shot, verbose
```
Optional, worth doing on a laptop so the weekly trim doesn't stutter an active build:
```bash
sudo systemctl edit fstrim.service
# [Service]
# IOSchedulingClass=best-effort
# IOSchedulingPriority=7
# Nice=19
```
Note: Ubuntu's `fstrim -a` walks `/etc/fstab` mounts, so anything mounted ad hoc (external NVMe enclosures) won't be trimmed automatically.

**LUKS caveat:** TRIM does not pass through dm-crypt unless the mapping has `discard` enabled (`/etc/crypttab` `discard` flag). That has a mild, well-documented confidentiality trade-off (reveals which blocks are unused). On a personal dev laptop, enabling it is the usual choice; your script should surface the decision rather than make it silently.

---

## 5. Filesystem: ext4 vs btrfs

**Recommendation: ext4** for this workload, unless you specifically want snapshot rollback badly enough to accept the tuning burden.

Reasoning specific to your profile:
- Docker's default and best-tested driver on Ubuntu is **overlay2**, and the documented supported backing filesystems are `xfs` (ftype=1), `ext4`, `btrfs`. Docker explicitly says the `btrfs` and `zfs` *drivers* "may require additional set-up or maintenance, which make them not recommended for common scenarios," while overlay2 "provides the highest stability." ([Docker storage driver selection](https://docs.docker.com/engine/storage/drivers/select-storage-driver/))
- Btrfs is copy-on-write. Container image layers, SQLite/Postgres data dirs, and large git pack files rewritten in place fragment badly, and you need periodic `btrfs balance` / `btrfs filesystem defragment` maintenance. If you go btrfs anyway, `chattr +C` the CoW-hostile directories **at creation time** (`/var/lib/docker`, `/var/lib/containers`, DB data dirs, VM images) — `+C` only takes effect on empty files/dirs.
- Btrfs `compress=zstd:1` is a genuine win for source trees and is the one strong argument in its favor, alongside snapshots.

If btrfs: `noatime,compress=zstd:1,ssd,discard=async,space_cache=v2` — note `discard=async` is btrfs's queued-discard implementation and does **not** have the inline-discard stall problem described in §4; it is btrfs's recommended mode.

### ext4 mount options that actually matter in 2026
```
# /etc/fstab
UUID=<root>  /  ext4  defaults,noatime,lazytime,errors=remount-ro  0 1
```

- **`noatime` — yes, still worth setting, and effectively risk-free.** The kernel default is `relatime`, which already suppresses most atime writes (it updates only when atime is older than mtime/ctime, or older than 24 h). So `noatime` buys you the once-per-file-per-day metadata write that `relatime` still does. On a tree with 400 k files in `node_modules` that a linter walks daily, that is a real number of journal transactions for zero benefit. **Risk:** anything genuinely depending on access time — classic `mutt`/mbox "new mail" detection, some backup tools' incremental heuristics, `tmpwatch`-style cleaners keyed on atime. None of these are in your stack. Verdict: set it.
- **`lazytime`** — keeps inode timestamp updates in memory and writes them on `fsync`, inode eviction, or the 24 h expiry, instead of dirtying the inode block on every touch. ([LWN on ext4 lazytime](https://lwn.net/Articles/620086/)) Composes with `noatime` (they address different timestamps: `noatime` = atime, `lazytime` = writeback deferral for all of them). **Risk:** up to 24 h of mtime/ctime imprecision lost on a hard crash. File *data* is unaffected. Acceptable — but be aware that make/ninja/webpack correctness depends on mtime, so after an unclean shutdown do a clean rebuild rather than trusting incremental state.
- **`commit=`** — default 5 s. Raising to 60 buys marginal throughput for 60 s of potential data loss on a laptop that can hard-lock (see the APST bug above). **Don't.**
- **`barrier`** — on by default and must stay on. `nobarrier`/`barrier=0` produces large `fsync` gains and can corrupt the filesystem on power loss. **Never set it.** This advice circulates from the 2010s SAN/BBU-controller era and does not apply to a laptop.
- **`data=ordered`** — default, keep. `data=writeback` is faster and can expose stale block contents after a crash.
- **`dioread_nolock`** — default since 5.6; don't specify.
- **`discard`** — no (see §4).
- **`errors=remount-ro`** — keep whatever the installer set.

Not a mount option but relevant: consider `tmpfs` on `/tmp` sized ~8 G for build scratch. Ubuntu 24.04 does **not** default `/tmp` to tmpfs (24.10+ does). `systemd` ships `tmp.mount`; enable with `sudo systemctl enable --now tmp.mount` — but audit first, since some toolchains dump multi-GB intermediates into `/tmp` and will OOM you.

---

## 6. inotify limits

**Kernel defaults are computed, not fixed.** From `fs/notify/inotify/inotify_user.c`:
```c
inotify_max_queued_events = 16384;
init_user_ns.ucount_max[UCOUNT_INOTIFY_INSTANCES] = 128;
watches_max = (((si.totalram - si.totalhigh) / 100) << PAGE_SHIFT) / INOTIFY_WATCH_COST;
watches_max = clamp(watches_max, 8192UL, 1048576UL);
```
i.e. up to **1 % of addressable RAM per user** for watches, clamped to [8192, 1048576]. ([kernel source](https://raw.githubusercontent.com/torvalds/linux/master/fs/notify/inotify/inotify_user.c))

Empirically derived cost: on an 8 GiB system the resulting limit was 64834, implying **≈1300 bytes of kernel memory per watch**. On your 32 GiB machine the computed default lands around **~260 000** — well under the 1 048 576 ceiling, so raising it is meaningful.

```ini
# /etc/sysctl.d/99-devbox-inotify.conf
fs.inotify.max_user_watches   = 1048576
fs.inotify.max_user_instances = 8192
fs.inotify.max_queued_events  = 524288
```

- **`max_user_watches = 1048576`** — the kernel's own hard ceiling; JetBrains recommends exactly this for real projects. ([JetBrains](https://intellij-support.jetbrains.com/hc/en-us/articles/15268113529362-Inotify-Watches-Limit-Linux)) Worst-case kernel memory if fully consumed: ~1.3 GB, unswappable. It is only allocated as watches are actually created, so this is a ceiling, not a reservation — but on 32 GB it's worth knowing.
- **`max_user_instances = 8192`** — the default of **128 is the one that bites hardest and gets overlooked.** Each `inotify_init()` consumes one instance. VS Code (multiple), each JetBrains IDE, `watchman`, `chokidar`/nodemon per project, `webpack --watch`, `tsc --watch`, `air`/`cargo-watch`, `dockerd`, `containerd`, `systemd`, `gvfs`, and the desktop indexer all take instances. With a dozen repos open you hit 128 and get `ENOSPC` from `inotify_init` — which most tools report as a confusing generic error.
- **`max_queued_events = 524288`** — default 16384. When the per-instance queue overflows, the kernel emits `IN_Q_OVERFLOW` and **silently drops events**. Symptom: your dev server stops hot-reloading after a `git checkout` or `npm install` touches thousands of files at once. This is the setting people never raise and then blame the bundler for.

### The Ubuntu gotcha: something else lowers your watch limit
Ubuntu's desktop indexer package ships a sysctl drop-in at **`/usr/lib/sysctl.d/30-tracker.conf`** (renamed to `30-localsearch.conf` in newer versions) that sets `fs.inotify.max_user_watches`. There is an open Debian bug — *"tracker-extract unintentionally lowers max_user_watches inotify limit"* — because the package's postinst runs `systemd-sysctl` on its own file unconditionally, clobbering an admin's higher value at install/upgrade time. ([Debian #1107866](https://www.mail-archive.com/debian-bugs-dist@lists.debian.org/msg2042309.html); JetBrains flags the same file by name on Ubuntu 24.04.) *Flag: I could not verify the exact numeric value it sets — widely reported as 65536, treat as unconfirmed.*

Two implications for your script:
1. `sysctl.d` files are applied in **lexical filename order across all directories**, so `99-devbox-inotify.conf` beats `30-tracker.conf` at boot. Use a `99-` prefix.
2. That doesn't protect you from the postinst clobber mid-session. Belt-and-braces: also drop a **same-named** shadow file at `/etc/sysctl.d/30-tracker.conf` (files in `/etc` mask identically-named files in `/usr/lib`) with your values.

Apply: `sudo sysctl --system` (note: `sysctl -p --system` also works; `--system` is the operative flag).

---

## 7. File descriptor and process limits

### `fs.file-max` — you do not need to raise this
It is memory-derived: `max_files = (mempages * (PAGE_SIZE/1024)) / 10`. Verified on an 8 GiB box: 820166, matching the formula. On **32 GiB that's ≈3.3 million**. Nothing you run will approach it. Skip it; scripts that set `fs.file-max=2097152` are cargo-culting and would actually *lower* your limit.

### `fs.nr_open` — the real per-process ceiling
Default **1048576**. This caps what any process's `RLIMIT_NOFILE` hard limit can be set to. If you set `LimitNOFILE=2097152` anywhere without raising `fs.nr_open` first, the unit fails to start. Either keep everything at ≤1048576 (recommended) or raise `fs.nr_open` in the same sysctl file.

### systemd is what actually governs your limits
`DefaultLimitNOFILE=` **defaults to `1024:524288`** (soft 1024, hard 524288). ([systemd-system.conf(5), noble](https://manpages.ubuntu.com/manpages/noble/man5/systemd-system.conf.5.html)) The soft limit of 1024 is the number that breaks Node.

The **critical nuance**: `/etc/systemd/system.conf` configures the *system* service manager (PID 1) and therefore system services (dockerd, containerd, sshd). `/etc/systemd/user.conf` configures the *per-user* service manager (`user@$UID.service`) — which is the parent of your entire graphical session, your terminal, and everything you launch from the desktop on a modern GNOME/COSMIC system. **Setting only `system.conf` leaves your actual interactive dev environment at soft 1024.** These are two independent config trees:

```
/etc/systemd/system.conf, /etc/systemd/system.conf.d/*.conf   -> system services
/etc/systemd/user.conf,   /etc/systemd/user.conf.d/*.conf     -> user@.service manager
~/.config/systemd/user.conf                                    -> per-user override
```

And a third, separate mechanism: **`pam_limits` / `/etc/security/limits.d/`** applies to PAM login sessions (SSH logins, TTY logins). **systemd services do not consult `limits.conf` at all.** You need all three to cover every entry path.

```ini
# /etc/systemd/system.conf.d/90-limits.conf
[Manager]
DefaultLimitNOFILE=1048576:1048576
DefaultLimitNPROC=131072:131072
DefaultLimitMEMLOCK=infinity
DefaultLimitCORE=0
```
```ini
# /etc/systemd/user.conf.d/90-limits.conf
[Manager]
DefaultLimitNOFILE=1048576:1048576
DefaultLimitNPROC=131072:131072
DefaultLimitMEMLOCK=infinity
```
```
# /etc/security/limits.d/90-devbox.conf   (SSH / TTY logins)
*    soft  nofile  1048576
*    hard  nofile  1048576
*    soft  nproc   131072
*    hard  nproc   131072
*    soft  memlock unlimited
*    hard  memlock unlimited
root soft  nofile  1048576
root hard  nofile  1048576
```
(`limits.conf` wildcards do not cover root; list it explicitly.)

Requires reboot (or `systemctl daemon-reexec` + `systemctl --user daemon-reexec` + fresh login) to take effect. Verify from a *new* session:
```bash
ulimit -Sn; ulimit -Hn
cat /proc/self/limits
systemctl show --property=DefaultLimitNOFILE
systemctl --user show --property=DefaultLimitNOFILE
```

**What specifically needs it:**
- **Node**: every `require` holds an fd during resolution; watch mode holds one per watched file in some polling configurations; a monorepo with pnpm workspaces + Jest workers exhausts 1024 trivially. `EMFILE: too many open files` is the signature.
- **Containers**: Docker/containerd ship their own `LimitNOFILE` in their unit files (historically `infinity`, later capped). Container processes inherit the daemon's limit unless overridden — set `default-ulimits` in `/etc/docker/daemon.json` (see §9) rather than relying on inheritance.
- **`DefaultLimitMEMLOCK=infinity`** is the one people forget and it matters for you: `llama.cpp --mlock`, `io_uring` registered buffers, and CUDA pinned host memory all charge against `RLIMIT_MEMLOCK`, whose default is a few MB.
- **`DefaultLimitCORE=0`** ties into §11 — it prevents a 20 GB-RSS inference process from dumping core to disk.

---

## 8. OOM handling

### Status on Ubuntu 24.04
`systemd-oomd` has been enabled by default since **Ubuntu 22.04** and remains so on 24.04. ([Phoronix](https://www.phoronix.com/news/Ubuntu-systemd-oomd-Headaches), [ubuntu-devel thread](https://lists.ubuntu.com/archives/ubuntu-devel/2022-June/042116.html)) *Flag: verify on Pop!_OS specifically with `systemctl is-enabled systemd-oomd` — System76 may not ship it enabled, and I could not confirm.*

### Yes, it kills dev workloads — and zram makes it worse
Ubuntu followed the upstream recommendation of setting **`ManagedOOMSwap=kill` on the root slice (`-.slice`)**, making every descendant cgroup a swap-kill candidate, with `SwapUsedLimit` at its default of **90 %** — while shipping only **1 GB of swap**. The result was Chrome and other apps being killed too frequently, and Canonical's Nick Rosbrook opened a discussion proposing to raise `SwapUsedLimit`, apply `ManagedOOMSwap` selectively, drop swap-kill entirely, or increase default swap. ([ubuntu-devel](https://lists.ubuntu.com/archives/ubuntu-devel/2022-June/042116.html))

**This is the single most important interaction in this whole report:** when you add zram, your swap device fills *quickly and by design* — that's the entire point of high swappiness. systemd-oomd sees "swap 90 % used" and kills your largest cgroup, which will be your build, your container stack, or your llama.cpp process. You will experience this as random unexplained process death under load. Tuning zram without tuning oomd is a trap.

Defaults ([oomd.conf(5), noble](https://manpages.ubuntu.com/manpages/noble/man5/oomd.conf.5.html)):

| Directive | Default | Meaning |
|---|---|---|
| `SwapUsedLimit` | 90% | system swap usage triggering swap-kill |
| `DefaultMemoryPressureLimit` | 60% | per-cgroup PSI memory pressure threshold |
| `DefaultMemoryPressureDurationSec` | 30s | how long pressure must persist |

Config paths: `/etc/systemd/oomd.conf`, `/etc/systemd/oomd.conf.d/*.conf`, `/usr/lib/systemd/oomd.conf.d/*.conf`.

### Option A (recommended): tune it, keep PSI-based protection
```ini
# /etc/systemd/oomd.conf.d/10-devbox.conf
[OOM]
SwapUsedLimit=100%
DefaultMemoryPressureLimit=80%
DefaultMemoryPressureDurationSec=60s
```
`SwapUsedLimit=100%` effectively disables swap-based killing (correct with zram — full zram is normal, not distress), while retaining PSI memory-pressure killing, which is the genuinely useful signal. Raising the pressure limit to 80 % over 60 s stops it firing during the normal thrash of a large parallel build.

Then opt your interactive session out of aggressive management:
```ini
# /etc/systemd/system/user@.service.d/10-oomd-optout.conf
[Service]
ManagedOOMSwap=auto
ManagedOOMMemoryPressure=auto
```
*Flag: Ubuntu's shipped drop-ins are commonly at `/usr/lib/systemd/system/-.slice.d/10-oomd-root-slice-defaults.conf` and `/usr/lib/systemd/system/user@.service.d/10-oomd-user-service-defaults.conf`. I could not verify these exact filenames on 24.04 — have the script enumerate `systemctl show -.slice user@1000.service -p ManagedOOMSwap -p ManagedOOMMemoryPressure -p ManagedOOMMemoryPressureLimit` and `grep -r ManagedOOM /usr/lib/systemd/system/` rather than hardcode paths.*

```bash
systemctl restart systemd-oomd
journalctl -u systemd-oomd -f     # watch what it's actually deciding
oomctl                            # live view of monitored cgroups + pressure
```

### Option B: disable oomd, use earlyoom
```bash
sudo systemctl disable --now systemd-oomd
sudo systemctl mask systemd-oomd     # stop it being pulled back in
sudo apt install earlyoom
```
```ini
# /etc/default/earlyoom
EARLYOOM_ARGS="-r 60 -m 5 -M 3 -s 100 --avoid '(^|/)(systemd|systemd-.*|Xorg|cosmic-comp|cosmic-session|gnome-shell|sshd|dbus-daemon|dockerd|containerd|NetworkManager)$' --prefer '(^|/)(chrome|chromium|firefox|electron|node|Web Content|code|java)$'"
```
earlyoom polls available memory + free swap up to **10× per second**, defaults to SIGTERM at 10 % and SIGKILL at 5 %, and configures via `EARLYOOM_ARGS` in `/etc/default/earlyoom`. ([earlyoom README](https://github.com/rfjakob/earlyoom))

Note the `-s 100`: earlyoom's swap criterion (`-s`) has the same zram pathology as oomd's `SwapUsedLimit` — with zram, free swap legitimately goes to near zero. `-s 100` makes the swap threshold non-binding so kills are driven purely by available RAM (`-m`/`-M`).

**Which to pick:** systemd-oomd's PSI-based approach is technically better (it measures actual stall, not a free-memory proxy) and is cgroup-aware, which matters when you want it to kill *a container* rather than *a random pid*. earlyoom is simpler, more predictable, and its `--prefer`/`--avoid` regexes are more precise than oomd's cgroup policy. For an agentic dev box where you want "kill the browser, never the build," **earlyoom's targeting is the pragmatic win.** Do not run both.

Either way, protect the things you actually care about via cgroup properties, which beats both daemons:
```bash
systemd-run --user --scope -p MemoryHigh=20G -p OOMPolicy=continue -p OOMScoreAdjust=-500 -- llama-server ...
```

---

## 9. Docker / Podman on Ubuntu 24.04

### The AppArmor unprivileged-userns restriction
Ubuntu 24.04 introduced kernel-level restriction of unprivileged user namespaces, gated by the sysctl **`kernel.apparmor_restrict_unprivileged_userns`**. It affects all unconfined, unprivileged programs system-wide. ([Ubuntu 24.04 release notes](https://documentation.ubuntu.com/release-notes/24.04/))

**What breaks:**
- Rootless Docker: `[rootlesskit:parent] error: failed to start the child: fork/exec /proc/self/exe: operation not permitted` ([writeup](https://medium.com/@eodeluga/fixing-rootless-docker-on-ubuntu-24-04-the-complete-guide-dc77cbd61f0d))
- Rootless Podman / `buildah` / `k3d` ([k3d on 24.04](https://stn-dts.github.io/2025/11/19/using-k3d-on-ubuntu-2404-with-rootless-podman.html))
- Chromium/Chrome/Electron sandbox (VS Code, Slack, Discord, Obsidian), AppImages, `bubblewrap`/`bwrap`, Flatpak in some paths — anything constructing its own sandbox.

**Fixes, in order of preference:**

1. **Per-binary AppArmor profile (recommended — keeps the mitigation for everything else):**
```
# /etc/apparmor.d/home.jim.bin.rootlesskit
abi <abi/4.0>,
include <tunables/global>

/home/jim/bin/rootlesskit flags=(unconfined) {
  userns,
  include if exists <local/home.jim.bin.rootlesskit>
}
```
```bash
sudo apparmor_parser -r /etc/apparmor.d/home.jim.bin.rootlesskit
sudo systemctl restart apparmor
```
The same pattern applies to Chrome (`/etc/apparmor.d/chrome` with `flags=(unconfined)` and `userns,`) per the release notes.

2. **System-wide disable (blunt, one boot):**
```bash
echo 0 | sudo tee /proc/sys/kernel/apparmor_restrict_unprivileged_userns
```

3. **System-wide persistent:**
```ini
# /etc/sysctl.d/60-apparmor-namespace.conf
kernel.apparmor_restrict_unprivileged_userns=0
```

Given your stated workload (many containers, agentic tooling, Electron editors), option 3 is defensible on a single-user dev laptop, but it does remove a real container-escape mitigation. Have the script make this an explicit opt-in flag with a printed warning, not a default.

There is a related sysctl `kernel.unprivileged_userns_clone` — that one is **Debian-specific** and is not the Ubuntu 24.04 mechanism. Don't set it blindly.

### cgroup v2
Ubuntu 24.04 is **cgroup v2 unified by default** (since 21.10). Verify with `podman info | grep "cgroup version"` → `v2`, or `stat -fc %T /sys/fs/cgroup` → `cgroup2fs`.

For rootless containers you must **delegate controllers to the user manager** — without this you get no memory/cpu limits in rootless mode:
```ini
# /etc/systemd/system/user@.service.d/delegate.conf
[Service]
Delegate=cpu cpuset io memory pids
```
```bash
sudo systemctl daemon-reload   # then log out and back in
loginctl enable-linger $USER   # so user services survive logout
```
([k3d/Podman on 24.04](https://stn-dts.github.io/2025/11/19/using-k3d-on-ubuntu-2404-with-rootless-podman.html))

For rootless Podman also confirm `/etc/subuid` and `/etc/subgid` have a range for your user (`usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER`), then `podman system migrate`.

### Storage driver
**`overlay2` on ext4.** It is Docker's default on Ubuntu, has "the highest stability," and supports ext4 / xfs(ftype=1) / btrfs as backing. `btrfs` and `zfs` drivers are explicitly "not recommended for common scenarios." ([Docker docs](https://docs.docker.com/engine/storage/drivers/select-storage-driver/))

```json
// /etc/docker/daemon.json
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 1048576, "Soft": 1048576 }
  },
  "default-address-pools": [ { "base": "172.20.0.0/16", "size": 24 } ]
}
```
The **log rotation entry is not optional** for your use case: Docker's default `json-file` driver has *no size limit*, and a chatty agentic container will quietly write tens of GB into `/var/lib/docker/containers/*/`-`*.log` and fill your 1 TB drive. This is the most common self-inflicted disk-full on dev boxes.

`default-address-pools` avoids the classic collision between Docker's default 172.17/172.18 bridges and corporate VPN routes.

Reclaim discipline for sustained use: `docker system df` and `docker buildx prune --filter until=168h` on a timer; `/var/lib/docker` on this workload grows without bound otherwise.

*Optional, verify before enabling:* Docker 25+ supports the containerd image store (`"features": {"containerd-snapshotter": true}`), which gives multi-platform images and better layer sharing — but migrating switches image stores and your existing local images will appear to vanish. Don't put it in an unattended script.

---

## 10. Thermal / sustained-load monitoring

Packages: `lm-sensors nvme-cli smartmontools` (add `s-tui`, `stress-ng`, `powertop` for interactive work; `thermald` on Intel).

```bash
sudo apt install -y lm-sensors nvme-cli smartmontools
sudo sensors-detect --auto
```
([lm-sensors on Ubuntu](https://oneuptime.com/blog/post/2026-03-02-how-to-monitor-system-temperatures-with-lm-sensors-on-ubuntu/view))

### What the script should sample

**CPU / package / ACPI zones**
```bash
sensors -j                                        # structured, best for parsing
for z in /sys/class/thermal/thermal_zone*; do
  printf '%s %s %s\n' "$z" "$(cat $z/type)" "$(( $(cat $z/temp) / 1000 ))"
done                                              # temp is millidegrees C
```
Also enumerate `/sys/class/hwmon/hwmon*/name` + `temp*_input` (also millidegrees), and read `temp*_crit` / `temp*_max` for the *actual* per-sensor thresholds rather than hardcoding numbers.

**CPU throttling counters (Intel)** — these are what tell you throttling actually happened, versus temperature which only tells you it might:
```bash
grep . /sys/devices/system/cpu/cpu0/thermal_throttle/*   # core_throttle_count, package_throttle_count
```
Sample twice with a delay and alert on *delta*, not absolute value.

**Frequency, to catch sustained-load droop:**
```bash
grep MHz /proc/cpuinfo | awk '{s+=$4; n++} END {print s/n}'
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
```

**NVMe**
```bash
sudo nvme smart-log /dev/nvme0 -o json
sudo smartctl -a /dev/nvme0
```
Fields to alert on:
| Field | Why |
|---|---|
| `temperature` | composite temp (nvme-cli prints °C; raw spec is Kelvin) |
| `critical_warning` | bitfield — **bit 1 set = temperature above threshold**, bit 2 = reliability degraded, bit 3 = read-only |
| `warning_temp_time` | cumulative **minutes** above WCTEMP — monotonic; alert on delta |
| `critical_comp_time` | cumulative minutes above CCTEMP — any increase is serious |
| `thm_temp1_trans_count` / `thm_temp1_total_time` | HCTM throttle transitions and time (TMT1); the direct throttling evidence |
| `percentage_used` | endurance consumed (>100 = past rated TBW) |
| `data_units_written` | ×1000×512 bytes; track write amplification from your container churn |
| `media_errors`, `num_err_log_entries` | any nonzero is worth surfacing |

**Read the drive's own thresholds instead of guessing** (values are Kelvin — subtract 273):
```bash
sudo nvme id-ctrl /dev/nvme0 | grep -E 'wctemp|cctemp'   # warning / critical composite temp
sudo nvme get-feature -f 0x10 -H /dev/nvme0              # HCTM: TMT1 / TMT2
```
Typical consumer values are WCTEMP ~70–85 °C and CCTEMP ~80–90 °C; the referenced example used TMT1 = 80 °C, TMT2 = 85 °C. But these vary per drive and the composite temperature "may not necessarily reflect the SSD's surface temperature" since the spec doesn't define the sensor location. ([HAGIWARA on NVMe thermal throttling](https://www.hagisol.com/techblog/?p=635))

Also available via hwmon without root, which is nicer for a background script:
```bash
# find the nvme hwmon: /sys/class/hwmon/hwmon*/name == "nvme"
# temp1_* = Composite, temp2/temp3 = Sensor 1/2
# temp1_crit = CCTEMP, temp1_max = WCTEMP, temp1_alarm
```

**Practical laptop thresholds for alerting:** CPU sustained >95 °C, or `package_throttle_count` rising = thermal-limited (repaste / raise the chassis / reduce `-j`). NVMe >70 °C = approaching throttle on most consumer drives; >WCTEMP-5 = warn; any `warning_temp_time` delta = the drive is already derating. A PCIe 4.0 drive under a laptop keyboard doing sustained container builds *will* hit this.

### Governor / power profile — relevant to sustained load
Ubuntu 24.04 shipped power-efficiency changes that bias laptops toward `powersave` / `balance_power` EPP. For sustained builds and inference this leaves performance on the table. ([OMG!Ubuntu on 24.04 power efficiency](https://www.omgubuntu.co.uk/2024/04/ubuntu-24-04-battery-life-improvements))
```bash
# Ubuntu:
powerprofilesctl list; powerprofilesctl set performance
# Pop!_OS ships system76-power, which conflicts with power-profiles-daemon:
system76-power profile performance
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
```
*Flag: on Pop!_OS, determine which daemon is actually active (`systemctl is-active power-profiles-daemon system76-power`) before driving either — running both produces contradictory EPP writes.*

---

## 11. Ubuntu 24.04 defaults that actively hurt sustained dev work

| # | Default | Impact | Fix |
|---|---|---|---|
| 1 | **`apport`** enabled | On a crash of a 20 GB-RSS inference process it writes a multi-GB core into `/var/crash`, stalling I/O and eating disk at the worst moment | `/etc/default/apport` → `enabled=0`; `sudo systemctl disable --now apport.service`; plus `DefaultLimitCORE=0` (§7) and `Storage=none` in `/etc/systemd/coredump.conf` if `systemd-coredump` is installed |
| 2 | **`unattended-upgrades`** | `apt-daily.timer` / `apt-daily-upgrade.timer` grab the dpkg lock and burn CPU/IO mid-build; can restart Docker under you | Set `APT::Periodic::Update-Package-Lists "0";` and `APT::Periodic::Unattended-Upgrade "0";` in `/etc/apt/apt.conf.d/20auto-upgrades`. **Better than disabling:** keep security updates but reschedule — `systemctl edit apt-daily-upgrade.timer` with `OnCalendar=` (clear) then `OnCalendar=04:00` and `RandomizedDelaySec=30m`. Behavior options live in `/etc/apt/apt.conf.d/50unattended-upgrades`; logs in `/var/log/unattended-upgrades/`. ([Ubuntu docs](https://ubuntu.com/server/docs/how-to/software/automatic-updates/)) |
| 3 | **`tracker-miners` / `localsearch`** (GNOME indexer) | Indexes `$HOME` including every repo, `node_modules`, `.venv`, model checkpoints, and container volumes. Documented 100 %-CPU-for-hours bugs. Also ships the sysctl file that lowers your inotify watches (§6) | `gsettings set org.freedesktop.Tracker3.Miner.Files index-recursive-directories "[]"` and `index-single-directories "[]"`; drop `.trackerignore` files into repo roots; or `systemctl --user mask tracker-miner-fs-3.service tracker-extract-3.service localsearch-3.service`. Reset a runaway index with `tracker3 reset --filesystem`. ([Launchpad #2025523](https://bugs.launchpad.net/bugs/2025523), [localsearch reset](https://neilzone.co.uk/2025/08/fixing-high-cpu-usage-of-localsearch-3-by-resetting-it/)) |
| 4 | **`systemd-oomd`** with `SwapUsedLimit=90%` | Kills your build/containers as soon as zram fills. See §8 — **this is the biggest one** | §8 |
| 5 | **AppArmor userns restriction** | Breaks rootless Docker/Podman, Electron/Chromium sandboxes, AppImages, bwrap | §9 |
| 6 | **`snapd`** (Ubuntu proper only) | Background `snapd.refresh` can restart your editor/browser mid-session and does periodic disk churn; each snap mounts a squashfs loop device | `sudo snap refresh --hold`, or `--hold=forever` per snap. **N/A on Pop!_OS — it ships Flatpak/Flathub, not snapd** ([OMG!Ubuntu](https://www.omgubuntu.co.uk/2025/12/pop_os-24-04-lts-stable-release)) |
| 7 | **`systemd-journald`** unbounded | Chatty containers fill the journal; journal writes are `fsync`-heavy | `/etc/systemd/journald.conf`: `SystemMaxUse=1G`, `SystemMaxFileSize=128M`, `Compress=yes` |
| 8 | **Power profile `balanced`** | Sustained builds/inference run at reduced EPP | §10 |
| 9 | **`/tmp` on disk** (24.04; changed in 24.10) | Build scratch hits the SSD | `sudo systemctl enable --now tmp.mount` — audit first, some toolchains write multi-GB there |
| 10 | **`motd-news`** | Network fetch on every login/SSH | `/etc/default/motd-news` → `ENABLED=0` |
| 11 | **Docker `json-file` logs unbounded** | Silent disk-fill | §9 `daemon.json` |
| 12 | **`fwupd-refresh.timer`, `gnome-software` auto-download** | Minor periodic IO/CPU | Reschedule or mask if you want a quiet machine |

---

## Consolidated file manifest for your script

```
/etc/systemd/zram-generator.conf                        §1
/etc/sysctl.d/99-devbox-vm.conf                         §2
/etc/sysctl.d/99-devbox-inotify.conf                    §6
/etc/sysctl.d/30-tracker.conf          (shadow)         §6
/etc/sysctl.d/60-apparmor-namespace.conf (opt-in)       §9
/etc/udev/rules.d/60-ioschedulers.rules                 §4
/etc/udev/rules.d/62-readahead.rules   (optional)       §4
/etc/systemd/system.conf.d/90-limits.conf               §7
/etc/systemd/user.conf.d/90-limits.conf                 §7
/etc/security/limits.d/90-devbox.conf                   §7
/etc/systemd/oomd.conf.d/10-devbox.conf                 §8
/etc/systemd/system/user@.service.d/10-oomd-optout.conf §8
/etc/systemd/system/user@.service.d/delegate.conf       §9
/etc/apparmor.d/<per-binary profiles>                   §9
/etc/docker/daemon.json                                 §9
/etc/default/earlyoom                    (if option B)  §8
/etc/default/apport                                     §11
/etc/apt/apt.conf.d/20auto-upgrades                     §11
/etc/systemd/journald.conf                              §11
/etc/fstab                                              §5
kernelstub -a "..."   (NOT grub on Pop!_OS)             §1,§4
```

Apply order: write sysctl files → `sysctl --system`; write udev rules → `udevadm control --reload && udevadm trigger`; write systemd drop-ins → `systemctl daemon-reload` (+ reboot for limits); apparmor → `apparmor_parser -r` + `systemctl restart apparmor`; kernel params → `kernelstub` + reboot.

---

## Things I could not verify — have the script detect, not assume

1. **Pop!_OS 24.04 specifics**: whether `systemd-oomd` is enabled, whether `apport` is installed, whether the THP default is `madvise`, and whether the shipped kernel (6.17) enables lockdown under Secure Boot (which would block hibernation). All are runtime-detectable.
2. **`systemd-zram-generator` version/pocket in noble** — Launchpad blocked scraping. `apt-cache policy systemd-zram-generator` before installing; fall back to a manual `zram0` systemd unit if absent.
3. **The exact value `30-tracker.conf` / `30-localsearch.conf` sets for `fs.inotify.max_user_watches`** — widely reported as 65536; I confirmed the file exists and the clobbering behavior ([Debian #1107866](https://www.mail-archive.com/debian-bugs-dist@lists.debian.org/msg2042309.html)) but not the number. Read it at runtime.
4. **Ubuntu's oomd drop-in filenames** (`10-oomd-root-slice-defaults.conf` etc.) — enumerate with `grep -r ManagedOOM /usr/lib/systemd/system/` instead.
5. **`ATTR{queue/read_ahead_kb}` vs `ATTR{bdi/read_ahead_kb}`** in udev — test-write both.
6. **`nr_requests=8` for NVMe** — one source recommends it; I consider it likely wrong for parallel build I/O and would not ship it.
7. **Whether llama.cpp calls `madvise(MADV_HUGEPAGE)`** — this determines whether THP `madvise` mode actually gives it huge pages. Check with `grep AnonHugePages /proc/<pid>/smaps_rollup` while it runs.
8. **`INOTIFY_WATCH_COST` exact constant** — I derived ~1300 bytes/watch empirically from a running 6.18 kernel rather than reading the constant.
9. **Ubuntu 24.04 zswap default-on state** — Kconfig-dependent; read `/sys/module/zswap/parameters/enabled`.
10. **MGLRU state** — kernel 6.1+ has it, distros vary on `lru_gen/enabled`; it changes reclaim behavior meaningfully with zram. Read `/sys/kernel/mm/lru_gen/enabled`.
11. **Pop!_OS 22.04 vs 24.04 branch** — if the machine is actually on Pop!_OS 22.04 (still widely deployed), it is Ubuntu 22.04-based with different defaults (no AppArmor userns restriction, `vm.max_map_count=65530`). Gate on `. /etc/os-release; echo $VERSION_ID`.

---

## Sources

- [Documentation for /proc/sys/vm/ — kernel.org](https://docs.kernel.org/admin-guide/sysctl/vm.html)
- [Transparent Hugepage Support — kernel.org](https://docs.kernel.org/admin-guide/mm/transhuge.html)
- [zram: Compressed RAM-based block devices — kernel.org](https://docs.kernel.org/admin-guide/blockdev/zram.html)
- [zswap — kernel.org](https://docs.kernel.org/admin-guide/mm/zswap.html)
- [fs/notify/inotify/inotify_user.c — torvalds/linux](https://raw.githubusercontent.com/torvalds/linux/master/fs/notify/inotify/inotify_user.c)
- [systemd/zram-generator — GitHub](https://github.com/systemd/zram-generator)
- [zram-generator.conf(5) — Ubuntu noble manpages](https://manpages.ubuntu.com/manpages/noble/man5/zram-generator.conf.5.html)
- [zram-generator.conf(5) — Arch manpages](https://man.archlinux.org/man/zram-generator.conf.5)
- [systemd-system.conf(5) — Ubuntu manpages](https://manpages.ubuntu.com/manpages/noble/man5/systemd-system.conf.5.html)
- [oomd.conf(5) — Ubuntu noble manpages](https://manpages.ubuntu.com/manpages/noble/man5/oomd.conf.5.html)
- [Ubuntu 24.04 LTS release notes](https://documentation.ubuntu.com/release-notes/24.04/)
- [Automatic updates — Ubuntu Server documentation](https://ubuntu.com/server/docs/how-to/software/automatic-updates/)
- [systemd-oomd issues on desktop — ubuntu-devel mailing list](https://lists.ubuntu.com/archives/ubuntu-devel/2022-June/042116.html)
- [Ubuntu Deciding How To Tame Their systemd-oomd Killing Experience — Phoronix](https://www.phoronix.com/news/Ubuntu-systemd-oomd-Headaches)
- [What Is Systemd-Oomd? How to Disable It? — CJ Jackson](https://www.cjjackson.dev/posts/what-is-systemd-oomd-how-to-disable-it/)
- [rfjakob/earlyoom — GitHub](https://github.com/rfjakob/earlyoom)
- [Linux 5.6 I/O Scheduler Benchmarks: None, Kyber, BFQ, MQ-Deadline — Phoronix](https://www.phoronix.com/review/linux-56-nvme)
- [Transparent Hugepage Performance On Linux 6.18 LTS: Madvise vs. Always — Phoronix](https://www.phoronix.com/review/thp-madvise-always)
- [A week into linux storage performances, Day 2 — Timote Brusson](https://blog.timotebrusson.fr/2025/06/17/A-week-into-linux-storage-performances-Day-2-Device-optimization-and-scheduler/)
- [Configuring TRIM — Rocky Linux documentation](https://docs.rockylinux.org/10/guides/filesystems/configuring_trim/)
- [Select a storage driver — Docker Docs](https://docs.docker.com/engine/storage/drivers/select-storage-driver/)
- [Fixing NVMe SSD Problems on Linux — mbaraa](https://mbaraa.com/blog/fixing-nvme-ssd-problems-on-linux)
- ["controller is down; will reset" on SK Hynix NVMe — LKML](https://lkml.iu.edu/hypermail/linux/kernel/2511.2/07277.html)
- [nvme-pci: Avoid the deepest sleep state on Western Digital SSD — LKML](https://lkml.iu.edu/hypermail/linux/kernel/2501.2/02341.html)
- [How NVMe SSD thermal throttling works — HAGIWARA Solutions](https://www.hagisol.com/techblog/?p=635)
- [How to Monitor System Temperatures with lm-sensors on Ubuntu — OneUptime](https://oneuptime.com/blog/post/2026-03-02-how-to-monitor-system-temperatures-with-lm-sensors-on-ubuntu/view)
- [How to Configure Readahead Settings for Disk Performance on Ubuntu — OneUptime](https://oneuptime.com/blog/post/2026-03-02-how-to-configure-readahead-settings-for-disk-performance-on-ubuntu/view)
- [Tuning the memory management subsystem — SUSE SLES 15 SP7](https://documentation.suse.com/sles/15-SP7/html/SLES-all/cha-tuning-memory.html)
- [Zram, zswap and Linux Swap: A Practical Configuration Guide — Enrico Pesce](https://www.enricopesce.it/zram-zswap-linux-swap-configuration/)
- [Zram Compression Debate: Is zstd Worth the Performance Hit? — BigGo](https://biggo.com/news/202510241923_zram-compression-debate-zstd-performance)
- [Inotify Watches Limit (Linux) — JetBrains](https://intellij-support.jetbrains.com/hc/en-us/articles/15268113529362-Inotify-Watches-Limit-Linux)
- [Bug#1107866: tracker-extract unintentionally lowers max_user_watches inotify limit — Debian](https://www.mail-archive.com/debian-bugs-dist@lists.debian.org/msg2042309.html)
- [Increasing the default vm.max_map_count value — Arch Linux News](https://archlinux.org/news/increasing-the-default-vmmax_map_count-value/)
- [Changes/IncreaseVmMaxMapCount — Fedora Project Wiki](https://fedoraproject.org/wiki/Changes/IncreaseVmMaxMapCount)
- [Ubuntu 24.04 increases vm.max_map_count for smoother Linux gaming — GamingOnLinux](https://www.gamingonlinux.com/2024/03/ubuntu-2404-increases-vm-max-map-count-for-smoother-linux-gaming/)
- [Fixing Rootless Docker on Ubuntu 24.04 — Eugene Odeluga](https://medium.com/@eodeluga/fixing-rootless-docker-on-ubuntu-24-04-the-complete-guide-dc77cbd61f0d)
- [Using k3d on Ubuntu 24.04 with rootless Podman — Digital Technology Solutions](https://stn-dts.github.io/2025/11/19/using-k3d-on-ubuntu-2404-with-rootless-podman.html)
- [Kernelstub Usage — System76 Support](https://system76.com/support/articles/kernelstub/)
- [Pop!_OS 24.04 LTS Released with New COSMIC Desktop — OMG! Ubuntu](https://www.omgubuntu.co.uk/2025/12/pop_os-24-04-lts-stable-release)
- [Ubuntu 24.04 Improves Power Efficiency on Laptops — OMG! Ubuntu](https://www.omgubuntu.co.uk/2024/04/ubuntu-24-04-battery-life-improvements)
- [Suspend and hibernate — Gentoo Wiki](https://wiki.gentoo.org/wiki/Suspend_and_hibernate)
- [ext4: add lazytime mount option — LWN.net](https://lwn.net/Articles/620086/)
- [Bug #2025523 "tracker3 taking 100% CPU for a long time" — Launchpad](https://bugs.launchpad.net/bugs/2025523)
- [Fixing high CPU usage of localsearch-3 by resetting it — Neil Brown](https://neilzone.co.uk/2025/08/fixing-high-cpu-usage-of-localsearch-3-by-resetting-it/)agentId: ae1b3120be9d4a6a6 (use SendMessage with to: 'ae1b3120be9d4a6a6', summary: '<5-10 word recap>' to continue this agent)
<usage>subagent_tokens: 141388
tool_uses: 94
duration_ms: 1381406</usage>