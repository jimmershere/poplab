# poplab — agent working notes

Workspace for the pop_os & Claude Lab project. Target machine: **NIMO N155**
(Ryzen 7 6800H, Radeon 680M/gfx1035, 32 GB DDR5-5600, 1 TB PCIe 4.0 NVMe) running
**Pop!_OS 24.04 LTS**. Repo: `github.com/jimmershere/poplab` (private).

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
lib/common.sh          logging, dry-run, backup/manifest, idempotent writes, detection
scripts/NN-*.sh        modules, run in numeric order; each sources lib/common.sh
docs/research/         sourced findings — the "why" behind every knob
local81/playbooks/     Local81 orchestration playbooks
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
- Local81 playbooks in `local81/` orchestrate apply/verify across hosts.
