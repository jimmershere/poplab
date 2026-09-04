#!/usr/bin/env bash
# local81/bootstrap-fleet.sh — one-shot enrolment of the pop-os + quasimodo pair.
#
#   bootstrap-fleet.sh                 dry run: print exactly what would change
#   bootstrap-fleet.sh --apply         commit the changes
#
# Steps, in order:
#   1. Ensure an ed25519 automation key exists on the controller (this machine).
#   2. Discover which account answers on quasimodo, using the password in
#      ~/quasi.env for that ONE exchange only.
#   3. Install the public key there, so password auth is never needed again.
#   4. Install a NOPASSWD sudoers drop-in on quasimodo (validated by visudo -cf).
#   5. Install the same drop-in here on pop-os (prompts once for the local password).
#   6. Create the /app workspace on quasimodo, owned by the fleet user.
#   7. Write a ~/.ssh/config stanza so `ssh quasimodo` just works.
#   8. Verify every one of the above and print a summary.
#
# Flags:
#   --apply            make changes (default is read-only, per poplab CLAUDE.md rule 1)
#   --user NAME        skip discovery; use this account on quasimodo
#   --host ADDR        override the default 192.168.0.20
#   --env-file PATH    override ~/quasi.env
#   --no-sudoers       skip steps 4 and 5
#   --no-local-sudoers skip step 5 only (remote NOPASSWD still installed)
set -o errexit -o nounset -o pipefail

APPLY=0; FLEET_USER=""; QHOST=""; QNAME="quasimodo"
QHOST_MDNS="quasimodo.local"; QHOST_LAN="192.168.0.20"
ENV_FILE="${HOME}/quasi.env"; DO_SUDOERS=1; DO_LOCAL_SUDOERS=1
KEY="${HOME}/.ssh/id_ed25519"
SUDOERS_FILE="/etc/sudoers.d/90-poplab-nopasswd"
CANDIDATES=(jimmer jimbro)

usage() { sed -n '2,26p' "$0" | sed 's/^# \?//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --user) FLEET_USER="$2"; shift ;;
    --host) QHOST="$2"; shift ;;
    --env-file) ENV_FILE="$2"; shift ;;
    --no-sudoers) DO_SUDOERS=0 ;;
    --no-local-sudoers) DO_LOCAL_SUDOERS=0 ;;
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

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o CheckHostIP=no -o ConnectTimeout=10 -o NumberOfPasswordPrompts=1)
ASKPASS=""
cleanup() { [[ -n "$ASKPASS" && -f "$ASKPASS" ]] && rm -f "$ASKPASS"; return 0; }
trap cleanup EXIT

# ------------------------------------------------------------------ step 1 --
head1 "1. controller automation key"
if [[ -f "$KEY" ]]; then
  skip "$KEY exists"
else
  if (( APPLY )); then
    ssh-keygen -t ed25519 -N '' -C "$(whoami)@$(hostname) fleet-automation" -f "$KEY" >/dev/null
    ok "generated $KEY"
  else
    dry "ssh-keygen -t ed25519 -N '' -f $KEY"
  fi
fi
if [[ -f "$KEY.pub" ]]; then info "fingerprint: $(ssh-keygen -lf "$KEY.pub" | awk '{print $2}')"; fi

# ----------------------------------------------------------------- step 1b --
# The fleet roams (Traverse City, and wherever next), so the LAN address is not a
# stable identity. mDNS follows the laptop between networks; the pinned host key
# is what actually proves the machine on the other end is quasimodo and not
# whatever else answered on a strange network.
head1 "1b. locate $QNAME and pin its identity"
if [[ -z "$QHOST" ]]; then
  if getent hosts "$QHOST_MDNS" >/dev/null 2>&1; then
    QHOST="$QHOST_MDNS"
    ok "resolved $QHOST_MDNS -> $(getent hosts "$QHOST_MDNS" | awk '{print $1}') (mDNS — survives a network change)"
  else
    QHOST="$QHOST_LAN"
    warn "$QHOST_MDNS did not resolve; falling back to the literal $QHOST_LAN"
    warn "that address is only correct on the home LAN — off it, pass --host"
  fi
fi

if ssh-keygen -F "$QHOST" >/dev/null 2>&1; then
  skip "host key for $QHOST already pinned in known_hosts"
