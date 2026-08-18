#!/usr/bin/env bash
# 90-hygiene.sh — remove background work that competes with sustained builds.
# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
  poplab_detect
  head1 "90 · background noise & container ergonomics"
  is_apply && require_root

  head2 "apport / coredumps"
  if pkg_installed apport; then
    write_file /etc/default/apport 0644 <<'AP'
# poplab: a crashing 20 GB-RSS inference process would otherwise write a
# multi-GB core into /var/crash, stalling I/O exactly when you least want it.
enabled=0
AP
    run systemctl disable --now apport.service || true
  else
    skip "apport not installed"
  fi
  if unit_exists systemd-coredump.socket; then
    write_file /etc/systemd/coredump.conf.d/10-poplab.conf 0644 <<'CD'
[Coredump]
Storage=none
ProcessSizeMax=0
CD
  fi

  head2 "unattended upgrades — reschedule, do not disable"
  # Keeping security updates matters; what hurts is dpkg-lock contention and a
  # Docker restart in the middle of a build. Move it to 04:00.
  if unit_exists apt-daily-upgrade.timer; then
    write_file /etc/systemd/system/apt-daily-upgrade.timer.d/10-poplab.conf 0644 <<'APT1'
[Timer]
OnCalendar=
OnCalendar=04:00
RandomizedDelaySec=30m
Persistent=true
APT1
    write_file /etc/systemd/system/apt-daily.timer.d/10-poplab.conf 0644 <<'APT2'
[Timer]
OnCalendar=
OnCalendar=03:30
RandomizedDelaySec=30m
Persistent=true
APT2
    systemd_reload
    run systemctl restart apt-daily.timer apt-daily-upgrade.timer || true
  fi

  head2 "desktop file indexer"
  # Indexing node_modules, .venv, model checkpoints and container volumes is pure
  # waste, and the indexer package also ships the sysctl file that undercuts your
  # inotify watch limit (see module 50).
  local u="${SUDO_USER:-}"
  if [[ -n "$u" ]] && require_cmd gsettings; then
    info "restricting the indexer for user $u"
    run sudo -u "$u" dbus-run-session -- gsettings set org.freedesktop.Tracker3.Miner.Files index-recursive-directories "[]" || \
      warn "could not set gsettings non-interactively; run this in your own session:"
    info "  gsettings set org.freedesktop.Tracker3.Miner.Files index-recursive-directories \"[]\""
    info "  gsettings set org.freedesktop.Tracker3.Miner.Files index-single-directories \"[]\""
  fi
  info "or mask it entirely from YOUR session (not root):"
  info "  systemctl --user mask tracker-miner-fs-3.service tracker-extract-3.service localsearch-3.service"

  head2 "journald bounds"
  write_file /etc/systemd/journald.conf.d/10-poplab.conf 0644 <<'JD'
[Journal]
SystemMaxUse=1G
SystemMaxFileSize=128M
Compress=yes
JD
  run systemctl restart systemd-journald || true

  head2 "motd-news"
  [[ -f /etc/default/motd-news ]] && run sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news || true

  head2 "docker"
  if require_cmd docker; then
    if [[ -f /etc/docker/daemon.json ]]; then
      warn "/etc/docker/daemon.json already exists — not overwriting. Merge these keys yourself:"
      cat <<'DJ' | sed 's/^/    /'
"log-driver": "json-file",
"log-opts": {"max-size": "50m", "max-file": "3"},
"storage-driver": "overlay2",
"default-ulimits": {"nofile": {"Name":"nofile","Hard":1048576,"Soft":1048576}}
DJ
    else
      write_file /etc/docker/daemon.json 0644 <<'DJ'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "storage-driver": "overlay2",
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 1048576, "Soft": 1048576 }
  }
}
DJ
      run systemctl restart docker || true
    fi
  else
    skip "docker not installed"
  fi

  head2 "unprivileged user namespaces (Ubuntu 24.04 AppArmor restriction)"
  local userns; userns="$(sysctl_get kernel.apparmor_restrict_unprivileged_userns)"
  if [[ "$userns" == "1" ]]; then
    warn "restriction is ON. It breaks rootless Docker/Podman, bwrap, AppImages and some Electron sandboxes."
    info "poplab's default is the surgical fix: a per-binary AppArmor profile, keeping the mitigation for everything else."
    info "Example for rootlesskit:"
    cat <<'AA' | sed 's/^/    /'
# /etc/apparmor.d/usr.bin.rootlesskit
abi <abi/4.0>,
include <tunables/global>
/usr/bin/rootlesskit flags=(unconfined) {
  userns,
  include if exists <local/usr.bin.rootlesskit>
}
# then: sudo apparmor_parser -r /etc/apparmor.d/usr.bin.rootlesskit
AA
    if [[ "${POPLAB_DISABLE_USERNS_RESTRICTION:-0}" == "1" ]]; then
      require_aggressive "disable userns restriction system-wide" && {
        warn "disabling a real container-escape mitigation system-wide, as explicitly requested"
        write_file /etc/sysctl.d/60-poplab-userns.conf 0644 <<'UNS'
# poplab: opt-in. Removes the Ubuntu 24.04 unprivileged-userns restriction.
# This is a genuine security trade-off, taken deliberately on a single-user box.
kernel.apparmor_restrict_unprivileged_userns = 0
UNS
        sysctl_apply
      }
    else
      info "to disable it globally anyway: POPLAB_DISABLE_USERNS_RESTRICTION=1 sudo ./bin/poplab apply --aggressive --only 90"
    fi
  else
    info "kernel.apparmor_restrict_unprivileged_userns=$userns"
  fi
  return 0
}
main "$@"
