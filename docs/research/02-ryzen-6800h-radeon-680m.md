# Ryzen 7 6800H (Rembrandt / Zen3+) + Radeon 680M (gfx1035) on Linux — researched 2026-08-18

Target: NIMO N155, 8c/16t, 45 W nominal, 32 GB DDR5-5600 dual-channel, kernel 6.17+.
Kernel-parameter changes on Pop!_OS go through `kernelstub`, not GRUB.

## A. CPU / power

### amd_pstate
- Check: `cat /sys/devices/system/cpu/amd_pstate/status` → `active|passive|guided|disable`
  `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver` → `amd-pstate-epp` (active) or `amd-pstate`.
- Boot: `amd_pstate=active|passive|guided`. Since ~6.10 the driver auto-loads and takes
  its mode from `CONFIG_X86_AMD_PSTATE_DEFAULT_MODE`; verify with
  `grep AMD_PSTATE /boot/config-$(uname -r)`.
- **Tradeoff on a 45 W part under all-core load:** the limiter is package power and
  skin temperature, not the governor. Expect only a few percent between modes on a
  long compile. `active` (EPP/CPPC firmware ramping) is the right default.

### EPP
- `/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference`
  Values: `default performance balance_performance balance_power power` (active mode
  also accepts raw 0–255 on newer kernels).
- **EPP resets on resume** — persist via a systemd unit wired to
  `WantedBy=multi-user.target suspend.target hibernate.target`, plus a
  `power_supply` udev rule for AC/battery transitions.
- EPP only applies in **active** mode with governor `powersave`. With governor
  `performance`, EPP is forced to `performance`. Note `powersave` under
  `amd-pstate-epp` is *EPP-driven*, not slow.
- Recommendation: AC → `performance`; battery → `balance_power`.

### Governors
- Active mode exposes only `powersave` and `performance`.
- Passive/guided exposes the generic set including `schedutil`.
- Under sustained load `schedutil` and `performance` converge.

### Core performance boost
- amd-pstate gained CPB control in **Linux 6.11**: `/sys/devices/system/cpu/cpufreq/policy*/boost`
  (and a global `boost` node when exported). `cpupower set --turbo-boost 0` also works.
- To cap without disabling boost: write `scaling_max_freq`.

### RyzenAdj on Rembrandt
- https://github.com/FlyGoat/RyzenAdj — build deps `build-essential cmake libpci-dev`.
- **`--stapm-limit` / `--stapm-time` have NO effect on Rembrandt** (platform uses STTv2).
  Effective: `--fast-limit`, `--slow-limit`, `--slow-time`, `--tctl-temp`,
  `--vrm*-current`. `--apu-skin-temp` / `--skin-temp-limit` work only if the OEM
  firmware enabled STTv2. Clock controls (gfxclk/socclk/fclk) are unsupported.
- Power values are in **milliwatts**; temps in °C.
- Needs the `ryzen_smu` module or `/dev/mem`. Kernel lockdown under Secure Boot can
  block it (enroll a MOK, or accept failure).
- **Firmware re-asserts its own values periodically** — ship it as a timer, not a
  one-shot. These are undocumented SMU writes with no safety interlock.

### Thermals / fans
- `k10temp` → `Tctl`; `sensors -j` for structured output.
- **amdgpu exposes no fan on an APU** — laptop fans hang off the embedded controller.
  Try `pwmconfig`/`fancontrol` (usually finds nothing), then
  [nbfc-linux](https://github.com/nbfc-linux/nbfc-linux) (needs `ec_sys write_support=1`
  or `acpi_ec`). If no NBFC config matches the chassis, **there is no fan curve control** —
  the only lever left is producing less heat.

## B. GPU / AI

### ROCm and gfx1035
- **gfx1035 has never been an officially supported ROCm target.** ROCm 6.4 supported
  gfx908/90a/942/1030/1100. ROCm 7.10 preview dropped gfx1030 entirely.
- `HSA_OVERRIDE_GFX_VERSION=10.3.0` (present as gfx1030) **works on ROCm 6.x and is
  expected to break on 7.x** because no gfx1030 code objects ship. Pin 6.4.x for HIP.
