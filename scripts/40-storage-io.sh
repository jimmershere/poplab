#!/usr/bin/env bash
# 40-storage-io.sh — NVMe scheduler, TRIM, mount options, tmpfs scratch.
# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
  poplab_detect
  head1 "40 · storage & I/O"
  is_apply && require_root

  head2 "I/O scheduler"
  # DEVTYPE=="disk" guard matters: a bare nvme* match also hits partitions, which
  # have no queue/ directory, and spams the boot log with ENOENT.
  write_file /etc/udev/rules.d/60-ioschedulers.rules 0644 <<'UDEV'
# poplab — NVMe has deep hardware queues and no seek cost; software reordering
# only adds CPU and latency. mq-deadline is for SATA SSDs, bfq for spinning rust.
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="nvme*", ATTR{queue/scheduler}="none"
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
UDEV
  run udevadm control --reload
  run udevadm trigger --subsystem-match=block

  # LUKS/LVM: the dm-* device has its own queue.
  local dm
  for dm in /sys/block/dm-*; do
    [[ -e "$dm/queue/scheduler" ]] || continue
    info "$(basename "$dm") scheduler: $(cat "$dm/queue/scheduler")"
  done

  head2 "periodic TRIM"
  # Inline `discard` makes many controllers drain outstanding I/O before servicing
  # the TRIM, which is an unpredictable latency spike — intolerable on a box doing
  # continuous container-layer churn. Use the timer instead.
  ensure_pkgs util-linux
  run systemctl enable --now fstrim.timer
  write_file /etc/systemd/system/fstrim.service.d/10-poplab.conf 0644 <<'FSTRIM'
# Keep the weekly trim from stuttering an active build.
[Service]
IOSchedulingClass=idle
Nice=19
FSTRIM
  systemd_reload

  if grep -qs 'discard' /etc/fstab; then
    warn "/etc/fstab contains an inline 'discard' mount option — remove it in favour of fstrim.timer"
    grep -n discard /etc/fstab | sed 's/^/    /' || true
  fi
  if [[ -f /etc/crypttab ]] && grep -qs '^[^#]' /etc/crypttab; then
    if grep -q 'discard' /etc/crypttab; then
      info "crypttab passes discard through dm-crypt — TRIM reaches the drive"
    else
      warn "LUKS detected without 'discard' in /etc/crypttab: TRIM never reaches the SSD."
      warn "Adding it has a documented, mild confidentiality trade-off (reveals which blocks are unused)."
      warn "poplab will not change this for you — decide and edit /etc/crypttab yourself, then run update-initramfs -u."
    fi
  fi

  head2 "root mount options"
  case "$ROOT_OPTS" in
    *noatime*) skip "root already noatime" ;;
    *)
      warn "root is not mounted noatime."
      info "relatime still writes one atime update per file per day; across a 400k-file node_modules that is real journal traffic for zero benefit."
      info "poplab does not rewrite /etc/fstab automatically — a bad edit there costs you a boot."
      info "Suggested root line options:  defaults,noatime,lazytime,errors=remount-ro"
      info "Current: $ROOT_OPTS"
      ;;
  esac
  if grep -qsE 'nobarrier|barrier=0' /etc/fstab; then
    err "nobarrier/barrier=0 found in /etc/fstab — this can corrupt the filesystem on power loss. Remove it."
  fi

  head2 "tmpfs build scratch"
  # Ubuntu 24.04 does not default /tmp to tmpfs (24.10+ does). Build intermediates
  # on tmpfs avoid SSD wear and are much faster — but some toolchains dump
  # multi-GB there, so we cap it rather than letting it eat RAM.
  if unit_active tmp.mount; then
    skip "/tmp already tmpfs"
  else
    local cap=$(( HW_MEM_GB / 4 ))
    [[ "$cap" -lt 2 ]] && cap=2
    write_file /etc/systemd/system/tmp.mount.d/10-poplab.conf 0644 <<TMPC
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=${cap}G
TMPC
    info "enabling tmp.mount with a ${cap}G cap"
    info "audit first if any of your toolchains write multi-GB intermediates to /tmp"
    if confirm "enable tmpfs /tmp capped at ${cap}G?"; then
      systemd_reload
      run systemctl enable tmp.mount
      warn "takes effect on next boot"
    else
      info "left /tmp on disk"
    fi
  fi

  head2 "SMART / thermal tooling"
  ensure_pkgs nvme-cli smartmontools

  head2 "verify"
  local d
  for d in /sys/block/nvme*n*; do
    [[ -e "$d/queue/scheduler" ]] || continue
    info "$(basename "$d"): scheduler=$(cat "$d/queue/scheduler") read_ahead_kb=$(cat "$d/queue/read_ahead_kb")"
  done
  return 0
}
main "$@"
