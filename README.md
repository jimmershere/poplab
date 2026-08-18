# poplab — Pop!_OS 24.04 LTS tuning harness for the NIMO N155

Audit, tune and verify a **NIMO N155** (AMD Ryzen 7 6800H "Rembrandt", Radeon 680M
iGPU, 32 GB DDR5-5600, 1 TB PCIe 4.0 NVMe) running **Pop!_OS 24.04 LTS** for
sustained AI/agentic development, containers, and audio/video work.

Nothing here is a copy-pasted tuning listicle. Every knob traces to a source in
[`docs/research/`](docs/research/), and everything the research could *not* verify
is detected at runtime rather than assumed.

## Quick start

```bash
git clone https://github.com/jimmershere/poplab.git ~/poplab && cd ~/poplab

./bin/poplab audit          # read-only. Scores the machine across 8 dimensions.
./bin/poplab plan           # shows every file it would write, with diffs. No writes.
sudo ./bin/poplab apply     # commits. Backs up everything it touches first.
./bin/poplab verify         # asserts the changes stuck. Exits non-zero if not.
sudo reboot                 # kernel cmdline + ulimits need it
./bin/poplab verify
```

Undo:

```bash
./bin/poplab runs                       # list previous apply runs
sudo ./bin/poplab rollback <run-id>     # restore every file from that run
```

## Safety model

| Guarantee | How |
|---|---|
| Default is read-only | `apply` is the only mutating verb; everything else pins `POPLAB_APPLY=0` |
| Every change is previewable | `plan` prints a unified diff against the current file |
| Every change is reversible | timestamped backups + a TSV manifest under `/var/lib/poplab/backups/<run-id>/` |
| Running twice is a no-op | byte-for-byte content comparison before any write |
| One failure doesn't abort the rest | `run` reports and continues; failures surface in the summary |
| Risky changes are opt-in | `--aggressive` gates RyzenAdj SMU writes and the userns opt-out |

Two things poplab deliberately **will not** do automatically, because a bad edit
costs you a boot or a security property: rewrite `/etc/fstab`, and disable the
Ubuntu 24.04 unprivileged-user-namespace restriction. It tells you exactly what to
change and why, and leaves the decision with you.

## Modules

| # | Module | What it does |
|---|---|---|
| 00 | `00-audit.sh` | Read-only scored inspection across platform, cpu, memory, storage, limits, oom, gpu, media, hygiene |
| 10 | `10-kernel-params.sh` | `amd_pstate=active`, `zswap.enabled=0`, `ttm.pages_limit`, conditional NVMe APST cap — **via `kernelstub`, not GRUB** |
| 20 | `20-cpu-power.sh` | Enforces one power daemon; EPP persisted across boot, resume and AC/battery; system76-scheduler priority rules |
| 30 | `30-memory-swap.sh` | zram sizing, `swappiness=150`, `page-cluster=0`, byte-valued writeback limits, watermark tuning, THP |
| 40 | `40-storage-io.sh` | NVMe `scheduler=none` udev rule, `fstrim.timer` (not inline discard), tmpfs `/tmp`, SMART tooling |
| 50 | `50-limits-inotify.sh` | inotify watches/**instances**/queue, NOFILE + MEMLOCK across all *three* limit mechanisms, cgroup delegation |
| 60 | `60-oom-guard.sh` | Stops systemd-oomd from killing your build when zram fills. Optional earlyoom strategy. `poplab-run` protected scopes |
| 70 | `70-gpu-ai.sh` | render/video groups, VRAM-vs-GTT reality check, `HSA_OVERRIDE_GFX_VERSION`, ollama drop-in, `poplab-bench-llm` |
| 80 | `80-media-stack.sh` | VAAPI probe + `poplab-encode` (H.264/HEVC hardware, AV1 falls back to CPU — VCN 3.1 cannot encode AV1) |
| 90 | `90-hygiene.sh` | apport, coredumps, apt timers rescheduled to 04:00, indexer, journald bounds, docker log rotation, userns guidance |
| 95 | `95-thermal-power-limits.sh` | **`--aggressive` only.** RyzenAdj power limits on a timer, fan-control triage |
| 98 | `98-soak.sh` | Sustained-load soak with clock/thermal/NVMe sampling |
| 99 | `99-verify.sh` | Post-apply assertions; non-zero exit on drift |

Run a subset: `sudo ./bin/poplab apply --only 30,50,60`

## The five findings that matter most

1. **`update-grub` does nothing on this machine.** Pop!_OS UEFI installs use
   systemd-boot driven by `kernelstub`. Every generic Ubuntu tuning guide that tells
   you to edit `/etc/default/grub` silently no-ops here.

