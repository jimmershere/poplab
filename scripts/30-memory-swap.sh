#!/usr/bin/env bash
# 30-memory-swap.sh — zram, reclaim behaviour and writeback bounds.
#
# The load-bearing insight: with zram, "swappiness=10" is actively wrong. A zram
# swap-in is a memcpy plus an lz4/zstd decompress — cheaper than re-reading a
# header from NVMe. Low swappiness makes the kernel throw away your build's page
# cache instead of compressing an idle Electron heap, so the next tsc/cargo run
# re-reads everything from disk.
# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
  poplab_detect
  head1 "30 · memory, zram & reclaim"
  is_apply && require_root

  head2 "zram swap"
  local have_zram=0
  swapon --noheadings --show=NAME 2>/dev/null | grep -q zram && have_zram=1

  if [[ -f /etc/default/pop-zram ]]; then
    # Pop!_OS ships its own zram unit (pop-default-settings-zram). Tune it in
    # place rather than fighting it with systemd-zram-generator.
    info "Pop!_OS pop-zram detected — configuring it rather than installing a second zram stack"
    local size=$(( HW_MEM_GB * 1024 / 2 ))     # 50% of RAM, compressed
    [[ "$size" -lt 4096 ]] && size=4096
    write_file /etc/default/pop-zram 0644 <<ZRAM
# Managed by poplab. Original backed up under /var/lib/poplab/backups.
# PORTION is a percentage of RAM; MAX_SIZE caps the resulting device in MiB.
# zstd gives ~3-4x on dev workloads (heaps, JS strings, model metadata) for a
# few percent of one core. page-cluster is forced to 0 for zstd by pop-zram-config.
MAX_SIZE=${size}
PORTION=50
ALGO=zstd
SWAPPINESS=150
ZRAM
    run systemctl restart pop-default-settings-zram.service || true
  elif [[ "$have_zram" == "1" ]]; then
    skip "zram already active and not Pop-managed — leaving the existing device alone"
  else
    info "no zram found; installing systemd-zram-generator"
    if pkg_available systemd-zram-generator; then
      ensure_pkgs systemd-zram-generator
      write_file /etc/systemd/zram-generator.conf 0644 <<ZGEN
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 1000
fs-type = swap
ZGEN
      systemd_reload
      run systemctl start systemd-zram-setup@zram0.service || true
    else
      warn "systemd-zram-generator not available in apt; falling back to a hand-rolled unit"
      write_file /etc/systemd/system/poplab-zram.service 0644 <<'ZUNIT'
[Unit]
Description=poplab: compressed swap in RAM
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe zram
ExecStart=/bin/bash -c 'zramctl --find --algorithm zstd --size $(( $(awk "/MemTotal/{print \$2}" /proc/meminfo) / 2 ))KiB > /run/poplab-zram && mkswap $(cat /run/poplab-zram) && swapon --priority 1000 $(cat /run/poplab-zram)'
ExecStop=/bin/bash -c 'swapoff $(cat /run/poplab-zram) && zramctl --reset $(cat /run/poplab-zram)'
[Install]
WantedBy=multi-user.target
ZUNIT
      systemd_reload
      run systemctl enable --now poplab-zram.service || true
    fi
  fi

  head2 "VM sysctls"
  # Dirty limits: use *_bytes, not *_ratio. On 32 GiB the ratio defaults let ~6 GiB
  # of dirty pages accumulate before a writer is throttled — that stall lands on
  # you at git-checkout / docker-build-commit / sqlite-fsync time.
  # NOTE: dirty_bytes and dirty_ratio are mutually exclusive; writing one zeroes
  # the other, so we set only the byte forms.
  write_file /etc/sysctl.d/99-poplab-vm.conf 0644 <<'SYSCTL'
# poplab — VM tuning for a 32 GiB zram-backed AI/dev workstation.

# --- reclaim (assumes zram is the primary swap device) ---
# Kernel docs: range is 0-200; values above 100 are sanctioned for in-memory swap.
vm.swappiness = 150
# Swap readahead exists to amortise disk seeks. zram has none; every extra page
# is a wasted decompress.
vm.page-cluster = 0
# Retain dentry/inode slabs. `git status` on a large tree is a dentry benchmark,
# and node_modules is hundreds of thousands of tiny files.
vm.vfs_cache_pressure = 50
# Wake kswapd early so allocations hit *background* reclaim. Direct reclaim is a
# synchronous stall in your process — it is what "the desktop froze" actually is.
vm.watermark_scale_factor = 125
# Disable fragmentation-triggered extra reclaim; it fires spuriously under heavy
# container churn and we are on THP=madvise anyway.
vm.watermark_boost_factor = 0
# Headroom for GFP_ATOMIC during NVMe + network + bridge bursts.
vm.min_free_kbytes = 262144

# --- writeback, PCIe 4.0 NVMe ---
vm.dirty_background_bytes = 268435456
vm.dirty_bytes = 1610612736
vm.dirty_expire_centisecs = 1500
vm.dirty_writeback_centisecs = 500

# --- address space ---
# Electron/VS Code, Chromium, the JVM, PyTorch allocators, Wine/Proton.
# ~200 bytes of kernel memory per VMA, allocated only on use.
vm.max_map_count = 1048576
# 0 = heuristic. Do not set 2: it breaks fork()-heavy tooling and interacts badly
# with zram, whose capacity counts toward CommitLimit while consuming RAM.
vm.overcommit_memory = 0
SYSCTL

  sysctl_apply

  head2 "transparent huge pages"
  local thp; thp="$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo '?')"
  case "$thp" in
    madvise) skip "THP=madvise (correct: ML allocators can still ask for huge pages, khugepaged does not tax everything else)" ;;
    always)
      warn "THP=always inflates RSS across dozens of containers and causes compaction stalls; switching to madvise"
      if is_apply; then echo madvise > /sys/kernel/mm/transparent_hugepage/enabled; fi
      write_file /etc/systemd/system/poplab-thp.service 0644 <<'THP'
[Unit]
Description=poplab: set transparent hugepages to madvise
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled'
[Install]
WantedBy=multi-user.target
THP
      systemd_reload
      run systemctl enable --now poplab-thp.service || true
      ;;
    never) warn "THP=never blocks ML allocators that legitimately want huge pages; consider madvise" ;;
  esac

  head2 "verify"
  info "swappiness=$(sysctl_get vm.swappiness) page-cluster=$(sysctl_get vm.page-cluster) dirty_bytes=$(sysctl_get vm.dirty_bytes)"
  swapon --show 2>/dev/null | sed 's/^/    /' || true
  return 0
}
main "$@"
