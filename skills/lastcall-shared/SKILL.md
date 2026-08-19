---
name: lastcall-shared
description: Internal file container for lastcall and tally. Not invocable.
user-invocable: false
disable-model-invocation: true
---

# lastcall-shared

Not a skill. A file container.

This directory exists as a skill directory only so that installers which copy
skill directories carry its files alongside `lastcall` and `tally`. Nothing
should invoke it, and both flags above are set to make sure nothing can.

## Contents

| Path | Purpose |
|---|---|
| `references/contracts.md` | The three interfaces that must not drift: meter output, evidence drop-box, ledger record. Read this first. |
| `references/pricing.md` | The cost formula, why cache traffic dominates a bill, and how to refresh the rate table. |
| `references/summary.md` | How `lastcall` describes a session. The grounding rule, the sections, and why there is no productivity score. |
| `scripts/meter-session.sh` | Session metering. Emits pure token/time/work counts as JSON. No pricing. |
| `scripts/cost.sh` | Counts → dollars, using `rates.json`. Separate from the meter because rates change and token counts do not. |
| `scripts/rates.json` | The rate table. Refreshed from the `claude-api` skill; never edited from memory. |
| `scripts/openloops.sh` | What the session started and did not finish: uncommitted work, churn hotspots, TODO markers. |
| `scripts/ledger.sh` | Session history and the baseline that makes ratios mean something. Written by `lastcall` only. |
| `scripts/doctrine-check.sh` | Detects guidance that contradicts the `memory/MEMORY.md` system, in `CLAUDE.md`, `AGENTS.md`, and live `bd prime` output. |

`cost.sh` and `ledger.sh` resolve their own symlinks to find siblings, so they
work both in place and through the `~/.lastcall/bin` links `install.sh` creates.

## For the skills that read this

Reference these files as `../lastcall-shared/...` relative to your own
`SKILL.md`. That is the only form that resolves in all four install modes —
Kiro global, Kiro workspace, Claude Code standalone, and Claude Code plugin.
Do not use `${CLAUDE_PLUGIN_ROOT}`; it resolves in Claude Code plugin installs
only, and Kiro has no equivalent.

Reading and executing differ. See `references/contracts.md` section 0.