- Known breakages: SIGSEGV after prompt with newer ROCm (ollama#12111); amdgpu ring
  resets killing the Wayland session.

### Memory ceilings — the decisive constraint
- **ROCm/HSA allocates from VRAM only — the BIOS UMA carve-out. It does not use GTT.**
  Vulkan/RADV *can* spill into GTT.
- `amdgpu.gttsize` still exists but is **deprecated** on modern kernels; the kernel
  prints a warning and wants `ttm.pages_limit` instead. Units are 4 KiB pages
  (GiB × 262144):
  ```
  sudo kernelstub -a "ttm.pages_limit=4194304" -a "ttm.page_pool_size=4194304"   # 16 GiB
  ```
  Use the plain `ttm.` prefix for the inbox driver; `amdttm.` only applies to `amdgpu-dkms`.
- Verify: `/sys/module/ttm/parameters/pages_limit`,
  `/sys/class/drm/card0/device/mem_info_gtt_total`, `.../mem_info_vram_total`.
- **BIOS:** set UMA_SPECIFIED with a 4–8 GB carve-out if the firmware offers it. If it
  doesn't, HIP is stuck around 512 MB–2 GB and Vulkan is the only usable GPU path.

### Backend choice
Token generation on this part is **bound by DDR5-5600 dual-channel bandwidth**
(~89.6 GB/s theoretical, ~60–70 GB/s real) — the same memory the CPU uses, so GPU
offload cannot beat CPU by much on decode. Prompt/prefill is compute-bound and does
favour the GPU strongly (a 7940HS datapoint: ROCm ≈263 tok/s prefill vs ≈62 CPU;
generation 19.6 vs 14.4).

Practical ranking on a 680M:
1. **Vulkan** (`-DGGML_VULKAN=ON`) — no ROCm install, can use GTT, actively maintained.
2. **ROCm/HIP** — only if you fixed a large UMA carve-out.
3. **CPU** (`-t 8`, physical cores not SMT threads) — a legitimate winner for decode.

⚠️ 680M-specific published numbers are scarce; the figures above are a 7940HS proxy.
**Benchmark on the actual machine** (`poplab-bench-llm`).

### Ollama
```
Environment="HSA_OVERRIDE_GFX_VERSION=10.3.0"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_KEEP_ALIVE=30m"
# HSA_ENABLE_SDMA=0 if you hit hangs
```
Users report it working on a 680M but sometimes **slower than CPU**.

### Packages / groups
```
sudo usermod -aG render,video $USER   # then re-login
sudo apt install mesa-vulkan-drivers vulkan-tools libdrm-amdgpu1 radeontop clinfo
sudo apt install rocm-smi rocminfo    # noble universe, 5.7.0-1 — old but fine for readout
```
Use the **inbox amdgpu** driver; kernel 6.17+ far outruns anything `amdgpu-dkms` targets.
For HIP: `amdgpu-install --usecase=rocm --no-dkms` pinned to 6.4.x.

## C. Media — VCN 3.1
- **H.264 decode+encode, HEVC 8-bit decode+encode, HEVC 10-bit decode, VP9 decode,
  AV1 DECODE ONLY.** AV1 encode requires VCN 4.0 (RDNA3) — not this chip.
- `sudo apt install mesa-va-drivers va-driver-all vainfo ffmpeg`
  (**`libva-drivers-all` is not an Ubuntu package name**; the metapackage is `va-driver-all`.)
- `vainfo --display drm --device /dev/dri/renderD128`; force with `LIBVA_DRIVER_NAME=radeonsi`.
```bash
ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi \
  -i in.mp4 -c:v hevc_vaapi -rc_mode CQP -qp 23 -c:a copy out.mp4
```

## Unverified
Pop's `CONFIG_X86_AMD_PSTATE_DEFAULT_MODE`; whether the NIMO BIOS exposes
UMA_SPECIFIED or enables STTv2; whether an NBFC config exists for this chassis;
680M-specific llama.cpp throughput; whether ROCm 7.x truly refuses `10.3.0`.

## Sources
- https://docs.kernel.org/admin-guide/pm/amd-pstate.html
- https://www.phoronix.com/news/AMD-Core-Perf-Boost-Linux-6.11
- https://github.com/FlyGoat/RyzenAdj · https://github.com/FlyGoat/RyzenAdj/wiki/Supported-Models
- https://github.com/nbfc-linux/nbfc-linux
- https://rocm.docs.amd.com/en/7.10.0-preview/compatibility/compatibility-matrix.html
- https://rocm.docs.amd.com/en/docs-6.4.0/compatibility/compatibility-matrix.html
- https://github.com/ROCm/ROCm/discussions/2932 (680M / gfx1035)
- https://github.com/ollama/ollama/issues/9184 · /issues/12111 · https://docs.ollama.com/gpu
- https://docs.kernel.org/gpu/amdgpu/module-parameters.html
- https://mvysny.github.io/amd-igpu-gtt-llm/ · https://llm-tracker.info/howto/AMD-GPUs
- https://github.com/ggml-org/llama.cpp/discussions/10879 · /15021
- https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/amd/
- https://en.wikipedia.org/wiki/Video_Core_Next · https://packages.ubuntu.com/noble/va-driver-all
