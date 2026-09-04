#!/usr/bin/env bash
# 60-oom-guard.sh — stop the OOM manager from killing your work.
#
# THE trap when you add zram: systemd-oomd ships SwapUsedLimit=90%. zram filling
# up is NORMAL and by design — it is the entire point of swappiness=150. oomd
# reads "swap 90% used" as distress and kills the largest cgroup, which will be
# your build, your container stack, or llama.cpp. You experience it as random
# unexplained process death under load.
# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

STRATEGY="${POPLAB_OOM_STRATEGY:-oomd}"   # oomd | earlyoom

main() {
  poplab_detect
  head1 "60 · OOM guard (strategy: $STRATEGY)"
  is_apply && require_root

  info "current ManagedOOM policy:"
  systemctl show -.slice "user@$(id -u).service" -p ManagedOOMSwap -p ManagedOOMMemoryPressure -p ManagedOOMMemoryPressureLimit 2>/dev/null | sed 's/^/    /' || true
  grep -rls ManagedOOM /usr/lib/systemd/system/ 2>/dev/null | sed 's/^/    ships: /' || true

  if [[ "$STRATEGY" == "earlyoom" ]]; then
    head2 "earlyoom"
    ensure_pkgs earlyoom
    # -s 100 makes the swap criterion non-binding: with zram, free swap
    # legitimately goes to zero. Kills are then driven purely by available RAM.
    write_file /etc/default/earlyoom 0644 <<'EO'
EARLYOOM_ARGS="-r 60 -m 5 -M 3 -s 100 --avoid '(^|/)(systemd|systemd-.*|Xorg|cosmic-comp|cosmic-session|cosmic-greeter|gnome-shell|sshd|dbus-daemon|dockerd|containerd|NetworkManager|llama-server|ollama)$' --prefer '(^|/)(chrome|chromium|firefox|electron|node|Web Content|code|java)$'"
EO
    run systemctl disable --now systemd-oomd.service || true
    run systemctl mask systemd-oomd.service || true
    run systemctl enable --now earlyoom.service
  else
    head2 "systemd-oomd"
    if ! unit_exists systemd-oomd.service; then
      skip "systemd-oomd not present on this system"
    else
      write_file /etc/systemd/oomd.conf.d/10-poplab.conf 0644 <<'OOMD'
[OOM]
# 100% = swap-based killing off. Correct with zram: a full zram device is normal
# operation, not distress. PSI memory-pressure killing (the genuinely useful
# signal, because it measures actual stall) stays on.
SwapUsedLimit=100%
# 60%/30s fires during the ordinary thrash of a large parallel build.
DefaultMemoryPressureLimit=80%
DefaultMemoryPressureDurationSec=60s
OOMD
      write_file /etc/systemd/system/user@.service.d/10-poplab-oomd.conf 0644 <<'OPTOUT'
[Service]
ManagedOOMSwap=auto
ManagedOOMMemoryPressure=auto
OPTOUT
      systemd_reload
      run systemctl restart systemd-oomd.service || true
      run systemctl unmask earlyoom.service 2>/dev/null || true
      unit_active earlyoom.service && { warn "earlyoom also running — disabling so they do not race"; run systemctl disable --now earlyoom.service; }
    fi
  fi

  head2 "protecting long-running inference"
  # cgroup properties beat both daemons: they express intent per-workload.
  write_file /usr/local/bin/poplab-run 0755 <<'RUNNER'
#!/usr/bin/env bash
# poplab-run — launch a long-running workload inside a protected cgroup scope.
#   poplab-run --mem 20G -- llama-server -m model.gguf
# The scope gets MemoryHigh (throttle before kill), a very negative OOM score,
# and OOMPolicy=continue so a child dying does not take the scope with it.
set -euo pipefail
mem="20G"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mem) mem="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[[ $# -gt 0 ]] || { echo "usage: poplab-run [--mem 20G] -- <command> [args...]" >&2; exit 64; }
exec systemd-run --user --scope --collect \
  -p "MemoryHigh=$mem" -p OOMPolicy=continue -p OOMScoreAdjust=-500 \
  -p ManagedOOMMemoryPressure=auto \
  -- "$@"
RUNNER

  head2 "verify"
  require_cmd oomctl && { oomctl 2>/dev/null | head -n 12 | sed 's/^/    /' || true; }
  return 0
}
main "$@"
