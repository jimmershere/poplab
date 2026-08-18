#!/usr/bin/env bash
# 00-audit.sh — READ-ONLY. Inspect the machine and score it across 8 dimensions.
# Never writes outside $POPLAB_REPORT_DIR. Safe to run as a normal user
# (a few probes need root and will be reported as "skipped: needs root").

# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
POPLAB_APPLY=0   # hard-pinned: the audit never mutates.
export POPLAB_APPLY

declare -A DIM_SCORE DIM_MAX
CUR_DIM="general"

dim() { CUR_DIM="$1"; DIM_SCORE["$1"]="${DIM_SCORE[$1]:-0}"; DIM_MAX["$1"]="${DIM_MAX[$1]:-0}"; head2 "$2"; }
pass() { DIM_SCORE[$CUR_DIM]=$(( ${DIM_SCORE[$CUR_DIM]} + 1 )); DIM_MAX[$CUR_DIM]=$(( ${DIM_MAX[$CUR_DIM]} + 1 )); check_ok "$*"; }
soft() { DIM_MAX[$CUR_DIM]=$(( ${DIM_MAX[$CUR_DIM]} + 1 )); check_warn "$*"; }
hard() { DIM_MAX[$CUR_DIM]=$(( ${DIM_MAX[$CUR_DIM]} + 1 )); check_fail "$*"; }
note() { info "$*"; }

# --------------------------------------------------------------- 0. platform --
audit_platform() {
  dim platform "0. Platform identity"
  note "OS          : $OS_NAME (id=$OS_ID version=$OS_VERSION_ID codename=$OS_CODENAME)"
  note "Kernel      : $HW_KERNEL  ($HW_ARCH)"
  note "CPU         : $HW_CPU_MODEL  (${HW_CPU_CORES} logical)"
  note "Memory      : ${HW_MEM_GB} GiB"
  note "GPU         : ${GPU_LINE:-none detected}"
  note "Boot        : $BOOT_MODE via ${BOOT_TOOL}"
  note "Root fs     : $ROOT_SRC ($ROOT_FSTYPE) on disk ${ROOT_DISK:-?}"

  if [[ "$IS_POP" == "1" ]]; then
    pass "running Pop!_OS — System76 tooling paths apply"
  else
    soft "not Pop!_OS (id=$OS_ID) — kernelstub/system76-* modules will self-skip"
  fi

  if [[ "$IS_AMD" == "1" ]]; then
    pass "AMD CPU detected — amd_pstate / amdgpu tuning is in scope"
  else
    soft "non-AMD CPU — the CPU/GPU modules will mostly no-op"
  fi

  case "$BOOT_TOOL" in
    kernelstub) pass "kernelstub present — kernel cmdline changes are scriptable" ;;
    grub)       pass "GRUB present — kernel cmdline changes are scriptable" ;;
    *)          hard "no kernelstub and no update-grub: kernel params must be set manually" ;;
  esac

  if [[ "$HW_MEM_GB" -ge 30 ]]; then pass "memory ${HW_MEM_GB} GiB — dual-channel target met"
  else soft "memory reads ${HW_MEM_GB} GiB — expected ~31 on a 32 GB machine; check both SODIMMs are populated (dual channel doubles bandwidth, which is what LLM decode is bound by)"; fi

  # Dual-channel check: two populated DIMM slots.
  if require_cmd dmidecode && [[ "$(id -u)" -eq 0 ]]; then
    local pop; pop="$(dmidecode -t memory 2>/dev/null | grep -c 'Size: [0-9]' || echo 0)"
    if [[ "$pop" -ge 2 ]]; then pass "$pop populated memory slots (dual-channel)"
    else soft "only $pop populated memory slot(s) — single channel halves memory bandwidth"; fi
  else
    note "dual-channel check skipped (needs root + dmidecode)"
  fi
  return 0
}

