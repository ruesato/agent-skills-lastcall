---
name: lastcall-shared
description: Internal shared contracts and scripts for the last-call and tally skills. Never invoke this directly. It holds the session metering script, the data contracts, and the pricing and summary reference files that those two skills read at runtime.
user-invocable: false
disable-model-invocation: true
---

# lastcall-shared

Not a skill. A file container.

This directory exists as a skill directory only so that installers which copy
skill directories carry its files alongside `last-call` and `tally`. Nothing
should invoke it, and both flags above are set to make sure nothing can.

## Contents

| Path | Purpose |
|---|---|
| `references/contracts.md` | The three interfaces that must not drift: meter output, evidence drop-box, ledger record. Read this first. |
| `scripts/meter-session.sh` | Session metering. Emits pure token/time/work counts as JSON. No pricing. |

## For the skills that read this

Reference these files as `../lastcall-shared/...` relative to your own
`SKILL.md`. That is the only form that resolves in all four install modes —
Kiro global, Kiro workspace, Claude Code standalone, and Claude Code plugin.
Do not use `${CLAUDE_PLUGIN_ROOT}`; it resolves in Claude Code plugin installs
only, and Kiro has no equivalent.

Reading and executing differ. See `references/contracts.md` section 0.
