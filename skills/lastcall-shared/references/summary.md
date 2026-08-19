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

| Source | Answers | Never used for |
|---|---|---|
| Meter output | **what** happened | why it happened |
| Evidence drop-box | **what** completed | anything unverified |
| `openloops.sh` | **what** is unfinished | — |
| The transcript | **why** it went that way | what happened |

If a claim can't be traced to one of the first three, it doesn't go under
**Landed**. It can go under *narrative* — clearly marked as such — or nowhere.

---

## Sections

### Headline

One sentence naming what this session was actually about. The transcript's
`ai-title` entries are cheap input here.

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
- **`todos_added`** — TODO/FIXME/XXX/HACK markers in uncommitted work. A marker
  already committed is a backlog item, not an open loop from this session.
- **evidence** with status `partial` or `blocked`.

**Test state is deliberately not automated.** Transcripts record `is_error` on
tool results, but a test command that exits non-zero is indistinguishable from
a grep that found nothing. Read the transcript for test outcomes and report
what you actually find, or say nothing — do not infer a pass or a failure from
exit codes alone.

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
