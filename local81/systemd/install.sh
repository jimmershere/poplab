#!/usr/bin/env bash
# local81/systemd/install.sh — install (or remove) the nightly repo-sync timer.
#
#   install.sh                 dry run: print exactly what would change
#   install.sh --apply         commit the changes
#   install.sh --uninstall     dry run of the removal
#   install.sh --uninstall --apply   stop, disable and delete both units
#
# What it does, in order:
#   1. Sanity-check that a user systemd instance is actually reachable.
#   2. Copy poplab-repo-sync.{service,timer} into ~/.config/systemd/user/.
#   3. systemctl --user daemon-reload
#   4. systemctl --user enable --now poplab-repo-sync.timer
#   5. Print `systemctl --user list-timers` and the linger advice.
#
# USER UNITS, NOT SYSTEM UNITS.
# The nightly job pushes to GitHub, which needs the user's own gh token
# (~/.config/gh/hosts.yml) and SSH key / agent socket. A system unit runs as
# root: different $HOME, no gh auth, no $SSH_AUTH_SOCK, every push fails. This
# is the kind of thing that wastes an hour, so it is written down here and in
# the unit files themselves.
#
# LINGERING IS YOUR CALL, NOT THIS SCRIPT'S.
# A user manager is normally torn down when the last session for that user
# ends, and started again at the next login — so a user timer does not fire on
# a machine sitting at the login screen. To make it run without a logged-in
# session:
#     loginctl enable-linger jimmer
# That keeps a user manager alive from boot to shutdown for that account. It is
# a standing change to how the machine behaves, so this script reports the
# current state and prints the command; it never runs it for you.
# Undo with: loginctl disable-linger jimmer
#
# Flags:
#   --apply       make changes (default is read-only, per poplab CLAUDE.md rule 1)
#   --uninstall   remove instead of install
#   --unit-dir D  override ~/.config/systemd/user
#   -h, --help
set -o errexit -o nounset -o pipefail

APPLY=0
UNINSTALL=0
SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNITS=(poplab-repo-sync.service poplab-repo-sync.timer)
TIMER="poplab-repo-sync.timer"
SERVICE="poplab-repo-sync.service"
LINGER_USER="$(id -un)"

usage() { sed -n '2,38p' "$0" | sed 's/^# \?//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --unit-dir) UNIT_DIR="${2:?--unit-dir needs a path}"; shift ;;
    -h|--help) usage ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\033[0m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_CYN=$'\033[36m'
else
  C_RST=""; C_DIM=""; C_BLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""
fi
info() { printf '%s\n' "${C_BLU}  ·${C_RST} $*"; }
ok()   { printf '%s\n' "${C_GRN}  ✔${C_RST} $*"; }
warn() { printf '%s\n' "${C_YEL}  ▲${C_RST} $*" >&2; }
err()  { printf '%s\n' "${C_RED}  ✘${C_RST} $*" >&2; }
skip() { printf '%s\n' "${C_DIM}  ~ $* (already correct)${C_RST}"; }
dry()  { printf '%s\n' "${C_YEL}  [dry-run]${C_RST} $*"; }
head1(){ printf '\n%s\n' "${C_BLD}${C_CYN}══ $* ${C_RST}"; }
die()  { err "$*"; exit 1; }

N_FAIL=0
fail() { err "$*"; N_FAIL=$((N_FAIL+1)); }

# ---------------------------------------------------------------------------
# Is there a user systemd instance to talk to? Over `ssh host` without linger
# there usually is not, and `systemctl --user` then fails with "Failed to
# connect to bus" — which is the same symptom as a broken unit and is worth
# distinguishing up front.
check_user_bus() {
  local rt="${XDG_RUNTIME_DIR:-}"
  if [[ -z "$rt" ]]; then
    warn "XDG_RUNTIME_DIR is unset — this is not a normal login session"
  fi
  if systemctl --user is-system-running >/dev/null 2>&1; then
    ok "user systemd instance reachable ($(systemctl --user is-system-running 2>/dev/null || true))"
    return 0
  fi
  # is-system-running exits non-zero for "degraded", which is still reachable.
  if systemctl --user show-environment >/dev/null 2>&1; then
    ok "user systemd instance reachable (degraded or starting)"
    return 0
  fi
  warn "cannot reach a user systemd instance (\$DBUS_SESSION_BUS_ADDRESS / \$XDG_RUNTIME_DIR)"
  warn "run this from a graphical or console login on the machine itself, not a bare ssh"
  return 1
}

# Idempotent copy: byte-for-byte compare first, mirroring lib/common.sh's
# write_file contract (CLAUDE.md rule 2).
install_unit() {
  local name="$1"
  local src="$SRC_DIR/$name"
  local dst="$UNIT_DIR/$name"
  [[ -f "$src" ]] || { fail "missing source unit: $src"; return 0; }
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    skip "$dst"
    return 0
  fi
  if (( APPLY )); then
    install -D -m 0644 "$src" "$dst"
    ok "installed $dst"
  else
    if [[ -f "$dst" ]]; then
      dry "overwrite $dst  (differs from $src)"
      if command -v diff >/dev/null 2>&1; then
        diff -u "$dst" "$src" | sed 's|^|        |' || true
      fi
    else
      dry "install -m 0644 $src $dst"
    fi
  fi
  return 0
}

remove_unit() {
  local name="$1"
  local dst="$UNIT_DIR/$name"
  if [[ ! -e "$dst" ]]; then
    skip "$dst absent"
    return 0
  fi
  if (( APPLY )); then
    rm -f "$dst"
    ok "removed $dst"
  else
    dry "rm -f $dst"
  fi
  return 0
}

run_systemctl() {
  local desc="$1"; shift
  if (( APPLY )); then
    if systemctl --user "$@"; then
      ok "$desc"
    else
      fail "$desc — systemctl --user $* failed"
    fi
  else
    dry "systemctl --user $*   ($desc)"
  fi
  return 0
}

# Same, but a non-zero exit is expected and not counted. Used on teardown,
# where stopping/disabling an already-absent unit is success, not failure.
soft_systemctl() {
  local desc="$1"; shift
  if (( APPLY )); then
    if systemctl --user "$@" >/dev/null 2>&1; then
      ok "$desc"
    else
      skip "$desc — nothing to do"
    fi
  else
    dry "systemctl --user $*   ($desc)"
  fi
  return 0
}

report_linger() {
  local state="unknown"
  if command -v loginctl >/dev/null 2>&1; then
    state="$(loginctl show-user "$LINGER_USER" --property=Linger --value 2>/dev/null || echo unknown)"
  fi
  head1 "lingering — your decision, not this script's"
  case "$state" in
    yes)
      ok "linger is already enabled for $LINGER_USER; the timer runs without a login session"
      ;;
    no)
      warn "linger is OFF for $LINGER_USER"
      info "the timer only fires while $LINGER_USER has a session; at the login"
      info "screen, or after a logout, the user manager is gone and 02:30 passes"
      info "unnoticed (Persistent=true then catches it at the next login)."
      info "to make it run regardless, run this yourself:"
      printf '%s\n' "        ${C_BLD}loginctl enable-linger $LINGER_USER${C_RST}"
      info "undo with: loginctl disable-linger $LINGER_USER"
      ;;
    *)
      warn "could not determine linger state for $LINGER_USER"
      info "check with: loginctl show-user $LINGER_USER --property=Linger"
      info "enable with: loginctl enable-linger $LINGER_USER"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
