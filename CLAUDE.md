# poplab — agent working notes

Workspace for the pop_os & Claude Lab project. Target machine: **NIMO N155**
(Ryzen 7 6800H, Radeon 680M/gfx1035, 32 GB DDR5-5600, 1 TB PCIe 4.0 NVMe) running
**Pop!_OS 24.04 LTS**. Repo: `github.com/jimmershere/poplab` — **PUBLIC**. Verified with
`gh repo view` on 2026-08-21; this line previously said "private", which was wrong.
Assume everything committed here is world-readable: no credentials, no customer
data, and think before adding fleet detail (usernames, sudoers lines, key paths).

## Non-negotiables when editing this repo

1. **Read-only by default.** Any new module must no-op unless `POPLAB_APPLY=1`.
   Use `write_file` / `run` from `lib/common.sh`; never call `cp`, `sed -i`, `tee`
   or `systemctl` directly in a module.
2. **Idempotent.** `write_file` compares content byte-for-byte and skips. Preserve that.
3. **Reversible.** Anything that touches an existing file must go through
   `backup_file` (which `write_file` already does). Kernel cmdline changes are the one
   exception and are called out loudly in `rollback`.
4. **Pop!_OS ≠ Ubuntu.** `update-grub` does nothing on a UEFI Pop install — use
   `kernel_param_add` (which dispatches to `kernelstub`). The apt mirror is
   `apt.pop-os.org/ubuntu`, not `archive.ubuntu.com`. There is no snapd.
5. **Every claim needs a source.** If a knob is not backed by something in
   `docs/research/`, either research it first or make the script *detect* the
   condition at runtime instead of asserting it.
6. **Flag uncertainty in the output.** The user has explicitly asked not to be given
   unverifiable specifics as fact. Where research was inconclusive (BIOS UMA options,
   NBFC chassis support, gfx1035 on ROCm 7.x), the script says so.
7. **shellcheck clean** at `-S warning` with `-x`. CI enforces it.

## Layout

```
bin/poplab             dispatcher: audit | plan | apply | verify | soak | rollback | runs
bin/local81            Local81 runner: run | lint | hosts. Python 3 + PyYAML. Dry run by default.
lib/common.sh          logging, dry-run, backup/manifest, idempotent writes, detection
scripts/NN-*.sh        modules, run in numeric order; each sources lib/common.sh
docs/research/         sourced findings — the "why" behind every knob
local81/playbooks/     Local81 orchestration playbooks
local81/playbooks/repo-init.yml  one-time: create each fleet repo behind the publish gate
local81/playbooks/repo-sync.yml  commit + push every fleet repo, same gate. The nightly job.
local81/bootstrap-fleet.sh  one-shot host enrolment: key, NOPASSWD sudo, /app, ssh_config
local81/repo-guard.sh  publish gate. 0 clean, 1 BLOCK (credentials), 2 REVIEW (personal data/media)
local81/systemd/       poplab-repo-sync.{service,timer} + install.sh — nightly timer,
                       USER units (needs the user's gh token and ssh agent, not root's)
tests/                 smoke tests run in CI
```

## Adding a module

```bash
cp scripts/90-hygiene.sh scripts/85-newthing.sh   # nearest structural template
# source common.sh, define main(), end with `return 0`
```
`errexit` is on. Guard anything that can legitimately fail with `|| true`, and end
every function with an explicit `return 0` — a trailing `[[ ... ]] && foo` that
evaluates false will otherwise abort the module.

## Verifying a change

```bash
shellcheck -x -S warning bin/poplab lib/common.sh scripts/*.sh
bash tests/smoke.sh
./bin/poplab plan                # inspect diffs
sudo ./bin/poplab apply --only NN
./bin/poplab verify
sudo ./bin/poplab rollback       # confirm it undoes cleanly
```

## Session workflow (project convention)

- Branch per chunk, PR per session. Keep `docs/` current in the same PR as the code.
- After each merge: security/compliance pass, check for circular reasoning and
  hallucinated facts against `docs/research/`, update documentation.
- Local81 playbooks in `local81/` orchestrate apply/verify across hosts. `bin/local81`
  is the runner; it treats **every** remote command as a mutation and refuses to open a
  socket without `--apply`, which is rule 1 applied to the orchestrator.
- **End every session by pushing.** Each fleet repo you touched gets committed and
  pushed to its origin before the session closes — an uncommitted change on
  quasimodo exists in exactly one place. `local81/playbooks/repo-sync.yml` does
  the whole fleet; the nightly timer in `local81/systemd/` does it unattended.
- **No push to a public repo without the guard in the same command.**
  `local81/repo-guard.sh <dir> --public && git push` — one command, one tree.
  A guard that ran earlier, or on its own schedule, attests to a tree that has
  already changed. Exit 1 (BLOCK, credentials) is never overridden; exit 2
  (REVIEW) needs a human to say yes. Publishing is not reversible: forks,
  caches and scrapers keep a copy after any delete.
- The fleet is `pop-os` (controller, 192.168.0.9) and `quasimodo` (192.168.0.20).
  `pop-os` runs no `sshd`, so orchestration is one-way; it audits itself directly.
  Workspace root is `/app` on both.
