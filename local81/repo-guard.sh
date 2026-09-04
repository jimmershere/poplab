#!/usr/bin/env bash
# local81/repo-guard.sh — decide whether a directory is safe to publish.
#
#   repo-guard.sh <dir> [--public|--private] [--quiet]
#
# Exit 0  clean          nothing found; safe to push
# Exit 1  BLOCK          a credential or private key is present — never publish
# Exit 2  REVIEW         personal data or media that a human must look at first
#
# This is the gate in front of every `git push` the fleet performs. It exists
# because a public repo is not reversible: forks, caches and scrapers keep a copy
# long after a delete. A nightly job that pushes without this check would publish
# whatever got committed during the day, at 3am, with nobody watching.
#
# It is deliberately noisy rather than clever. False positives cost you a look;
# a false negative costs you a leaked key.
set -o errexit -o nounset -o pipefail

DIR="${1:-}"; shift || true
VIS="private"; QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --public) VIS="public" ;;
    --private) VIS="private" ;;
    --quiet) QUIET=1 ;;
    *) echo "unknown flag: $1" >&2; exit 64 ;;
  esac
  shift
done
[[ -d "$DIR" ]] || { echo "repo-guard: not a directory: $DIR" >&2; exit 64; }

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\033[0m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
else C_RST=""; C_BLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; fi
say()  { (( QUIET )) || printf '%s\n' "$*"; }
ok()   { say "${C_GRN}  ✔${C_RST} $*"; }
warn() { say "${C_YEL}  ▲${C_RST} $*"; }
bad()  { say "${C_RED}  ✘${C_RST} $*"; }
head1(){ say ""; say "${C_BLD}${C_CYN}══ $* ${C_RST}"; }

BLOCK=0; REVIEW=0

# Skip VCS internals and dependency trees — noise, not signal.
PRUNE=( -name .git -o -name node_modules -o -name .venv -o -name vendor -o -name __pycache__ )

# This script necessarily CONTAINS the token patterns it hunts for, so scanning
# itself always "finds" credentials. Exclude it by realpath, plus anything listed
# in an optional .repo-guard-ignore (one path or glob per line, # for comments).
SELF="$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
IGNORE_FILE="$DIR/.repo-guard-ignore"
excluded() {
  local f; f="$(realpath -- "$1" 2>/dev/null || echo "$1")"
  [[ "$f" == "$SELF" ]] && return 0
  # The exclusion list is configuration for this scanner, not shippable content,
  # and naming what it excludes tends to mean naming credential shapes.
  [[ "$f" == "$(realpath -- "$IGNORE_FILE" 2>/dev/null || echo "$IGNORE_FILE")" ]] && return 0
  [[ -f "$IGNORE_FILE" ]] || return 1
  local pat
  while IFS= read -r pat; do
    [[ -z "$pat" || "$pat" == \#* ]] && continue
    # shellcheck disable=SC2053
    [[ "${f#"$DIR"/}" == $pat || "$f" == *"$pat"* ]] && return 0
  done < "$IGNORE_FILE"
  return 1
}
# NUL-delimited end to end. A newline-delimited pipeline into `xargs` splits
# "my secret.txt" into two nonexistent paths, grep's errors get suppressed, and
# the guard reports CLEAN over a file it never opened.
findf() {
  local f
  while IFS= read -r -d '' f; do
    excluded "$f" || printf '%s\0' "$f"
  done < <(find "$DIR" \( "${PRUNE[@]}" \) -prune -o -type f "$@" -print0 2>/dev/null)
}
countf() { tr -cd '\0' | wc -c; }

head1 "credentials  (publishing these is unrecoverable)"
# 1. filenames that are secrets by definition
CRED_FILES="$(findf \( -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \
  -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name '.env' -o -name '.env.*' \
  -o -name 'credentials*.json' -o -name 'service-account*.json' -o -name '.netrc' \
  -o -name '*.keystore' -o -name '.htpasswd' \) | tr '\0' '\n' || true)"
if [[ -n "$CRED_FILES" ]]; then
  bad "credential-bearing files present:"
  printf '%s\n' "$CRED_FILES" | sed 's|^|        |'
  BLOCK=$((BLOCK+1))
else ok "no credential files by name"; fi

# 2. private key blocks and provider token shapes, in file contents
PATTERNS='BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk_live_[A-Za-z0-9]{16,}|rk_live_[A-Za-z0-9]{16,}|xox[abposr]-[A-Za-z0-9-]{10,}|-----BEGIN CERTIFICATE-----|AIza[0-9A-Za-z_-]{35}'
HITS="$(findf | xargs -0 -r grep -IlEs "$PATTERNS" 2>/dev/null || true)"
if [[ -n "$HITS" ]]; then
  bad "credential-shaped strings inside:"
  printf '%s\n' "$HITS" | sed 's|^|        |'
  BLOCK=$((BLOCK+1))
else ok "no private keys or provider tokens in contents"; fi

# 3. assignments that look like real secrets (ignore obvious placeholders)
ASSIGN="$(findf | xargs -0 -r grep -IEnsi \
  '(api[_-]?key|[a-z]+[_-]key|secret|passwd|password|token|client[_-]?secret)[[:space:]]*[:=][[:space:]]*.{8,}' 2>/dev/null \
  | grep -vEi '(your|example|placeholder|changeme|xxx+|<[^>]+>|\$\{|process\.env|os\.environ|getenv|None|null|""|'"''"')' \
  | head -25 || true)"
if [[ -n "$ASSIGN" ]]; then
  warn "hard-coded-looking secret assignments (review each):"
  printf '%s\n' "$ASSIGN" | cut -c1-140 | sed 's|^|        |'
  REVIEW=$((REVIEW+1))
else ok "no hard-coded secret assignments"; fi

head1 "git history  (a push ships commits, not the working tree)"
# The working-tree scan above prunes .git, so a credential committed at 2pm and
# deleted at 4pm leaves a clean tree — and `git push` publishes both commits.
# Scan what would actually go over the wire: every line ADDED by any outgoing
# commit, plus any credential-shaped path that ever appeared in that range.
if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if UP="$(git -C "$DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    RANGE="$UP..HEAD"
  else
    RANGE="HEAD"          # never pushed: every commit is outgoing
  fi
  NC="$(git -C "$DIR" rev-list --count "$RANGE" 2>/dev/null || echo 0)"
  if [[ "$NC" -eq 0 ]]; then
    ok "nothing outgoing to publish"
  else
    say "${C_DIM}        range $RANGE — $NC commit(s)${C_RST}"
    GITADD="$(git -C "$DIR" log -p --no-color --no-textconv "$RANGE" 2>/dev/null \
      | grep '^+' | grep -Es "$PATTERNS" | head -10 || true)"
    GITNAMES="$(git -C "$DIR" log --no-color --name-only --pretty=format: "$RANGE" 2>/dev/null \
      | sort -u | grep -Ev '^$' \
      | grep -Ei '(^|/)(\.env(\..+)?|\.netrc|\.htpasswd|id_rsa.*|id_ed25519.*|credentials.*\.json|service-account.*\.json|.*\.(pem|key|p12|pfx|keystore))$' || true)"
    if [[ -n "$GITADD" ]]; then
      bad "credential-shaped strings ADDED by outgoing commits:"
      printf '%s\n' "$GITADD" | cut -c1-120 | sed 's|^|        |'
      BLOCK=$((BLOCK+1))
    fi
    if [[ -n "$GITNAMES" ]]; then
      bad "credential-bearing paths that appear in outgoing history:"
      printf '%s\n' "$GITNAMES" | sed 's|^|        |'
      BLOCK=$((BLOCK+1))
    fi
    if [[ -z "$GITADD" && -z "$GITNAMES" ]]; then
      ok "outgoing commits carry no credential-shaped content"
    else
      say "${C_DIM}        Deleting the file is not enough — the blob stays reachable.${C_RST}"
      say "${C_DIM}        Rewrite the range or start a fresh history, and rotate the secret.${C_RST}"
    fi
  fi
else
  say "${C_DIM}  ~ not a git work tree — history scan skipped${C_RST}"
fi

head1 "personal data  (someone else's, not yours to publish)"
EMAILS="$(findf | xargs -0 -r grep -IohEs '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 2>/dev/null | sort -u | grep -viE 'example\.(com|org)|@sentry|noreply|@w3\.org|@schema\.org|\.(service|target|socket|timer|mount|scope|slice|local|test|invalid)$' || true)"
NEMAIL=$(printf '%s' "$EMAILS" | grep -c . || true)
PHONES=$(findf | xargs -0 -r grep -IohEs '\(?[0-9]{3}\)?[-. ][0-9]{3}[-. ][0-9]{4}' 2>/dev/null | sort -u | grep -c . || true)
if (( NEMAIL > 0 || PHONES > 0 )); then
  warn "$NEMAIL distinct email address(es), $PHONES phone-shaped string(s)"
  [[ -n "$EMAILS" ]] && printf '%s\n' "$EMAILS" | head -12 | sed 's|^|        |'
  REVIEW=$((REVIEW+1))
else ok "no contact details found"; fi

head1 "media  (photographs of people are personal data)"
IMGS=$(findf \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \
  -o -iname '*.heic' -o -iname '*.mp4' -o -iname '*.mov' \) | countf)
if (( IMGS > 0 )); then
  BYTES=$(findf \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \
    -o -iname '*.heic' -o -iname '*.mp4' -o -iname '*.mov' \) \
    | xargs -0 -r stat -c '%s' 2>/dev/null | awk '{t+=$1} END {printf "%.1f MB", t/1048576}')
  warn "$IMGS image/video file(s), $BYTES total"
  say "${C_DIM}        Do you hold publication rights for every person depicted?${C_RST}"
  say "${C_DIM}        Check EXIF too — phone photos carry GPS coordinates.${C_RST}"
  REVIEW=$((REVIEW+1))
else ok "no image or video files"; fi

head1 "verdict"
say "  directory:  $DIR"
say "  visibility: $VIS"
say "  files:      $(findf | countf)"
if (( BLOCK > 0 )); then
  bad "${C_BLD}BLOCK${C_RST} — credentials present. Do not publish. Remove them, and rotate anything that was already committed."
  exit 1
fi
if (( REVIEW > 0 )); then
  if [[ "$VIS" == "public" ]]; then
    warn "${C_BLD}REVIEW${C_RST} — nothing disqualifying, but a human must approve this before it goes public."
    exit 2
  fi
  warn "${C_BLD}REVIEW${C_RST} — findings above. Acceptable for a private repo."
  exit 2
fi
ok "${C_BLD}CLEAN${C_RST} — safe to publish as $VIS."
exit 0