elif (( APPLY )); then
  if ssh-keyscan -T 8 -t ed25519,rsa "$QHOST" 2>/dev/null >> "$HOME/.ssh/known_hosts"; then
    ok "pinned the host key for $QHOST"
    info "verify this against the machine itself:"
    ssh-keyscan -T 8 -t ed25519 "$QHOST" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | sed 's/^/      /'
  else
    fail "could not fetch a host key from $QHOST"
  fi
else
  dry "ssh-keyscan $QHOST >> ~/.ssh/known_hosts   (trust-on-first-use — do this on a network you trust)"
fi

# ------------------------------------------------------------------ step 2 --
# The password is read from a file into an askpass helper. It is never placed on
# a command line, never exported into the environment, and never printed.
head1 "2. discover the account on $QNAME ($QHOST)"

password_available=0
if [[ -r "$ENV_FILE" ]]; then
  ASKPASS="$(mktemp)"; chmod 700 "$ASKPASS"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'exec tr -d "\\r\\n" < %q\n' "$ENV_FILE"
  } > "$ASKPASS"
  password_available=1
  info "using credential from $ENV_FILE (one exchange only, then keys take over)"
else
  warn "$ENV_FILE not readable — will fall back to an interactive prompt"
fi

key_works() { ssh "${SSH_OPTS[@]}" -o PreferredAuthentications=publickey -i "$KEY" "$1@$QHOST" true 2>/dev/null; }

pw_ssh() { # pw_ssh user -- cmd...
  local u="$1"; shift; [[ "${1:-}" == "--" ]] && shift
  if (( password_available )); then
    SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
      ssh -o StrictHostKeyChecking=yes -o CheckHostIP=no -o ConnectTimeout=10 \
          -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=password \
          -o PubkeyAuthentication=no "$u@$QHOST" "$@"
  else
    ssh -o StrictHostKeyChecking=yes -o CheckHostIP=no -o ConnectTimeout=10 \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no "$u@$QHOST" "$@"
  fi
}

if [[ -z "$FLEET_USER" ]]; then
  for u in "${CANDIDATES[@]}"; do
    if key_works "$u"; then FLEET_USER="$u"; ok "key already trusted for $u@$QHOST"; break; fi
    if pw_ssh "$u" -- true >/dev/null 2>&1; then FLEET_USER="$u"; ok "password accepted for $u@$QHOST"; break; fi
    info "$u@$QHOST — no"
  done
fi
[[ -z "$FLEET_USER" ]] && die "could not authenticate as any of: ${CANDIDATES[*]}. Re-run with --user NAME."
info "fleet user on $QNAME: ${C_BLD}$FLEET_USER${C_RST}"

# ------------------------------------------------------------------ step 3 --
head1 "3. install the public key on $QNAME"
if key_works "$FLEET_USER"; then
  skip "key auth to $FLEET_USER@$QHOST already works"
elif (( APPLY )); then
  if (( password_available )); then
    SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
      ssh-copy-id -o StrictHostKeyChecking=yes -o CheckHostIP=no -o NumberOfPasswordPrompts=1 \
                  -i "$KEY.pub" "$FLEET_USER@$QHOST" >/dev/null 2>&1 \
      || die "ssh-copy-id failed"
  else
    ssh-copy-id -o StrictHostKeyChecking=yes -o CheckHostIP=no -i "$KEY.pub" "$FLEET_USER@$QHOST" >/dev/null
  fi
  key_works "$FLEET_USER" && ok "key auth established" || die "key installed but auth still fails"
else
  dry "ssh-copy-id -i $KEY.pub $FLEET_USER@$QHOST"
fi

# ------------------------------------------------------------------ steps 4/5 --
SUDOERS_LINE="$FLEET_USER ALL=(ALL) NOPASSWD: ALL"
SUDOERS_BODY="# Installed by poplab local81/bootstrap-fleet.sh
# Grants passwordless sudo so Local81 playbooks can run unattended.
# Remove this file to revert: sudo rm $SUDOERS_FILE
$SUDOERS_LINE"

install_sudoers_remote() {
  ssh "${SSH_OPTS[@]}" -i "$KEY" "$FLEET_USER@$QHOST" \
    "sudo -n true 2>/dev/null && echo ALREADY || echo NEEDPW" 2>/dev/null
}