# ------------------------------------------------------------- 1. cpu/power --
audit_cpu() {
  dim cpu "1. CPU scaling & power"
  note "scaling_driver=$SCALING_DRIVER governor=$SCALING_GOV amd_pstate.status=$PSTATE_STATUS epp=$EPP_NOW"

  case "$PSTATE_STATUS" in
    active) pass "amd_pstate in 'active' mode (EPP-driven, firmware ramping)" ;;
    guided) pass "amd_pstate in 'guided' mode (OS bounds, firmware picks)" ;;
    passive) soft "amd_pstate 'passive' — governor-driven; fine, but EPP is unavailable" ;;
    disable|n/a) hard "amd_pstate not active — falling back to acpi-cpufreq costs sustained clocks" ;;
    *) soft "amd_pstate status unrecognised: $PSTATE_STATUS" ;;
  esac

  case "$EPP_NOW" in
    performance|balance_performance) pass "EPP=$EPP_NOW — good for sustained build/inference on AC" ;;
    balance_power|power) soft "EPP=$EPP_NOW — biased to efficiency; leaves throughput on the table when plugged in" ;;
    n/a) note "EPP not exposed (expected outside amd_pstate active mode)" ;;
    *) note "EPP=$EPP_NOW" ;;
  esac

  local boost="/sys/devices/system/cpu/cpufreq/boost"
  if [[ -r "$boost" ]]; then
    [[ "$(cat "$boost")" == "1" ]] && pass "core performance boost enabled" || soft "core performance boost is OFF"
  else
    note "no global boost knob (per-policy boost lives at /sys/devices/system/cpu/cpufreq/policy*/boost on kernel >= 6.11)"
  fi

  # Power daemon sanity: system76-power and power-profiles-daemon must not both run.
  local s76=0 ppd=0 tlp=0
  unit_active com.system76.PowerDaemon.service && s76=1
  unit_active power-profiles-daemon.service && ppd=1
  unit_active tlp.service && tlp=1
  if (( s76 + ppd + tlp > 1 )); then
    hard "multiple power daemons active (system76-power=$s76 ppd=$ppd tlp=$tlp) — they fight over EPP and platform_profile"
  elif (( s76 == 1 )); then
    pass "system76-power is the single power daemon"
    require_cmd system76-power && note "current profile: $(system76-power profile 2>/dev/null | tail -n1)"
  elif (( ppd == 1 )); then
    pass "power-profiles-daemon is the single power daemon"
    require_cmd powerprofilesctl && note "current profile: $(powerprofilesctl get 2>/dev/null)"
  else
    soft "no power daemon active — profiles will not follow AC/battery transitions"
  fi

  # system76-scheduler: useful half (process priorities) still works on EEVDF kernels.
  if unit_active com.system76.Scheduler.service; then
    pass "system76-scheduler running (deprioritises apt/dpkg/build processes)"
    [[ -f /etc/system76-scheduler/process-scheduler/99-poplab.kdl ]] \
      && pass "poplab process-priority rules installed" \
      || soft "no poplab scheduler rules — compilers/test runners are not deprioritised vs the UI"
  elif [[ "$IS_POP" == "1" ]]; then
    soft "system76-scheduler not running — desktop responsiveness under -j16 builds will suffer"
  fi

  # Thermals
  if require_cmd sensors; then
    local tctl; tctl="$(sensors 2>/dev/null | awk '/Tctl/{gsub(/[+°C]/,"",$2); print $2; exit}')"
    [[ -n "$tctl" ]] && note "k10temp Tctl now: ${tctl} °C"
    pass "lm-sensors installed"
  else
    soft "lm-sensors not installed — no thermal telemetry"
  fi
  [[ -x /usr/local/bin/ryzenadj || -x /usr/bin/ryzenadj ]] \
    && pass "ryzenadj present (power-limit control available)" \
    || note "ryzenadj not installed (optional; aggressive module can build it)"
  return 0
}

