#!/usr/bin/env bash
# 10-kernel-params.sh — kernel command line.
# On Pop!_OS UEFI this goes through kernelstub (systemd-boot). `update-grub` is
# a no-op there, which is the #1 reason copy-pasted Ubuntu tuning guides silently
# do nothing on this distro.
# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
  poplab_detect
  head1 "10 · kernel command line  (boot tool: $BOOT_TOOL)"
  is_apply && require_root

  if [[ "$BOOT_TOOL" == "none" ]]; then
    warn "no kernelstub and no GRUB — skipping module"
    return 0
  fi
  [[ "$BOOT_TOOL" == "kernelstub" ]] && info "using kernelstub; config: /etc/kernelstub/configuration"

  head2 "amd_pstate mode"
  if [[ "$IS_AMD" == "1" ]]; then
    # 'active' = EPP/CPPC firmware ramping. Best default. We pin it explicitly so
    # a kernel rebuild with a different CONFIG_X86_AMD_PSTATE_DEFAULT_MODE cannot
    # silently change behaviour under us.
    if [[ "$PSTATE_STATUS" == "active" ]] && ! kernel_cmdline_has amd_pstate=active; then
      info "already active by kernel default; pinning it explicitly anyway"
    fi
    kernel_param_add "amd_pstate=active" || true
  else
    skip "non-AMD CPU"
  fi

  head2 "zswap off (we use zram; stacking them double-compresses)"
  local zsw; zsw="$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo N)"
  if [[ "$zsw" == "Y" ]]; then
    kernel_param_add "zswap.enabled=0" || true
  else
    skip "zswap already disabled"
  fi

  head2 "TTM pool for the iGPU (system memory the GPU may pin)"
  # Units are 4 KiB pages. 16 GiB of 32 = 4194304 pages. Vulkan/RADV can spill
  # into GTT; ROCm/HIP cannot (it sees the BIOS UMA carve-out only).
  # amdgpu.gttsize is deprecated on modern kernels in favour of ttm.pages_limit.
  if [[ "$AMDGPU_LOADED" == "1" ]]; then
    local want_pages=$(( HW_MEM_GB / 2 * 262144 ))   # half of RAM
    [[ "$want_pages" -lt 262144 ]] && want_pages=262144
    kernel_param_add "ttm.pages_limit=${want_pages}" || true
    kernel_param_add "ttm.page_pool_size=${want_pages}" || true
    if grep -q 'amdgpu.gttsize' /proc/cmdline 2>/dev/null; then
      warn "amdgpu.gttsize present on the cmdline and is deprecated; removing"
      kernel_param_del "amdgpu.gttsize" || true
    fi
  else
    skip "no amdgpu"
  fi

  head2 "NVMe APST"
  # Budget consumer/OEM drives frequently mis-implement the deepest APST states
  # and hang minutes after boot during idle. 5500us permits the shallow states
  # (nearly all the battery benefit) and forbids the deep ones.
  if journalctl -k --no-pager -b 2>/dev/null | grep -qiE 'nvme.*(controller is down|will reset|I/O.*timeout|Device not ready)'; then
    warn "NVMe resets seen this boot — capping APST latency"
    kernel_param_add "nvme_core.default_ps_max_latency_us=5500" || true
  else
    info "no NVMe resets observed; leaving APST at the kernel default"
    info "if you ever see an unexplained multi-second I/O freeze, run:"
    info "    sudo ./bin/poplab apply --only 10 --force-apst"
    if [[ "${POPLAB_FORCE_APST:-0}" == "1" ]]; then
      kernel_param_add "nvme_core.default_ps_max_latency_us=5500" || true
    fi
  fi

  head2 "Result"
  if [[ "$BOOT_TOOL" == "kernelstub" ]] && require_cmd kernelstub; then
    kernelstub -p 2>/dev/null | sed 's/^/    /' || true
  fi
  [[ "${POPLAB_REBOOT_NEEDED:-0}" == "1" ]] && warn "reboot required for these to take effect"
  return 0
}
main "$@"