if (( UNINSTALL )); then
  head1 "uninstall — nightly repo-sync timer"
  check_user_bus || warn "continuing; file removal does not need the bus"
  soft_systemctl "timer stopped"      stop    "$TIMER"
  soft_systemctl "timer disabled"     disable "$TIMER"
  for u in "${UNITS[@]}"; do remove_unit "$u"; done
  run_systemctl  "unit files reloaded" daemon-reload
  soft_systemctl "failed-state reset"  reset-failed "$SERVICE"
  printf '\n'
  if (( APPLY )); then
    if (( N_FAIL == 0 )); then
      ok "${C_BLD}uninstalled${C_RST} — no nightly push will run"
    else
      warn "${C_BLD}$N_FAIL step(s) reported an error${C_RST} — check the messages above"
    fi
    info "linger, if you enabled it, is untouched: loginctl disable-linger $LINGER_USER"
  else
    info "dry run — nothing was changed. Re-run with --uninstall --apply to commit."
  fi
  exit "$N_FAIL"
fi

head1 "install — nightly repo-sync timer"
info "source:   $SRC_DIR"
info "target:   $UNIT_DIR"
info "playbook: /app/poplab/local81/playbooks/repo-sync.yml"
info "runs as:  $LINGER_USER   (user unit — needs this account's gh token and SSH key)"

if [[ ! -x /app/poplab/bin/local81 ]]; then
  warn "/app/poplab/bin/local81 is not executable here — the unit hardcodes that path"
fi
if [[ ! -f /app/poplab/local81/playbooks/repo-sync.yml ]]; then
  warn "/app/poplab/local81/playbooks/repo-sync.yml does not exist yet"
  warn "the unit carries ConditionPathExists= for it, so until it lands the timer"
  warn "fires and the service is skipped rather than failing"
fi

head1 "1. user systemd instance"
check_user_bus || die "refusing to install units that cannot be loaded"

head1 "2. unit files"
if (( APPLY )); then mkdir -p "$UNIT_DIR"; else
  [[ -d "$UNIT_DIR" ]] || dry "mkdir -p $UNIT_DIR"
fi
for u in "${UNITS[@]}"; do install_unit "$u"; done

head1 "3. reload and enable"
run_systemctl "unit files reloaded"        daemon-reload
run_systemctl "timer enabled and started"  enable --now "$TIMER"

head1 "4. state"
if (( APPLY )); then
  systemctl --user list-timers "$TIMER" --all --no-pager || true
  printf '\n'
  systemctl --user --no-pager --lines=0 status "$TIMER" 2>/dev/null | sed 's|^|      |' || true
else
  dry "systemctl --user list-timers $TIMER --all"
  info "current timers on this machine, for context:"
  systemctl --user list-timers --all --no-pager 2>/dev/null | sed 's|^|      |' || \
    warn "could not list timers"
fi

report_linger

printf '\n'
if (( N_FAIL == 0 )); then
  if (( APPLY )); then
    ok "${C_BLD}installed${C_RST} — poplab-repo-sync.timer is enabled, nightly at 02:30 (+0-30m jitter)"
    info "next run:   systemctl --user list-timers $TIMER"
    info "fire now:   systemctl --user start $SERVICE"
    info "read logs:  journalctl --user -u $SERVICE -n 200"
    warn "this timer pushes to a PUBLIC repo unattended. repo-guard.sh runs"
    warn "immediately before each push, in the same command; read local81/README.md"
    warn "§ Publishing before you leave it running."
  else
    ok "${C_BLD}dry run clean${C_RST} — nothing was changed"
    info "commit it with: ./local81/systemd/install.sh --apply"
  fi
else
  err "${C_BLD}$N_FAIL step(s) failed${C_RST} — see above"
fi
exit "$N_FAIL"
