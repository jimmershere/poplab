#!/usr/bin/env bash
# tests/smoke.sh — CI smoke tests. Must pass on any Linux, including containers
# with no systemd, no AMD hardware and no NVMe.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FAIL=0
t() { local name="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  ok   %s\n' "$name"
  else printf '  FAIL %s\n' "$name"; FAIL=$((FAIL+1)); fi
}
tno() { local name="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  FAIL %s (expected non-zero)\n' "$name"; FAIL=$((FAIL+1))
  else printf '  ok   %s\n' "$name"; fi
}

echo "syntax"
for f in bin/poplab lib/common.sh scripts/*.sh; do t "bash -n $f" bash -n "$f"; done

echo "lint"
if command -v shellcheck >/dev/null; then
  t "shellcheck" shellcheck -x -S warning bin/poplab lib/common.sh scripts/*.sh
else
  echo "  skip shellcheck (not installed)"
fi

echo "executables"
for f in bin/poplab scripts/*.sh; do t "$f is executable" test -x "$f"; done

echo "read-only guarantees"
BEFORE="$(find /etc /var/lib/poplab /usr/local -newermt '-1 second' 2>/dev/null | wc -l)"
t "audit exits 0"        env NO_COLOR=1 ./bin/poplab audit
t "plan exits 0"         env NO_COLOR=1 ./bin/poplab plan --yes
t "plan --aggressive"    env NO_COLOR=1 ./bin/poplab plan --yes --aggressive
tno "no state dir created" test -d /var/lib/poplab
tno "no sysctl file written" test -e /etc/sysctl.d/99-poplab-vm.conf
tno "no limits file written" test -e /etc/security/limits.d/90-poplab.conf
tno "no udev rule written"   test -e /etc/udev/rules.d/60-ioschedulers.rules

echo "dispatcher"
t   "help"                    env NO_COLOR=1 ./bin/poplab --help
tno "unknown command rejected" env NO_COLOR=1 ./bin/poplab bogus-command
t   "--only filters"          bash -c 'NO_COLOR=1 ./bin/poplab plan --only 30 --yes | grep -q "30 · memory"'
tno "--skip filters"          bash -c 'NO_COLOR=1 ./bin/poplab plan --skip 30 --yes | grep -q "30 · memory"'

echo "docs"
for d in README.md CLAUDE.md docs/research/01-pop-os-24.04.md docs/research/02-ryzen-6800h-radeon-680m.md docs/research/03-memory-io-dev.md local81/README.md; do
  t "$d exists" test -s "$d"
done

echo
if [[ "$FAIL" -eq 0 ]]; then echo "ALL SMOKE TESTS PASSED"; else echo "$FAIL FAILURE(S)"; fi
exit "$FAIL"
