#!/usr/bin/env bash
# 95-thermal-power-limits.sh — AGGRESSIVE. Opt-in only (--aggressive).
#
# Writes undocumented SMU registers via RyzenAdj. There is no safety interlock:
# bad limits can hang the SMU or destabilise the machine, and on a chassis whose
# cooling you have not characterised, raising limits can simply make it throttle
# harder and run hotter for the same throughput.
#
# The honest use of this module on a thin 15.6" chassis is usually the OPPOSITE
# of "more power": lowering tctl-temp and the slow limit gives you a lower, FLATTER
# sustained clock, which finishes a 40-minute build faster than boosting to 95 °C
# and then thermal-throttling for the remaining 38 minutes.
# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# Defaults tuned as "sustained, not spiky". Override via env.
PL_FAST="${POPLAB_PL_FAST:-60000}"    # mW, short burst
PL_SLOW="${POPLAB_PL_SLOW:-45000}"    # mW, sustained (6800H nominal TDP)
PL_SLOW_TIME="${POPLAB_PL_SLOW_TIME:-60}"
PL_TCTL="${POPLAB_PL_TCTL:-90}"       # °C
PL_SKIN="${POPLAB_PL_SKIN:-55}"       # °C, only honoured if the OEM enabled STTv2

main() {
  poplab_detect
  head1 "95 · thermal & power limits (AGGRESSIVE)"
  require_aggressive "ryzenadj power limits" || return 0
  is_apply && require_root

  if [[ "$IS_AMD" != "1" ]]; then warn "not an AMD CPU — skipping"; return 0; fi

  head2 "baseline thermals (record these before changing anything)"
  require_cmd sensors || ensure_pkgs lm-sensors
  sensors 2>/dev/null | sed 's/^/    /' | head -30 || true

  head2 "ryzenadj"
  local RA=""
  for c in /usr/local/bin/ryzenadj /usr/bin/ryzenadj; do [[ -x "$c" ]] && RA="$c"; done
  if [[ -z "$RA" ]]; then
    info "building RyzenAdj from source"
    ensure_pkgs build-essential cmake libpci-dev git
    if is_apply; then
      local tmp; tmp="$(mktemp -d)"
      git clone --depth 1 https://github.com/FlyGoat/RyzenAdj "$tmp/RyzenAdj"
      cmake -S "$tmp/RyzenAdj" -B "$tmp/RyzenAdj/build" -DCMAKE_BUILD_TYPE=Release
      cmake --build "$tmp/RyzenAdj/build" -j"$HW_CPU_CORES"
      install -m0755 "$tmp/RyzenAdj/build/ryzenadj" /usr/local/bin/ryzenadj
      rm -rf "$tmp"
      RA=/usr/local/bin/ryzenadj
      ok "installed $RA"
    else
      dry "clone + build FlyGoat/RyzenAdj -> /usr/local/bin/ryzenadj"
      RA=/usr/local/bin/ryzenadj
    fi
  fi

  head2 "caveats for this silicon"
  warn "On Rembrandt (6800H), --stapm-limit and --stapm-time have NO effect: the"
  warn "platform uses STTv2. Use --fast-limit / --slow-limit. --apu-skin-temp and"
  warn "--skin-temp-limit are honoured only if the OEM firmware enabled STTv2."
  warn "Firmware re-asserts its own values periodically, which is why this ships"
  warn "as a timer, not a one-shot."
  if [[ -d /sys/firmware/efi/efivars ]] && [[ "$(mokutil --sb-state 2>/dev/null | grep -c enabled || echo 0)" -gt 0 ]]; then
    warn "Secure Boot appears enabled: kernel lockdown may block /dev/mem access."
    warn "Either enroll a MOK for the ryzen_smu module or accept that this module will fail."
  fi

  head2 "persistent limits"
  write_file /usr/local/sbin/poplab-power-limits 0755 <<PL
#!/usr/bin/env bash
# poplab: re-assert SMU power limits. Firmware overwrites them; re-apply on a timer.
set -u
RA=$RA
on_ac=1
for p in /sys/class/power_supply/A{C,DP}*/online; do
  [[ -r "\$p" ]] && { [[ "\$(cat "\$p")" == "1" ]] && on_ac=1 || on_ac=0; break; }
done
if [[ "\$on_ac" == "1" ]]; then
  "\$RA" --fast-limit=$PL_FAST --slow-limit=$PL_SLOW --slow-time=$PL_SLOW_TIME \\
         --tctl-temp=$PL_TCTL --apu-skin-temp=$PL_SKIN >/dev/null 2>&1
else
  "\$RA" --fast-limit=30000 --slow-limit=20000 --slow-time=60 \\
         --tctl-temp=85 --apu-skin-temp=45 >/dev/null 2>&1
fi
PL

  write_file /etc/systemd/system/poplab-power-limits.service 0644 <<'PLS'
[Unit]
Description=poplab: re-assert AMD SMU power limits
After=multi-user.target suspend.target hibernate.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/poplab-power-limits
[Install]
WantedBy=multi-user.target suspend.target hibernate.target
PLS

  write_file /etc/systemd/system/poplab-power-limits.timer 0644 <<'PLT'
[Unit]
Description=poplab: keep SMU power limits applied (firmware resets them)
[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
PLT

  systemd_reload
  if confirm "apply power limits now (fast=${PL_FAST}mW slow=${PL_SLOW}mW tctl=${PL_TCTL}C)?"; then
    run systemctl enable --now poplab-power-limits.timer
    run systemctl start poplab-power-limits.service
  else
    info "units written but not enabled; enable with: sudo systemctl enable --now poplab-power-limits.timer"
  fi

  head2 "fan control"
  info "amdgpu exposes no fan on an APU — laptop fans hang off the embedded controller."
  info "Try, in order:"
  info "  1. pwmconfig / fancontrol      (usually finds nothing on this class of chassis)"
  info "  2. nbfc-linux                  https://github.com/nbfc-linux/nbfc-linux"
  info "     sudo nbfc update && sudo nbfc config --recommend"
  info "If no NBFC config matches the NIMO chassis, you have no fan curve control."
  info "In that case the only lever is producing less heat — which is what the limits above do."

  head2 "sustained-load validation"
  info "Run a real soak test and watch for clock droop before trusting any of this:"
  info "  sudo ./bin/poplab soak 900"
  return 0
}
main "$@"