# ------------------------------------------------------------ 2. memory/swap --
audit_memory() {
  dim memory "2. Memory, swap & reclaim"
  local zram_dev=0
  swapon --noheadings --show=NAME 2>/dev/null | grep -q zram && zram_dev=1
  local zswap; zswap="$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo '?')"

  if [[ "$zram_dev" == "1" ]]; then
    pass "zram swap active: $(swapon --show=NAME,SIZE,PRIO --noheadings 2>/dev/null | tr '\n' ' ')"
  else
    hard "no zram swap — on 32 GiB this is the single biggest win for agentic workloads"
  fi
  if [[ "$zswap" == "Y" && "$zram_dev" == "1" ]]; then
    hard "zswap AND zram both enabled — double compression, documented anti-pattern (set zswap.enabled=0)"
  else
    pass "zswap/zram not stacked (zswap=$zswap)"
  fi

  local sw; sw="$(sysctl_get vm.swappiness)"
  if [[ "$zram_dev" == "1" ]]; then
    if [[ "${sw:-60}" -ge 100 ]]; then pass "vm.swappiness=$sw — correct for zram (kernel docs sanction >100 for in-memory swap)"
    else hard "vm.swappiness=$sw with zram — too low; the kernel will evict your build's page cache instead of compressing idle anon pages"; fi
  else
    note "vm.swappiness=$sw (no zram present, so the >100 guidance does not apply yet)"
  fi

  local pc; pc="$(sysctl_get vm.page-cluster)"
  [[ "${pc:-3}" == "0" ]] && pass "vm.page-cluster=0 — swap readahead off, correct for zram" \
                          || soft "vm.page-cluster=$pc — wasted decompressions on every zram fault (want 0)"

  local vcp; vcp="$(sysctl_get vm.vfs_cache_pressure)"
  [[ "${vcp:-100}" -le 60 && "${vcp:-100}" -gt 0 ]] && pass "vm.vfs_cache_pressure=$vcp — dentry cache retained for big repos" \
                          || soft "vm.vfs_cache_pressure=$vcp — 'git status' on large trees is a dentry benchmark; 50 is better"

  local db bb dr
  db="$(sysctl_get vm.dirty_bytes)"; bb="$(sysctl_get vm.dirty_background_bytes)"; dr="$(sysctl_get vm.dirty_ratio)"
  if [[ "${db:-0}" -gt 0 ]]; then pass "writeback bounded by bytes (dirty_bytes=$db background=$bb)"
  else soft "writeback still ratio-based (dirty_ratio=$dr) — on 32 GiB that is ~6 GiB of dirty pages before throttling, i.e. multi-second stalls at fsync time"; fi

  local mmc; mmc="$(sysctl_get vm.max_map_count)"
  [[ "${mmc:-65530}" -ge 1048576 ]] && pass "vm.max_map_count=$mmc" \
                                    || soft "vm.max_map_count=$mmc — raise to 1048576 for Electron/JVM/PyTorch"

  local wsf; wsf="$(sysctl_get vm.watermark_scale_factor)"
  [[ "${wsf:-10}" -ge 100 ]] && pass "vm.watermark_scale_factor=$wsf — kswapd wakes early, avoids direct-reclaim stalls" \
                             || soft "vm.watermark_scale_factor=$wsf — low; expect 'the desktop froze for 4 seconds' under memory pressure"

  local thp; thp="$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo '?')"
  case "$thp" in
    madvise) pass "THP=madvise — right for mixed container + ML workloads" ;;
    always)  soft "THP=always — khugepaged compaction spikes hurt interactive latency with heavy container churn" ;;
    never)   soft "THP=never — blocks ML allocators that legitimately ask for huge pages" ;;
    *)       note "THP mode unreadable" ;;
  esac

  local mglru; mglru="$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || echo '')"
  [[ -n "$mglru" ]] && note "MGLRU: $mglru (affects reclaim behaviour with zram)"
  return 0
}

