#!/usr/bin/env bash
# tests/local81-smoke.sh — CI smoke tests for bin/local81, the agentless
# playbook runner. Runs entirely offline: ssh/rsync are shadowed by stubs on
# PATH, so nothing here ever opens a socket or touches a real host.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FAIL=0
L81="$ROOT/bin/local81"
export NO_COLOR=1

t() { local name="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  ok   %s\n' "$name"
  else printf '  FAIL %s\n' "$name"; FAIL=$((FAIL+1)); fi
}
tno() { local name="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  FAIL %s (expected non-zero)\n' "$name"; FAIL=$((FAIL+1))
  else printf '  ok   %s\n' "$name"; fi
}

TMP="$(mktemp -d -t local81-smoke.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/fixtures" "$TMP/work"

# ---------------------------------------------------------------- ssh stubs --
# Every remote invocation is recorded in $L81_CALLS instead of happening, so the
# suite is hermetic: no network, no target, no sudo.
cat > "$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$L81_CALLS"
if [[ "${L81_SSH_RC:-0}" != "0" ]]; then
  echo "ssh: connect to host port 22: No route to host" >&2
  exit "$L81_SSH_RC"
fi
echo "FAKE-REMOTE-STDOUT"
STUB
cat > "$TMP/bin/rsync" <<'STUB'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >> "$L81_CALLS"
STUB
chmod +x "$TMP/bin/ssh" "$TMP/bin/rsync"
export PATH="$TMP/bin:$PATH"
export L81_CALLS="$TMP/calls.log"
: > "$L81_CALLS"

# Every variable any shipped playbook needs, so the whole directory can be
# dry-run offline. A new playbook with a new required var belongs here too.
VARS=(--var N155_HOST=10.9.9.9 --var N155_USER=tester
      --var QUASI_HOST=10.9.9.10 --var QUASI_USER=tester)

echo "syntax"
t "bash -n tests/local81-smoke.sh" bash -n tests/local81-smoke.sh
t "python3 -m py_compile bin/local81" \
  env PYTHONPYCACHEPREFIX="$TMP/pyc" python3 -m py_compile bin/local81
t "bin/local81 is executable" test -x bin/local81

echo "cli surface"
"$L81" hosts local81/playbooks/poplab-audit.yml "${VARS[@]}" > "$TMP/hosts.out" 2>&1
rc=$?
t   "hosts exits 0"            test "$rc" -eq 0
t   "hosts lists the target"   grep -q "tester@10.9.9.9" "$TMP/hosts.out"
t   "--help"                   "$L81" --help
t   "--version"                "$L81" --version
tno "unknown command rejected" "$L81" bogus-command foo.yml
tno "unknown flag rejected"    "$L81" lint local81/playbooks/poplab-audit.yml --bogus
tno "run needs a playbook"     "$L81" run
tno "missing playbook file"    "$L81" lint "$TMP/fixtures/nope.yml"
tno "unknown --host rejected"  "$L81" run local81/playbooks/poplab-audit.yml --host nosuchhost "${VARS[@]}"

