# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Prefer `bd` for task tracking that spans sessions or has dependencies
- Run `bd prime` for detailed command reference and session close protocol
- `bd remember` is available for bead-scoped knowledge. It does **not** replace this
  environment's `memory/MEMORY.md` system, which remains authoritative for session
  memories — see "Conventions & Patterns" below.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

## Memory system — overrides the block above

**`memory/MEMORY.md` is the authoritative memory system in this project.** Where
beads guidance says *"Use `bd remember` … do NOT use MEMORY.md files"*, that line
does not apply here and must not be followed. `bd remember` is fine for
bead-scoped notes; it does not replace the memory system.

This section sits **outside** the `BEGIN/END BEADS INTEGRATION` markers on
purpose, and everything inside them is regenerated. Verified by experiment
(2026-08-18): a fresh `bd init`, and `bd init --force` on an existing repo, both
write `do NOT use MEMORY.md files` into that block, and both leave content
outside it untouched. So this is the only place the correction survives.

Two separate vectors reinstate the conflicting rule, and only one is a file:

1. The managed block above — rewritten by `bd init` / `bd init --force`.
   (`bd setup claude` does not touch it, and the `bd setup --print` template
   does not contain the rule, so this is specifically an *init* path.)
2. **`bd prime` output**, emitted every session by the beads plugin's
   SessionStart hook. This one is compiled into the binary — there is no file to
   correct, which is why an in-repo override is the only available fix.

Why it matters: `/lastcall`'s memories delegation writes to `memory/MEMORY.md`.
If the rule takes effect, sessions are told to bypass the exact system the skill
depends on, and the failure is silent — memories just stop being written.

Run `skills/lastcall-shared/scripts/doctrine-check.sh` to see which vectors are
currently live. `/lastcall` runs it before the memories delegation.

## Build & Test

This is a **shell + jq project**. There is no `package.json`, so the JS/TS defaults in
`~/code/CLAUDE.md` (`pnpm dev`, `pnpm build`, `pnpm test`) do **not** apply here.

All scripts live in `skills/lastcall-shared/scripts/`. The full pipeline:

```bash
S=skills/lastcall-shared/scripts
M=$($S/meter-session.sh <session-uuid>)   # always pass the id; the fallback
                                          # picks the newest transcript, which
                                          # is wrong when sessions share a dir
printf '%s' "$M" | $S/cost.sh             # dollars
printf '%s' "$M" | $S/openloops.sh        # what is unfinished
printf '%s' "$M" | $S/ledger.sh append [sha ...]   # write/replace this row
$S/ledger.sh trend <session-uuid>         # baseline + focus comparison
IDLE_GAP_S=600 $S/meter-session.sh        # widen the idle threshold
```

Set `LASTCALL_LEDGER` to a scratch path while testing so the real baseline at
`~/.claude/lastcall/ledger.jsonl` is not polluted.

Verify a change by running the meter across every local transcript and confirming all
sessions exit 0 — sessions with and without subagents exercise different code paths.

`./install.sh --target claude` links the skills and puts the five scripts on a fixed
path under `~/.lastcall/bin`. A skill with no `SKILL.md` is skipped rather than
installed as an empty directory.

**SkillSpector is the CI security gate.** Every skill under `skills/` is scanned
by NVIDIA SkillSpector on push and PR, and the build fails on any non-suppressed
finding (`.github/workflows/skillspector.yml`, `bin/scan-skills.sh`). It is
complementary to `verify.sh`, which is a local-only correctness sweep over
transcripts — neither replaces the other. Suppressions live in
`.skillspector-baseline.yaml` as fingerprints bound to the source text and the
scanner version, so they fail closed: when a `SKILL.md` edit or a version bump
shifts findings, re-run `bin/scan-skills.sh`, review what resurfaced at its
source location, and re-baseline. Never suppress a finding you have not
understood.

## Architecture Overview

Builds two Claude Code skills for closing out agentic work sessions:

- **`/lastcall`** — wraps up a session: meters tokens/time/cost, summarizes what
  landed, then delegates to other skills (commit, save memories, report, tracker).
- **`/tally`** — the mid-session checkpoint. Metering and readout only, no side
  effects, safe to run at any time.

`meter-session.sh` is the metering layer. It reads Claude Code transcripts from
`~/.claude/projects/<slug>/` and emits pure counts as JSON — deliberately no pricing,
so rates can come from the `claude-api` skill at runtime and this stays correct when
prices change.

Non-obvious constraints the meter handles, each of which silently corrupts totals:
streaming duplicates assistant entries (dedupe by `requestId`); subagent turns live in
separate `<session>/subagents/*.jsonl` files; main threads use 1h cache TTL while
subagents use 5m, which price differently; wall-clock time is meaningless for resumed
sessions, so active time uses gap bucketing.

## Conventions & Patterns

- **Memory**: use this environment's `memory/MEMORY.md` system for session memories.
  The beads block above is task tracking, not a replacement for it — see
  "Memory system — overrides the block above", which is the authoritative
  statement and is placed outside the regenerated markers deliberately.
- **`/lastcall` subsumes the beads "Session Completion" protocol above.** They both
  claim session end, and this is the resolution: the tracker delegation covers steps
  1 and 3 (file issues, update status), the commit delegation covers step 4, and the
  summary covers step 5. Step 2 (quality gates) stays manual — a test command that
  exits non-zero is indistinguishable in a transcript from a grep that matched
  nothing, so test state is never inferred. `lastcall`'s user gate is a stronger
  guarantee than the conservative profile's "ask first", not a weaker one: it asks
  per durable action. The overlap is documented in `skills/lastcall/SKILL.md`.
- **Cost math stays out of the meter.** The meter counts tokens; pricing is applied
  downstream from the `claude-api` skill. Never hardcode rates.
- **Evidence is a drop-box.** External skills contribute work summaries by writing
  JSON to `<session>/evidence/*.json`. `/lastcall` globs that directory, so it needs
  no per-skill integration code.
- **Grounding rule for summaries**: every claim must trace to an artifact — a file
  path, commit SHA, task ID, or test result. Never summarize from conversational
  narrative alone; transcripts are full of intentions that never landed.
- Two jq traps this codebase has already hit: `add` on objects *overwrites* duplicate
  keys rather than summing them, and `fromdateiso8601` rejects the milliseconds these
  timestamps carry.