# ------------------------------------------------------------- 3. storage/io --
audit_storage() {
  dim storage "3. Storage & I/O"
  note "root: $ROOT_SRC  fstype=$ROOT_FSTYPE"
  note "opts: $ROOT_OPTS"

  local d
  for d in /sys/block/nvme*n*; do
    [[ -e "$d" ]] || continue
    local n sched; n="$(basename "$d")"
    sched="$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$d/queue/scheduler" 2>/dev/null || echo '?')"
    if [[ "$sched" == "none" ]]; then pass "$n scheduler=none (correct for NVMe)"
    else soft "$n scheduler=$sched — software reordering only adds latency on a device with hardware queues"; fi
    note "$n read_ahead_kb=$(cat "$d/queue/read_ahead_kb" 2>/dev/null || echo ?) rotational=$(cat "$d/queue/rotational" 2>/dev/null || echo ?)"
  done
  [[ -e /etc/udev/rules.d/60-ioschedulers.rules ]] && pass "io scheduler udev rule persisted" \
                                                   || soft "no udev rule — scheduler choice is not guaranteed across reboots/kernels"

  case "$ROOT_OPTS" in
    *noatime*) pass "root mounted noatime" ;;
    *) soft "root not noatime — relatime still writes one atime update per file per day; on a 400k-file node_modules that is real journal traffic" ;;
  esac
  case "$ROOT_OPTS" in
    *discard*) soft "inline 'discard' on root — TRIM on every unlink stalls the queue; prefer fstrim.timer" ;;
    *) pass "no inline discard on root" ;;
  esac
  case "$ROOT_OPTS" in
    *nobarrier*|*barrier=0*) hard "barriers disabled on root — filesystem corruption risk on power loss. Remove immediately." ;;
    *) pass "write barriers intact" ;;
  esac

  if unit_enabled fstrim.timer; then pass "fstrim.timer enabled (periodic TRIM)"
  else soft "fstrim.timer not enabled — the SSD never gets TRIM"; fi

  local apst; apst="$(cat /sys/module/nvme_core/parameters/default_ps_max_latency_us 2>/dev/null || echo '?')"
  note "nvme APST max latency: ${apst} us (kernel default 100000 permits the deepest states)"
  if journalctl -k --no-pager -b 2>/dev/null | grep -qiE 'nvme.*(controller is down|will reset|I/O.*timeout|Device not ready)'; then
    hard "NVMe controller resets/timeouts in this boot's kernel log — classic APST bug on budget drives; cap default_ps_max_latency_us"
  else
    pass "no NVMe controller resets in this boot"
  fi

  if require_cmd nvme && [[ "$(id -u)" -eq 0 ]]; then
    local dev="${NVME_DEVS[0]:-}"
    if [[ -n "$dev" ]]; then
      local warn_time used temp
      warn_time="$(nvme smart-log "$dev" 2>/dev/null | awk -F: '/Warning Temperature Time/{gsub(/ /,"",$2); print $2}')"
      used="$(nvme smart-log "$dev" 2>/dev/null | awk -F: '/percentage_used|Percentage Used/{gsub(/[ %]/,"",$2); print $2; exit}')"
      temp="$(nvme smart-log "$dev" 2>/dev/null | awk -F: '/^temperature/{print $2; exit}')"
      note "nvme: temp=${temp:-?} percentage_used=${used:-?}% warning_temp_time=${warn_time:-?} min"
      [[ "${warn_time:-0}" -gt 0 ]] && soft "drive has spent ${warn_time} minutes above its warning temperature — it is already derating under sustained load" || pass "no time above warning temperature"
    fi
  else
    note "NVMe SMART detail skipped (needs root + nvme-cli)"
  fi

  # Free space — sustained AI dev eats disk via model weights + container layers.
  local pct; pct="$(df --output=pcent / 2>/dev/null | tail -n1 | tr -dc '0-9')"
  if [[ "${pct:-0}" -ge 90 ]]; then hard "root filesystem ${pct}% full"
  elif [[ "${pct:-0}" -ge 75 ]]; then soft "root filesystem ${pct}% full — model weights and container layers grow fast"
  else pass "root filesystem ${pct}% used"; fi
  return 0
}

