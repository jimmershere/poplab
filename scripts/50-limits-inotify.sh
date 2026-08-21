#!/usr/bin/env bash
# 50-limits-inotify.sh — inotify, file descriptors, memlock, cgroup delegation.
#
# Three independent mechanisms govern limits and you need all three:
#   /etc/systemd/system.conf.d/  -> system services (dockerd, containerd, sshd)
#   /etc/systemd/user.conf.d/    -> user@$UID.service, the parent of your ENTIRE
#                                   graphical session. Setting only system.conf
#                                   leaves your actual terminal at soft 1024.
#   /etc/security/limits.d/      -> PAM logins (ssh, tty). systemd services never
#                                   consult limits.conf at all.
# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

INOTIFY_CONF='# poplab — file watching for large monorepos.
# max_user_watches: 1048576 is the kernel'"'"'s own ceiling (a ceiling, not a
#   reservation — ~1.3 KB of kernel memory per watch, allocated on use).
# max_user_instances: the default of 128 is the one that actually bites. Every
#   VS Code window, JetBrains IDE, watchman, chokidar, tsc --watch, cargo-watch,
#   dockerd and systemd takes an instance. ENOSPC from inotify_init() surfaces as
#   a confusing generic error in most tools.
# max_queued_events: on overflow the kernel emits IN_Q_OVERFLOW and SILENTLY
#   DROPS events. That is why hot-reload dies after a git checkout or npm install.
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
fs.inotify.max_queued_events = 524288'

main() {
  poplab_detect
  head1 "50 · inotify, ulimits & cgroup delegation"
  is_apply && require_root

  head2 "inotify"
  write_file /etc/sysctl.d/99-poplab-inotify.conf 0644 <<<"$INOTIFY_CONF"

  # sysctl.d files apply in lexical order across directories, so 99- beats 30-.
  # But the desktop-indexer package's postinst re-runs systemd-sysctl on its own
  # file unconditionally, clobbering us mid-session. A same-named file in /etc
  # masks the one in /usr/lib entirely.
  local tf
  for tf in /usr/lib/sysctl.d/30-tracker.conf /usr/lib/sysctl.d/30-localsearch.conf; do
    [[ -f "$tf" ]] || continue
    warn "$tf lowers max_user_watches on package upgrade; shadowing it"
    info "  it currently sets: $(grep -h inotify "$tf" | tr '\n' ' ')"
    write_file "/etc/sysctl.d/$(basename "$tf")" 0644 <<<"$INOTIFY_CONF"
  done
  sysctl_apply

  head2 "systemd limits (system manager)"
  # fs.nr_open defaults to 1048576 and caps any RLIMIT_NOFILE hard limit. Asking
  # for more than that makes units fail to start, so we stay at the ceiling.
  write_file /etc/systemd/system.conf.d/90-poplab-limits.conf 0644 <<'LIMITS'
[Manager]
DefaultLimitNOFILE=1048576:1048576
DefaultLimitNPROC=131072:131072
# llama.cpp --mlock, io_uring registered buffers and pinned host memory all
# charge against RLIMIT_MEMLOCK, whose default is a few MB.
DefaultLimitMEMLOCK=infinity
# Stop a crashing 20 GB-RSS inference process from dumping core to the SSD.
DefaultLimitCORE=0
LIMITS

  head2 "systemd limits (user manager — this is the one people miss)"
  write_file /etc/systemd/user.conf.d/90-poplab-limits.conf 0644 <<'ULIMITS'
[Manager]
DefaultLimitNOFILE=1048576:1048576
DefaultLimitNPROC=131072:131072
DefaultLimitMEMLOCK=infinity
ULIMITS

  head2 "PAM limits (ssh / tty logins)"
  write_file /etc/security/limits.d/90-poplab.conf 0644 <<'PAM'
# limits.conf wildcards do not cover root; list it explicitly.
*     soft  nofile   1048576
*     hard  nofile   1048576
*     soft  nproc    131072
*     hard  nproc    131072
*     soft  memlock  unlimited
*     hard  memlock  unlimited
root  soft  nofile   1048576
root  hard  nofile   1048576
root  soft  memlock  unlimited
root  hard  memlock  unlimited
PAM

  head2 "cgroup v2 controller delegation"
  # Without this, rootless containers get no memory/cpu accounting at all.
  write_file /etc/systemd/system/user@.service.d/delegate.conf 0644 <<'DELEGATE'
[Service]
Delegate=cpu cpuset io memory pids
DELEGATE

  systemd_reload
  run systemctl daemon-reexec
  warn "ulimit changes require a fresh login session (or a reboot) to be visible"

  head2 "verify (values below are for THIS shell — check again after re-login)"
  info "nofile soft/hard: $(ulimit -Sn)/$(ulimit -Hn)   memlock: $(ulimit -Sl 2>/dev/null || echo ?)"
  info "inotify watches=$(sysctl_get fs.inotify.max_user_watches) instances=$(sysctl_get fs.inotify.max_user_instances) queued=$(sysctl_get fs.inotify.max_queued_events)"
  return 0
}
main "$@"
