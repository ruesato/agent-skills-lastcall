---
name: tally
description: Report what the current session has cost so far — tokens, active time, files touched, and friction — without ending it or changing anything. A read-only checkpoint that is always safe to run.
when_to_use: Use when the user asks how much this session has cost, how long they have been working, how many tokens have been burned, where things stand, or types /tally. Safe at any point mid-session; it has no side effects and writes nothing. If the user wants to END the session — wrap up, commit, save memories, close out — use the last-call skill instead.
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
the wrong skill — use `last-call`.

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
- **`tokens` is one row per (model, lane).** Sum across rows for totals, and
  keep `lane: "subagent"` visible when it is a meaningful share — subagent cost
  is invisible to the user otherwise.

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

If the cost script errors with an unknown model, **report the error and give the
token counts without a dollar figure.** Never substitute a guessed rate — a
wrong cost figure is worse than no cost figure, because nothing about it looks
wrong. See `../lastcall-shared/references/pricing.md`.

## Notes

Report what the meter measured, nothing more. Do not infer productivity from
token counts here: burn measures effort, not output, and a session that thrashes
scores higher than one that succeeds cheaply. Interpretation is `last-call`'s
job, and it needs the evidence drop-box to do it honestly.
