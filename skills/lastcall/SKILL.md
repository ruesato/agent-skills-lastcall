---
name: lastcall
description: Close out a work session — meter what it cost, summarize what actually landed and what is still open, then offer to commit, save memories, publish a report, and update the tracker. Every durable action happens only after you approve it.
when_to_use: Use when the user is ending a session — "let's wrap up", "close this out", "I'm done for the day", "call it here" — or types /lastcall. For a mid-session checkpoint with no side effects, use the tally skill instead; tally measures, lastcall measures and then acts.
argument-hint: "[session-id] [--no-memories] [--no-ledger] [--no-file-issues] [--publish-report] [--reset-setup]"
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
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/memory-check.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/memory-check.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/emit-evidence-beads.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/emit-evidence-beads.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/config.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/config.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/detect.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/detect.sh:*)
---

# lastcall

Measure the session, say what landed, **ask**, then act.

`allowed-tools` above pre-approves the bundled scripts and nothing else. They
measure; none of them takes an outward-facing action. `git commit`, `Write`, and
the tracker are deliberately absent. Do not read that absence as a backstop: a
user's own `permissions.allow` entries — user-level or per-project — can
pre-approve those tools independently, and a blanket grant on `git commit` is a
common one. Where such a grant exists no prompt fires, and the gate in step 5 is
the **only** thing standing between a suggestion and a durable action. Assume
that is the case. Whatever else later becomes a configurable default, the commit
gate stays mandatory and always asked.

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

## 0. Resolve the run plan

Read this before metering — one of the overrides below changes *which session*
step 1 measures.

### What actually reaches you

`$ARGUMENTS` is substituted into a skill body, so whatever the user typed after
`/lastcall` is in front of you. Verified 2026-08-22 against the installed
plugin tree: ten `SKILL.md` files use it, official Anthropic plugins among
them, with usages as blunt as `Parse $ARGUMENTS`. Delivery is not in question.

Parsing is. That text arrives as prose, not as `argv`. Nothing tokenizes it,
nothing rejects an unknown flag, and a near miss produces an *interpretation*
rather than an error. The determinism comes from the table below being written
down and from echoing the result back before anything acts — not from the
harness. So call it what it is when you report it: recognition, not parsing.
Calling a flag "invalid" claims a validator that does not exist here. You either
recognized the text or you did not, and those two failures have different fixes.

Flag form and plain English are the **same mechanism**. The flag is not more
literal than the phrase; it is a stable mnemonic, which is why it is worth
publishing one. The `argument-hint` in the frontmatter lists the same flags for
the slash-command picker — that is a label shown while typing, not a grammar the
harness enforces, so keep it in step with the table below and expect nothing
from it beyond discoverability.

### The vocabulary

| What you see | What it does | Where it lands |
|---|---|---|
| `--no-memories` · "no memories", "skip memories", "don't save memories" | The memories delegation is not offered and does not run. | Steps 5 and 6 |
| `--no-ledger` · "don't log this", "no ledger" | No ledger row is written for this run. **The only way to suppress it.** | Step 7 |
| `--no-file-issues` · "don't file issues" | The tracker files no new issues for open loops. Reconciling issues the evidence says already moved is unaffected. | Step 6 |
| `--publish-report` · "publish the report", "share this", "make an artifact" | The report arrives at the gate **pre-selected**. The gate still asks. | Step 5 |
| `--reset-setup` · "redo lastcall setup", "reconfigure lastcall" | Discard this project's configured answers and ask them again from scratch. | Before step 5 |
| a session id (`a1b2c3d4-…`) | Meter that session instead of this one. | Step 1 |

**The table is closed.** Text that is not in it is not an override — treat it as
context for the summary, or ask. Two consequences worth stating outright,
because both are things a helpful model would otherwise invent:

- **There is no flag that skips the commit gate.** Not `--auto-commit`, not
  `--yes`, not "just commit it". If the user asks for one, tell them it does not
  exist. The gate in step 5 is the only check standing between a suggestion and
  a commit, and a flag that removed it would remove the reason this skill is
  safe to run on a dirty tree.
- **No override adds an outward-facing action silently.** The only opt-in in the
  table, `--publish-report`, ticks a box the user still has to submit.

### Where the defaults come from