# ---------------------------------------------------------------- 4. limits --
audit_limits() {
  dim limits "4. Limits, inotify & file descriptors"

  local w i q
  w="$(sysctl_get fs.inotify.max_user_watches)"
  i="$(sysctl_get fs.inotify.max_user_instances)"
  q="$(sysctl_get fs.inotify.max_queued_events)"
  [[ "${w:-0}" -ge 524288 ]] && pass "inotify max_user_watches=$w" \
                             || soft "inotify max_user_watches=$w — IDEs and watchers on large monorepos exhaust this"
  [[ "${i:-0}" -ge 1024 ]]   && pass "inotify max_user_instances=$i" \
                             || hard "inotify max_user_instances=$i — this is the one that actually bites; every VS Code window, tsc --watch, nodemon and dockerd takes one, and ENOSPC from inotify_init is reported as a confusing generic error"
  [[ "${q:-0}" -ge 131072 ]] && pass "inotify max_queued_events=$q" \
                             || soft "inotify max_queued_events=$q — queue overflow silently drops events, which is why hot-reload dies after a big git checkout"

  # Does the desktop indexer's sysctl drop-in undercut us?
  local tf
  for tf in /usr/lib/sysctl.d/30-tracker.conf /usr/lib/sysctl.d/30-localsearch.conf; do
    [[ -f "$tf" ]] || continue
    note "$tf present: $(grep -h inotify "$tf" 2>/dev/null | tr '\n' ' ')"
    [[ -f "/etc/sysctl.d/$(basename "$tf")" ]] \
      && pass "shadowed by /etc/sysctl.d/$(basename "$tf")" \
      || soft "$tf can clobber your watch limit on package upgrade — shadow it with a same-named file in /etc/sysctl.d/"
  done

  local sn hn; sn="$(ulimit -Sn)"; hn="$(ulimit -Hn)"
  [[ "$sn" -ge 65536 ]] && pass "nofile soft limit in this shell: $sn (hard $hn)" \
                        || soft "nofile soft limit is $sn in this shell — Node monorepos hit EMFILE at 1024"
  note "systemd system DefaultLimitNOFILE: $(systemctl show -p DefaultLimitNOFILE --value 2>/dev/null || echo ?)"
  note "systemd user   DefaultLimitNOFILE: $(systemctl --user show -p DefaultLimitNOFILE --value 2>/dev/null || echo 'n/a')"
  [[ -f /etc/systemd/user.conf.d/90-poplab-limits.conf ]] \
    && pass "user-manager limits drop-in installed" \
    || soft "no user.conf.d limits drop-in — raising only system.conf leaves your actual desktop session at soft 1024"

  local ml; ml="$(ulimit -Sl 2>/dev/null || echo 0)"
  [[ "$ml" == "unlimited" ]] && pass "memlock unlimited (llama.cpp --mlock, io_uring registered buffers)" \
                             || soft "memlock soft limit is $ml KB — 'llama.cpp --mlock' and io_uring buffer registration will fail"

  note "fs.nr_open=$(sysctl_get fs.nr_open)  fs.file-max=$(sysctl_get fs.file-max) (file-max is memory-derived; do not lower it)"
  return 0
}

# -------------------------------------------------------------------- 5. oom --
audit_oom() {
  dim oom "5. OOM handling"
  local oomd=0 eo=0
  unit_active systemd-oomd.service && oomd=1
  unit_active earlyoom.service && eo=1

  if (( oomd && eo )); then hard "systemd-oomd and earlyoom both running — they will race to kill things"
  elif (( oomd )); then
    local conf; conf="$(grep -rhs 'SwapUsedLimit' /etc/systemd/oomd.conf /etc/systemd/oomd.conf.d/ 2>/dev/null | tail -n1)"
    note "systemd-oomd active; SwapUsedLimit config: ${conf:-<default 90%>}"
    if [[ "$conf" == *100%* ]]; then
      pass "SwapUsedLimit=100% — swap-based killing disabled, correct alongside zram"
    else
      hard "systemd-oomd with default SwapUsedLimit=90% + zram is a trap: zram filling up is NORMAL, but oomd reads it as distress and kills your largest cgroup (your build, containers, or llama.cpp). This is the highest-value fix in the whole audit."
    fi
    note "$(oomctl 2>/dev/null | head -n3 | tr '\n' ' ' || true)"
  elif (( eo )); then
    pass "earlyoom active"
    grep -q 'EARLYOOM_ARGS' /etc/default/earlyoom 2>/dev/null && note "args: $(grep EARLYOOM_ARGS /etc/default/earlyoom | head -n1)"
    grep -qs '\-s 100' /etc/default/earlyoom && pass "earlyoom -s 100 — swap criterion made non-binding (correct with zram)" \
      || soft "earlyoom without '-s 100' has the same zram pathology as oomd: free swap legitimately hits zero"
  else
    soft "no userspace OOM manager — the kernel OOM killer will fire late, after the desktop has already stalled"
  fi
  return 0
}

