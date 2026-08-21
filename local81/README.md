# Local81 playbooks for poplab

Local81 is agentless (SSH + rsync), so the target needs nothing installed beyond
a shell and sudo. These playbooks push the repo to `/opt/poplab` on the target and
drive the same `bin/poplab` entrypoints a human would use.

| Playbook | Targets | Purpose |
|---|---|---|
| `poplab-audit.yml` | n155 | Read-only. Sync + audit + fetch the report. Safe to run on a schedule. |
| `poplab-apply.yml` | n155 | Plan → human gate → apply → verify. Prints the rollback command. |
| `poplab-soak.yml` | n155 | Sustained-load validation after a tuning change. |
| `fleet-audit.yml` | quasimodo | Read-only. Inventories the second node — hardware, distro, toolchain, `/app` — then audits it and fetches the report. |
| `fleet-sync.yml` | quasimodo | Mirrors `/app/poplab` and `/app/portwright` across. Excludes `.git`, `.env`, `node_modules`, `.venv`. |
| `quasimodo-provision.yml` | quasimodo | Installs the dev toolchain. Detects the package manager rather than assuming apt; gates before installing. |
| `repo-init.yml` | quasimodo | **Mutates.** One-time: create the GitHub repo for a fleet codebase and set its origin. Runs `repo-guard.sh` first and refuses on a non-zero verdict — see [Publishing](#publishing). |
| `repo-sync.yml` | quasimodo | **Mutates.** Commit and push every fleet repo to its origin. Same gate, same command, every time. This is what the nightly timer runs. |

Required vars: `N155_HOST` / `N155_USER` for the `poplab-*` playbooks,
`QUASI_HOST` / `QUASI_USER` for the `fleet-*`, `quasimodo-*` and `repo-*` ones. Set
`auto_approve: true` only in a non-interactive pipeline where you have already
reviewed the plan.

## Enrolling a new host

`bootstrap-fleet.sh` is the one-shot that makes a machine addressable by the
playbooks above: automation key → key install → passwordless sudo (validated by
`visudo -cf` before it lands) → `/app` → an `ssh_config` stanza. Dry run by
default, like everything else here.

```bash
./local81/bootstrap-fleet.sh            # show every change, make none
./local81/bootstrap-fleet.sh --apply    # commit; prompts once for the local sudo password
```

It reads a password from `~/quasi.env` for exactly one exchange — installing the
public key — via an `SSH_ASKPASS` helper, so the secret never reaches a command
line, the environment, or the log. Every connection after that is key-only under
`BatchMode=yes`, which fails closed rather than falling back to a prompt.

**The controller is not a Local81 host.** `pop-os` runs no `sshd`, so it audits
itself directly with `./bin/poplab audit`; the playbooks only ever run
pop-os → quasimodo. Enabling a listener on the primary is a security decision,
not a setup step.

The OODA loop this repo runs on:
**observe** (`poplab-audit`) → **orient** (read `docs/research/`) → **decide**
(`poplab plan`) → **act** (`poplab-apply`) → back to observe (`poplab verify`,
`poplab-soak`).

## Publishing

`repo-guard.sh` is the gate in front of every `git push` the fleet performs.
`repo-init.yml` and `repo-sync.yml` both run it, and both refuse to push on a
non-zero verdict.

```bash
./local81/repo-guard.sh /app/portwright-studio --public
```

| Exit | Verdict | Meaning |
|---|---|---|
| 0 | `CLEAN` | Nothing found. Safe to push. |
| 1 | `BLOCK` | A credential or private key is present. Never publish; remove it, and rotate anything already committed. |
| 2 | `REVIEW` | Personal data or media. Not disqualifying, but a human looks first. |

What it actually checks, walking the tree with `.git`, `node_modules`, `.venv`,
`vendor` and `__pycache__` pruned:

- **Credentials by filename** — `*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa*`,
  `id_ed25519*`, `.env` and `.env.*`, `credentials*.json`,
  `service-account*.json`, `.netrc`, `*.keystore`, `.htpasswd`. → BLOCK.
- **Credential shapes in file contents** — `BEGIN … PRIVATE KEY` blocks,
  `BEGIN CERTIFICATE`, AWS `AKIA…`, GitHub `ghp_/gho_/ghu_/ghs_/ghr_…`,
  Anthropic `sk-ant-…`, Stripe `sk_live_/rk_live_…`, Slack `xox…`, Google
  `AIza…`. → BLOCK.
- **Hard-coded-looking secret assignments** — `password: …`, `api_key = …` and
  friends, with the obvious placeholders (`example`, `changeme`, `${…}`,
  `os.environ`, `process.env`, empty strings) filtered out. → REVIEW.
- **Personal data** — distinct email addresses and phone-shaped strings.
  → REVIEW.
- **Media** — images and video, counted and totalled in MB, because a
  photograph of a person is personal data and a phone photo carries GPS in its
  EXIF. → REVIEW.

`--public` / `--private` changes the *wording* of a REVIEW, not the exit code:
either way it is `2`, and the caller decides what a `2` means for that repo.
It is deliberately noisy rather than clever — a false positive costs you a
look, a false negative costs you a leaked key.

The guard excludes itself by realpath — it necessarily contains the token
patterns it hunts for — plus anything listed in an optional
`.repo-guard-ignore` at the root of the scanned directory (one path or glob
per line, `#` for comments). Keep that file short and justify each line in it:
every entry is a place the gate has been told not to look.

### Why gate a repo you are publishing on purpose

Because publishing is not reversible. Deleting a repo, force-pushing over a
bad commit, or rewriting history removes *your* copy and nothing else: forks,
GitHub's own cached blob and PR views, downstream mirrors and archives, and
anything that scraped the repo in the interval all keep what was there. For a
leaked credential the only real remediation is rotation; for someone else's
email address or face there is no remediation at all. A gate that runs before
the push is the only place the decision can still be made.

▲ `poplab` itself is **public** (`gh repo view`, 2026-08-21 — see `CLAUDE.md`),
so this applies to it too. The visibility of the other fleet repos is a
per-repo setting on GitHub and is not asserted anywhere in this tree; confirm
with `gh repo view <name> --json visibility` rather than trusting a document.

### The nightly timer

**An automated nightly push to a public repo is the highest-risk thing in this
repo.** Nothing else here publishes anything; this pushes whatever got
committed during the day, at 02:30, with nobody watching. What makes it
acceptable is that `repo-guard.sh` runs immediately before each push, in the
same command as the push — not on a schedule of its own. A guard on its own
schedule attests to a tree that has already changed by the time the push
happens, which is worse than no guard, because it reads like assurance.

`local81/systemd/` holds the units. They are **user** units, not system units:
the push needs this account's `gh` token (`~/.config/gh/hosts.yml`) and SSH
key/agent. A system unit runs as root, with root's `$HOME`, no `gh` auth and
no `$SSH_AUTH_SOCK`, and every push fails.

```bash
./local81/systemd/install.sh                    # dry run — prints every change
./local81/systemd/install.sh --apply            # install + daemon-reload + enable --now
./local81/systemd/install.sh --uninstall --apply  # stop, disable, delete
```

| File | Role |
|---|---|
| `poplab-repo-sync.service` | `Type=oneshot`. Runs `bin/local81 run … repo-sync.yml --apply --yes`. |
| `poplab-repo-sync.timer` | `OnCalendar=*-*-* 02:30:00`, `Persistent=true`, `RandomizedDelaySec=30min`. |
| `install.sh` | Installs into `~/.config/systemd/user/`. Dry run by default. |

02:30 is late enough that the day's work is committed, early enough to be done
before the next morning's session, and off the hour where `cron.daily` and
`logrotate` cluster. `Persistent=true` fires a run that was missed while the
laptop was asleep or away; the timer does **not** wake the machine.
`RandomizedDelaySec` spreads the start over half an hour so two fleet members
never hit GitHub — or the disk — at the same instant.

Target host and user come from `Environment=` defaults (`quasimodo.local`,
`%u`) and can be overridden without touching the unit by writing
`~/.config/poplab/repo-sync.env`.

**Lingering is a decision, not a setup step.** A user timer only fires while
that user has a session; at the login screen the user manager is gone and
02:30 passes unnoticed (`Persistent=true` then catches it at the next login).
To have it run regardless, run this yourself:

```bash
loginctl enable-linger jimmer     # undo: loginctl disable-linger jimmer
```

`install.sh` reports the current linger state and prints that command. It does
not run it.

```bash
systemctl --user list-timers poplab-repo-sync.timer
systemctl --user start poplab-repo-sync.service      # fire one now
journalctl --user -u poplab-repo-sync.service -n 200
```

## The runner

`bin/local81` executes these playbooks. It is Python 3 (PyYAML is the only
dependency, `apt install python3-yaml`) and needs `ssh` and `rsync` on the
controller. Nothing is installed on the target — that is what agentless means.

```
local81 run <playbook.yml>   execute a playbook (DRY RUN unless --apply)
local81 lint <playbook.yml>  validate structure, dialect and every {{ expr }}
local81 hosts <playbook.yml> list the hosts a playbook targets
```

Flags for `run`: `--host NAME`, `--var K=V` (repeatable), `--apply`, `--check`,
`--yes`, `--quiet`. `local81 --help` prints the same block.

```bash
./bin/local81 lint  local81/playbooks/poplab-audit.yml
./bin/local81 hosts local81/playbooks/poplab-audit.yml --var N155_HOST=10.0.0.5 --var N155_USER=jimmer
./bin/local81 run   local81/playbooks/poplab-audit.yml --var N155_HOST=10.0.0.5 --var N155_USER=jimmer
./bin/local81 run   local81/playbooks/poplab-audit.yml --var N155_HOST=10.0.0.5 --var N155_USER=jimmer --apply
```

### Dry run is the default

CLAUDE.md rule 1 applies to the orchestrator too. Without `--apply`, local81
**opens no socket at all**: it renders every template, resolves every `when:`,
and prints the exact `ssh`/`rsync` argv it would have run. `--check` is accepted
as an explicit spelling of the same thing.

This is stricter than the poplab dispatcher on purpose. local81 cannot know
whether `shell: ./bin/poplab audit` mutates the target, so it treats *every*
remote command as a mutation and refuses to run it without `--apply`. A
read-only audit therefore still needs `--apply`; the dry run tells you what it
would do. `debug:` is the one exception — it renders locally, so it prints in
both modes (register values show as `<dry-run>`).

Exit status is non-zero if any task fails without `ignore_errors: true`, or if
any host was unreachable. An unreachable host is reported, its remaining tasks
are abandoned, and the other hosts still run.

### Supported dialect

Top level: `name` (required), `description`, `hosts`, `vars`, `tasks`. Anything
else is a lint error — local81 does not quietly ignore keys it does not know.

Hosts are `{name, address, user}`; `user` defaults to `$USER`.

| Task | Body | Mutating |
|---|---|---|
| `shell` | a string, run as `bash -c` over one ssh connection | yes |
| `sync` | `src`, `dest`, `exclude: []`, `delete: bool` — rsync push | yes |
| `fetch` | `src`, `dest` — rsync pull, or `src: "stdout:<register>"` to write a captured stream to a local file | yes |
| `package` | `name` (string or list), `state: present` — apt-get, idempotent via dpkg-query | yes |
| `pause` | `prompt`, and optionally its own `when` | gate only |
| `debug` | `msg` | no |

Task attributes: `name`, `register`, `become`, `ignore_errors`, `when`,
`timeout` (seconds).

`register: foo` captures `{{ foo.stdout }}`, `{{ foo.stderr }}`, `{{ foo.rc }}`
for later tasks. `become: true` wraps the whole command in `sudo -n` — never a
password prompt; if passwordless sudo is missing, local81 says exactly which
sudoers line to add. A command that already contains its own `sudo` still works,
because the wrap is `sudo -n bash -c '<the whole thing>'`.

### Templating

`{{ ... }}` only. There are no `{% ... %}` statement blocks and Jinja2 is not a
dependency: expressions are tokenised and parsed into an AST by a ~150-line
recursive-descent parser in `bin/local81`, and `eval()` is never called on
playbook input.

Supported: names and dotted attributes (`{{ run_id.stdout }}`), string/number/
bool/none literals, `and` `or` `not`, comparisons, `+ - * // %`, parentheses,
the conditional form `{{ 'a' if cond else 'b' }}`, and filters
`default(x)` (`d`), `bool`, `int`, `string`, `lower`, `upper`, `trim`, `length`.
Filters bind tighter than operators, as in Jinja, so
`{{ not auto_approve | default(false) }}` means `not (auto_approve | default(false))`.

Builtins: `host.name`, `host.address`, `host.user`, and `now` (UTC
`YYYYmmddTHHMMSSZ`, safe in filenames). Variable precedence, lowest first:
environment → playbook `vars:` → `--var`. Registers and builtins sit on top and
cannot be shadowed. `--var` and environment values are coerced, so
`--var auto_approve=false` is falsy rather than a non-empty string.

Anything outside that grammar — a function call, a subscript, an unknown filter,
a `{% %}` block — is a **lint error**, not an empty string. A referenced
variable that is never supplied aborts the run and names itself; guard optional
ones with `| default(...)`. `local81 run` lints before it does anything.

### Environment

| Var | Effect |
|---|---|
| `L81_SSH_KEY` | passed to ssh and rsync as `-i` |
| `NO_COLOR` | disable colour, same contract as `lib/common.sh` |

SSH is always invoked with `-o BatchMode=yes -o StrictHostKeyChecking=accept-new
-o ConnectTimeout=10`, and rsync tunnels over the identical options via `-e`.

### Tests

`tests/local81-smoke.sh` runs the whole suite offline — `ssh` and `rsync` are
shadowed by stubs on `PATH`, so it needs no target and no network. It lints every
playbook in `local81/playbooks/`, proves a default run contacts nothing, and
proves unsupported expression forms fail lint. `tests/smoke.sh` invokes it.
