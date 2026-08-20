---
name: lastcall
description: Close out a work session — meter what it cost, summarize what actually landed and what is still open, then offer to commit, save memories, publish a report, and update the tracker. Every durable action happens only after you approve it.
when_to_use: Use when the user is ending a session — "let's wrap up", "close this out", "I'm done for the day", "call it here" — or types /lastcall. For a mid-session checkpoint with no side effects, use the tally skill instead; tally measures, lastcall measures and then acts.
argument-hint: "[session-id]"
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/meter-session.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/meter-session.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/cost.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/cost.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/openloops.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/openloops.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/ledger.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/ledger.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/doctrine-check.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/doctrine-check.sh:*)
---

# lastcall

Measure the session, say what landed, **ask**, then act.

`allowed-tools` above pre-approves the five bundled scripts — all read-only.
It deliberately does **not** pre-approve `git commit`, `Write`, or the tracker.
Those still go through the normal permission prompt, so the gate in step 5 is
backed by a second, independent check rather than being the only thing standing
between a suggestion and a durable action.

## The one rule

**No durable action happens before the gate.** Steps 1–4 read. Step 5 asks.
Only step 6 writes.

Committing code, saving memories, publishing a report, and updating a tracker
are outward-facing and awkward to reverse. The user sees the summary first and
picks which of them fire. This ordering is the whole point of the skill — if you
find yourself committing before summarizing, stop and start over.

**Partial completion is the normal path.** The user approving two of four
delegations is a success, not a degraded run. Never re-ask for a declined
delegation, and never let one delegation's failure abort the others.

---

## 1. Meter

Resolve `$METER`, `$COST`, `$OPENLOOPS`, `$LEDGER_SH`, and `$DOCTRINE` to the
first location that exists:

1. `${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/<script>` — substituted in
   Claude Code, and matches the `allowed-tools` grants above, so it runs without
   a prompt.
2. `~/.lastcall/bin/<script>` — a fixed absolute path created by `install.sh`.
   Use this in Kiro, which has no skill-directory variable.

```bash
"$METER" ${CLAUDE_SESSION_ID}
```

**Always pass a session id.** Use the id above by default; when this skill was
invoked with an argument, that argument is the session to meter instead. With no
id at all the meter falls back to the newest transcript in the project
directory, which is the wrong session whenever two share a directory.

Keep this output. You need it again in step 7, and re-running the meter mid-flow
gives a different (larger) number that will not match what the user approved.

If the meter exits non-zero, report stderr verbatim and stop. Do not estimate.

## 2. Cost

```bash
printf '%s' "$M" | "$COST"
```

Report `total_usd`, and mention `promo_applied` when true — a promotional rate
explains a figure that will not reproduce later. It is true when **any** lane
billed at a promo, so name the models from `promo_models`; a session mixing a
promo model with a full-rate one is the normal case, and reporting it as
wholly promotional is as wrong as dropping it. On an unknown-model error,
report token counts with **no dollar figure**. Never substitute a guessed rate:
a wrong cost figure is worse than none, because nothing about it looks wrong.
See `../lastcall-shared/references/pricing.md`.

**Surface `caveats` whenever it is non-empty.** It lists what `total_usd` is
known to leave out — server-tool requests that bill per request rather than per
token, or a fast-mode/priority-tier row that no rate in the table covers. This
figure goes into the ledger and becomes a baseline other sessions are compared
against, so an unflagged understatement contaminates every later comparison.

`by_skill` is available when the user wants to know where the money went by
skill rather than by model. The `skill: null` row is the unattributed
remainder — plain conversational turns — not a skill named null.

### Native signals — only when `.native` is present

`meter-session.sh` emits a `native` block **only** when the optional statusLine
capture exists for this session (see the README). Most sessions will not have
it, and then the key is absent entirely.

**Absent means unmeasured. Never report a missing number as zero**, and never
reconstruct one of these from something else. A session that reports "0% of the
5-hour window used" tells the user they have the whole window left, which is a
worse outcome than saying nothing at all.

- **`native.rate_limits`** — the payoff. `five_hour` and `seven_day` each carry
  `used_percentage` and `resets_at` (epoch seconds, with `resets_at_utc`
  alongside). **Convert the reset to the user local time** before reporting it:
  `date -r <epoch>` on macOS, `date -d @<epoch>` on Linux.

  Report it as the constraint that actually binds. On a Max plan the real cost
  of a session is a slice of the window, not a dollar figure, and `resets_at`
  is what makes it actionable at close:

  > 71% of the weekly window used, resets Thursday 09:00

  Each window can be absent on its own. Rate limits appear only for Pro/Max
  subscribers and only after the first API response, so a user on an API key
  legitimately has nothing here — say nothing rather than inventing a 0%.

- **`native.split`** — `api_s` is time spent waiting on the model and `tool_s`
  is time spent running tools, which is the difference between "the model was
  slow" and "your test suite is slow". Both inputs are floors measured at
  different moments, so **label it approximate**. When `clamped` is true the
  subtraction went negative and `tool_s` was floored at 0; say the split is
  unavailable rather than reporting a zero as a finding.