echo "lint (shipped playbooks)"
for p in local81/playbooks/*.yml; do t "lint $(basename "$p")" "$L81" lint "$p"; done

echo "lint (rejects unsupported dialect)"
# Every fixture is valid YAML and structurally plausible — only the flagged
# construct is out of dialect. A pass here means local81 refuses to silently
# degrade something it cannot evaluate.
mk() { printf '%s\n' "$2" > "$TMP/fixtures/$1.yml"; }
mk call        'name: x
hosts: [{name: a, address: "1.2.3.4", user: u}]
tasks:
  - name: t
    debug: {msg: "{{ lookup() }}"}'
mk badfilter   'name: x
hosts: [{name: a, address: "1.2.3.4", user: u}]
tasks:
  - name: t
    debug: {msg: "{{ word | tojson }}"}'
mk statement   'name: x
hosts: [{name: a, address: "1.2.3.4", user: u}]
tasks:
  - name: t
    debug: {msg: "{% if flag %}yes{% endif %}"}'
mk subscript   'name: x
hosts: [{name: a, address: "1.2.3.4", user: u}]
tasks:
  - name: t
    debug: {msg: "{{ reg[0] }}"}'
mk unbalanced  'name: x
hosts: [{name: a, address: "1.2.3.4", user: u}]
tasks:
  - name: t
    debug: {msg: "{{ word "}'
mk badtask     'name: x
hosts: [{name: a, address: "1.2.3.4", user: u}]
tasks:
  - name: t
    copy: {src: a, dest: b}'
mk badattr     'name: x
hosts: [{name: a, address: "1.2.3.4", user: u}]
tasks:
  - name: t
    shell: "true"
    notify: something'
mk badtop      'name: x
gather_facts: true
hosts: [{name: a, address: "1.2.3.4", user: u}]
tasks:
  - {name: t, shell: "true"}'
mk badregister 'name: x
hosts: [{name: a, address: "1.2.3.4", user: u}]
tasks:
  - name: t
    fetch: {src: "stdout:never_registered", dest: "./out.txt"}'
mk badpkg      'name: x
hosts: [{name: a, address: "1.2.3.4", user: u}]
tasks:
  - name: t
    package: {name: [foo], state: absent}'
mk nohost      'name: x
tasks:
  - {name: t, shell: "true"}'
for f in call badfilter statement subscript unbalanced badtask badattr badtop badregister badpkg nohost; do
  tno "lint rejects $f" "$L81" lint "$TMP/fixtures/$f.yml"
done
tno "run refuses a playbook that fails lint" "$L81" run "$TMP/fixtures/badtask.yml"

echo "templating"
cat > "$TMP/fixtures/tmpl.yml" <<'YAML'
name: tmpl-check
description: exercises every supported expression form
hosts:
  - name: t1
    address: "{{ addr }}"
    user: tester
vars:
  base: 100
  flag: true
  word: hello
tasks:
  - name: render everything
    debug:
      msg: |
        host={{ host.name }} addr={{ host.address }} user={{ host.user }}
        sum={{ base + 20 }} cmp={{ base > 99 }}
        pick={{ 'yes-branch' if flag else 'no-branch' }}
        dflt={{ missing | default('fallback') }}
        guard={{ not missing | default(false) }}
        upper={{ word | upper }}
        stamp={{ now }}
  - name: never runs
    debug: {msg: "SHOULD-NOT-APPEAR"}
    when: "{{ base < 10 }}"
YAML
t "templating fixture lints" "$L81" lint "$TMP/fixtures/tmpl.yml"
"$L81" run "$TMP/fixtures/tmpl.yml" --var addr=10.9.9.9 > "$TMP/tmpl.out" 2>&1
rc=$?
t   "templating run exits 0"      test "$rc" -eq 0
t   "host.* builtins"             grep -q "host=t1 addr=10.9.9.9 user=tester" "$TMP/tmpl.out"
t   "arithmetic + comparison"     grep -q "sum=120 cmp=true" "$TMP/tmpl.out"
t   "inline conditional"          grep -q "pick=yes-branch" "$TMP/tmpl.out"
t   "default() filter"            grep -q "dflt=fallback" "$TMP/tmpl.out"
t   "filter binds tighter than not" grep -q "guard=true" "$TMP/tmpl.out"
t   "upper filter"                grep -q "upper=HELLO" "$TMP/tmpl.out"
t   "now is filename-safe"        grep -Eq "stamp=[0-9]{8}T[0-9]{6}Z" "$TMP/tmpl.out"
t   "when:false is reported"      grep -q "never runs (when is false)" "$TMP/tmpl.out"
tno "when:false skips the task"   grep -q "SHOULD-NOT-APPEAR" "$TMP/tmpl.out"
tno "no {{ }} survives rendering" grep -q "{{" "$TMP/tmpl.out"

# Regression: a string that STARTS with {{ used to hit the native-type fast path,
# which fullmatch()'d across every expression in the string and fed
# " a }}\n{{ b " to the expression parser. Two adjacent expressions must render.
cat > "$TMP/fixtures/multi.yml" <<'YAML'
name: multi
hosts:
  - {name: m1, address: "10.9.9.9", user: tester}
vars: {one: "ALPHA", two: "BETA", flag: true}
tasks:
  - name: leading expression then another
    debug:
      msg: |
        {{ one }}
        {{ two }}
  - name: adjacent on one line
    debug: {msg: "{{ one }} {{ two }}"}
  - name: typed fast path still returns a bool
    debug: {msg: "typed-ok"}
    when: "{{ flag }}"
YAML
t "multi-expression fixture lints" "$L81" lint "$TMP/fixtures/multi.yml"
"$L81" run "$TMP/fixtures/multi.yml" > "$TMP/multi.out" 2>&1
rc=$?
t   "multi-expression run exits 0"   test "$rc" -eq 0
t   "leading {{ }} then another"     grep -q "ALPHA" "$TMP/multi.out"
t   "second expression rendered"     grep -q "BETA" "$TMP/multi.out"
t   "adjacent on one line"           grep -q "ALPHA BETA" "$TMP/multi.out"
t   "typed fast path survives"       grep -q "typed-ok" "$TMP/multi.out"
tno "no {{ }} survives multi"        grep -q "{{" "$TMP/multi.out"

# --var overrides vars: and coerces literals, so `--var flag=false` is falsy.
"$L81" run "$TMP/fixtures/tmpl.yml" --var addr=1.1.1.1 --var flag=false > "$TMP/tmpl2.out" 2>&1
t "--var overrides vars:"     grep -q "pick=no-branch" "$TMP/tmpl2.out"
t "--var reaches host.address" grep -q "addr=1.1.1.1" "$TMP/tmpl2.out"

cat > "$TMP/fixtures/undef.yml" <<'YAML'
name: undef-check
hosts: [{name: a, address: "1.2.3.4", user: u}]
tasks:
  - name: unguarded
    debug: {msg: "value={{ never_set_anywhere }}"}
YAML
"$L81" run "$TMP/fixtures/undef.yml" > "$TMP/undef.out" 2>&1
rc=$?
t "undefined var fails the run" test "$rc" -ne 0
t "undefined var says why"      grep -q "undefined variable 'never_set_anywhere'" "$TMP/undef.out"

echo "dry run is the default (no host contacted)"
: > "$L81_CALLS"
rm -rf "${TMP:?}/work"; mkdir -p "$TMP/work"
for p in local81/playbooks/*.yml; do
  base="$(basename "$p")"
  ( cd "$TMP/work" && "$L81" run "$ROOT/$p" "${VARS[@]}" > "$TMP/dry-$base.out" 2>&1 )
  rc=$?   # captured before any other expansion can clobber $?
  t "dry run $base exits 0" test "$rc" -eq 0
done
t   "dry run announces itself"   grep -q "DRY RUN — no host was contacted" "$TMP/dry-poplab-apply.yml.out"
t   "dry run prints the ssh argv" grep -q "\[dry-run\] ssh -o BatchMode=yes" "$TMP/dry-poplab-apply.yml.out"
t   "dry run prints the rsync argv" grep -q "\[dry-run\] rsync -a" "$TMP/dry-poplab-audit.yml.out"
t   "dry run does not prompt"    grep -q "\[dry-run\] pause: would ask" "$TMP/dry-poplab-apply.yml.out"
tno "dry run invoked no ssh/rsync" test -s "$L81_CALLS"
tno "dry run wrote no report"    bash -c 'ls "$0"/work/reports/* >/dev/null 2>&1' "$TMP"
t   "--check is the same as default" bash -c '"$0" run "$1" --check "${@:2}" | grep -q "DRY RUN"' \
      "$L81" "$ROOT/local81/playbooks/poplab-audit.yml" "${VARS[@]}"

echo "--apply executes (against the stubs)"
: > "$L81_CALLS"
( cd "$TMP/work" && "$L81" run "$ROOT/local81/playbooks/poplab-audit.yml" \
    --apply --yes "${VARS[@]}" > "$TMP/apply.out" 2>&1 )
rc=$?
t   "apply exits 0"               test "$rc" -eq 0
t   "apply invoked ssh/rsync"     test -s "$L81_CALLS"
t   "ssh uses BatchMode"          grep -q -- "-o BatchMode=yes" "$L81_CALLS"
t   "ssh pins the host key"      grep -q -- "-o StrictHostKeyChecking=yes" "$L81_CALLS"
tno "ssh never uses accept-new"  grep -q -- "-o StrictHostKeyChecking=accept-new" "$L81_CALLS"
t   "ssh verifies name not IP"   grep -q -- "-o CheckHostIP=no" "$L81_CALLS"
t   "ssh uses ConnectTimeout=10"  grep -q -- "-o ConnectTimeout=10" "$L81_CALLS"
t   "rsync tunnels over the same" grep -q -- "rsync .*-e ssh -o BatchMode=yes" "$L81_CALLS"
t   "rsync honours exclude"       grep -q -- "--exclude docs/research" "$L81_CALLS"
t   "rsync honours delete"        grep -q -- "--delete" "$L81_CALLS"
t   "address was substituted"     grep -q "tester@10.9.9.9" "$L81_CALLS"
tno "no {{ }} reached the wire"   grep -q "{{" "$L81_CALLS"
t   "register captured stdout"    bash -c 'grep -q FAKE-REMOTE-STDOUT "$0"/work/reports/n155-audit-*.txt' "$TMP"

echo "L81_SSH_INSECURE escape hatch"
: > "$L81_CALLS"
( cd "$TMP/work" && L81_SSH_INSECURE=1 "$L81" run "$ROOT/local81/playbooks/poplab-audit.yml" \
    --apply --yes "${VARS[@]}" > "$TMP/insecure.out" 2>&1 ) || true
t   "insecure=1 relaxes to accept-new" grep -q -- "-o StrictHostKeyChecking=accept-new" "$L81_CALLS"
tno "insecure=1 drops the strict opt"  grep -q -- "-o StrictHostKeyChecking=yes" "$L81_CALLS"

echo "--apply honours become / L81_SSH_KEY"
: > "$L81_CALLS"
( cd "$TMP/work" && L81_SSH_KEY=/dev/null "$L81" run "$ROOT/local81/playbooks/poplab-apply.yml" \
    --apply --yes --var auto_approve=true "${VARS[@]}" > "$TMP/apply2.out" 2>&1 )
t "become emits sudo -n"          grep -q "sudo -n bash -c" "$L81_CALLS"
t "L81_SSH_KEY becomes -i"        grep -q -- "-i /dev/null" "$L81_CALLS"
t "auto_approve skipped the gate" grep -q "gate on human review (when is false)" "$TMP/apply2.out"
t "register feeds a later task"   grep -q "run id:    FAKE-REMOTE-STDOUT" "$TMP/apply2.out"

echo "unreachable host"
: > "$L81_CALLS"
( cd "$TMP/work" && L81_SSH_RC=255 "$L81" run "$ROOT/local81/playbooks/poplab-audit.yml" \
    --apply --yes "${VARS[@]}" > "$TMP/unreach.out" 2>&1 )
rc=$?
t   "unreachable exits non-zero"   test "$rc" -ne 0
t   "unreachable is reported"      grep -q "unreachable" "$TMP/unreach.out"
t   "unreachable shows in summary" grep -q "n155 *unreachable" "$TMP/unreach.out"
tno "unreachable ran no tasks"     grep -q "^rsync" "$L81_CALLS"

echo "output style"
t   "poplab glyphs in use"        grep -q "✔" "$TMP/apply.out"
tno "NO_COLOR leaves no escapes"  bash -c 'cat -v "$0" | grep -q "\^\[\["' "$TMP/apply.out"

echo "docs"
t "README documents bin/local81" grep -q "bin/local81" local81/README.md
t "README documents --apply"     grep -q -- "--apply" local81/README.md

echo
if [[ "$FAIL" -eq 0 ]]; then echo "ALL LOCAL81 SMOKE TESTS PASSED"; else echo "$FAIL FAILURE(S)"; fi
exit "$FAIL"
