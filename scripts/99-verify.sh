#!/usr/bin/env bash
# 99-verify.sh — post-apply verification. Read-only. Exits non-zero if any
# expected setting did not stick, so it can be used in CI or a cron check.
# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
POPLAB_APPLY=0
export POPLAB_APPLY

FAILED=0
expect() { # expect <label> <actual> <op> <expected>
  local label="$1" actual="$2" op="$3" want="$4" good=1
  case "$op" in
    eq) [[ "$actual" == "$want" ]] || good=0 ;;
    ge) [[ "${actual:-0}" =~ ^[0-9]+$ ]] && [[ "${actual:-0}" -ge "$want" ]] || good=0 ;;
    has) [[ "$actual" == *"$want"* ]] || good=0 ;;
    file) [[ -e "$want" ]] || good=0 ;;
  esac
  if [[ "$good" == "1" ]]; then ok "$label = $actual"
  else err "$label = ${actual:-<unset>} (expected $op $want)"; FAILED=$((FAILED+1)); fi
}

main() {
  poplab_detect
  head1 "99 · verify"

  head2 "kernel cmdline (needs a reboot after module 10)"
  info "$(cat /proc/cmdline)"
  grep -q 'amd_pstate' /proc/cmdline && ok "amd_pstate on cmdline" || warn "amd_pstate not yet on the active cmdline — reboot pending?"

  head2 "cpu"
  expect "amd_pstate.status" "$PSTATE_STATUS" has "active"
  [[ -e /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]] && \
    expect "EPP" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)" has "performance"
  unit_enabled poplab-cpu-profile.service && ok "poplab-cpu-profile enabled" || { err "poplab-cpu-profile not enabled"; FAILED=$((FAILED+1)); }

  head2 "memory"
  expect "vm.swappiness" "$(sysctl_get vm.swappiness)" ge 100
  expect "vm.page-cluster" "$(sysctl_get vm.page-cluster)" eq 0
  expect "vm.max_map_count" "$(sysctl_get vm.max_map_count)" ge 1048576
  expect "vm.dirty_bytes" "$(sysctl_get vm.dirty_bytes)" ge 1
  swapon --show=NAME --noheadings 2>/dev/null | grep -q zram && ok "zram swap active" || { err "no zram swap"; FAILED=$((FAILED+1)); }

  head2 "storage"
  local d
  for d in /sys/block/nvme*n*; do
    [[ -e "$d/queue/scheduler" ]] || continue
    expect "$(basename "$d") scheduler" "$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$d/queue/scheduler")" eq none
  done
  unit_enabled fstrim.timer && ok "fstrim.timer enabled" || { err "fstrim.timer not enabled"; FAILED=$((FAILED+1)); }

  head2 "limits"
  expect "fs.inotify.max_user_watches" "$(sysctl_get fs.inotify.max_user_watches)" ge 1048576
  expect "fs.inotify.max_user_instances" "$(sysctl_get fs.inotify.max_user_instances)" ge 8192
  expect "fs.inotify.max_queued_events" "$(sysctl_get fs.inotify.max_queued_events)" ge 524288
  expect "user.conf.d limits drop-in" "" file /etc/systemd/user.conf.d/90-poplab-limits.conf
  info "this shell nofile soft=$(ulimit -Sn) (re-login required before this reflects the new value)"

  head2 "oom"
  if unit_active systemd-oomd.service; then
    local sul; sul="$(grep -rhs SwapUsedLimit /etc/systemd/oomd.conf.d/ 2>/dev/null | tail -n1)"
    expect "oomd SwapUsedLimit" "$sul" has "100%"
  elif unit_active earlyoom.service; then
    ok "earlyoom active"
    grep -qs -- '-s 100' /etc/default/earlyoom && ok "earlyoom swap criterion neutralised" || { err "earlyoom missing -s 100"; FAILED=$((FAILED+1)); }
  else
    err "no OOM manager active"; FAILED=$((FAILED+1))
  fi

  head2 "gpu"
  [[ -e /sys/module/ttm/parameters/pages_limit ]] && info "ttm.pages_limit=$(cat /sys/module/ttm/parameters/pages_limit)"
  [[ -e /dev/kfd ]] && ok "/dev/kfd present" || warn "/dev/kfd absent (ROCm unavailable; Vulkan path unaffected)"

  head2 "result"
  if [[ "$FAILED" -eq 0 ]]; then
    ok "all checks passed"
  else
    err "$FAILED check(s) failed"
  fi
  return "$FAILED"
}
main "$@"