2. **systemd-oomd + zram is a trap.** oomd ships `SwapUsedLimit=90%`. A full zram
   device is *normal operation* — it's the entire point of high swappiness — but oomd
   reads it as distress and kills your largest cgroup: your build, your containers, or
   `llama-server`. You experience it as random unexplained process death under load.
   Module 60 sets `SwapUsedLimit=100%` and keeps the PSI-pressure signal, which is the
   genuinely useful one.

3. **`vm.swappiness=10` is now wrong.** With zram a swap-in is a memcpy plus a zstd
   decompress — cheaper than re-reading a header from NVMe. Low swappiness makes the
   kernel throw away your build's page cache instead of compressing an idle Electron
   heap. The kernel docs sanction values above 100 for in-memory swap; poplab uses 150.

4. **`fs.inotify.max_user_instances` (default 128) bites harder than
   `max_user_watches`.** Every VS Code window, JetBrains IDE, `tsc --watch`, nodemon,
   watchman and dockerd consumes one. `ENOSPC` from `inotify_init()` surfaces as a
   confusing generic error in most tools. And the desktop indexer package ships a
   sysctl drop-in that re-lowers your watch limit on every package upgrade — module 50
   shadows it.

5. **ROCm on the 680M is not the obvious win.** gfx1035 has never been an official
   ROCm target, and ROCm/HSA allocates from the BIOS UMA carve-out, *not* GTT. Token
   generation is bound by the same DDR5 bandwidth the CPU uses, so decode is often a
   wash against 8 CPU threads. Prefill genuinely favours the GPU. Vulkan (which *can*
   use GTT) is usually the better backend. `poplab-bench-llm` measures all three
   instead of guessing.

## Installed helpers

| Command | Purpose |
|---|---|
| `poplab-run --mem 20G -- llama-server …` | Launch a workload in a protected cgroup scope (MemoryHigh, OOMScoreAdjust=-500) |
| `poplab-bench-llm model.gguf` | Compare CPU vs Vulkan vs ROCm llama.cpp backends |
| `poplab-encode in.mov out.mp4` | Hardware H.264/HEVC transcode; AV1 falls back to CPU libsvtav1 |
| `poplab-cpu-profile` | Re-applies EPP on boot, resume, and AC/battery change |
| `poplab-power-limits` | (aggressive) Re-asserts SMU limits the firmware keeps resetting |

## Things poplab can't do for you

- **Set the BIOS UMA frame-buffer size.** If you want ROCm/HIP to have real memory,
  reboot into firmware, switch the iGPU memory setting from AUTO to UMA_SPECIFIED and
  give it 4–8 GB. On NIMO/Tongfang-class boards this is usually under
  Advanced → AMD CBS → NBIO, or Chipset.
- **Give you a fan curve.** amdgpu exposes no fan on an APU; the fans are on the
  embedded controller. If no `nbfc-linux` config matches the chassis, the only lever
  is producing less heat.
- **Make suspend/resume reliable on COSMIC + AMD.** There are open upstream bugs
  (cosmic-comp #2444, #2191, #2495). Disabling automatic suspend is the current
  workaround.

## Research

- [`docs/research/01-pop-os-24.04.md`](docs/research/01-pop-os-24.04.md) — release, kernelstub, system76-power/scheduler, apt layout, zram defaults, known COSMIC+AMD bugs
- [`docs/research/02-ryzen-6800h-radeon-680m.md`](docs/research/02-ryzen-6800h-radeon-680m.md) — amd_pstate/EPP, RyzenAdj on Rembrandt, gfx1035 ROCm status, GTT vs VRAM, VCN 3.1 codecs
- [`docs/research/03-memory-io-dev.md`](docs/research/03-memory-io-dev.md) — zram vs zswap, VM sysctls, NVMe scheduler and APST, ext4 vs btrfs, inotify, ulimits, oomd, Docker on 24.04

## Hardware reference

| | |
|---|---|
| CPU | AMD Ryzen 7 6800H — 8C/16T Zen3+, up to 4.7 GHz, 45 W nominal |
| GPU | Radeon 680M (RDNA2, gfx1035, 12 CU, up to 2200 MHz), VCN 3.1 |
| RAM | 2× DDR5-5600 SODIMM (32 GB as configured; board takes 64 GB) |
| Storage | 2× M.2 PCIe 4.0 NVMe slots (1 TB as configured) |
| Display | 15.6" FHD IPS 60 Hz |
| Power | 58 Wh battery, 100 W USB-C PD |

Source: [nimopc.com N155 product page](https://www.nimopc.com/products/nimo-15-6-n155-r7-6800h-fhd-laptop-2)

## License

MIT.
