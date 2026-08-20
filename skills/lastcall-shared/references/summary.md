# Summary

How `lastcall` describes a session. This is the read-only half — everything
before the user gate.

---

## The grounding rule

**Every claim must trace to an artifact:** a file path, a commit SHA, a task
id, a test result, or a tool call.

Transcripts are dense with intentions that never landed — "I'll refactor the
adapter next", "let me add tests for that". A model summarizing its own
session will reliably promote those to accomplishments, because from the
inside an intention and an accomplishment read almost identically.

So the sources have fixed roles, and they are not interchangeable:

| Source | Answers | Never used for | Where it comes from |
|---|---|---|---|
| Meter output | **what** happened | why it happened | `meter-session.sh`, any session |
| Evidence drop-box | **what** completed | anything unverified | `<session>/evidence/*.json` |
| `openloops.sh` | **what** is unfinished | — | git state, any session |
| `session.ai_title` | **what it was about** | that anything landed | the transcript, any session |
| The conversation | **why** it went that way | what happened | **your own context only** |

If a claim can't be traced to one of the first four, it doesn't go under
**Landed**. It can go under *narrative* — clearly marked as such — or nowhere.

### The last row is not a file

The first four rows are read from disk and are complete for **any** session id.
The last one is not read at all — it is in your context because `/lastcall`
normally runs inside the session it is measuring. Nothing hands it to you, and
no script in this project reads conversation content.

That makes the last row the only source that can silently vanish:

- **You are metering a different session.** If the id you metered is not
  `${CLAUDE_SESSION_ID}`, you have never seen that conversation. Not a
  degraded view of it — none of it.
- **The session was compacted.** `context.compactions` is greater than
  zero and `dropped_tokens` says how much left the window. The transcript on
  disk is still whole; your view of it is not.

**In both cases say so, and drop the sections that depended on it.** The
failure to avoid is a confident narrative built on a fraction of the session,
because that reads exactly like one built on all of it. The quantitative
sections are unaffected and should be reported in full — the numbers come from
the transcript, which is complete either way.

---

## Sections

### Headline

One sentence naming what this session was actually about. `session.ai_title`
is Claude Code own generated title for the session, carried through by the
meter — cheap, available for any session id, and the one qualitative input
that survives compaction. It is a **label, not evidence**: it says what the
session was about, never that anything was finished.

### Landed

Verified changes only:

- Files changed, with edit counts
- Commits in the session window, by SHA
- Tasks closed, by id, from evidence
- Tests that ran and passed

A task marked `completed` in evidence with an empty `artifacts` array is
reported as **unverified**, not as landed. The ledger already counts these
separately.

### Open loops

The highest-value section, and the one nothing else in the toolchain
produces. From `openloops.sh`:

- **`session_files_uncommitted`** — files this session edited that are still
  uncommitted. Sharper than the raw dirty list, which also catches drift that
  was already there when the session started.
- **`churn_hotspots`** — files edited three or more times. Repeated editing of
  one file is a struggle signature, and it is exactly what you have forgotten
  by tomorrow morning. **Project files only**: the meter records every path
  edited, including scratchpad temp files and memory files under `~/.claude`,
  and a hotspot line pointing at a temp file spends the reader's attention on
  nothing. `churn_external_files` carries the count that was filtered out, so
  the filtering is visible rather than silent — report it only if it is large
  enough to be interesting.
- **`churn_available`** — whether the churn list above means anything. Churn is
  counted from edit tool calls, so a session that edited through Bash — heredocs,
  `sed -i`, a script that writes files — produces no hotspots however much it
  thrashed. **When this is false, say the file-level view is unavailable. Never
  report "no churn" or a file count of zero**, and never write a Landed line
  that leans on `work.files` being empty. Paths are deliberately not recovered
  from shell commands: the common forms name no file the transcript can see, and
  a wrong path here is worse than a missing one.
- **`uncommitted_unattributed`** — uncommitted files that no edit tool accounts
  for. Read with `churn_available`, this is the direct evidence that work landed
  outside the meter view. On its own it is not proof: a file that was already
  dirty when the session started looks the same from here.
- **`todos_added`** — TODO/FIXME/XXX/HACK markers in uncommitted work. A marker
  already committed is a backlog item, not an open loop from this session.
- **evidence** with status `partial` or `blocked`.

**Test state is deliberately not automated.** Transcripts record `is_error` on
tool results, but a test command that exits non-zero is indistinguishable from
a grep that found nothing. Report test outcomes you actually saw run, or say
nothing — do not infer a pass or a failure from exit codes alone. "Saw" means
in your own context: nothing reads test output from disk, so if you are
metering another session, or the run happened before a compaction, you did not
see it and there is nothing to report.

### Friction

From the meter: tool errors, interrupts, and `user-rejected` denials.
Interrupts and denials are the strongest signals in the set — they are the
moments the user actively stopped you.

### Cost

From `cost.sh`. Report `total_usd`, and `promo_applied` when true, since a
promotional rate explains a figure that won't reproduce later.

---

## Productivity: ratios, never a score

**Do not emit a composite productivity score.** There is no defensible
weighting between "tokens spent" and "tasks closed", and single numbers get
quoted out of the context that made them meaningful. Emit ratios with explicit
denominators instead:

```
cost per completed task          needs evidence
active minutes per completed task needs evidence
friction rate                    (errors + interrupts + denials) per 100 tool calls
churn ratio                      total edits / distinct files
                                 (omit entirely when churn_available is false —
                                  a ratio over an unmeasured denominator is a
                                  fabrication, not an approximation)
subagent share                   % of cost in the subagent lane
```

**These are close to meaningless in isolation.** One session's cost-per-task
tells you nothing. The same figure against thirty prior sessions tells you a
great deal — which is what `ledger.sh trend` is for. Prefer
"2.3× your median per task" over "$4.18", and note when the baseline is thin:
under five rows `trend` says so, and you should pass that caveat through
rather than presenting a median of three as typical.

## When there is no evidence

Say **"not assessed"** and move on.

Do not infer productivity from token burn. Burn measures effort, not output: a
session that thrashes for three hours on a bad approach scores higher than one
that succeeds cheaply in twenty minutes. Reporting the first as more productive
is worse than reporting nothing, because it is confidently backwards.

Cost, time, files, and friction are all still reportable without evidence —
they're measurements, not judgments. It's the *per-task* ratios that require
evidence, and their absence is a fact worth stating plainly rather than
papering over.
