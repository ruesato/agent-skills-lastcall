# lastcall

Two Claude Code skills for closing out agentic work sessions.

- **`/lastcall`** — wraps up a session. Meters what it cost in tokens, active
  time, and dollars; summarizes what actually landed and what is still open;
  then offers to commit, save memories, publish a report, and update the
  tracker. Every durable action happens only after you approve it.
- **`/tally`** — the mid-session checkpoint. Metering and readout only, no side
  effects, safe to run at any point.

`tally` measures. `lastcall` measures and then acts.

## Install

As a plugin, from the `ruesato-plugins` marketplace:

```
/plugin marketplace add ruesato/plugins
/plugin install lastcall
```

Or link this repo directly, which is the better option if you intend to edit
the skills — it symlinks rather than copies, so edits apply live:

```bash
./install.sh                  # auto-detect target(s)
./install.sh --target claude  # ~/.claude/skills
./install.sh --target kiro    # ~/.kiro/skills
./install.sh --uninstall
```

`install.sh` also puts the shared scripts on a fixed path under
`~/.lastcall/bin`, which is how the skills find them in Kiro — it has no
skill-directory variable, so a relative path from a `SKILL.md` cannot be
executed there.

## How the metering works

`skills/lastcall-shared/scripts/meter-session.sh` reads Claude Code transcripts
from `~/.claude/projects/<slug>/` and emits pure counts as JSON. It deliberately
carries no pricing, so rates come from the `claude-api` skill at runtime and the
meter stays correct when prices change.

Four things silently corrupt session totals, and the meter handles each:

- Streaming writes one assistant entry per chunk, all sharing a `requestId`.
  Summing raw entries overcounts by roughly 90%.
- Subagent turns live in separate `<session>/subagents/*.jsonl` files, so
  metering only the main transcript omits their cost entirely.
- Main threads use a 1h cache TTL while subagents use 5m, and the two price
  differently, so cache writes are never collapsed into one number.
- Wall-clock time is meaningless for a resumed session, which can span days.
  Active time is computed by gap bucketing instead.

Every claim in a summary must trace to an artifact — a file path, a commit SHA,
a task id, a test result. Transcripts are full of intentions that never landed,
so nothing is ever summarized from conversational narrative alone.

## Development

This is a shell + jq project. There is no `package.json` and no build step.

```bash
S=skills/lastcall-shared/scripts
M=$($S/meter-session.sh <session-uuid>)          # always pass the id
printf '%s' "$M" | $S/cost.sh                    # dollars
printf '%s' "$M" | $S/openloops.sh               # what is unfinished
printf '%s' "$M" | $S/ledger.sh append [sha ...] # write/replace this row
$S/ledger.sh trend <session-uuid>                # baseline + focus comparison
```

Set `LASTCALL_LEDGER` to a scratch path while testing, so the real baseline at
`~/.claude/lastcall/ledger.jsonl` is not polluted.

`./verify.sh` runs every script against every transcript on this machine.
Sessions with and without subagents exercise different code paths, and that
local corpus is the only one covering both, so the suite is a sweep over real
data rather than fixtures. It is local-only and exits non-zero on any failure.

## Security scanning

Every skill under `skills/` is scanned by
[NVIDIA SkillSpector](https://github.com/NVIDIA/SkillSpector) in CI on push and
pull request. **The build fails on any non-suppressed finding.**

This repo ships scripts that run from agent sessions under implicit trust —
they read transcripts, write to a ledger under `~/.claude/`, and read
`CLAUDE.md` and `AGENTS.md`. That is exactly the taint, sink, and persistence
surface SkillSpector's static pass examines.

Run it locally:

```bash
uv tool install git+https://github.com/NVIDIA/skillspector.git
bin/scan-skills.sh            # every skill
bin/scan-skills.sh tally      # one skill
```

Reviewed false positives are suppressed in `.skillspector-baseline.yaml`, each
with a written reason. **Never suppress a finding you have not understood.**
Suppressions are fingerprints bound to the decoded source text and to the
scanner version, so they fail closed: editing the excused text, or bumping the
pinned SkillSpector version in `.github/workflows/skillspector.yml`, brings the
finding back for re-review rather than keeping it silently suppressed.

The LLM semantic stage runs only when `ANTHROPIC_API_KEY` is present and falls
back to static-only otherwise, so the same green check can mean two depths of
scan. `bin/scan-skills.sh` prints the mode it ran in and stamps it into every
uploaded report.

This complements `verify.sh`; it does not replace it. `verify.sh` is a
local-only correctness sweep over transcripts, SkillSpector is the CI security
gate.

## License

MIT.
