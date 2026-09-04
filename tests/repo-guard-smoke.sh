#!/usr/bin/env bash
# tests/repo-guard-smoke.sh — the publish gate must fail CLOSED.
#
# Every case here is a way a credential reached a public repo through a gate that
# said CLEAN. They are regressions, not hypotheticals.
set -o errexit -o nounset -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/local81/repo-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

N_FAIL=0
verdict() { NO_COLOR=1 "$GUARD" "$1" --public >/dev/null 2>&1; echo $?; }
want() { # want <dir> <expected-exit> <label>
  local got; got="$(verdict "$1")"
  if [[ "$got" == "$2" ]]; then
    printf '  ok   %s\n' "$3"
  else
    printf '  FAIL %s (exit %s, wanted %s)\n' "$3" "$got" "$2"; N_FAIL=$((N_FAIL+1))
  fi
}

echo "clean baseline"
mkdir -p "$TMP/clean"; printf 'print("hi")\n' > "$TMP/clean/app.py"
want "$TMP/clean" 0 "an ordinary directory is CLEAN"

echo "credentials in the working tree"
mkdir -p "$TMP/plain"; printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n' > "$TMP/plain/deploy.key"
want "$TMP/plain" 1 "private key file BLOCKS"

mkdir -p "$TMP/envfile"; printf 'X=1\n' > "$TMP/envfile/.env"
want "$TMP/envfile" 1 ".env BLOCKS by name"

echo "filenames that break naive pipelines"
mkdir -p "$TMP/ws"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n' > "$TMP/ws/my secret.txt"
want "$TMP/ws" 1 "space in filename still BLOCKS"

mkdir -p "$TMP/nl"
printf -- '-----BEGIN RSA PRIVATE KEY-----\n' > "$TMP/nl/$(printf 'two\nlines').txt"
want "$TMP/nl" 1 "newline in filename still BLOCKS"

echo "git history — a push ships commits, not the working tree"
mk_repo() { # mk_repo <dir>
  mkdir -p "$1"; git -C "$1" init -q -b main
  git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name t
  printf 'harmless\n' > "$1/app.py"; git -C "$1" add -A; git -C "$1" commit -q -m init
}
mk_repo "$TMP/hist"
git clone -q "$TMP/hist" "$TMP/hist-origin"
git -C "$TMP/hist" remote add origin "$TMP/hist-origin"
git -C "$TMP/hist" fetch -q origin
git -C "$TMP/hist" branch -q --set-upstream-to=origin/main main
want "$TMP/hist" 0 "nothing outgoing is CLEAN"

printf 'AWS=AKIAQQQQWWWWEEEERRRR\n' > "$TMP/hist/leak.env"
git -C "$TMP/hist" add -A; git -C "$TMP/hist" commit -q -m oops
git -C "$TMP/hist" rm -q leak.env; git -C "$TMP/hist" commit -q -m "removed the secret"
want "$TMP/hist" 1 "secret committed then DELETED still BLOCKS"

mk_repo "$TMP/fresh"
printf 'tok=ghp_abcdefghijklmnopqrstuvwxyz012345\n' > "$TMP/fresh/c.py"
git -C "$TMP/fresh" add -A; git -C "$TMP/fresh" commit -q -m add
git -C "$TMP/fresh" rm -q c.py; git -C "$TMP/fresh" commit -q -m drop
want "$TMP/fresh" 1 "no upstream: whole history is outgoing, BLOCKS"

echo "review, not block"
mkdir -p "$TMP/pii"; printf 'contact: someone@realdomain.com\n' > "$TMP/pii/roster.md"
want "$TMP/pii" 2 "personal data is REVIEW, not BLOCK"

mkdir -p "$TMP/img"; : > "$TMP/img/headshot.jpg"
want "$TMP/img" 2 "media is REVIEW, not BLOCK"

echo
if (( N_FAIL == 0 )); then echo "ALL REPO-GUARD TESTS PASSED"; else echo "$N_FAIL FAILURE(S)"; fi
exit "$N_FAIL"