# -------------------------------------------------------------------- 6. gpu --
audit_gpu() {
  dim gpu "6. GPU / local inference"
  note "GPU: ${GPU_LINE:-none}"
  [[ "$AMDGPU_LOADED" == "1" ]] && pass "amdgpu kernel module loaded" || soft "amdgpu module not loaded"
  note "ISA target: $GFX_TARGET  (Radeon 680M = gfx1035)"

  local gtt vram
  gtt="$(cat /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -n1 || echo '')"
  vram="$(cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | head -n1 || echo '')"
  [[ -n "$gtt"  ]] && note "GTT  total: $(( gtt  / 1024 / 1024 )) MiB"
  [[ -n "$vram" ]] && note "VRAM total: $(( vram / 1024 / 1024 )) MiB  (BIOS UMA carve-out — this is the hard ceiling for ROCm/HIP)"
  if [[ -n "$vram" ]] && [[ $(( vram / 1024 / 1024 )) -lt 2048 ]]; then
    soft "VRAM carve-out is small. ROCm/HIP allocates from VRAM only, not GTT — with this little UMA, the Vulkan backend (which can use GTT) is the more useful path for llama.cpp"
  fi

  local pl; pl="$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo '')"
  [[ -n "$pl" ]] && note "ttm.pages_limit=$pl pages ($(( pl * 4 / 1024 / 1024 )) GiB)"
  if kernel_cmdline_has "amdgpu.gttsize" 2>/dev/null || grep -q 'amdgpu.gttsize' /proc/cmdline 2>/dev/null; then
    soft "amdgpu.gttsize is on the kernel cmdline — deprecated; the kernel wants ttm.pages_limit now"
  fi

  id -nG 2>/dev/null | grep -qw render && pass "user in 'render' group" || soft "user not in 'render' group — /dev/kfd is unreachable, so no GPU compute"
  id -nG 2>/dev/null | grep -qw video  && pass "user in 'video' group"  || soft "user not in 'video' group"
  [[ -e /dev/kfd ]] && pass "/dev/kfd present (compute queue)" || note "/dev/kfd absent — ROCm/HIP unavailable"

  require_cmd vulkaninfo && pass "vulkan tools installed" || soft "vulkan-tools not installed — cannot verify the llama.cpp Vulkan backend, which is usually the better bet on a 680M"
  require_cmd rocminfo && pass "rocminfo installed" || note "rocminfo not installed (optional)"
  require_cmd ollama && note "ollama present: $(ollama --version 2>/dev/null | head -n1)" || note "ollama not installed"
  if require_cmd ollama && [[ -f /etc/systemd/system/ollama.service.d/10-poplab.conf ]]; then
    pass "ollama HSA override drop-in installed"
  elif require_cmd ollama; then
    soft "ollama present without HSA_OVERRIDE_GFX_VERSION=10.3.0 — gfx1035 is not an official ROCm target and will be ignored or crash"
  fi
  return 0
}

# ------------------------------------------------------------------ 7. media --
audit_media() {
  dim media "7. Media / hardware encode"
  if require_cmd vainfo; then
    local vi; vi="$(vainfo --display drm --device /dev/dri/renderD128 2>/dev/null || vainfo 2>/dev/null || true)"
    if [[ -n "$vi" ]]; then
      grep -q 'VAProfileH264High.*EncSlice' <<<"$vi" && pass "VAAPI H.264 hardware encode available" || soft "no VAAPI H.264 encode entrypoint"
      grep -q 'VAProfileHEVCMain.*EncSlice' <<<"$vi" && pass "VAAPI HEVC 8-bit hardware encode available" || soft "no VAAPI HEVC encode entrypoint"
      grep -q 'VAProfileAV1' <<<"$vi" && note "AV1 present — on VCN 3.1 (Rembrandt) this is decode-only; AV1 encode needs RDNA3"
    else
      soft "vainfo produced no output — driver probably not loaded (try LIBVA_DRIVER_NAME=radeonsi)"
    fi
  else
    soft "vainfo not installed — hardware transcode unverified"
  fi
  require_cmd ffmpeg && pass "ffmpeg installed" || soft "ffmpeg not installed"
  return 0
}