- **`native.cost_usd`** — Claude Code own client-side estimate. Never report it
  as the cost; `cost.sh` `total_usd` is the figure. See `cross_check` below.

- **`native.captured_at`** — the capture is only as fresh as the last status
  line render. If it is materially older than `session.ended`, the numbers lag
  the session; say so rather than presenting them as current.

`cost.sh` adds a `cross_check` object whenever a native cost figure exists. It
compares the two independently derived numbers and is **advisory only** — it
never changes `total_usd`. When `comparable` is false, `skipped_reason` says why
(a resumed session or a stale capture covers less work than the transcript
does); report nothing. When `diverged` is true the divergence is already in
`caveats`, naming both figures — surface it, because the likely cause is a stale
`rates.json` and that silently contaminates every ledger comparison downstream.

## 3. Evidence and open loops

```bash
printf '%s' "$M" | "$OPENLOOPS"
```

Evidence arrives through the drop-box at `<session>/evidence/*.json` — other
skills write there, and the meter folds it into `.evidence`. Glob it, skip
unparseable files with a warning rather than aborting, and dedupe on
`(source, task.id)` keeping the highest `emitted_at`. Full shape in
`../lastcall-shared/references/contracts.md` section 2.

`openloops.sh` gives you `session_files_uncommitted`, `churn_hotspots`,
`todos_added`, and `evidence_open`. Its `git.dirty` also decides whether the
commit delegation is offered at all in step 5.

### When file counts are unavailable

`work.files` sees `Edit`, `Write`, and `NotebookEdit` and nothing else, so a
session that edited through Bash reports no files and no churn hotspots however
much it actually changed. `work.files_coverage.attributed` is false when the
session ran Bash but never called an edit tool, and `openloops.sh` carries the
same signal as `churn_available`.

**When it is false, say the file-level view is unavailable rather than reporting
zero**, and drop the churn ratio entirely — a ratio over an unmeasured
denominator is a fabrication. `uncommitted_unattributed` lists the uncommitted
files no edit tool accounts for, which is the closest thing to a file list this
case has; it cannot separate a Bash edit from drift that was already there, so
present it as what it is.

The grounding rule decides the rest: commits and diffs are artifacts and remain
fully usable for the **Landed** section, so a session with no measurable
`work.files` can still be summarized precisely. It is the *counts* that go
missing, not the evidence.

## 4. Summarize

**Read `../lastcall-shared/references/summary.md` and follow it.** It is the
doctrine for this half, not background reading.

The single rule that matters most: every claim under **Landed** must trace to an
artifact — a file path, a commit SHA, a task id, a test result. Transcripts are
dense with intentions that never landed, and from the inside an intention and an
accomplishment read almost identically. If it traces to nothing, it goes under
*narrative*, clearly marked, or nowhere.

Sections: Headline, Landed, Open loops, Friction, Cost. Emit ratios with
explicit denominators, **never a composite productivity score**. With no
evidence, per-task ratios are "not assessed" — say so plainly rather than
inferring output from token burn, which rewards thrashing.

## 5. The gate

Present the summary, then ask which delegations to run. Use `AskUserQuestion`
with `multiSelect: true`, and offer only what applies:

| Delegation | Offer it when | Skip it when |
|---|---|---|
| Commit | `git.dirty` is true | tree is clean |
| Memories | something durable was learned | nothing was |
| Report | always | — |
| Tracker | a tracker is configured (`bd`, Linear, Asana) | none is |

Two things not to do here: do not offer a delegation you already know has
nothing to do, and do not manufacture work to fill a slot. An unoffered
delegation is the correct outcome when its precondition is absent.

If the user declines everything, go straight to step 7. The ledger row is a
measurement, not a delegation — it is written either way.

## 6. Delegate

Run only what was approved. Each is independent: **catch failures per
delegation, report them, and continue to the next.** One failure never strands
the rest.

### Commit

The user's standing rule applies verbatim:

> **Try once. On a git lock error — or any other error — stop and print the
> commit message for them to commit manually. Never retry.**

This is not a suggestion to soften. A retry loop against a lock file is how you
end up with a half-staged tree the user did not ask for.

- Semantic-release format, with bullets summarizing the changes.
- If the task referenced tracker ids (`Linear [ONC-5]`, `agent-skill-wrapup-7re`),
  append `Closes …` listing them.
- Capture the resulting SHA — step 7 puts it in the ledger row.

**Re-running `lastcall` must not double-commit.** The precondition is a dirty
tree, checked fresh in step 3. After a successful commit the tree is clean, so a
second run does not offer the delegation at all. Do not "helpfully" amend or
re-commit an already-committed change.

### Memories

First, check that nothing is contradicting the memory system:

```bash
"$DOCTRINE" .
```

