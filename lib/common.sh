#!/usr/bin/env bash
# poplab/lib/common.sh — shared primitives for every poplab script.
#
# Contract every module script honours:
#   * Read-only unless POPLAB_APPLY=1 (or --apply). Default is DRY-RUN.
#   * Every mutation of an existing file takes a timestamped backup first.
#   * Every mutation is recorded in the run manifest so `poplab rollback` can undo it.
#   * Every module is idempotent: running it twice changes nothing the second time.
#
# shellcheck shell=bash

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------- constants --
POPLAB_VERSION="1.0.0"
export POPLAB_VERSION
POPLAB_ROOT="${POPLAB_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
POPLAB_STATE_DIR="${POPLAB_STATE_DIR:-/var/lib/poplab}"
POPLAB_BACKUP_ROOT="${POPLAB_BACKUP_ROOT:-$POPLAB_STATE_DIR/backups}"
POPLAB_REPORT_DIR="${POPLAB_REPORT_DIR:-$POPLAB_STATE_DIR/reports}"
POPLAB_RUN_ID="${POPLAB_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
POPLAB_MANIFEST="${POPLAB_MANIFEST:-$POPLAB_BACKUP_ROOT/$POPLAB_RUN_ID/manifest.tsv}"

# Behaviour flags (all overridable by env or the poplab dispatcher).
POPLAB_APPLY="${POPLAB_APPLY:-0}"          # 1 = actually change things
POPLAB_YES="${POPLAB_YES:-0}"              # 1 = never prompt
POPLAB_AGGRESSIVE="${POPLAB_AGGRESSIVE:-0}" # 1 = allow risky modules (ryzenadj, userns)
POPLAB_QUIET="${POPLAB_QUIET:-0}"