Each row starts from what this project already answered during setup, and falls
back to the built-ins described in the rest of this file when it has answered
nothing. **No configured answers must mean exactly today's behaviour** — a fresh
checkout, a machine that never ran setup, and a project whose entry was removed
all behave identically. That equivalence is what makes the configuration safe to
throw away, so never let a missing answer become a different answer.

Configuration may only narrow what `lastcall` does, or pre-tick something it
would otherwise leave blank. It can never make an outward-facing action fire
unseen: **"configured on" means pre-selected in the gate, never that the gate is
skipped.** Ledger and memories are local and reversible, so they may be
defaulted outright; the report and the tracker leave this machine, so they
are confirmed every single time regardless of what is configured; the commit
gate takes no configuration at all.

`--reset-setup` routes to section 0b. Where this project has no recorded
answers, there is nothing to reset — say so plainly and offer setup instead.

### Ambiguity stops — it does not guess

A UUID and an English phrase rarely collide, but the near cases are real: a bare
"no", a lone word like "report", a flag that is close to a table entry without
being one, an id-shaped token that is actually a branch name. **Ask.** One
`AskUserQuestion` offering the two readings costs a round trip; guessing costs
either work the user wanted skipped or an action they never requested, and they
find out afterwards.

Fathom draws the same line during tracker setup — *"stop and ask which question
it answered; never guess, and never treat an ambiguous or negative reply as
approval"* — in its case, approval to file. The second clause is the one that
binds here. An ambiguous reply is not approval.

## 0b. Setup — first run, and re-run

Two scripts answer everything this section needs, and both are cheap enough to
run before metering:

```bash
"$DETECT" --cheap        # what is available here
"$CONFIG" drift          # has this project answered, and is the answer stale
```

`drift` returns a `recommend` field, and it is the whole routing decision:

| `recommend` | Meaning | What you do |
|---|---|---|
| `first_run` | This project has no recorded answers | Offer the screen below, once |
| `rerun_setup` | Answers exist but predate options that now exist | One line in the closing summary. Not a screen |
| `none` | Answers exist and are current | Nothing. Say nothing |

`first_run` and `rerun_setup` are different populations, and treating them alike
is the mistake to avoid: someone who has never seen setup should not be shown an
upgrade notice, and someone mid-project should not be re-interrogated because a
release added a question.

### The first-run screen

**Lead with what was found, not with a question.** The detection is the useful
part; the question is a formality on top of it.

> Setting up lastcall for `<project>` — one time.
> Detected: memories → Claude Code's own memory system · tasks → beads · tracker → GitHub Issues.
> Also present but not reachable: Linear (needs authentication) — run `/mcp` and I will pick it up next time.

Then **one** `AskUserQuestion`, `multiSelect`, pre-ticked to the built-ins:

- ☑ **Save memories** — what this project taught you, so a later session starts informed. Each one is named in the closing summary.
- ☑ **Keep the ledger row** — the measurement this run produced. Without it, a cost figure has nothing to be compared against.
- ☐ **Publish a report** — a shareable artifact. Off unless asked; `--publish-report` opts in per run.
- ☐ **File open loops to the tracker** — the titles are always shown and confirmed before anything is filed.

A second question, *which tracker owns this project*, appears **only when two or
more trackers came back eligible**. One or none is not a question. Today, in most
projects, that means first run is a single screen.

### What the screen must not do

- **It must not ask which memory system to use.** That is resolved by looking,
  not by asking. `detect.sh` reports it; the alternatives cannot carry the same
  record — no type, no description, no links between entries — so offering the
  choice would be offering a worse answer as though it were equal.
- **It must not offer a tracker that came back anything other than `connected`.**
  Report those with their remediation. An offer implies it will work.
- **It must not treat a short tracker list as proof of absence** when
  reachability was not measured. `detect.sh` says so in `caveats` when that is
  the case; pass it through rather than reading silence as "none here".

### Dismissal

Escaping the screen records nothing. The run continues on the built-ins, which
is the same behaviour as a machine that never had setup at all — so a dismissal
costs the user nothing and commits them to nothing.

Offer it once more on the next close. If it is dismissed a second time, record
*that* and stop offering. Repeatedly asking someone who has twice declined is
how a helpful prompt becomes a nuisance, and the answer is still recoverable
with `--reset-setup` whenever they want it.