if (( DO_SUDOERS )); then
  head1 "4. passwordless sudo on $QNAME"
  state="$(install_sudoers_remote || echo UNREACHABLE)"
  if [[ "$state" == ALREADY ]]; then
    skip "sudo -n already works for $FLEET_USER@$QHOST"
  elif (( APPLY )); then
    # visudo -cf validates BEFORE the file lands in /etc/sudoers.d, so a typo
    # can never lock the account out of sudo.
    if (( password_available )); then
      # SSH_ASKPASS authenticates the ssh *client*; it gives remote sudo nothing.
      # And a single stdin stream does not work either — the remote `cat` drains
      # it to EOF before `sudo -S` ever reads. So: step 3 has already installed
      # the key, so connect with the key, and send the password as the FIRST LINE
      # of stdin for the remote to consume with `read` before `cat` takes the rest.
      REMOTE_SUDOERS_INSTALL="
        IFS= read -r PW
        umask 077; cat > /tmp/.poplab-sudoers
        printf '%s\n' \"\$PW\" | sudo -S -p '' visudo -cf /tmp/.poplab-sudoers >/dev/null 2>&1 || { rm -f /tmp/.poplab-sudoers; echo VISUDO_REJECTED >&2; exit 3; }
        printf '%s\n' \"\$PW\" | sudo -S -p '' install -o root -g root -m 0440 /tmp/.poplab-sudoers $SUDOERS_FILE
        rc=\$?; unset PW; rm -f /tmp/.poplab-sudoers; exit \$rc"
      if { tr -d '\r\n' < "$ENV_FILE"; printf '\n%s\n' "$SUDOERS_BODY"; } \
           | ssh "${SSH_OPTS[@]}" -i "$KEY" "$FLEET_USER@$QHOST" "$REMOTE_SUDOERS_INSTALL" 2>/dev/null; then
        ok "installed $SUDOERS_FILE on $QNAME"
      else
        rc=$?
        if (( rc == 3 )); then
          fail "visudo rejected the drop-in on $QNAME — nothing was installed"
        else
          fail "could not install sudoers on $QNAME (wrong password in $ENV_FILE, or $FLEET_USER is not a sudoer)"
        fi
        warn "run this on $QNAME yourself instead:"
        printf '%s\n' "      echo '$SUDOERS_LINE' | sudo tee $SUDOERS_FILE && sudo chmod 0440 $SUDOERS_FILE"
      fi
    else
      warn "no credential available; run this on $QNAME yourself:"
      printf '%s\n' "      echo '$SUDOERS_LINE' | sudo tee $SUDOERS_FILE && sudo chmod 0440 $SUDOERS_FILE"
    fi
  else
    dry "install $SUDOERS_FILE on $QNAME containing: $SUDOERS_LINE"
  fi

  if (( DO_LOCAL_SUDOERS )); then
    head1 "5. passwordless sudo on $(hostname)"
    if sudo -n true 2>/dev/null; then
      skip "sudo -n already works locally"
    elif (( APPLY )); then
      warn "this is the ONE place you will be asked for your local password"
      tmp="$(mktemp)"; printf '%s\n' "$SUDOERS_BODY" > "$tmp"
      if sudo visudo -cf "$tmp" >/dev/null; then
        sudo install -o root -g root -m 0440 "$tmp" "$SUDOERS_FILE" \
          && ok "installed $SUDOERS_FILE locally" || fail "local sudoers install failed"
      else
        fail "visudo rejected the drop-in — nothing was installed"
      fi
      rm -f "$tmp"
    else
      dry "install $SUDOERS_FILE locally containing: $SUDOERS_LINE"
    fi
  fi
fi

# ----------------------------------------------------------------- step 5b --
head1 "5b. /app workspace on $(hostname)"
# The venture layout is FLAT under /app — that is the convention already in use on
# quasimodo (/app/portwright-studio, /app/AU2, /app/fantasys), so the workspace
# docs land at /app/CLAUDE.md rather than under an umbrella folder.
# --ignore-existing: this never overwrites a file that is already there.
STAGING="$HOME/portwright-staging"
if [[ ! -d "$STAGING" ]]; then
  skip "no staging tree at $STAGING — nothing to place"
elif (( APPLY )); then
  if [[ ! -w /app ]]; then
    sudo -n chown "$(id -un):$(id -gn)" /app 2>/dev/null || sudo chown "$(id -un):$(id -gn)" /app
    ok "/app is now writable by $(id -un) (the directory itself; contents untouched)"
  fi
  rsync -a --ignore-existing "$STAGING"/ /app/
  ok "placed the workspace docs into /app (existing files left alone)"
  info "staging kept at $STAGING — remove it once you have checked /app"