# ------------------------------------------------------------------ colours --
if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  C_RST=$'\033[0m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_CYN=$'\033[36m'
else
  C_RST=""; C_DIM=""; C_BLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""
fi

# Cross-process tally (defined before logging because warn/err use it).
POPLAB_TALLY="${POPLAB_TALLY:-}"
tally() { [[ -n "$POPLAB_TALLY" ]] && printf '%s\n' "$1" >> "$POPLAB_TALLY"; return 0; }

# ------------------------------------------------------------------ logging --
log()   { [[ "$POPLAB_QUIET" == "1" ]] || printf '%s\n' "$*"; }
info()  { log "${C_BLU}  ·${C_RST} $*"; }
ok()    { log "${C_GRN}  ✔${C_RST} $*"; }
warn()  { tally warn; log "${C_YEL}  ▲${C_RST} $*" >&2; }
err()   { tally fail; log "${C_RED}  ✘${C_RST} $*" >&2; }
skip()  { log "${C_DIM}  ~ $* (already correct)${C_RST}"; }
die()   { err "$*"; exit 1; }
head1() { log ""; log "${C_BLD}${C_CYN}══ $* ${C_RST}"; }
head2() { log ""; log "${C_BLD}$*${C_RST}"; }
dry()   { log "${C_YEL}  [dry-run]${C_RST} $*"; }

# Counters used by the audit scorer and the apply summary.
POPLAB_N_OK=0; POPLAB_N_WARN=0; POPLAB_N_FAIL=0; POPLAB_N_CHANGED=0; POPLAB_N_SKIP=0
# (tally() is defined above the logging helpers, since warn/err call it.)

check_ok()   { POPLAB_N_OK=$((POPLAB_N_OK+1));     tally ok;   ok "$*"; }
check_warn() { POPLAB_N_WARN=$((POPLAB_N_WARN+1)); warn "$*"; }
check_fail() { POPLAB_N_FAIL=$((POPLAB_N_FAIL+1)); err "$*"; }

# ------------------------------------------------------------------- guards --
is_apply() { [[ "$POPLAB_APPLY" == "1" ]]; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "this action needs root — re-run with sudo"
  fi
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || return 1
  done
  return 0
}

confirm() {
  local prompt="$1"
  [[ "$POPLAB_YES" == "1" ]] && return 0
  [[ -t 0 ]] || { warn "not a tty and --yes not given; refusing: $prompt"; return 1; }
  local reply
  read -r -p "${C_YEL}?${C_RST} $prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Hard stop for anything that could brick the box unless the operator opted in.
require_aggressive() {
  if [[ "$POPLAB_AGGRESSIVE" != "1" ]]; then
    warn "skipping '$*' — needs --aggressive"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- inventory --
# Populate globals once; every module reuses them.
poplab_detect() {
  HW_CPU_MODEL="$(awk -F: '/^model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)"
  HW_CPU_CORES="$(nproc 2>/dev/null || echo 0)"
  HW_MEM_KB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  HW_MEM_GB=$(( HW_MEM_KB / 1024 / 1024 ))
  HW_KERNEL="$(uname -r)"
  HW_ARCH="$(uname -m)"

  OS_ID="$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")"
  OS_NAME="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  OS_VERSION_ID="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-unknown}")"
  OS_CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}")"

  IS_POP=0; [[ "$OS_ID" == "pop" ]] && IS_POP=1

  # Boot mechanism: Pop!_OS UEFI = systemd-boot + kernelstub; BIOS = GRUB.
  BOOT_MODE="unknown"
  if [[ -d /sys/firmware/efi ]]; then BOOT_MODE="uefi"; else BOOT_MODE="bios"; fi
  BOOT_TOOL="none"
  if [[ "$BOOT_MODE" == "uefi" ]] && require_cmd kernelstub; then
    BOOT_TOOL="kernelstub"
  elif require_cmd update-grub || require_cmd grub-mkconfig; then
    BOOT_TOOL="grub"
  fi

  # Root block device (strip partition suffix) — used for NVMe/scheduler work.
  ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || echo '')"
  ROOT_FSTYPE="$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)"
  ROOT_OPTS="$(findmnt -no OPTIONS / 2>/dev/null || echo '')"
  ROOT_DISK=""
  if [[ -n "$ROOT_SRC" ]]; then
    ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 || true)"
    # For LUKS/LVM, walk up to the physical disk.
    if [[ -z "$ROOT_DISK" ]]; then
      ROOT_DISK="$(lsblk -nso NAME "$ROOT_SRC" 2>/dev/null | tail -n1 || true)"
    fi
  fi
  NVME_DEVS=()
  local d
  while IFS= read -r d; do [[ -n "$d" ]] && NVME_DEVS+=("$d"); done < <(ls /dev/nvme?n? 2>/dev/null || true)

  # CPU vendor / AMD specifics
  CPU_VENDOR="$(awk -F: '/^vendor_id/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)"
  IS_AMD=0; [[ "$CPU_VENDOR" == "AuthenticAMD" ]] && IS_AMD=1
  PSTATE_STATUS="$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || echo 'n/a')"
  SCALING_DRIVER="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo 'n/a')"
  SCALING_GOV="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'n/a')"
  EPP_NOW="$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo 'n/a')"

  # GPU
  GPU_LINE="$(lspci -nn 2>/dev/null | grep -iE 'VGA|Display|3D' | head -n1 || echo '')"
  GFX_TARGET="$( { rocminfo 2>/dev/null || true; } | grep -om1 'gfx[0-9a-f]\+' || echo 'unknown')"
  AMDGPU_LOADED=0; lsmod 2>/dev/null | grep -q '^amdgpu' && AMDGPU_LOADED=1

  export HW_CPU_MODEL HW_CPU_CORES HW_MEM_KB HW_MEM_GB HW_KERNEL HW_ARCH
  export OS_ID OS_NAME OS_VERSION_ID OS_CODENAME IS_POP BOOT_MODE BOOT_TOOL
  export ROOT_SRC ROOT_FSTYPE ROOT_OPTS ROOT_DISK CPU_VENDOR IS_AMD
  export PSTATE_STATUS SCALING_DRIVER SCALING_GOV EPP_NOW GPU_LINE GFX_TARGET AMDGPU_LOADED
}

# ------------------------------------------------------- backup + manifest --
_manifest_init() {
  is_apply || return 0
  mkdir -p "$(dirname "$POPLAB_MANIFEST")"
  [[ -f "$POPLAB_MANIFEST" ]] || printf 'action\ttarget\tbackup\n' > "$POPLAB_MANIFEST"
}

_manifest_add() { # action target backup
  is_apply || return 0
  _manifest_init
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$POPLAB_MANIFEST"
}