**A dismissal is not an answer.** Never read it as agreement to the pre-ticked
boxes, and never read it as rejection of the skill.

### Re-running it

Three ways back in, deliberately unequal in how loud they are:

1. **The user asks** — `--reset-setup`, or "redo lastcall setup". Drops this
   project's answers and runs the screen again. Always available.
2. **Options have been added since** — `drift` returns `rerun_setup` and names
   them. Surface **one line** in the closing summary, e.g. *"setup has new
   options since this project was configured (filing issues). Say 'redo lastcall
   setup' to review."* An offer, not a flow, and never an automatic change: an
   upgrade must not alter behaviour for someone who did not ask for it.
3. **Something unreachable became reachable** — the common case is a tracker
   that needed authentication at setup and now has it. You can see the tools
   available to you in this session at no cost, so notice it that way rather
   than re-probing on every close. Mention it once, the same single line.

In all three, what a project has already answered stays answered until the user
chooses otherwise. A new option arrives unticked, not applied.

## 1. Meter

Resolve `$METER`, `$COST`, `$OPENLOOPS`, `$LEDGER_SH`, `$DOCTRINE`,
`$MEMCHECK` (`memory-check.sh`, used in step 5),
`$EMIT_BEADS` (`emit-evidence-beads.sh`, used in step 7), `$CONFIG`
(`config.sh`) and `$DETECT` (`detect.sh`, both used in section 0b) to the first
location that exists:

1. `${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/<script>` — substituted in
   Claude Code, and matches the `allowed-tools` grants above, so it runs without
   a prompt.
2. `~/.lastcall/bin/<script>` — a fixed absolute path created by `install.sh`.
   Use this in Kiro, which has no skill-directory variable.

```bash
"$METER" ${CLAUDE_SESSION_ID}
```

**Always pass a session id.** Use the id above by default; when step 0 resolved
a session id out of the invocation, meter that one instead. With no id at all
the meter falls back to the newest transcript in the project directory, which is
the wrong session whenever two share a directory.

Keep this output. You need it again in step 7, and re-running the meter mid-flow
gives a different (larger) number that will not match what the user approved.

If the meter exits non-zero, report stderr verbatim and stop. Do not estimate.

**If the output carries a top-level `stub` block, there was no transcript to
read.** Keep going — that is what the stub is for. Everything from step 3 on
still works, because open loops, the evidence drop-box and every delegation read
git and the drop-box rather than the transcript. What changes:

- Say once, plainly, that this session was **not metered** and why (`stub.reason`).
- Report **no** cost, token, time or friction figures. They are unmeasured, not
  zero, and `cost.sh` returns `total_usd: null` for exactly that reason. Do not
  fill the gap with an estimate.
- Step 7 writes no ledger row; `ledger.sh` declines it and says so. Report that
  rather than treating it as a failure.
- Evidence found under a stub id is scoped to the **directory**, not to this
  session, so describe it as outstanding work here rather than as work this
  session did.

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

**Quote `usd_per_turn` beside `usd`, never `usd` alone.** A row measures spend
while a skill held attribution, so it is dominated by window length times
resident context and will rank a cheap skill invoked late above an expensive one
invoked early. For what a skill cost to load, read
`work.skill_load[].load_tokens`, which is an upper bound and is `null` when
unmeasured. `references/summary.md` has the full reading.

`effort`, `thinking_carry_usd`, `cache_reestablish`, and `tool_context` are the
four figures that name something changeable rather than restating the total.
Report the ones that are actually large — `references/summary.md` says how to
read each, including which of them must not turn into a configuration
recommendation.

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

Evidence arrives through the drop-box at
`~/.claude/lastcall/evidence/<session-id>/*.json` (override with
`LASTCALL_EVIDENCE_DIR`) — producers write there, and `ledger.sh` folds it into
`.evidence`. It is keyed on the session id alone, so a directory rename or a
`--worktree` session still finds its own evidence. Glob it, skip
unparseable files with a warning rather than aborting, and merge on `task.id`
alone — the producer name is not part of the identity, so two producers
describing one task yield one task, with their artifacts pooled and the highest
`emitted_at` deciding the rest. Full shape in
`../lastcall-shared/references/contracts.md` section 2.