`doctrine-check.sh` looks for guidance saying *"do NOT use MEMORY.md"* in
`CLAUDE.md`, `AGENTS.md`, and live `bd prime` output. Beads ships that rule, and
it is correct for a beads-only workspace but wrong wherever `memory/MEMORY.md` is
authoritative. **If `status` is `conflicts-present`, follow the project's override
and write the memory anyway** — then mention the conflict in the final readout.
The failure mode this prevents is silent: told to bypass MEMORY.md, you would
skip the delegation and report success having written nothing.

Then follow the environment's memory system (here, `memory/MEMORY.md` plus one
file per fact). **Skip silently when nothing durable was learned.** A session
that taught you nothing worth carrying forward should produce no memory — a
manufactured one is worse than an absent one, because it dilutes recall for
every future session.

Save what was non-obvious: a constraint discovered, a preference the user
expressed, a dead end worth not re-walking. Not what the repo already records.

### Report

Publish the step-4 summary as a shareable artifact. **If artifact publishing is
unavailable, fall back to terminal output** — the summary is the deliverable,
the artifact is just its nicest form. Never let a publishing failure lose it.

### Tracker

File new issues for the open loops from step 3, and update the issues the
evidence says moved.

**The evidence `status` is the signal for which of those an entry is. Read it
before touching anything.** A producer that emits evidence is a skill that
completes real work, and it has usually already updated the tracker itself
before handing off. Re-closing its work is a double-touch: it churns the issue
history, and it can reopen-then-close or clobber a status the producer set
deliberately.

| Status | What the tracker delegation does |
|---|---|
| `completed` | **Nothing.** The producer already moved it. Do not close it again. |
| `partial` | File or update an issue for the remaining work. |
| `blocked` | File or update an issue, naming the external dependency. |
| `abandoned` | **Nothing.** Deliberately dropped is not an open loop, and not a failure. |

Two cases that look like exceptions and are not. A `completed` task with an
empty `artifacts` array is reported as **unverified** (contract 2), so it is not
grounds for closing anything — an unverified claim is the weakest possible
reason to touch a tracker. And when no evidence exists at all, there is nothing
to reconcile: file the open loops from `openloops.sh` and leave existing issues
alone, rather than inferring status from the transcript.

**On an API failure, report it and continue** — the tracker is downstream of the
work, and a failed sync is a nuisance, not a reason to abandon the wrap-up.
Print what you would have filed so nothing is lost.

## 7. Re-meter, then write the ledger

Meter **again**, now that delegation is done:

```bash
M2="$("$METER" ${CLAUDE_SESSION_ID})"
printf '%s' "$M2" | "$LEDGER_SH" append <sha> ...
```

Why twice: the first reading was taken before this skill did its own work, so it
understates the session by exactly the amount `lastcall` cost. The second
reading is what the ledger should carry. It is a jq pass over a local file — the
second run is free.

Pass any SHAs the commit delegation produced; they land in `work.commits`.

The ledger is **keyed on `session_id` alone** and replaces that session's row in
place, so re-running never appends a duplicate. Written by `lastcall` only —
`tally` never writes.

Note: if the gate involved a free-text reply, the `allowed-tools` grant has
cleared and this call may prompt for permission. That is expected, not a fault.

## 8. Emit

Close with the final numbers from `M2`, plus the trend:

```bash
"$LEDGER_SH" trend ${CLAUDE_SESSION_ID}
```

Prefer "2.3× your median session" over a bare dollar figure — one session's cost
means nothing without the baseline. When `trend` reports `baseline_note` (under
five rows), **pass that caveat through** rather than presenting a median of
three as typical.

State plainly what ran and what did not: "committed a1b2c3d, saved 2 memories,
skipped the report, tracker update failed — here's the error." A wrap-up that
overstates itself defeats its own purpose.

---

## Relationship to the beads session-close protocol

This project's `CLAUDE.md` carries a beads-managed **Session Completion**
protocol that also claims session end. They do not conflict; `lastcall`
subsumes it, with one carve-out:

| Beads step | Here |
|---|---|
| 1. File issues for remaining work | The **tracker** delegation, fed by `openloops.sh` |
| 2. Run quality gates | **Not automated.** See below |
| 3. Update issue status | The **tracker** delegation |
| 4. Handle git by profile | The **commit** delegation, behind the gate |
| 5. Hand off | Steps 4 and 8 |

The gate *is* the conservative profile's "ask first" — an explicit approval per
durable action, which is strictly stronger than the profile requires.

**Quality gates stay manual on purpose.** A test command that exits non-zero is
indistinguishable in a transcript from a grep that found nothing, so inferring a
pass or a failure from exit codes produces confident, wrong claims. Read the
transcript for test outcomes and report what you actually find, or say nothing.

## Notes

This skill does not set `disable-model-invocation`. Conversational invocation —
"let's wrap up here" — is the primary path, and blocking it would leave only the
slash command. Safety comes from the gate, not from being hard to reach.