backup_file() {
  local target="$1"
  is_apply || return 0
  [[ -e "$target" ]] || { _manifest_add CREATED "$target" ""; return 0; }
  local dest="$POPLAB_BACKUP_ROOT/$POPLAB_RUN_ID/files$target"
  mkdir -p "$(dirname "$dest")"
  cp -a -- "$target" "$dest"
  _manifest_add MODIFIED "$target" "$dest"
}

# ------------------------------------------------------- file write helpers --
# write_file <path> <mode> <<'EOF' ... EOF
# Idempotent: no-op (and no backup) when content already matches byte-for-byte.
write_file() {
  local path="$1" mode="${2:-0644}" content
  content="$(cat)"
  if [[ -f "$path" ]] && [[ "$(cat -- "$path")" == "$content" ]]; then
    skip "$path"
    POPLAB_N_SKIP=$((POPLAB_N_SKIP+1)); tally skip
    return 0
  fi
  if ! is_apply; then
    tally planned
    dry "write $path (mode $mode, $(printf '%s' "$content" | wc -l) lines)"
    if [[ -f "$path" ]]; then
      dry "  diff vs current:"
      diff -u --label "current:$path" --label "poplab:$path" \
        "$path" <(printf '%s\n' "$content") 2>/dev/null | sed 's/^/      /' | head -40 || true
    fi
    return 0
  fi
  backup_file "$path"
  mkdir -p -- "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod "$mode" -- "$path"
  ok "wrote $path"
  POPLAB_N_CHANGED=$((POPLAB_N_CHANGED+1)); tally changed
}

remove_file() {
  local path="$1"
  [[ -e "$path" ]] || { skip "absent: $path"; return 0; }
  if ! is_apply; then dry "remove $path"; return 0; fi
  backup_file "$path"
  rm -f -- "$path"
  ok "removed $path"
  POPLAB_N_CHANGED=$((POPLAB_N_CHANGED+1)); tally changed
}

# run: execute a mutating command, honouring dry-run.
# A failure is REPORTED but does not abort the module — tuning is a sequence of
# independent best-effort steps, and one unavailable unit should not stop the
# other twenty from being applied. Failures show up in the summary count.
run() {
  if ! is_apply; then tally planned; dry "$*"; return 0; fi
  info "\$ $*"
  local rc=0
  "$@" || rc=$?
  if [[ "$rc" -eq 0 ]]; then tally changed; else err "command failed (rc=$rc): $*"; fi
  return 0
}

# run_strict: same, but propagates failure. Use when later steps depend on it.
run_strict() {
  if ! is_apply; then tally planned; dry "$*"; return 0; fi
  info "\$ $*"
  "$@"
}

# ------------------------------------------------------------ kernel params --
# Pop!_OS UEFI installs use systemd-boot driven by kernelstub. `update-grub`
# is a no-op there. This wrapper picks the right mechanism at runtime.
kernel_cmdline_has() { grep -qw -- "$1" /proc/cmdline; }

kernel_param_add() {
  local param="$1"
  local key="${param%%=*}"
  if kernel_cmdline_has "$param"; then
    skip "kernel param $param (active this boot)"
    return 0
  fi
  case "$BOOT_TOOL" in
    kernelstub)
      # kernelstub stores options in /etc/kernelstub/configuration
      if grep -q -- "\"$param\"" /etc/kernelstub/configuration 2>/dev/null; then
        skip "kernel param $param (already staged, pending reboot)"
        return 0
      fi
      backup_file /etc/kernelstub/configuration
      run kernelstub --add-options "$param"
      POPLAB_REBOOT_NEEDED=1
      ;;
    grub)
      local f=/etc/default/grub
      if grep -q -- "$param" "$f" 2>/dev/null; then skip "kernel param $param"; return 0; fi
      backup_file "$f"
      if ! is_apply; then dry "append '$param' to GRUB_CMDLINE_LINUX_DEFAULT in $f && update-grub"; return 0; fi
      sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 $param\"/" "$f"
      run update-grub
      POPLAB_REBOOT_NEEDED=1
      ;;
    *)
      warn "no supported bootloader tool found; add '$param' to the kernel cmdline by hand (key=$key)"
      return 1
      ;;
  esac
}

