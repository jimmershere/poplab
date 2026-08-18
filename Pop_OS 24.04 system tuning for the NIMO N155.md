# poplab — Session 01: Pop!_OS 24.04 system tuning for the NIMO N155

**Date:** 2026-08-18
**Workspace:** `/app/poplab` (session container) — delivered as `poplab.tar.gz` + `poplab.bundle`
**Target repo:** `github.com/jimmershere/poplab` (private) — **not yet pushed**, see Blockers

## What was built

A read-only-by-default tuning harness for the NIMO N155 (Ryzen 7 6800H "Rembrandt",
Radeon 680M / gfx1035, 32 GB DDR5-5600, 1 TB PCIe 4.0 NVMe) on Pop!_OS 24.04 LTS.

```
bin/poplab             audit | plan | apply | verify | soak | rollback | runs
lib/common.sh          dry-run engine, backup/manifest, idempotent writes, hw detection
scripts/00-audit.sh    read-only scored audit across 8 dimensions
scripts/10..95         tuning modules (kernel cmdline, cpu/power, memory/zram, storage,
                       limits/inotify, oom, gpu/ai, media, hygiene, aggressive thermals)
scripts/98-soak.sh     sustained-load test with clock/thermal sampling
scripts/99-verify.sh   post-apply assertions, non-zero exit on drift
local81/playbooks/     audit / apply / soak orchestration
.github/workflows/ci.yml  shellcheck + smoke + real apply/idempotency/rollback + docs consistency
docs/research/01..03   sourced research behind every knob
```

Safety model: dry-run default, unified-diff preview, timestamped backups with a TSV
manifest under `/var/lib/poplab/backups/<run-id>`, byte-for-byte idempotency,
`--aggressive` gate on RyzenAdj and the userns opt-out. Verified in-container:
audit, plan, apply, idempotent re-apply, and rollback all pass; shellcheck clean.

## Key platform findings (encoded in the scripts)

1. **Pop!_OS UEFI = systemd-boot + `kernelstub`.** `update-grub` is a no-op. Every
   generic Ubuntu tuning guide silently fails to change the kernel cmdline here.
2. **systemd-oomd + zram is a trap.** Default `SwapUsedLimit=90%` reads a full zram
   device as distress and kills the largest cgroup — your build, containers, or
   `llama-server`. Module 60 sets it to 100% and keeps PSI-pressure killing.
3. **`vm.swappiness=10` is now wrong** with zram; kernel docs sanction >100 for
   in-memory swap. poplab uses 150 with `page-cluster=0`.
4. **`fs.inotify.max_user_instances` (default 128)** bites harder than
   `max_user_watches`, and the desktop indexer package re-lowers the watch limit on
   every upgrade — module 50 shadows its sysctl file.
5. **ROCm on the 680M is not the obvious win.** gfx1035 was never an official ROCm
   target; ROCm allocates from the BIOS UMA carve-out, not GTT; decode is DDR5
   bandwidth-bound. Vulkan is usually the better llama.cpp backend. `poplab-bench-llm`
   measures CPU vs Vulkan vs ROCm rather than guessing.
6. **VCN 3.1 decodes AV1 but cannot encode it.** `poplab-encode` falls back to
   libsvtav1 on CPU for AV1 delivery.
7. **system76-scheduler's CFS-latency half is dead** on EEVDF kernels (≥6.6); the
   process-priority half still works and is worth configuring.

## Blockers / next session

- **GitHub push is blocked.** This session's token is repo-scoped and
  `github.com/jimmershere/poplab` is not attached to it; the API returns 403 with
  "use add_repo to request access", and no `add_repo` tool is exposed. Either attach
  the repo to a future Claude Code session, or push manually from the laptop:
  ```
  gh repo create jimmershere/poplab --private --source=. --push
  ```
  The full history is in `poplab.bundle` (`git clone poplab.bundle poplab`).
- **CI has not run** — the workflow is written but unexercised until the repo exists.
- **Not yet verified on real hardware.** Everything was exercised in a non-AMD,
  non-systemd container. First run on the N155 should be `audit` → `plan` → read the
  diffs → `apply` → reboot → `verify` → `soak 900`.
- **Firmware task for Jim:** check whether the NIMO BIOS exposes UMA_SPECIFIED for the
  iGPU frame buffer. That single setting decides whether ROCm/HIP is usable at all.
- **Open upstream issue:** COSMIC + AMD suspend/resume is broken (cosmic-comp #2444,
  #2191, #2495). Disable automatic suspend until fixed.Pop!_OS 24.04 system tuning for the NIMO N155