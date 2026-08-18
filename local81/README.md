# Local81 playbooks for poplab

Local81 is agentless (SSH + rsync), so the target needs nothing installed beyond
a shell and sudo. These playbooks push the repo to `/opt/poplab` on the target and
drive the same `bin/poplab` entrypoints a human would use.

| Playbook | Purpose |
|---|---|
| `poplab-audit.yml` | Read-only. Sync + audit + fetch the report. Safe to run on a schedule. |
| `poplab-apply.yml` | Plan → human gate → apply → verify. Prints the rollback command. |
| `poplab-soak.yml` | Sustained-load validation after a tuning change. |

Required vars: `N155_HOST`, `N155_USER`. Set `auto_approve: true` only in a
non-interactive pipeline where you have already reviewed the plan.

The OODA loop this repo runs on:
**observe** (`poplab-audit`) → **orient** (read `docs/research/`) → **decide**
(`poplab plan`) → **act** (`poplab-apply`) → back to observe (`poplab verify`,
`poplab-soak`).