kernel_param_del() {
  local param="$1"
  case "$BOOT_TOOL" in
    kernelstub)
      grep -q -- "\"$param\"" /etc/kernelstub/configuration 2>/dev/null || { skip "kernel param $param not set"; return 0; }
      backup_file /etc/kernelstub/configuration
      run kernelstub --delete-options "$param"
      POPLAB_REBOOT_NEEDED=1
      ;;
    grub)
      backup_file /etc/default/grub
      if ! is_apply; then dry "strip '$param' from /etc/default/grub && update-grub"; return 0; fi
      sed -i "s/ *$param//" /etc/default/grub
      run update-grub
      POPLAB_REBOOT_NEEDED=1
      ;;
  esac
}

# ------------------------------------------------------------------ sysctl --
sysctl_get() { sysctl -n "$1" 2>/dev/null || echo ''; }

sysctl_apply() {
  if ! is_apply; then dry "sysctl --system"; return 0; fi
  # sysctl --system returns non-zero if ANY key in ANY drop-in on the system is
  # unknown (a stale third-party file, a module not loaded yet). That must not
  # abort our module, so we report rather than propagate.
  local out rc=0
  out="$(sysctl --system 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok "sysctl --system reloaded"
  else
    warn "sysctl --system reported errors (usually unrelated pre-existing drop-ins):"
    printf '%s\n' "$out" | grep -i 'cannot\|No such\|Invalid' | sed 's/^/      /' | head -10 || true
  fi
  # Confirm OUR keys actually landed.
  local k
  for k in "$@"; do
    info "  $k = $(sysctl -n "$k" 2>/dev/null || echo '<unset>')"
  done
  return 0
}

# ------------------------------------------------------------------ apt ------
pkg_installed() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -q '^installed$'; }

pkg_available() { apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [^(]'; }

ensure_pkgs() {
  local missing=() p
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  if [[ ${#missing[@]} -eq 0 ]]; then skip "packages present: $*"; return 0; fi
  if ! is_apply; then dry "apt-get install -y ${missing[*]}"; return 0; fi
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

# ------------------------------------------------------------------ systemd --
systemd_reload() { run systemctl daemon-reload; }

unit_exists()  { systemctl list-unit-files "$1" >/dev/null 2>&1 && systemctl cat "$1" >/dev/null 2>&1; }
unit_active()  { systemctl is-active --quiet "$1" 2>/dev/null; }
unit_enabled() { [[ "$(systemctl is-enabled "$1" 2>/dev/null || echo no)" == "enabled" ]]; }

# ------------------------------------------------------------------ report ---
POPLAB_REBOOT_NEEDED="${POPLAB_REBOOT_NEEDED:-0}"

poplab_summary() {
  head2 "Summary"
  if [[ -n "$POPLAB_TALLY" && -f "$POPLAB_TALLY" ]]; then
    local c
    for c in planned changed skip warn fail; do
      printf -v "POPLAB_T_$c" '%s' "$(grep -cx "$c" "$POPLAB_TALLY" || true)"
    done
    if is_apply; then
      log "  changed=${POPLAB_T_changed:-0}  unchanged=${POPLAB_T_skip:-0}  warnings=${POPLAB_T_warn:-0}  failures=${POPLAB_T_fail:-0}"
    else
      log "  would change=${POPLAB_T_planned:-0}  already correct=${POPLAB_T_skip:-0}  warnings=${POPLAB_T_warn:-0}"
    fi
  else
    log "  ok=${POPLAB_N_OK}  warn=${POPLAB_N_WARN}  fail=${POPLAB_N_FAIL}  changed=${POPLAB_N_CHANGED}  unchanged=${POPLAB_N_SKIP}"
  fi
  if ! is_apply; then
    log "  ${C_YEL}DRY RUN — nothing was modified. Re-run with --apply to commit.${C_RST}"
  else
    log "  backups + manifest: ${POPLAB_BACKUP_ROOT}/${POPLAB_RUN_ID}"
    [[ "$POPLAB_REBOOT_NEEDED" == "1" ]] && log "  ${C_YEL}reboot required for kernel cmdline / limit changes${C_RST}"
  fi
}