else
  dry "chown $(id -un) /app   (currently $(stat -c '%U:%G' /app))"
  dry "rsync -a --ignore-existing $STAGING/ /app/   — places:"
  find "$STAGING" -mindepth 1 -maxdepth 1 -printf '        /app/%P\n' | sort
fi

# ------------------------------------------------------------------ step 6 --
head1 "6. /app workspace on $QNAME"
if ssh "${SSH_OPTS[@]}" -i "$KEY" "$FLEET_USER@$QHOST" "test -w /app" 2>/dev/null; then
  skip "/app exists and is writable by $FLEET_USER"
elif (( APPLY )); then
  ssh "${SSH_OPTS[@]}" -i "$KEY" "$FLEET_USER@$QHOST" \
    "sudo -n mkdir -p /app && sudo -n chown $FLEET_USER:$FLEET_USER /app" \
    && ok "/app created and chowned to $FLEET_USER" \
    || fail "/app setup failed (needs step 4 to have succeeded)"
else
  dry "mkdir -p /app && chown $FLEET_USER:$FLEET_USER /app on $QNAME"
fi

# ------------------------------------------------------------------ step 7 --
head1 "7. ssh config stanza"
# CheckHostIP=no is the roaming setting: verify the key against the NAME, not the
# address, so quasimodo moving from 192.168.0.20 to a Traverse City DHCP lease is
# not mistaken for a man-in-the-middle.
STANZA="Host $QNAME
    HostName $QHOST_MDNS
    User $FLEET_USER
    IdentityFile $KEY
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    CheckHostIP no
    ServerAliveInterval 30
    ServerAliveCountMax 4

# Fallback for a network with no mDNS. Override the address with:
#   ssh -o HostName=<addr> quasimodo-lan
Host quasimodo-lan
    HostName $QHOST_LAN
    User $FLEET_USER
    IdentityFile $KEY
    IdentitiesOnly yes
    CheckHostIP no"
CFG="$HOME/.ssh/config"
if [[ -f "$CFG" ]] && grep -qE "^Host .*\b$QNAME\b" "$CFG"; then
  skip "$CFG already has a $QNAME stanza"
elif (( APPLY )); then
  touch "$CFG"; chmod 600 "$CFG"
  { [[ -s "$CFG" ]] && printf '\n'; printf '# poplab fleet — added by local81/bootstrap-fleet.sh\n%s\n' "$STANZA"; } >> "$CFG"
  ok "appended $QNAME stanza to $CFG"
else
  dry "append to $CFG:"; printf '%s\n' "${C_DIM}$STANZA${C_RST}"
fi

# ------------------------------------------------------------------ step 8 --
head1 "8. verify"
if (( APPLY )); then
  key_works "$FLEET_USER" && ok "ssh key auth" || fail "ssh key auth"
  ssh "${SSH_OPTS[@]}" -i "$KEY" "$FLEET_USER@$QHOST" "sudo -n true" 2>/dev/null \
    && ok "passwordless sudo on $QNAME" || fail "passwordless sudo on $QNAME"
  ssh "${SSH_OPTS[@]}" -i "$KEY" "$FLEET_USER@$QHOST" "test -w /app" 2>/dev/null \
    && ok "/app writable on $QNAME" || fail "/app writable on $QNAME"
  sudo -n true 2>/dev/null && ok "passwordless sudo on $(hostname)" || fail "passwordless sudo on $(hostname)"
  command -v rsync >/dev/null && ssh "${SSH_OPTS[@]}" -i "$KEY" "$FLEET_USER@$QHOST" "command -v rsync >/dev/null" 2>/dev/null \
    && ok "rsync present on both ends" || warn "rsync missing on one end — Local81 sync tasks will fail"
else
  info "dry run — nothing was changed. Re-run with --apply to commit."
fi

printf '\n'
if (( N_FAIL == 0 )); then
  if (( APPLY )); then
    ok "${C_BLD}fleet bootstrap complete: $QNAME enrolled as $FLEET_USER${C_RST}"
  else
    ok "${C_BLD}dry run clean — target account on $QNAME is $FLEET_USER${C_RST}"
    info "commit it with: ./local81/bootstrap-fleet.sh --apply"
  fi
  if (( APPLY )); then info "next: bin/local81 run local81/playbooks/fleet-audit.yml"; fi
else
  err "${C_BLD}$N_FAIL step(s) failed${C_RST} — see above"
fi
exit "$N_FAIL"
