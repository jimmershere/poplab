#!/usr/bin/env bash
# 20-cpu-power.sh — sustained-load CPU behaviour.
#   * one power daemon, not three
#   * EPP=performance on AC, balance_power on battery, re-applied after resume
#   * system76-scheduler rules so a -j16 build does not make the desktop unusable
# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
  poplab_detect
  head1 "20 · CPU scaling, EPP & scheduler"
  is_apply && require_root

  head2 "power daemon exclusivity"
  local s76=0 ppd=0 tlp=0
  unit_active com.system76.PowerDaemon.service && s76=1
  unit_active power-profiles-daemon.service && ppd=1
  unit_active tlp.service && tlp=1
  if (( s76 && ppd )); then
    warn "system76-power and power-profiles-daemon are both running; they conflict at the dpkg level and fight over EPP"
    if [[ "$IS_POP" == "1" ]]; then
      info "on Pop!_OS, system76-power wins — disabling power-profiles-daemon"
      run systemctl disable --now power-profiles-daemon.service
    fi
  fi
  if (( tlp && (s76 || ppd) )); then
    warn "tlp overlaps with the active power daemon; disabling tlp"
    run systemctl disable --now tlp.service
  fi
  if (( s76 )); then
    info "current system76-power profile: $(system76-power profile 2>/dev/null | tail -n1)"
    run system76-power profile performance
  elif (( ppd )); then
    run powerprofilesctl set performance
  fi

  head2 "EPP + governor, persistent across boot and resume"
  # EPP only exists in amd_pstate 'active' mode, and is forced to 'performance'
  # if the governor is 'performance'. Keeping governor=powersave + EPP is the
  # correct combination: 'powersave' under amd-pstate-epp is EPP-driven, not slow.
  if [[ -e /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
    write_file /usr/local/sbin/poplab-cpu-profile 0755 <<'SCRIPT'
#!/usr/bin/env bash
# Applied at boot and after every resume. Picks EPP by power source.
set -u
on_ac=1
for p in /sys/class/power_supply/A{C,DP}*/online /sys/class/power_supply/*/online; do
  [[ -r "$p" ]] || continue
  [[ "$(cat "$p")" == "1" ]] && on_ac=1 || on_ac=0
  break
done
if [[ "$on_ac" == "1" ]]; then epp=performance; else epp=balance_power; fi
for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
  [[ -w "$f" ]] && echo "$epp" > "$f" 2>/dev/null || true
done
# Core performance boost on (per-policy knob exists on kernel >= 6.11).
for f in /sys/devices/system/cpu/cpufreq/boost /sys/devices/system/cpu/cpufreq/policy*/boost; do
  [[ -w "$f" ]] && echo 1 > "$f" 2>/dev/null || true
done
logger -t poplab-cpu-profile "epp=$epp on_ac=$on_ac"
SCRIPT

    write_file /etc/systemd/system/poplab-cpu-profile.service 0644 <<'UNIT'
[Unit]
Description=poplab: apply CPU energy-performance preference
After=multi-user.target suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/poplab-cpu-profile
RemainAfterExit=no

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target
UNIT

    # AC/battery transitions do not go through systemd sleep targets, so also
    # hook the power_supply uevent.
    write_file /etc/udev/rules.d/61-poplab-power.rules 0644 <<'UDEV'
SUBSYSTEM=="power_supply", ACTION=="change", RUN+="/usr/local/sbin/poplab-cpu-profile"
UDEV

    systemd_reload
    run systemctl enable --now poplab-cpu-profile.service
    run udevadm control --reload
  else
    warn "no EPP sysfs node — amd_pstate is not in 'active' mode. Run module 10 and reboot first."
  fi

  head2 "system76-scheduler process priorities"
  # The CFS-latency half of this daemon is inert on EEVDF kernels (>=6.6), but the
  # process-priority half is genuinely useful: it keeps the compositor responsive
  # while cargo/tsc/ninja saturate all 16 threads.
  if [[ -d /etc/system76-scheduler ]]; then
    write_file /etc/system76-scheduler/process-scheduler/99-poplab.kdl 0644 <<'KDL'
// poplab: keep the desktop responsive under sustained builds and inference.
// Reload without restarting: sudo system76-scheduler daemon reload
assignments {
    // Build tooling: nice it down and put it on the batch scheduling class.
    batch nice=15 sched="batch" io=(best-effort)6 {
        cc1
        cc1plus
        rustc
        include name="cargo*"
        include name="ninja*"
        include name="make"
        include name="tsc*"
        include name="esbuild*"
        include name="webpack*"
        include name="ffmpeg"
        include descends="dockerd"
    }
    // Foreground: the compositor and the editor should always win.
    foreground nice=-5 io=(best-effort)0 {
        cosmic-comp
        cosmic-session
        include name="code*"
        include name="jetbrains*"
        include name="*studio*"
    }
    // Inference servers: normal priority but do not let them starve the UI.
    default nice=0 {
        include name="llama-server"
        include name="ollama*"
    }
}
KDL
    if require_cmd system76-scheduler; then
      run system76-scheduler daemon reload || run systemctl restart com.system76.Scheduler.service
    fi
  else
    skip "system76-scheduler not installed"
  fi

  head2 "cpupower tooling"
  ensure_pkgs linux-tools-common || true
  return 0
}
main "$@"
