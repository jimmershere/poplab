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
# A dry run must not touch the system. Asserting "these paths do not exist" is
# the wrong proposition: on any host where `sudo ./bin/poplab apply` has
# legitimately run they DO exist, and that is the intended end state for every
# managed machine. What we actually mean is "the dry run did not create or
# change them". Two independent guarantees, both host-independent:
#
#   1. Sandboxed state. Point POPLAB_STATE_DIR at a fresh temp path nothing has
#      ever applied to. `apply` is the only command that mkdirs it, so a dry run
#      must leave it non-existent — true on a virgin box and an applied one alike.
#   2. Unchanged system. Snapshot type/mode/size/mtime(ns) of every path the
#      modules would write, run the dry runs, snapshot again, diff.
#
# Paths below are the write_file targets of scripts/*.sh — keep in sync.
WATCH=(
  /etc/sysctl.d/99-poplab-vm.conf                # 30-memory-swap.sh
  /etc/sysctl.d/99-poplab-inotify.conf           # 50-limits-inotify.sh
  /etc/sysctl.d/60-poplab-userns.conf            # 90-hygiene.sh
  /etc/security/limits.d/90-poplab.conf          # 50-limits-inotify.sh
  /etc/udev/rules.d/60-ioschedulers.rules        # 40-storage-io.sh
  /etc/udev/rules.d/61-poplab-power.rules        # 20-cpu-power.sh
  /etc/systemd/zram-generator.conf               # 30-memory-swap.sh
  /etc/default/pop-zram                          # 30-memory-swap.sh
  /etc/default/earlyoom                          # 60-oom-guard.sh
  /etc/profile.d/poplab-ai.sh                    # 70-gpu-ai.sh
  /etc/profile.d/poplab-vaapi.sh                 # 80-media-stack.sh
  /usr/local/bin/poplab-run                      # 60-oom-guard.sh
  /usr/local/bin/poplab-encode                   # 80-media-stack.sh
  /usr/local/sbin/poplab-cpu-profile             # 20-cpu-power.sh
  /usr/local/sbin/poplab-power-limits            # 95-thermal-power-limits.sh
  /var/lib/poplab                                # default POPLAB_STATE_DIR
)

# One line per path. Absent paths are recorded as absent, so absent -> present
# is a diff just like present -> modified. Directories are walked to depth 2,
# which is enough to catch a new backups/<run-id>/manifest.tsv appearing.
snapshot_paths() {
  local p
  for p in "$@"; do
    if [[ -e "$p" ]]; then
      find "$p" -maxdepth 2 -printf '%p\t%y\t%m\t%s\t%T@\n' 2>/dev/null | sort
    else
      printf '%s\tABSENT\n' "$p"
    fi
  done
}

SANDBOX="$(mktemp -d -t poplab-smoke.XXXXXX)"
trap 'rm -rf -- "$SANDBOX"' EXIT
SANDBOX_STATE="$SANDBOX/state"   # deliberately never created

# Self-test the detector before trusting it: a suite that silently compares two
# empty snapshots would pass no matter what plan did.
: > "$SANDBOX/canary"
snapshot_paths "$SANDBOX/canary" > "$SANDBOX/canary.1"
printf 'mutated' >> "$SANDBOX/canary"
snapshot_paths "$SANDBOX/canary" > "$SANDBOX/canary.2"
snapshot_paths "$SANDBOX/ghost"  > "$SANDBOX/ghost.1"
: > "$SANDBOX/ghost"
snapshot_paths "$SANDBOX/ghost"  > "$SANDBOX/ghost.2"
tno "snapshot detects a modified file" diff -q "$SANDBOX/canary.1" "$SANDBOX/canary.2"
tno "snapshot detects a created file"  diff -q "$SANDBOX/ghost.1"  "$SANDBOX/ghost.2"

snapshot_paths "${WATCH[@]}" > "$SANDBOX/before"
t "audit exits 0"        env NO_COLOR=1 POPLAB_STATE_DIR="$SANDBOX_STATE" ./bin/poplab audit
t "plan exits 0"         env NO_COLOR=1 POPLAB_STATE_DIR="$SANDBOX_STATE" ./bin/poplab plan --yes
t "plan --aggressive"    env NO_COLOR=1 POPLAB_STATE_DIR="$SANDBOX_STATE" ./bin/poplab plan --yes --aggressive
snapshot_paths "${WATCH[@]}" > "$SANDBOX/after"

tno "dry run created no state dir"     test -e "$SANDBOX_STATE"
t   "dry run changed no watched path"  diff -q "$SANDBOX/before" "$SANDBOX/after"
diff -u --label before --label after "$SANDBOX/before" "$SANDBOX/after" | sed 's/^/       /' >&2 || true

echo "dispatcher"
t   "help"                    env NO_COLOR=1 ./bin/poplab --help
tno "unknown command rejected" env NO_COLOR=1 ./bin/poplab bogus-command
t   "--only filters"          bash -c 'NO_COLOR=1 ./bin/poplab plan --only 30 --yes | grep -q "30 · memory"'
tno "--skip filters"          bash -c 'NO_COLOR=1 ./bin/poplab plan --skip 30 --yes | grep -q "30 · memory"'

echo "local81"
t "bin/local81 is executable"  test -x bin/local81
t "local81 --help"             env NO_COLOR=1 ./bin/local81 --help
for p in local81/playbooks/*.yml; do
  t "local81 lint $(basename "$p")" env NO_COLOR=1 ./bin/local81 lint "$p"
done
t "local81 smoke suite"        bash tests/local81-smoke.sh

echo "docs"
for d in README.md CLAUDE.md docs/research/01-pop-os-24.04.md docs/research/02-ryzen-6800h-radeon-680m.md docs/research/03-memory-io-dev.md local81/README.md; do
  t "$d exists" test -s "$d"
done

echo
if [[ "$FAIL" -eq 0 ]]; then echo "ALL SMOKE TESTS PASSED"; else echo "$FAIL FAILURE(S)"; fi
exit "$FAIL"
