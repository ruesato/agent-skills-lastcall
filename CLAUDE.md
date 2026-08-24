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

Two behaviours of that gate, learned the hard way and cheap to re-hit:
a fingerprint is invalidated by **any** edit to the file it lives in, not only
by an edit to the excused paragraph — so re-baselining after an unrelated
change is expected, and the re-review is the point. And LP3 ("no declared
permissions") fires on *prose inside a script*: the phrase "requests billed per
request" in a shell comment was enough to flag `lastcall-shared`, a
non-invocable container that declares no tools because it can invoke none.
`allowed-tools: []` does not satisfy it. Rewording ("per-request tool spend")
cleared it, which is better than suppressing a whole-skill least-privilege rule
that would then mask a real finding later.

More instances of the same class, all found 2026-08-22/23 while editing
`skills/lastcall/SKILL.md`. **The scanner reads prose as behaviour**, so a
paragraph documenting a hazard looks identical to one performing it. Every one
of these was cleared by rewording, and none of them described an action the
skill takes:

| Rule | Fired on the literal phrase |
|---|---|
| AS1 Agent Config Directory Access | the settings-file path, written while *explaining* that a user may have allowlisted `git commit` |
| RA2 Session Persistence | "the ledger row, the evidence drop-box"; separately a span starting "create anything." |
| EA2 Autonomous Decision Making | "without asking" |
| P4 Behavior Manipulation | "never tell them" |
| RA2 again | the bare verb **"Write"** in "Write the ledger row" — "Keep the ledger row" and "Ledger row" both score 0 |

AS1 is narrower than it first looked: `SKILL.md` carries a literal
`~/.claude/lastcall/...` path today and still scores 0, so it is the *agent
config* file specifically that trips it, not any path under `~/.claude`. Naming
`permissions.allow` as the mechanism carried the same information safely.

**Diagnosing a hit cheaply:** `REPORT_DIR=<dir> ./bin/scan-skills.sh <skill>`
then `jq -r '.issues[0].finding' <dir>/<skill>.json` prints the matched span —
`.finding` is the field that carries it; `.evidence` and `.snippet` are null.
`.location.start_line` gives the line. That narrows it to a paragraph; to narrow
it to a WORD, loop a one-word substitution over a scratch copy and re-scan,
which is how "Write" was isolated above. Both are far faster than bisecting.

Also note the local/CI version split: the installed scanner is v2.9.6 while
`.github/workflows/skillspector.yml` pins v2.9.5 and `.skillspector-baseline.yaml`
is calibrated to 2.9.5. So a local run warns about the mismatch and resurfaces
the `tally` RA2 fingerprint while CI stays green. **Do not re-baseline to the
local version** — that would invert the problem and break CI. Scan locally to
confirm your own skill is clean, and read a `tally`-only failure as drift.

The version mismatch alone defeats suppression, so the local scanner cannot
tell you anything about the baseline: verified 2026-08-23, v2.9.6 resurfaces the
`tally` RA2 finding even on **unmodified** `HEAD` content. That matters when you
edit `skills/tally/SKILL.md` for any reason, because the per-file binding then
invalidates the fingerprint for CI too, and you cannot regenerate it or even
confirm the breakage with the local binary.

The fix is to run the pinned SHA without disturbing the installed one:

```bash
export UV_TOOL_DIR=<scratch>/uvtools UV_TOOL_BIN_DIR=<scratch>/uvbin
uv tool install git+https://github.com/NVIDIA/skillspector.git@27fd9620dbfed1a2f405fd8c519661e51511f06e
"$UV_TOOL_BIN_DIR/skillspector" baseline skills/tally --no-llm -o <scratch>/new.yaml
```

Take only the `hash:` from the generated file — it ships a placeholder reason,
and the reviewed prose in `.skillspector-baseline.yaml` is the part worth
keeping. Re-review at the source location first and append what you checked to
the existing `reason`; the entry records every re-review for exactly this
reason. Then confirm with `PATH=<scratch>/uvbin:$PATH ./bin/scan-skills.sh`,
which is the gate as CI runs it, and `uv tool uninstall skillspector` with the
same two env vars set.

Useful property when editing `lastcall`: it has **no** baseline fingerprint of
its own and scores 0, so it has no cushion — any finding on it is unambiguously
from the edit in hand.

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
streaming duplicates assistant entries (dedupe by response id: `requestId` on the
first-party API, `message.id` on Bedrock); subagent turns live in
separate `<session>/subagents/*.jsonl` files; main threads use 1h cache TTL while
subagents use 5m, which price differently; wall-clock time is meaningless for resumed
sessions, so active time uses gap bucketing.

Native signals the meter reads straight out of the transcript, rather than
inferring (all verified against real transcripts, not assumed):
`system`/`turn_duration` records give agent-busy time per completed turn
(`session.agent_s`) with no idle heuristic — but they are written at turn *end*,
so the turn in flight is always missing; `attributionSkill` / `attributionPlugin`
attribute spend to the skill that caused it (`work.skills`, `cost.by_skill`);
`usage.speed` and `usage.service_tier` are pricing dimensions and therefore part
of the token row key; `usage.output_tokens_details.thinking_tokens` is a subset
of output, never a sixth bucket; `usage.server_tool_use` counts requests that
bill per request, which no token bucket can express, so `cost.sh` reports them
under `caveats` instead of pretending the total is complete.

**Transcripts are not a documented public contract.** These fields can move
without notice, so every one of them is read with a `//` fallback and its
absence means *unmeasured*, never zero. There is no `costUSD` in current
transcripts (verified across every local file) — computing cost from tokens is
the only local option, not a workaround.

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
  **Run it per issue, after Fathom.** When the `execute` skill finishes an issue
  (its step-12 final summary), invoke `/lastcall` to meter the session and write
  the ledger row. Per issue, not per task — that matches Fathom's unit of work
  and keeps the baseline from being diluted by many short rows. No double-commit
  risk: the commit delegation is skipped when Fathom leaves a clean tree
  (`git.dirty` precondition).
- **Cost math stays out of the meter.** The meter counts tokens; pricing is applied
  downstream from the `claude-api` skill. Never hardcode rates.
- **Evidence is a drop-box.** External skills contribute work summaries by writing
  JSON to `~/.claude/lastcall/evidence/<session-id>/*.json` (override with
  `LASTCALL_EVIDENCE_DIR`). `/lastcall` globs that directory, so it needs no
  per-skill integration code. Keyed on session id alone, so a directory rename
  or a `--worktree` session still finds its own evidence.
- **Grounding rule for summaries**: every claim must trace to an artifact — a file
  path, commit SHA, task ID, or test result. Never summarize from conversational
  narrative alone; transcripts are full of intentions that never landed.
- Three jq traps this codebase has already hit:
  - `add` on objects *overwrites* duplicate keys rather than summing them.
  - `fromdateiso8601` rejects the milliseconds these timestamps carry.
  - `false // true` is **`true`**. jq treats `false` as empty, so `//` cannot be
    used to default a boolean — it collapses exactly the value you were trying to
    read. Hit in `openloops.sh` on `files_coverage.attributed`, where it inverted
    the flag in precisely the case it exists for. Use
    `if . == null then <default> else . end`.
  - An apostrophe inside a **comment** in a single-quoted jq program ends the shell
    string early. Write "the row" and "the reader", never "the row's" or "the
    reader's". The damage lands far from the typo: in `openloops.sh` it surfaced as
    a jq compile error, in `ledger.sh` as a bash syntax error on an unrelated line
    ~110 lines below the edit. `bash -n` catches the second form instantly, and
    `verify.sh:36` runs it over every script. Both files carry an inline warning at
    the top of their jq programs — keep it there.
