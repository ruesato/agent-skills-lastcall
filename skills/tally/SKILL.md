---
name: tally
description: Report what the current session has cost so far — tokens, active time, files touched, and friction — without ending it or changing anything. A read-only checkpoint that is always safe to run.
when_to_use: Use when the user asks how much this session has cost, how long they have been working, how many tokens have been burned, where things stand, or types /tally. Safe at any point mid-session; it has no side effects and writes nothing. If the user wants to END the session — wrap up, commit, save memories, close out — use the lastcall skill instead.
argument-hint: "[session-id]"
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/meter-session.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/meter-session.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/cost.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/cost.sh:*)
---

# tally

A checkpoint, not a closeout. Meter the session, print the numbers, stop.

## Absolute boundary

**This skill has no side effects.** It does not commit, does not write to the
ledger, does not save memories, does not touch the evidence drop-box, and does
not modify any file. If the task in front of you needs any of those, you are in
the wrong skill — use `lastcall`.

That guarantee is the entire reason `tally` exists separately. Never weaken it.

## Steps

### 1. Run the meter

```bash
"$METER" ${CLAUDE_SESSION_ID}   # current session
"$METER" <session-id>           # a specific session
```

**Always pass the session id.** With no id the meter falls back to the newest
transcript in the project directory, which is the *wrong* session whenever two
sessions share a directory — a common case. Claude Code substitutes
`${CLAUDE_SESSION_ID}` in this file; Kiro does not, so there the meter reads the
`CLAUDE_SESSION_ID` environment variable, and falls back to newest only if
neither is available.

Resolve `$METER` to the first of these that exists:

1. `${CLAUDE_SKILL_DIR}/../lastcall-shared/scripts/meter-session.sh`
   — substituted in Claude Code; matches the `allowed-tools` grant above, so it
   runs without a permission prompt.
2. `~/.lastcall/bin/meter-session.sh`
   — a fixed absolute path created by `install.sh`. Use this in Kiro, which has
   no skill-directory variable.

`$COST` resolves the same way, as `cost.sh` in that same directory.

When this skill was invoked with an argument, that argument is the session id to
meter instead of the current one.

If the meter exits non-zero, report the stderr verbatim and stop. Do not
estimate numbers it failed to produce.

### 2. Read the output

The shape is specified in `../lastcall-shared/references/contracts.md` section 1.
Two fields are easy to misread:

- **`session.wall_s` is not how long the user worked.** A resumed session spans
  days. Always report `session.active_s`.
- **`session.agent_s` is not the same number as `active_s`.** It is Claude Code
  own sum of completed turn durations — agent busy time, with no idle threshold
  in it — while `active_s` is how long the *user* was engaged. Expect `agent_s`
  to be the smaller of the two. It is a floor: the turn in flight has not been
  recorded yet, so mid-session it always lags, and it is `0` before the first
  turn completes. Report it only alongside `active_s`, never instead of it, and
  omit it when `agent_turns` is 0.
- **`tokens` is one row per (model, lane, speed, service_tier).** Sum across
  rows for totals, and keep `lane: "subagent"` visible when it is a meaningful
  share — subagent cost is invisible to the user otherwise. A `speed` or
  `service_tier` other than `"standard"` means the row is not priced correctly;
  `cost.sh` flags it in `caveats`.
- **`tokens[].thinking` is part of `output`, not an addition to it.** Report it
  as a share ("of which 63.8k thinking"), never as another bucket.

### 3. Print one line

```
tally · 47m active · $4.18 · 148.5k out · 35.0M cached · 25 files · 7 errors
```

Rules for the readout:

- Lead with active time, then cost. Those are the two numbers the user is
  actually calibrating against.
- Abbreviate: `k` above 1,000, `M` above 1,000,000, one decimal place.
- Omit any segment that is zero. A session with no errors should not say `0 errors`.
- Append ` · N subagents` only when `agents` is non-empty.
- Singularize counted nouns at 1: `1 subagent`, `1 error`, `1 file`.
- Round cost to cents for display (`$18.24`). `cost.sh` returns four decimal
  places on purpose — the ledger sums them and sub-cent precision matters there
  — but a readout showing `$18.2358` reads as noise.

Expand beyond one line **only** if the user asked for detail. When they do, add
the per-model/lane token table, the top few churn hotspots from `work.files`
(highest edit counts first — repeated edits to one file are a struggle
signature), and the friction counts broken out.

### 4. Cost

Pipe the meter's output through the cost script, which lives beside it:

```bash
"$METER" ${CLAUDE_SESSION_ID} | "$COST"
```

Read `total_usd` for the headline and `by_bucket` when the user wants detail.

Two things this reports that are easy to miss:

- **`promo_applied`** — a promotional rate was in effect when those tokens were
  burned. Mention it when true; it explains a figure that won't reproduce later.
  It is true when **any** lane billed at a promo, so check `promo_models` and
  name them: a session mixing a promo model with a full-rate one is the normal
  case, and "partly promotional" is the accurate thing to say.
- **`pricing_source`** — which rate table produced the number, as
  `source@verified-date`.
- **`caveats`** — a non-empty array means `total_usd` is known to understate.
  **Always surface it**, in the one-line readout if need be: a figure that is
  quietly missing per-request server-tool spend, or that priced a fast-mode
  session at standard rates, is exactly the kind of wrong number that looks
  right.

When the user asks for detail, `by_skill` answers "what did each skill cost" —
including what this skill costs to run. The `skill: null` row is the
unattributed remainder, so label it as such rather than dropping it.

If the cost script errors with an unknown model, **report the error and give the
token counts without a dollar figure.** Never substitute a guessed rate — a
wrong cost figure is worse than no cost figure, because nothing about it looks
wrong. See `../lastcall-shared/references/pricing.md`.

## 5. Native signals

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

## 6. When file counts are unavailable

`work.files` is built from `Edit`, `Write`, and `NotebookEdit` calls only. A
session that edits through Bash — heredocs, `sed -i`, a script that writes files
— leaves nothing there, and some harness modes instruct Bash-first editing, so
this is a normal operating condition rather than an edge case.

`work.files_coverage` says whether to trust it:

```jsonc
{ "edit_tool_calls": 0, "bash_calls": 86, "attributed": false }
```

**When `attributed` is false, report that the file-level view is unavailable.**
Do not print `0 files`, and do not drop the segment silently either — an absent
number and a zero read identically to someone scanning a one-line readout, and
zero is the one that is wrong. Say "files: not measured (edited through Bash)"
and give the Bash call count if the user wants the detail.

This does not affect anything else. Cost, tokens, time, friction, and skill
attribution are all still exact — only the per-file breakdown degrades.

## Notes

Report what the meter measured, nothing more. Do not infer productivity from
token counts here: burn measures effort, not output, and a session that thrashes
scores higher than one that succeeds cheaply. Interpretation is `lastcall`'s
job, and it needs the evidence drop-box to do it honestly.
