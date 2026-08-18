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


## Build & Test

This is a **shell + jq project**. There is no `package.json`, so the JS/TS defaults in
`~/code/CLAUDE.md` (`pnpm dev`, `pnpm build`, `pnpm test`) do **not** apply here.

```bash
./meter-session.sh                  # meter the current session
./meter-session.sh <session-uuid>   # meter a specific session
IDLE_GAP_S=600 ./meter-session.sh   # widen the idle threshold
```

Verify a change by running the meter across every local transcript and confirming all
sessions exit 0 — sessions with and without subagents exercise different code paths.

## Architecture Overview

Builds two Claude Code skills for closing out agentic work sessions:

- **`/last-call`** — wraps up a session: meters tokens/time/cost, summarizes what
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
  The beads block above is task tracking, not a replacement for it.
- **Cost math stays out of the meter.** The meter counts tokens; pricing is applied
  downstream from the `claude-api` skill. Never hardcode rates.
- **Evidence is a drop-box.** External skills contribute work summaries by writing
  JSON to `<session>/evidence/*.json`. `/last-call` globs that directory, so it needs
  no per-skill integration code.
- **Grounding rule for summaries**: every claim must trace to an artifact — a file
  path, commit SHA, task ID, or test result. Never summarize from conversational
  narrative alone; transcripts are full of intentions that never landed.
- Two jq traps this codebase has already hit: `add` on objects *overwrites* duplicate
  keys rather than summing them, and `fromdateiso8601` rejects the milliseconds these
  timestamps carry.