`openloops.sh` gives you `session_files_uncommitted`, `churn_hotspots`,
`todos_added`, and `evidence_open`. Its `git.dirty` also decides whether the
commit delegation is offered at all in step 5.

Each entry in `todos_added` carries the `file` it landed in, repo-root-relative
like every other path in that output, so a marker can be reported somewhere the
reader can act on. The scan covers markers added to tracked files *and* markers
in files git does not track yet: an untracked file is in neither `git diff` nor
`git diff --cached`, so before 2026-08-25 a session that created a new file full
of TODOs reported none of them. `.gitignore` still applies and binaries are
skipped, so build and vendor trees stay out of it.

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

## 3b. Establish what you can actually see

Do this **before** writing anything qualitative. Two questions, both cheap:

**1. Are you metering yourself?** Compare the id you metered against
`${CLAUDE_SESSION_ID}`. They differ whenever this skill was invoked with an
argument. When they differ you have **never seen that conversation** — it was
never in your context and nothing in this project reads it from disk.

**2. Was the session compacted?** `context.compactions > 0` means part of it
left your context window; `context.dropped_tokens` says how much.

```bash
printf '%s' "$M" | jq -c '{metered: .session.id, context}'
```

Neither affects the numbers. The meter, `cost.sh`, `openloops.sh`, and the
evidence drop-box all read from disk and are complete and correct for any
session id, compacted or not. **Report them in full regardless.**

What they affect is everything sourced from the conversation — the Headline
rationale, the *why* behind Landed items, narrative, and test outcomes. When
either check trips, **say so plainly and drop those sections** rather than
writing them from what little you have:

> Metered session `a1b2c3d4` — not this one. Numbers below are complete; the
> narrative and *why* sections are unavailable, because this session never saw
> that conversation.

> This session was compacted once, dropping ~260k tokens. Everything below the
> numbers covers only what remained in context.

`session.ai_title` still works in both cases — it is carried by the meter, so
the Headline keeps a real source. Treat it as a label for what the session was
*about*, never as evidence that anything landed.

The failure this prevents is the one this whole skill exists to avoid: a
confident summary built on a fraction of the session reads exactly like one
built on all of it.

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

### Echo the run plan first

Before you present the gate — before any delegation is even offered — print one
line naming what this run resolved to:

> Run plan: memories ON (default) · ledger ON · report OFF · tracker
> github-issues, filing OFF (--no-file-issues)

Name the *source* in parentheses for each: `(default)` for a built-in,
`(configured)` for this project's answer, the flag itself for a per-run
override. That parenthetical is the whole value of the line.

Recognition in step 0 is a judgment call, so sooner or later it will be wrong.
This line is what makes a wrong reading survivable: it turns a misread override
from a silent wrong action into a visible one, sitting directly above the
question the user is already answering, where correcting it costs a sentence.
It is the cheapest safety in the design — without it, plain-English overrides
are a guess with consequences.

Print it on every run, including the one where nothing was overridden. A line
that appears only when something is unusual teaches the user to read its absence
as "nothing to see", and the all-defaults line is precisely the one that
establishes what the defaults are.

### Ask

Present the summary, then ask which delegations to run. Use `AskUserQuestion`
with `multiSelect: true`, and offer only what applies:

| Delegation | Offer it when | Skip it when |
|---|---|---|
| Commit | `git.dirty` is true | tree is clean |
| Memories | something durable was learned | nothing was, or `--no-memories` |
| Report | always | — |
| Tracker | a tracker is configured (`bd`, Linear, Asana) | none is |

Two things not to do here: do not offer a delegation you already know has
nothing to do, and do not manufacture work to fill a slot. An unoffered
delegation is the correct outcome when its precondition is absent.

Where the run plan says a delegation is on, offer it **pre-selected**.
Pre-selected is not approved — the user still submits the gate, and unticking a
box is one keystroke. The report and the tracker are never more than
pre-selected no matter what is configured, because both leave this machine.
Memories may instead be defaulted on and run without appearing here at all,
which is the one place the gate genuinely shrinks; that trade is paid back in
step 8, where every file written is named. Disclosure after the fact is the
right shape for something a `rm` undoes.

If the user declines everything, go straight to step 7. The ledger row is a
measurement, not a delegation — it is written either way, unless `--no-ledger`
was given.

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