# ------------------------------------------------------------- 8. background --
audit_hygiene() {
  dim hygiene "8. Background noise & desktop hygiene"

  if pkg_installed apport && unit_enabled apport.service; then
    soft "apport enabled — a crashing 20 GB-RSS inference process writes a multi-GB core into /var/crash at the worst possible moment"
  else pass "apport not writing crash dumps"; fi

  if unit_enabled apt-daily-upgrade.timer; then
    local sched; sched="$(systemctl show apt-daily-upgrade.timer -p TimersCalendar --value 2>/dev/null)"
    soft "apt-daily-upgrade.timer enabled ($sched) — grabs the dpkg lock and can restart Docker mid-build"
  else pass "unattended upgrade timer not firing unscheduled"; fi

  local t
  for t in tracker-miner-fs-3.service localsearch-3.service; do
    if systemctl --user is-enabled "$t" >/dev/null 2>&1; then
      soft "$t enabled — indexes node_modules, .venv, model checkpoints and container volumes"
    fi
  done

  local jmax; jmax="$(grep -hs '^SystemMaxUse' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/* 2>/dev/null | tail -n1)"
  [[ -n "$jmax" ]] && pass "journald bounded ($jmax)" || soft "journald unbounded — chatty containers produce fsync-heavy journal growth"

  local userns; userns="$(sysctl_get kernel.apparmor_restrict_unprivileged_userns)"
  if [[ "$userns" == "1" ]]; then
    note "kernel.apparmor_restrict_unprivileged_userns=1 (Ubuntu 24.04 default). Breaks rootless Docker/Podman, bwrap, and some Electron sandboxes. poplab can add per-binary AppArmor profiles rather than disabling it globally."
  elif [[ "$userns" == "0" ]]; then
    soft "unprivileged userns restriction disabled globally — convenient, but it is a real container-escape mitigation you have turned off"
  fi

  if require_cmd docker; then
    pass "docker present"
    [[ -f /etc/docker/daemon.json ]] && grep -q 'log-opts' /etc/docker/daemon.json 2>/dev/null \
      && pass "docker log rotation configured" \
      || soft "docker json-file logs unbounded — silent disk fill"
  fi

  [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == "cgroup2fs" ]] && pass "cgroup v2 unified" || soft "not cgroup v2"
  [[ -f /etc/systemd/system/user@.service.d/delegate.conf ]] \
    && pass "cgroup controllers delegated to the user manager (needed for rootless resource limits)" \
    || note "no controller delegation drop-in — rootless containers get no memory/cpu limits"
  return 0
}

# ------------------------------------------------------------------- report --
audit_score() {
  head1 "Score"
  local total=0 tmax=0 k
  printf '%-12s %-8s %s\n' "DIMENSION" "SCORE" "BAR"
  for k in platform cpu memory storage limits oom gpu media hygiene; do
    local s="${DIM_SCORE[$k]:-0}" m="${DIM_MAX[$k]:-0}"
    [[ "$m" -eq 0 ]] && continue
    total=$((total+s)); tmax=$((tmax+m))
    local pct=$(( s * 100 / m )) filled=$(( s * 20 / m )) bar=""
    local j; for ((j=0;j<20;j++)); do [[ $j -lt $filled ]] && bar+="█" || bar+="░"; done
    printf '%-12s %-8s %s %3d%%\n' "$k" "$s/$m" "$bar" "$pct"
  done
  local pct=0; [[ $tmax -gt 0 ]] && pct=$(( total * 100 / tmax ))
  log ""
  log "${C_BLD}OVERALL: $total/$tmax  (${pct}%)${C_RST}"
  local grade
  if   [[ $pct -ge 90 ]]; then grade="A — tuned"
  elif [[ $pct -ge 75 ]]; then grade="B — mostly there, a few real wins left"
  elif [[ $pct -ge 60 ]]; then grade="C — stock-ish; the tuning modules will make a felt difference"
  elif [[ $pct -ge 40 ]]; then grade="D — untuned for sustained load"
  else                          grade="F — stock defaults throughout"
  fi
  log "${C_BLD}GRADE:   $grade${C_RST}"
  log ""
  log "Next: ${C_CYN}./bin/poplab plan${C_RST}    (show exactly what would change, no writes)"
  log "Then: ${C_CYN}sudo ./bin/poplab apply${C_RST}"
  return 0
}

main() {
  poplab_detect
  head1 "poplab audit v$POPLAB_VERSION — $(date -u '+%Y-%m-%d %H:%M UTC')"
  audit_platform || warn "stage platform aborted early"
  audit_cpu || warn "stage cpu aborted early"
  audit_memory || warn "stage memory aborted early"
  audit_storage || warn "stage storage aborted early"
  audit_limits || warn "stage limits aborted early"
  audit_oom || warn "stage oom aborted early"
  audit_gpu || warn "stage gpu aborted early"
  audit_media || warn "stage media aborted early"
  audit_hygiene || warn "stage hygiene aborted early"
  audit_score
}

main "$@"
