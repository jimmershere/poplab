#!/usr/bin/env bash
# 70-gpu-ai.sh — local inference on a Radeon 680M (gfx1035).
#
# Reality check, so the script does not oversell itself:
#   * gfx1035 has NEVER been an officially supported ROCm target. ROCm 6.x can be
#     coaxed via HSA_OVERRIDE_GFX_VERSION=10.3.0 (masquerade as gfx1030). ROCm
#     7.x dropped gfx1030 from its target list, so the override is expected to
#     stop working there — pin 6.4.x if you want HIP at all.
#   * ROCm/HSA allocates from VRAM (the BIOS UMA carve-out), NOT from GTT. Vulkan
#     via RADV *can* use GTT. On a machine whose BIOS offers no large UMA option,
#     Vulkan is the only usable GPU path.
#   * Token generation on this part is bound by DDR5-5600 dual-channel bandwidth
#     — the same memory the CPU uses. Expect prefill/prompt processing to improve
#     a lot on GPU and decode to be roughly a wash vs 8 CPU threads. Benchmark,
#     do not assume.
# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
  poplab_detect
  head1 "70 · GPU & local inference"
  is_apply && require_root

  if [[ "$AMDGPU_LOADED" != "1" ]]; then
    warn "amdgpu not loaded — skipping module"
    return 0
  fi
  info "GPU: ${GPU_LINE:-unknown}"
  info "ISA: ${GFX_TARGET} (Radeon 680M = gfx1035)"

  head2 "device access"
  ensure_pkgs mesa-vulkan-drivers vulkan-tools libdrm-amdgpu1 clinfo
  pkg_available radeontop && ensure_pkgs radeontop || true
  local target_user="${SUDO_USER:-${USER:-}}"
  if [[ -n "$target_user" && "$target_user" != "root" ]]; then
    if id -nG "$target_user" | grep -qw render && id -nG "$target_user" | grep -qw video; then
      skip "$target_user already in render+video"
    else
      run usermod -aG render,video "$target_user"
      warn "log out and back in for the new groups to apply"
    fi
  fi
  [[ -e /dev/kfd ]] && ok "/dev/kfd present" || warn "/dev/kfd absent — no HIP compute queue"

  head2 "memory ceilings"
  local vram gtt
  vram="$(cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | head -n1 || echo 0)"
  gtt="$(cat /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -n1 || echo 0)"
  info "VRAM (BIOS UMA carve-out): $(( vram / 1024 / 1024 )) MiB   <- hard ceiling for ROCm/HIP"
  info "GTT  (system memory pool): $(( gtt  / 1024 / 1024 )) MiB   <- usable by Vulkan/RADV"
  if [[ $(( vram / 1024 / 1024 )) -lt 3072 ]]; then
    warn "UMA carve-out is under 3 GiB."
    warn "ACTION FOR YOU (poplab cannot do this — it is a firmware setting):"
    warn "  reboot into BIOS/UEFI, find the iGPU / UMA Frame Buffer setting, switch it"
    warn "  from AUTO to UMA_SPECIFIED, and give it 4-8 GB. Many NIMO/Tongfang-class"
    warn "  boards expose this under Advanced > AMD CBS > NBIO or Chipset."
    warn "  If your firmware has no such option, use the Vulkan backend and skip ROCm."
  fi
  info "ttm.pages_limit is set by module 10 (kernel cmdline); currently: $(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo n/a) pages"

  head2 "llama.cpp environment profile"
  write_file /etc/profile.d/poplab-ai.sh 0644 <<'PROFILE'
# poplab — local inference defaults for a Radeon 680M (gfx1035) APU.
# gfx1035 is not an official ROCm target; 10.3.0 makes it present as gfx1030.
# This is a no-op for the Vulkan backend, which is usually the better choice here.
export HSA_OVERRIDE_GFX_VERSION=10.3.0
# APUs report a single agent; being explicit avoids ROCm picking the CPU agent.
export ROCR_VISIBLE_DEVICES=0
# Keep the CPU fallback on physical cores, not SMT threads — hyperthread pairs
# contend for the same FP units and memory ports, so -t 16 is usually slower.
export LLAMA_ARG_THREADS=8
PROFILE

  head2 "ollama"
  if require_cmd ollama; then
    write_file /etc/systemd/system/ollama.service.d/10-poplab.conf 0644 <<'OLLAMA'
[Service]
Environment="HSA_OVERRIDE_GFX_VERSION=10.3.0"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_KEEP_ALIVE=30m"
# Uncomment if you hit SDMA-related hangs on an APU:
# Environment="HSA_ENABLE_SDMA=0"
OLLAMA
    systemd_reload
    run systemctl restart ollama || true
  else
    skip "ollama not installed"
  fi

  head2 "benchmark harness"
  # The honest answer to "ROCm or Vulkan or CPU?" on this part is: measure it.
  write_file /usr/local/bin/poplab-bench-llm 0755 <<'BENCH'
#!/usr/bin/env bash
# poplab-bench-llm — compare llama.cpp backends on this machine.
# usage: poplab-bench-llm /path/to/model.gguf
# Requires llama-bench from llama.cpp (build the Vulkan and/or HIP variants).
set -uo pipefail
model="${1:-}"
[[ -f "$model" ]] || { echo "usage: poplab-bench-llm <model.gguf>" >&2; exit 64; }
run_one() {
  local label="$1"; shift
  echo "── $label ──"
  if ! command -v "$1" >/dev/null 2>&1; then echo "   (binary '$1' not found, skipping)"; return; fi
  "$@" -m "$model" -p 512 -n 128 -r 3 2>&1 | tail -n 8
  echo
}
echo "model: $model"
echo "cpu:   $(awk -F: '/^model name/{print $2; exit}' /proc/cpuinfo)"
echo "mem:   $(awk '/MemTotal/{printf "%.0f GiB\n", $2/1048576}' /proc/meminfo)"
echo
run_one "CPU (8 physical threads)" llama-bench -t 8 -ngl 0
run_one "Vulkan (RADV, can use GTT)" llama-bench-vulkan -ngl 99
HSA_OVERRIDE_GFX_VERSION=10.3.0 run_one "ROCm/HIP (VRAM-limited)" llama-bench-hip -ngl 99
cat <<'NOTE'
Reading the numbers:
  pp512 = prompt processing (compute-bound)  -> GPU should win clearly
  tg128 = token generation  (bandwidth-bound) -> often a wash vs CPU on an APU
If tg128 is not better on GPU, run inference on CPU and keep the GPU free for
the compositor and video encode. That is a legitimate outcome on Rembrandt.
NOTE
BENCH

  head2 "notes"
  info "ROCm/HIP install (only if your BIOS gives a large UMA carve-out):"
  info "  amdgpu-install --usecase=rocm --no-dkms   # pin 6.4.x; kernel $HW_KERNEL far outruns amdgpu-dkms"
  info "llama.cpp Vulkan build:  cmake -B build -DGGML_VULKAN=ON && cmake --build build -j"
  info "Then benchmark:          poplab-bench-llm /path/to/model.gguf"
  return 0
}
main "$@"
