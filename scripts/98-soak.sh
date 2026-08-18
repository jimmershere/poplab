#!/usr/bin/env bash
# 98-soak.sh — sustained-load soak test. Read-only w.r.t. configuration.
# Loads every thread for N seconds and samples clocks, temperature, throttle
# counters and NVMe temperature. This is how you find out whether a power-limit
# change actually helped, rather than assuming it did.
# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
POPLAB_APPLY=0
export POPLAB_APPLY

DURATION="${1:-300}"

sample() {
  local t mhz nvme_t h
  mhz="$(awk '/MHz/{s+=$4;n++} END{if(n)printf "%.0f", s/n}' /proc/cpuinfo)"
  t="$(sensors -j 2>/dev/null | grep -o '"temp1_input":[0-9.]*' | head -n1 | cut -d: -f2)"
  [[ -z "$t" ]] && t="$(awk '{printf "%.1f", $1/1000}' /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | head -c6)"
  nvme_t=""
  for h in /sys/class/hwmon/hwmon*; do
    [[ "$(cat "$h/name" 2>/dev/null)" == "nvme" ]] && nvme_t="$(awk '{printf "%.0f", $1/1000}' "$h/temp1_input" 2>/dev/null)" && break
  done
  printf '%6ss  avg %5s MHz   tctl %5s C   nvme %s C\n' "$1" "${mhz:-?}" "${t:-?}" "${nvme_t:-?}"
}

main() {
  poplab_detect
  head1 "98 · sustained-load soak (${DURATION}s)"
  require_cmd stress-ng || { warn "stress-ng not installed: sudo apt install stress-ng"; return 1; }
  require_cmd sensors   || warn "lm-sensors not installed; temperature samples will be crude"

  info "cpu: $HW_CPU_MODEL (${HW_CPU_CORES} threads)"
  info "baseline:"
  sample 0

  stress-ng --cpu "$HW_CPU_CORES" --timeout "${DURATION}s" --metrics-brief >/tmp/poplab-soak.log 2>&1 &
  local pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15; i=$((i+15))
    sample "$i"
  done
  wait "$pid" || true

  head2 "stress-ng result"
  sed 's/^/    /' /tmp/poplab-soak.log | tail -n 10

  head2 "reading the curve"
  info "A healthy sustained profile plateaus within ~60s and then holds flat."
  info "A sawtooth (spike, drop, spike) means you are hitting the thermal limit and"
  info "the SMU is oscillating — lower --tctl-temp and --slow-limit in module 95 until"
  info "the curve flattens. A flat 3.2 GHz beats an oscillating 2.4-4.2 GHz average."
  return 0
}
main "$@"