When this ran because it was defaulted on rather than because it was ticked at
the gate, **name every file you wrote in step 8**. That disclosure is the entire
justification for skipping the prompt: undoing a memory is deleting a file, so
telling the user afterwards is a fair trade, while telling them nothing is not.

#### Then check that it landed

```bash
"$MEMCHECK" <every file you just wrote>
```

The doctrine check above runs *before* the write and only sees one failure path.
This one runs after and covers the rest: a `Write` that was denied, frontmatter
the recall step cannot parse, a file that never got an index line, or a doctrine
vector the scan cannot see. All of those end with the store unchanged and a
readout that says "saved 2 memories".

**If `ok` is false, say so in step 8 and do not report the memories step as
successful.** Report the `problems` array as written — each entry names a file
and what is wrong with it, which is enough to fix by hand. Re-writing the file
once is reasonable if the problem is yours to fix (bad frontmatter, missing
index line); a denied `Write` is the user's call, so surface it rather than
retrying. Skipping the check because the write "obviously worked" defeats the
one failure mode it exists for — this failure always looks like success.

If the memories delegation deliberately wrote nothing, do not run this. It
reports `claimed: 0`, which is honest but says nothing you did not know.

### Report

Publish the step-4 summary as a shareable artifact. **If artifact publishing is
unavailable, fall back to terminal output** — the summary is the deliverable,
the artifact is just its nicest form. Never let a publishing failure lose it.

### Tracker

File new issues for the open loops from step 3, and update the issues the
evidence says moved.

`--no-file-issues` removes the first half only: file nothing new, and still
reconcile the issues the evidence says already moved. The two are different
actions — one creates rows in someone else's backlog, the other corrects rows
that are already there — and a user who wants the noise suppressed almost never
wants the corrections dropped with it. Report the loops you did not file so
they survive in the readout.

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
printf '%s' "$M2" | "$EMIT_BEADS" <sha> ...     # no-op without a beads workspace
printf '%s' "$M2" | "$LEDGER_SH" append <sha> ...
```

`emit-evidence-beads.sh` runs **before** the append, because `ledger.sh` reads
the drop-box while building the row. It derives one `lastcall.evidence/1` file
from beads closed inside the session window, and exits 0 silently when there is
no beads workspace — the normal case for most projects. Both scripts
**discover the session commits themselves**, from the metered window, so a
session whose commits were made by another skill is still grounded; pass any
SHAs you do know about and they are unioned in. A commit that names a bead
becomes that task's artifact, a commit that merely falls inside the bead active
range is a weaker `window` match, and a `completed` task with no artifact at all
is reported as `unverified` rather than counted. That is the grounding rule reaching into the evidence layer, so do not
invent artifacts to make the number look better.

Why twice: the first reading was taken before this skill did its own work, so it
understates the session by exactly the amount `lastcall` cost. The second
reading is what the ledger should carry. It is a jq pass over a local file — the
second run is free.

`work.commits` is discovered from the same window. Pass any SHAs the commit
delegation produced and they are unioned in, but the row no longer depends on
it: before discovery, a clean-tree session recorded an empty commit list and
every task in it read as unverified.

**On a stub meter this step writes nothing, by design.** Both scripts decline
and say so on stderr: there is no session window to match beads against, and a
row with no measurements in it would poison the baseline it was added to rather
than extend it. Report that the session was not metered and move on — it is not
a failure to retry.

The ledger is **keyed on `session_id` alone** and replaces that session's row in
place, so re-running never appends a duplicate. Written by `lastcall` only —
`tally` never writes.

`--no-ledger` skips the `append` and nothing else: still re-meter, still run
`emit-evidence-beads.sh`, still report the final numbers in step 8. What the
user loses is this run in the baseline, so say so — `trend` compares against a
median, and a session omitted from it is a session that quietly stops counting.
There is no gate for the row precisely because this flag exists; a prompt on
every run for a local idempotent line would train the user to click through the
prompts that matter.

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

Anything that ran on a default rather than on an answer gets **named, not
counted**: the memory files by path, a skipped ledger row as a skipped ledger
row. "Saved 2 memories" is a summary; the two paths are something the user can
act on. Close the loop the run plan opened — the line at step 5 said what was
about to happen, and this one says what did.

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
