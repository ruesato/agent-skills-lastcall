# Contracts

The five interfaces that must not drift. Everything else in this project is
implementation detail and can change freely.

Written first, before any skill, because Fathom is being built in parallel and
needs contract 2 to be stable.

---

## 0. Environment and path resolution

These skills target three environments. The layout below is the only one that
works in all of them, because skills are flat siblings in each:

| Environment | Skill root |
|---|---|
| Kiro (global) | `~/.kiro/skills/` |
| Kiro (workspace) | `.kiro/skills/` |
| Claude Code (standalone) | `~/.claude/skills/` |
| Claude Code (plugin) | `<plugin>/skills/` |

**Reference shared files as `../lastcall-shared/...`.** That is the one form
that resolves everywhere. `${CLAUDE_PLUGIN_ROOT}` resolves in Claude Code plugin
installs only, and Kiro has no equivalent — do not depend on it.

`lastcall-shared` is not an invocable skill. It carries `user-invocable: false`
and `disable-model-invocation: true`, and exists as a skill directory only so
installers that copy skill directories carry its files alongside the other two.

### Reading vs executing

These resolve differently, and conflating them is the easy mistake:

- **Reading** a reference file: `../lastcall-shared/references/pricing.md` works,
  because the agent resolves it against the `SKILL.md` it is currently holding.
- **Executing** a script: a relative path resolves against the *current working
  directory*, not the skill directory, so the same form breaks.

Scripts must be invoked by a path resolved at install time. `install.sh` is the
only component that knows which environment it is installing into, so it owns
this: it links the scripts onto `PATH` and the skills invoke them by bare name.

---

## 1. Meter output

Produced by `../lastcall-shared/scripts/meter-session.sh`. Consumed by both
`tally` and `lastcall`.

**Pure counts. No pricing.** Rates change; token counts do not. Cost is applied
downstream from `references/pricing.md` so this contract stays correct.

```jsonc
{
  "session": {
    "id":       "f70c6774-635a-434c-b3a5-b540d355c1f8",
    "cwd":      "/Users/you/code/project",
    "branch":   "feat/thing",
    // null when the transcript carries no parseable timestamp at all, which is
    // unmeasured rather than epoch zero. Consumers must not feed these to a
    // date function without checking.
    "started":  "2026-08-03T01:34:38Z",
    "ended":    "2026-08-06T08:46:49Z",
    "wall_s":   285131,   // first to last timestamp; near-meaningless if resumed
    "active_s": 7754,     // sum of inter-event gaps <= IDLE_GAP_S (default 300)

    // Claude Code own measure of agent-busy time: the sum of its turn_duration
    // records. No idle heuristic in it, but it is a FLOOR — the turn in flight
    // has not been written yet, so a session metered mid-turn is missing it,
    // and a session that has never completed a turn reports 0.
    "agent_s":     4177.8,
    "agent_turns": 17,    // completed user turns that contributed to agent_s

    // Claude Code own generated title. A LABEL, not evidence: it says what the
    // session was about, never that anything landed. null when the session
    // never got one. The only qualitative input available for a session the
    // reader was not present for.
    "ai_title": "Support multiple code forges in skill project",

    // Reasoning effort, rolled up from the per-turn field Claude Code has
    // always recorded and nothing downstream ever reported. It is one of the
    // few levers in this row the user actually controls. "unset" is a turn that
    // carried no effort field — unrecorded, not a low setting.
    "effort": { "mix": { "high": 290 }, "turns": 290,
                "dominant": "high", "dominant_share": 1.0 }
  },

  // One row per (model, lane, speed, service_tier). Never collapse these:
  // main threads and subagents use different cache TTLs, and speed (fast mode)
  // and service_tier (priority, batch) change what a request bills at. null in
  // either means the transcript did not record it, which is not the same claim
  // as "standard".
  "tokens": [
    { "model": "claude-opus-5", "lane": "main",     // "main" | "subagent"
      "speed": "standard", "service_tier": "standard",
      "turns": 211, "input": 396, "output": 148499,
      "cache_read": 35035360, "cache_w_5m": 0, "cache_w_1h": 1107741,
      "thinking": 63846,        // SUBSET of output, never added to a total
      // Token-weight of re-reading that reasoning on every later turn: sum over
      // turns of thinking_i x (turns remaining after i). Billed once as output,
      // then carried as cache_read for the rest of the session. cost.sh prices
      // it as thinking_carry_usd at the cache_read multiplier.
      "thinking_carry": 12554366,
      "web_search": 0, "web_fetch": 0,   // server tools; billed per REQUEST
      "efforts": { "high": 211 }         // reasoning effort -> turn count
    }
  ],

  "agents": [ { "agentType": "Explore", "description": "...", "spawnDepth": 1 } ],

  "work": {
    "tools": { "Bash": 150, "Edit": 61 },            // name -> call count
    "files": { "/abs/path.md": 14 },                 // path -> edit count (churn)

    // Whether `files` above can be read as the whole picture. It is built from
    // Edit/Write/NotebookEdit only, so a session that edits through Bash leaves
    // it EMPTY, and {} then has to mean unmeasured rather than untouched.
    // attributed is false when the session ran Bash but never called an edit
    // tool. Paths are never recovered from shell commands: the common forms
    // name no file the transcript can see.
    "files_coverage": { "edit_tool_calls": 61, "bash_calls": 150,
                        "attributed": true },

    // Per-turn skill/plugin attribution, written by Claude Code itself.
    // skill: null is the unattributed remainder — plain conversational turns.
    // Keep it: without it the parts stop summing to the whole.
    //
    // A row measures spend WHILE a skill held attribution, which is dominated
    // by how many turns that lasted times how much context was resident — not
    // by the skill own overhead. It cannot answer "is this skill expensive?".
    // See invariant 13; `skill_load` below is the metric that can.
    "skills": [
      { "skill": "claude-api", "plugin": null, "model": "claude-opus-5",
        "turns": 8, "input": 16, "output": 11340,
        "cache_read": 4049677, "cache_w_5m": 0, "cache_w_1h": 361355 }
    ],

    // What each skill cost to LOAD: the context jump when it took attribution.
    // Keyed on skill alone, not (skill, model), because load is a property of
    // the skill. load_tokens is null when the deltas were degenerate — never 0.
    "skill_load": [
      { "skill": "lastcall:lastcall", "runs": 2,
        "load_tokens": 7478, "approximate": true }
    ],

    // What put the tokens in the window. Cache reads are the bulk of the bill
    // and their price is a function of what is resident, so without this a
    // report can name a total without naming one fixable thing.
    // carry_tokens is payload x turns that re-read it; cost.sh prices it.
    "tool_context": [
      { "tool": "Bash", "model": "claude-opus-5", "speed": "standard",
        "service_tier": "standard", "calls": 174, "payload_tokens": 39174,
        "avg_tokens": 225, "carry_tokens": 6338800 }
    ],

    // Whether the table above covers the session. A tool_result whose tool_use
    // is not in the transcript cannot be attributed to a tool.
    "tool_context_coverage": { "results": 272, "matched": 272, "unmatched": 0,
                               "image_tokens_each": 1600, "approximate": true }
  },

  // Turns where a cache write rewrote at least `threshold_ratio` of what was
  // resident — the prefix expired and was rebuilt at 1.25x/2.00x input instead
  // of read at 0.10x. Folded into the cache_w_* aggregate, a session that paid
  // for several full rewrites is indistinguishable from one that paid for none.
  // Each event carries the idle gap before it. See invariant 15.
  "cache_reestablish": {
    "threshold_ratio": 0.5, "events": 4, "writing_turns": 289,
    "tokens": 478700,
    "largest": { "at": "...", "model": "claude-opus-5", "tokens": 229895,
                 "tokens_5m": 0, "tokens_1h": 229895,
                 "ratio": 0.934, "idle_s": 10285 },
    "detail":  [ /* up to 10 events, largest first, each with idle_s */ ],
    "by_model": [ { "model": "claude-opus-5", "speed": "standard",
                    "service_tier": "standard", "events": 4,
                    "tokens_5m": 0, "tokens_1h": 478700 } ]
  },

  // How much of the session is still visible to whoever is summarizing it.
  // Unlike `native`, ZERO here is a measurement, not an absence: every entry of
  // every transcript was read and no compaction boundary was found. Read from
  // system/compact_boundary records. Main lanes only — a subagent compacting
  // its own context costs the main thread nothing.
  "context": { "compactions": 1, "dropped_tokens": 260337,
               "triggers": ["manual"] },

  "friction": { "tool_errors": 7, "interrupts": 1, "denials": 0 },

  // Filled from the contract 2 drop-box, merged on task.id alone: one entry
  // per task however many producers described it, artifacts unioned, and the
  // highest emitted_at deciding the rest. Each entry also carries `sources`
  // with every contributor. [] means no producer wrote anything, which is the
  // normal case. openloops.sh narrows this to partial/blocked for Open loops.
  "evidence": [],

  // OPTIONAL, and absent on most sessions. Present only when the opt-in
  // statusLine capture (capture-statusline.sh) wrote a payload for this
  // session id. Every field inside is likewise dropped when absent rather than
  // zeroed: rate_limits exist only for Pro/Max subscribers and only after the
  // first API response, and "0% of the weekly window used" is the opposite
  // claim from "not measured".
  "native": {
    "source":      "statusline",
    "captured_at": "2026-08-19T18:22:03Z",  // last status line render, NOT live
    "cc_version":  "2.1.236",

    "cost_usd":      0.6512,   // Claude Code client-side estimate. ADVISORY.
    "wall_ms":       450000,   // its clock; resets when /clear starts a session
    "api_ms":        231000,   // time spent waiting on the API
    "lines_added":   156,      // derived from EDIT TOOL CALLS, so a Bash
    "lines_removed": 23,       // heredoc edit contributes nothing — measured,
                               // see agent-skill-wrapup-yg3.8

    // The only local source for these. They are in no transcript, no hook
    // payload, and no OTel metric. resets_at is epoch seconds as sent.
    "rate_limits": {
      "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600,
                     "resets_at_utc": "2025-02-01T16:00:00Z" },
      "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600,
                     "resets_at_utc": "2025-02-06T16:00:00Z" }
    },

    // agent_s minus API wait: time spent RUNNING TOOLS. Both inputs are floors
    // captured at different moments, so this is approximate by construction.
    // clamped means the subtraction went negative and tool_s was floored at 0.
    "split": { "api_s": 231.0, "tool_s": 84.3,
               "clamped": false, "approximate": true }
  }
}
```

### The statusline capture store

Written by `capture-statusline.sh`, read by the meter. One file per session:

```
~/.claude/lastcall/statusline/<session-id>.json
{ "schema": "lastcall.statusline/1", "captured_at": "...", "payload": { ... } }
```

`payload` is the statusLine JSON verbatim. The meter rejects a file whose
`payload.session_id` does not match the id being metered, and treats an
unparseable file as absent. The capture is opt-in and `install.sh` never
configures it — see the README for why.

### The stub document

When there is no transcript to read, the meter emits a **stub** rather than
exiting non-zero. Not a fallback for Kiro alone: it covers a transcript the
harness has rotated away (measured 2026-08-22, five of eight ledger rows had
none left on disk), a session too new to have been flushed, and a session id
that does not resolve.

```jsonc
{
  "stub": {
    "reason":    "no session id was available and no transcript directory exists for ...",
    "id_source": "cwd"     // "argument" | "environment" | "newest" | "cwd"
  },
  "session": { "id": "stub-Users-you-code-project", "cwd": "/Users/you/code/project",
               "meter_version": 2,
               "branch": null, "started": null, "ended": null,
               "wall_s": null, "active_s": null, "agent_s": null,
               "agent_turns": null, "ai_title": null,
               "effort": null, "dedup": null },
  "tokens": [], "agents": [], "context": null,
  "work": { "tools": {}, "files": {},
            "files_coverage": { "edit_tool_calls": null, "bash_calls": null,
                                "attributed": false },
            "skills": [], "skill_load": [] },
  "friction": { "tool_errors": null, "interrupts": null, "denials": null },
  "evidence": [ /* the drop-box, read as normal */ ]
}
```

**`null` here means unmeasured, exactly as it does for `native`** (invariant 11)
— extended from one block to the whole document. A stub reporting `active_s: 0`
would say the session did nothing, which is a confident false statement rather
than a missing one.

Two fields are not null, and both on purpose:

- **`work.files` is `{}`**, because `openloops.sh` iterates it and `{}` is
  already the shape that means unmeasured there, given the flag below.
- **`work.files_coverage.attributed` is `false`, explicitly, never omitted.**
  `openloops.sh` defaults `churn_available` to `true` when `files_coverage` is
  absent, because absence means *output from an older meter*, not *nothing was
  attributed*. A stub that left the field out would claim the struggle signal
  was measured when nothing was. This is invariant 10 at its limit — "an empty
  `work.files` is not a claim that nothing was edited" — not a new concept.

No `native` block, even when a statusLine capture happens to exist for the id:
every figure in it is a cross-check on a transcript-derived figure, and there is
none here.

Consumers:

- `openloops.sh` needs only `session.cwd`, `work.files`,
  `work.files_coverage.attributed` and `evidence`, all of which a stub carries,
  so the open-loop report is **unaffected** — branch, dirty paths, TODO scan and
  uncommitted files all come from git rather than from the meter.
- `cost.sh` nulls `total_usd` and every token-derived figure and leads its
  `caveats` with the reason. An empty token list otherwise prices to exactly
  $0.00, which is the one answer it must never give.
- `ledger.sh append` **refuses the row** — see section 3.
- `emit-evidence-beads.sh` exits 0 with a message: the session window is what
  joins a bead to this session, and a stub has none.

`LASTCALL_REQUIRE_TRANSCRIPT=1` restores the hard failure for a caller that
wants a measurement or nothing.

### Invariants the meter guarantees

Each of these silently corrupts totals if a reimplementation drops it:

1. **Deduped by response id: `requestId`, then `message.id`, then `uuid`.**
   Streaming writes one entry per chunk sharing a response id, and every chunk
   in a group repeats the same cumulative `usage`, so the group collapses to
   its first entry. Summing raw entries overcounts by roughly 90%. The id goes
   by different names per provider. First-party API transcripts carry
   `requestId`: present on 5629 of 5630 assistant entries over 27 local
   transcripts, most common group size *three* (measured 2026-08-22).
   Bedrock-served transcripts carry `message.id` instead, with `requestId`
   absent: 0 of 6148 entries over 27 transcripts — **externally reported
   2026-08-23, not reproduced here.** No Bedrock transcript exists on this
   machine, so every Bedrock figure in this invariant comes from that report
   and could not be re-derived locally; the `verify.sh` fixture *constructs*
   the shape the report describes rather than sampling a real file, which
   confirms the code handles that shape but cannot confirm the shape. The
   inference is well-supported — one message id per response is how the
   Messages API is specified, and on the local first-party corpus `requestId`
   and `message.id` partition identically (3657 groups each, zero
   cross-spanning, 7611 entries, measured 2026-08-24) — but it is an inference,
   and is marked as one so a later reader does not spend it as a measurement.
   **This guard is load-bearing, not vestigial.** A 2026-08-22 external review
   of the Bedrock corpus sampled `requestId` as absent from 100% of turns,
   concluded the guard was inert, and proposed changing the grouping key — on
   the first-party corpus that change would have inflated every total by
   ~2.3x, and on Bedrock the missing fallback measurably *did* inflate them:
   ~2x across an 11-row ledger, with per-field factors of 1.36x–3.74x, so
   stored rows cannot be repaired by scaling, only re-metered (contract 3).
   The meter therefore MEASURES what the key did rather than assuming it,
   reported as `session.dedup` — `entries`, `turns`, `collapsed`,
   `rid_coverage`, `mid_coverage`. `rid_coverage` 0 with `mid_coverage` above
   0 is the Bedrock envelope handled by the fallback; *both* 0 means the
   fallback to `uuid` carried the whole file, nothing was collapsed, and
   `cost.sh` raises a caveat, because that is the signal the transcript format
   moved again. Meter JSON saved before `mid_coverage` existed (absent, not
   0) still warns: those rows are exactly the ones the rename already
   inflated. Do not delete the guard on the strength of a session that
   happens to need no collapsing.

   Coverage answers *was the field there*, which is a proxy with a blind spot
   it structurally cannot see: an envelope that writes its response id **per
   chunk** scores full coverage, collapses nothing, and inflates every total —
   the identical failure one field along. So `session.dedup` also carries
   `adj_pairs`, `adj_dup`, and `adj_dup_share`, which answer *did collapsing
   happen* without reference to any field name. Duplicate chunks repeat the
   same cumulative `usage`, so surviving duplicates appear as adjacent turns
   with byte-identical usage; genuine consecutive replies never match, because
   `cache_read` alone moves every turn. Measured 2026-08-24 across all 55 local
   transcripts: `adj_dup_share` is **0.0 in every file**, and re-keying the
   same corpus on `uuid` to simulate the break gives **0.11–0.57**. `cost.sh`
   raises a caveat at `>= 0.05`, a threshold sitting inside a gap that is
   empirically empty. `adj_dup_share` is null when there was no adjacent pair
   to compare, which is *unmeasured* — a one-turn session has not demonstrated
   the dedup working, it has given it nothing to do.
2. **Subagents included.** Their turns live in
   `<project>/<session-id>/subagents/*.jsonl`, not in the main transcript.
   Metering only the main file silently omits all subagent cost.
3. **`<synthetic>` entries excluded, by model name.** They carry a null
   `requestId` and all-zero usage, but the *name* is the only sound test.
   Exclusion used to fall out of the key chain for free — no `requestId` meant
   the entry keyed on its `uuid` and matched nothing — and that stopped being
   true when `rkey` gained the `message.id` fallback, because synthetic
   entries do carry a `message.id` (1 of 1 locally, measured 2026-08-24). Both
   the token pipeline and the tool-context scan therefore test
   `.message.model != "<synthetic>"` explicitly. Do not reintroduce reliance on
   a missing identifier: it is a side effect of the current key chain, not a
   property of synthetic entries.
4. **Active time, not wall clock.** A resumed session can span days.
5. **Cache write TTLs kept separate.** `cache_w_5m` and `cache_w_1h` bill at
   different multipliers.
6. **`denials` counts only `toolDenialKind == "user-rejected"`.** The
   `automode-*` kinds are harness state, not user friction.
7. **Pricing dimensions stay in the group key.** `speed` and `service_tier`
   change what a request bills at. Folding rows across them prices a fast-mode
   or priority-tier session at standard rates and leaves no trace that it
   happened — the same silent-miscomparison failure `pricing_source` exists to
   prevent.
8. **`thinking` is a subset of `output`, not a sixth bucket.** Adding it to a
   total double-counts. It exists so a jump in output tokens can be told apart
   from a jump in reasoning.
9. **Nothing here reads conversation content.** The meter dips into
   `message.content` in four places and every one is filtered to structure —
   `tool_use` names, ids and paths; `tool_result.is_error`; and, for
   `work.tool_context`, the *length* of a `tool_result` body and the block
   `type` of its parts. That last one touches the bytes of tool output, so say
   what it does with them precisely: it measures how many there are and never
   inspects, stores, or emits them. No prompts, no assistant prose, no tool
   output bodies leave this script. Any narrative in a summary comes
   from the reader own context, which is present only when `lastcall` runs
   inside the session it measures. `context.compactions` and a metered id that
   differs from the current one are the two ways that silently stops being
   true; `session.ai_title` is the only qualitative field that survives both.
10. **An empty `work.files` is not a claim that nothing was edited.** Read
   `work.files_coverage.attributed` first. When it is false, the file-level
   view is unmeasured and any ratio over it is a fabrication rather than an
   approximation. Note for consumers: `attributed` is a real boolean, so
   defaulting it with jq `//` inverts it — `false // true` is `true`.
11. **`native` is absent unless captured, and never emitted with zeroes.** A
   missing field there means unmeasured. Reporting an absent rate-limit window
   as 0% tells the user they have a full window left, which is worse than
   reporting nothing. Its `cost_usd` is advisory and never substitutes for the
   figure `cost.sh` derives from tokens; `cost.sh` compares them in
   `cross_check` and refuses the comparison outright when `native.wall_ms`
   shows their clock covers less time than the transcript does.
12. **`agent_s` is a floor, never a replacement for `active_s`.** They measure
   different things — agent busy versus human engaged — and only `active_s`
   covers the turn currently in flight.
13. **A `work.skills` row is not a skill price tag, and attribution is not
   sticky.** The row measures spend while a skill held attribution, which is
   window length times resident context. A cheap skill invoked late in a large
   session outscores an expensive one invoked early, so the row cannot answer
   "is this skill expensive?" — `cost.sh` adds `usd_per_turn` to normalize the
   window, and `work.skill_load[].load_tokens` is the metric for overhead.
   **No sticky invariant.** A 2026-08-22 review proposed guaranteeing that a
   skill row covers every turn until the next `Skill` call. It does not hold
   here. Measured on session 31221561, every named run RELEASES back to null and
   runs are short: `claude-api` takes attribution at turn 156, releases at 172,
   and no further `Skill` call appears in the remaining 117 turns — under the
   sticky model it would have held to the end. Three of its four named runs
   begin nowhere near a `Skill` call, so attribution is not driven by that tool.
   For the same reason `skill: null` is the **unattributed remainder** and not
   "pre-attribution turns": null appears interleaved (136-155, 172-188, 198-281),
   all of it after the first named run.
14. **`work.tool_context` is approximate by construction, and payload-derived.**
   Sizes are chars/4, and an `image` block counts at a flat
   `tool_context_coverage.image_tokens_each` rather than by its base64 length —
   without that a `Read` of a screenshot reports as a six-figure-token call and
   the table becomes fiction. Attribution comes from measuring `tool_result`
   bodies, **never** from dividing a per-turn context delta among the tools that
   preceded it: that method loads generic per-turn growth onto whichever tool is
   most frequent, and produced a $101 figure for `Bash` against a real payload
   near 225 tokens per call. Read `tool_context_coverage.unmatched` before
   reading the table — a `tool_result` whose `tool_use` is missing cannot be
   attributed, and a thin table then means partial coverage, not light tool use.
15. **The `cache_reestablish` threshold is a FRACTION of resident context, never
   a token constant.** Local baseline resident is median 37.6K over a 28.9K-59.5K
   range (`bin/baselines.sh`, 2026-08-22), so it varies ~2x between sessions and
   any constant is tuned to one of them. The distribution is strongly bimodal —
   p50 0.006, p95 0.053, then p99 0.892 — so 0.25 and 0.50 select 60 and 59 of
   2909 writing turns. That insensitivity is the justification. Index 0 of each
   transcript part is excluded: establishing a prefix the first time is
   unavoidable and counting it would report an event in every session.
   **No TTL configuration advice follows from this.** Whether a 1-hour TTL is
   reachable from Claude Code is unverified, and on this machine 100% of writes
   are already 1h — which also makes "do not leave a session parked" a weaker
   lever than it would be at 5m. Report the events; do not prescribe a setting.
16. **`load_tokens` is an upper bound, and null rather than 0 when degenerate.**
   Two failure modes pull opposite ways and each has its own correction: a
   one-turn window reads LOW because the load has not landed (`claude-api`
   measured +0.6K at one turn against +29.5K at two), so the max across a wider
   window is taken; and every window is contaminated by whatever else those
   turns pulled in, which only ever ADDS, so the smallest reading across runs
   wins. Contamination survives both when `runs` is 1 — measured 2026-08-23,
   `lastcall:lastcall` reads 8326 and 7478 across two sessions against a 3.2K
   `SKILL.md`, while a single-run `claude-api` reads 355201 because a genuine
   350K context jump landed in the same turn. So: use it to RANK skills and to
   check against a `SKILL.md` size, never to quote an absolute, and treat a
   `runs: 1` figure as the weakest of them. `load_tokens: null` means the deltas
   were degenerate — unmeasured, not free.

---

## 2. Evidence drop-box

**Any skill or script that completes real work contributes here.** `lastcall`
globs the directory — it holds no per-skill integration code, so new producers
need no changes on the consumer side.

Earlier revisions called this "the Fathom seam" and named Fathom as the
producer. That was a guess, and it pointed integrators at the wrong plugin: for
beads-backed users `fathom-shared/memory.md:63` writes no per-task file at all,
so a Fathom-side emitter would have to read beads anyway. The seam is real; the
named producer was not. See `emit-evidence-beads.sh`.

### Location

```
${LASTCALL_EVIDENCE_DIR:-~/.claude/lastcall/evidence}/<session-id>/<source>-<timestamp>.json
```

One file per emitting run. Never modify or overwrite another producer's file.

Keyed on the **session id alone** — no cwd, no project slug. This mirrors the
statusline store, and it is deliberate rather than incidental: a slug-keyed path
loses evidence silently in two ordinary situations. A session that outlives a
directory rename splits across two project directories under one id, so reading
one drops the other. And `claude --worktree` sets cwd to
`.claude/worktrees/<name>`, which slugs to a different project directory than
the repository root, so a worktree session and its evidence can never meet.

### When there is no session id

Kiro has none: nothing there sets `CLAUDE_SESSION_ID` and there is no transcript
tree to read one out of. The meter falls back to a **cwd-derived id**,
`stub` + the project-directory slug of `$PWD` — `stub-Users-you-code-project`.

Derived rather than generated, because a generated id could not be guessed by
anyone else. A producer writing evidence and `lastcall` reading it have no
channel to agree on an identity through, so the identity has to be something
both can compute from what they already have. `$PWD` is the only such thing.

**Its cost, stated plainly: this id is a rendezvous point, not a session
identity.** It is stable across runs in a directory, so a stub session picks up
evidence left by *earlier* stub sessions in that same directory. There is no
window to bound it with — a stub has no `started`/`ended` — so nothing filters
it, and a consumer must read such evidence as "outstanding in this directory"
rather than "done in this session". It is also why `ledger.sh` refuses a stub
row: rows are replaced on session id alone, so a second stub session would
overwrite the first (section 3).

A producer that *does* know a real session id should always use it. The fallback
is for producers that have nothing better, and it must be computed the same way
— `sed 's|[^a-zA-Z0-9-]|-|g'` over `$PWD`, prefixed with `stub`.

The drop-box also lives under a directory `lastcall` owns rather than inside the
Claude Code transcript tree. That tree is managed and rotated by the harness —
measured 2026-08-22, five of eight ledger rows already had no transcript left on
disk — and nothing guarantees a third-party producer's files survive there.

### Shape

```jsonc
{
  "schema":     "lastcall.evidence/1",
  "source":     "fathom",             // producer name, stable across runs
  "session_id": "f70c6774-...",
  "emitted_at": "2026-08-17T18:33:44Z",

  "tasks": [
    {
      "id":     "ONC-5",                        // tracker key, or any stable id
      "title":  "Forge adapter for GitLab",
      "status": "completed",                    // see enum below
      "started": "2026-08-17T17:02:11Z",
      "ended":   "2026-08-17T18:20:04Z",

      // Grounding. See rules below — this field carries real weight.
      "artifacts": ["skills/shared/forges/gitlab.md", "PR#241", "commit:a1b2c3d"],

      // Optional, additive. How each artifact was joined to this task, for
      // producers that match rather than being told. Absent means unlabeled,
      // never unearned. Consumers that only count grounding ignore it.
      "artifact_matches": [{ "ref": "commit:a1b2c3d", "key": "id" }],

      "notes": "Free text. Why it went the way it did."
    }
  ]
}
```

### Status enum

| Status | Meaning |
|---|---|
| `completed` | Done and verified. The only status counted in productivity ratios. |
| `partial` | Real progress, not finished. Surfaces under **Open loops**. |
| `blocked` | Cannot proceed; external dependency. Surfaces under **Open loops**. |
| `abandoned` | Deliberately dropped. Excluded from ratios entirely, not counted as failure. |

### Rules for producers

- Emit at task transitions, not only at session end. A crashed session should
  still leave behind everything that finished before the crash.
- `artifacts` is how a claim earns trust. **A `completed` task with an empty
  `artifacts` array is reported by `lastcall` as unverified** rather than
  counted — this is the grounding rule reaching into the contract.
- **`id` is the merge key across producers**, so it has to name the task the
  same way everyone else names it. Use the tracker key verbatim. Invent an id
  only when there is no tracker to borrow one from, and prefix it if it could
  collide with another tracker in the same session (`linear:ONC-5`) — two
  producers must not disagree about whether a prefix is there, or one task
  arrives as two.
- Unknown fields are preserved and ignored. Add fields freely; never repurpose
  an existing one.
- Bump `schema` on any breaking change. Consumers reject unknown major versions
  loudly rather than guessing.

### Shipped producer: `emit-evidence-beads.sh`

Derives evidence from a beads workspace, so the seam is filled by a script
rather than by an agent remembering to emit. Reads meter output on stdin,
discovers the session commits itself, and writes one file per run:

- A bead closed inside `[started, ended]` becomes `completed`; one moved to
  `in_progress` in that window becomes `partial`; `blocked` maps through.
- **`started_at` is not reliably present** — bd omits the key from most rows
  (46 of 85 in this workspace, 2026-08-24), and jq reads a missing key as
  `null`, so an `in_progress` bead with no start timestamp used to fail the
  window test and vanish from the file entirely. `updated_at` is the fallback:
  it moves on the status change that made the bead `in_progress`, so it is a
  real transition time, only a coarser one. It decides inclusion and bounds the
  range below; the emitted `started` still carries whatever bd recorded, so a
  `null` there says the start was never observed rather than asserting one.
- **Session commits are discovered from the metered window**, and any SHAs
  passed as arguments are unioned in and deduped. Discovery exists because
  `lastcall` offers its commit delegation only on a dirty tree: a session whose
  commits came from another skill passed zero SHAs, and the matcher then ran no
  comparison at all. `LASTCALL_COMMIT_DISCOVERY=0` restores argv-only.
- **Join keys, strongest first, and every match carries its key.**

  | Key | Match | Strength |
  |---|---|---|
  | `id` | the message names the bead id | exact |
  | `tracker` | the message names the `external_ref` bd records | exact |
  | `window` | commit time inside the bead own active range | weak |

  A bead with any exact match uses only those, so an earned commit is never
  diluted by everything committed beside it; `window` applies only when no
  exact match exists. That range starts at `started_at`, or at the `updated_at`
  fallback above when bd recorded none. File overlap was considered as a fourth
  key and rejected: the meter does not see edits made through Bash, so absence
  there proves nothing.

  Do NOT look for a `Closes <ref>` trailer in a Fathom commit. Its
  `conventions.md` puts that line in the REVIEW body; its commit-message
  section defines `type(<issue-ref>): summary`, so the ref is in the
  conventional-commit scope, which is what the `tracker` key reads.
- Two limits of the window query, recorded rather than papered over.
  `--since`/`--until` filter on **committer** date — verified by dating a
  commit 2020 and committing it today, where it appears in a 2026 window and is
  absent from a 2020 one — so a rebase inside the window can sweep in older
  work. And any commit made in that checkout during the window is picked up
  whoever authored it.
- Attaching every session commit to every task would inflate grounding, so a
  task nothing references stays empty and is reported `unverified`. That is the
  intended outcome, not a gap.
- No beads workspace, no `bd`, or no window: exits 0 silently and writes
  nothing. Absence is the normal case. **This is not the same state as running
  and matching nothing**, and the two must not arrive at a consumer looking
  alike — see the marker rule below.
- **A run that matches no bead still writes its file, with `tasks: []`.** That
  empty document is the difference between *this producer does not apply here*
  (no file at all) and *it applied and found nothing* (a file with no tasks).
  Before it existed both reached the ledger as `evidence: null`, so `trend`
  reported `per_task: null` for a session that was never assessed and for one
  that was assessed and came back zero — a measurement and the absence of one,
  reported identically. Section 3 requires absent evidence to be recorded as
  absent; the marker is what makes that rule enforceable in the other
  direction too.
- A SHA git cannot resolve **warns to stderr** and the run continues. Dropping
  it silently would strip a task of its grounding and report it unverified with
  nothing saying why — the inverse of `files_coverage.attributed` and the rest
  of the absence-is-visible discipline here. A bad SHA degrades grounding; it
  does not lose the evidence file.
- **Completed tasks with zero artifacts warn once**, and the warning names the
  cause rather than the symptom: the workspace is not a git repository, no
  commit falls in the window and none was passed, none of the SHAs passed
  resolve, or none of the commits in scope matches any join key. A commit
  grounds a task by naming it — a `Closes <bead-id>` trailer, or the issue ref
  in the conventional-commit scope. Both commit discovery and any external
  producer are best effort, so the file can look healthy while every task in it
  reports `unverified` with nothing saying why; this closes that silent-failure
  mode. Non-fatal — the evidence file is still emitted.
- The workspace is found by walking up from the session `cwd`, falling back to
  `$PWD` when the recorded path no longer exists — a renamed directory leaves
  every later row pointing at a path that is gone (5 of 26 sessions here).

### Producer registration: pushed by name, not discovered

**Consumption is extensible and production is not, and that asymmetry is
deliberate.** `evidence_for` globs the drop-box, accepts any `source`, dedupes,
skips unparseable files with a warning, and preserves unknown fields — adding a
producer needs zero changes here. But exactly one producer is ever *invoked*,
by name, from the skill, with its own `allowed-tools` entries. There is no
registry, no discovery, no config key. Anyone can write a producer and nothing
will run it.

For **push** producers that is not a gap: contract 2 *is* the registration
mechanism. A skill that does real work writes a file at its own task
transitions, and nothing needs to invoke it. That is the intended path, and the
one Fathom should take.

It bites only **pull** producers, which derive from a passive store at wrap-up
time because no agent is there to push. `emit-evidence-beads.sh` is one. So is
every item in the "evidence beyond git" epic — an mtime sweep, published
Artifact URLs, tracker status transitions. Adding those the way beads was added
yields one hardcoded invocation each and an `allowed-tools` list that grows per
producer.

**Decision, 2026-08-25: they stay hardcoded, and a runner is not built yet.**
Two reasons, in order of weight:

1. **No second pull producer is waiting.** Every item in that epic is open, and
   the Fathom path is push-side and owned upstream. A runner would be built for
   a caller that does not exist.
2. **It is a real execution surface, and it costs the permission model.**
   Running every executable in a directory is arbitrary code execution by
   design, and it collapses per-script `allowed-tools` entries into one entry
   that can execute anything — a regression in a permission model this skill
   has otherwise kept narrow. A scanner would flag it and would be right to.

A third reason stood here until 2026-08-25 and is now discharged: dedupe had
no rule for a second producer, and two producers claiming the same task id were
both counted — confirmed empirically, not inferred, with evidence from `fathom`
and from `linear` both naming `ONC-5` reporting `completed: 2` for one task.
The merge rule under "Rules for consumers" settles it, so a runner no longer
makes double-counting easy to reach.

Revisit when a second pull producer is genuinely ready to ship. What the runner
would then have to settle, none of which is settled here: the trust boundary (ship-with-the-skill only, or a
user-owned directory behind explicit opt-in), how least privilege survives one
generic invocation, and a per-producer timeout — one producer blocking on a
tracker call must not hold up wrap-up, consistent with the 20s discipline in
`detect.sh`.

### Rules for consumers

- Glob all `*.json`; skip unparseable files with a warning rather than aborting.
- **Task identity is `task.id` alone. `source` is not part of it.** Records
  sharing an id are one task, however many producers described it. Merge them:

  | Field | Rule |
  |---|---|
  | `status`, `title`, `notes`, `started`, `ended` | from the record with the highest `emitted_at` |
  | `artifacts`, `artifact_matches` | union across every contributing record |
  | `source` | the highest-`emitted_at` contributor |
  | `sources` | every contributor, added by the consumer |

  Recency deciding status is the single-producer rule generalized: a task
  re-emitted as `completed` supersedes its earlier `partial`, whoever emitted
  it. Ties on `emitted_at` break on `source` name, so the winner does not
  depend on directory glob order. Unioning `artifacts` is what stops a task
  grounded by one producer being reported `unverified` because the other saw no
  commit — merging *improves* grounding rather than picking a winner for it.

  **Precedence between named producers was considered and rejected.** A rank
  order needs a registry, and consumption here accepts any `source` with no
  registration at all (see below); an unknown producer would have no rank. A
  recency rule is source-agnostic, so it keeps that property.

  **Known cost, chosen deliberately:** two genuinely different tasks that share
  an id across trackers — `ONC-5` in Linear and in Jira — merge into one and
  undercount by one. The alternative was the previous behaviour, which
  overcounted by one for *every* task two producers both described, which is
  the guaranteed case rather than the rare one. Between the two directions of
  error, a productivity ratio should take the one that under-claims. A producer
  whose ids are not globally unique can namespace them in the id itself
  (`linear:ONC-5`); that needs no new field and no change here.
- **An empty `tasks` array is a marker, never a retraction.** It says the
  producer ran; it does not withdraw what an earlier run established. Dedupe is
  keyed on task id and an empty document carries none, so this falls out of the
  rule above rather than needing a special case — but a consumer that reads the
  newest file per source instead of deduping per task would get it wrong.
- A source appearing in `sources` with zero tasks counted means *assessed,
  nothing found*. Distinguish it from a source that is absent entirely, which
  means *not assessed*. Never fold the first into the second.

---

## 3. Ledger record

Append-only, one row per metered session. This is what makes productivity
figures meaningful — a single session's cost-per-task says nothing; thirty
sessions give you a baseline to compare against.

### Location

```
~/.claude/lastcall/ledger.jsonl
```

Global across projects, with `cwd` as a filterable field. Written by
`lastcall` only — `tally` never writes.

**A stub meter never becomes a row.** `append` reads the `stub` marker from
contract 1 and exits 0 with a message, writing nothing, because a stub carries
nothing a baseline is built out of — no cost, no active time, no token rows.
Storing it anyway would do two separate kinds of damage. It would poison
`trend`, whose medians take `.cost.usd` and `.active_s / 60` straight off every
row: a `null` sorts below every number in jq, and `null` divided by a number
aborts the program outright. And it would destroy history, because rows are
replaced on `session_id` alone and a stub id is derived from the working
directory (section 2) — the second stub session in a directory would silently
overwrite the first.

A host with no transcripts therefore gets open loops, evidence and the
delegations, but no baseline. That is the honest outcome: there is nothing to
build one from.

### Shape

```jsonc
{
  "schema":     "lastcall.ledger/1",
  "session_id": "f70c6774-...",
  "metered_at": "2026-08-17T18:40:00Z",   // when measured; freshness, not identity
  "cwd":        "/Users/you/code/project",
  "branch":     "feat/thing",
  "started":    "...", "ended": "...", "active_s": 7754,
  "agent_s":    4177.8,                         // null on rows written before it existed

  // How this row was COUNTED, not what it holds. Absent means UNKNOWN, never
  // version 1 — see the re-metering rule below for why the distinction is the
  // whole point of the field.
  "meter_version": 2,
  "dedup": { /* contract 1 `session.dedup`, verbatim: the evidence behind
                meter_version — which response-id field this session carried,
                and whether collapsing actually happened */ },

  "cost": {
    "usd": 4.18,
    "by_model": [ { "model": "claude-opus-5", "lane": "main", "usd": 3.91 } ],
    // usd_per_turn normalizes the window; see invariant 13 for why the raw
    // usd cannot be read as what the skill costs.
    "by_skill": [ { "skill": "claude-api", "plugin": null, "usd": 0.27,
                    "turns": 16, "usd_per_turn": 0.1598 } ],
    "pricing_source": "claude-api@2026-08-18",  // which rate table produced this
    "promo_applied": true,                      // any lane billed at a promo rate
    "promo_models": ["claude-sonnet-5"],        // which ones
    "caveats": []                               // why usd may understate; see below
  },

  "tokens":   { /* contract 1 `tokens`, verbatim */ },
  // commits is discovered from the metered window, unioned with any SHAs the
  // caller passed and deduped to the abbreviated form.
  "work":     { "tool_calls": 218, "files_changed": 25, "commits": ["a1b2c3d"] },
  "friction": { "tool_errors": 7, "interrupts": 1, "denials": 0 },

  "evidence": {
    "sources":   ["fathom"],
    "completed": 3, "partial": 1, "blocked": 0, "abandoned": 0,
    "unverified": 0        // completed tasks with no artifacts
  }
}
```

### Rules

- **Idempotent, keyed on `session_id` alone.** Re-running `lastcall` on a
  session *replaces* that session's row rather than appending a duplicate.
  `metered_at` records when the measurement was taken and breaks ties if
  duplicates ever appear — it is deliberately **not** part of the key. An
  earlier draft of this contract keyed on `(session_id, metered_at)`; that is
  wrong, because `metered_at` changes on every run, so every re-run would
   append. `lastcall` meters twice within a single run (see delegation), so
   the row must be replaceable in place.
- **`meter_version` identifies rows a re-metering repair must target.** The
  rule below says affected rows are re-metered rather than scaled; this is the
  field that makes finding them possible. It was added 2026-08-24 after the
  rule was written without it, which left the repair path stated but not
  executable — an inflated row and a corrected one were byte-identical on
  disk. Bump it only when a change moves the numbers a previous version would
  have produced for the same transcript; a new field is additive and does not
  qualify. `ledger.sh trend` reports `meter_regimes` from it, in the same shape
  as `pricing_regimes` and for the same reason: a step in the trend that comes
  from a measurement fix must not be read as a change in behavior. That note
  fires only when the ledger also contains a Bedrock-envelope session, because
  the 2026-08-24 fix moved first-party rows by zero and a note that fires on
  every ledger forever would not be read. Unversioned rows recorded no envelope
  of their own, so the trigger is an inference from the machine's later rows
  and the note says so — it does not assert those rows are wrong.
- **Re-metering is the repair path, and provenance is caller-supplied.** When
  a metering bug is fixed, affected rows are re-metered, never scaled: the
  inflation factor varies per field and per session (1.36x–3.74x across
  fields in the 2026-08-23 Bedrock report, invariant 1), so no single factor
  repairs a stored row. `append` replaces the row wholesale, and
  `work.commits` now re-derives from the recorded `started`/`ended` window, so
  a repair no longer strips the session-to-commit grounding on its own. It is
  still worth extracting `.work.commits` from the affected row and re-passing
  those SHAs, because a commit rewritten by a rebase since the original run has
  a committer date the window no longer covers. Evidence survives if the
  drop-box files persist, because `evidence_for` re-reads them at append, and
  re-derives through `emit-evidence-beads.sh` even if they do not, because its
  window filter reads the session's recorded `started`/`ended`.
- **A repair must run the producer itself.** Nothing in `ledger.sh` writes the
  drop-box — `evidence_for` only reads it, and `emit-evidence-beads.sh` is
  invoked from the skill, not from `append`. So a row written by a bare
  `ledger.sh append` repair carries `evidence: null`, and re-metering alone
  never lifts it: the same null row comes back every time. That is not
  hypothetical — an external report arrived with 13 of 14 rows in exactly that
  state from one repair pass, which is why its `with_evidence` read 0, and
  `trend` excludes such rows from every per-task ratio. The producer runs
  *before* `append`, both reading the same `LASTCALL_EVIDENCE_DIR`; README
  "Repairing a ledger row" carries the recipe and `verify.sh` pins it.
- **`pricing_source` is required.** A cost figure whose rate table is unknown
  cannot be compared against other rows, and rates change over time.
- **`promo_applied` records the pricing regime, and absent means unknown.** A
  promo expiring re-prices every later row without any behavior changing, so
  `ledger.sh trend` reports how many rows fall in each regime and flags a
  baseline that spans a change. Rows written before this field existed carry
  `null`, which counts as *unknown* — never as "no promo", since silently
  folding them into the full-rate bucket would erase the very boundary the
  field exists to expose.
- **`caveats` is non-empty when `usd` is known to understate.** An
  unpriceable service tier or server-tool requests that bill per request rather
  than per token both land here. A row carrying caveats is not directly
  comparable to one that does not, for the same reason `pricing_source` exists.
- **New fields are additive and do not bump `schema`.** Consumers ignore
  unknown fields, and a missing field on an older row means *unmeasured*, never
  zero — `agent_s` and `caveats` are both absent on rows written before they
  existed. Never fold an absent value into a real bucket.
- **Absent evidence is recorded as absent**, never as zero completed tasks.
  A session with no evidence files reports "not assessed" — inferring
  productivity from token burn rewards thrashing.
- **`per_task_basis` says which of three populations a null came from.**
  `trend` reports it beside `per_task`, and the focus block beside
  `per_task_usd`. The three states are: rows carrying completed tasks, which
  are the only ones in the ratios; rows a producer assessed and found nothing
  in (`evidence` non-null, `completed` 0, driven by the empty marker in section
  2); and rows never assessed (`evidence: null`). A bare `null` conflated all
  three, and the third is also what a repair pass that skipped the producer
  leaves behind, so the reader could not tell a quiet workspace from a broken
  recipe. The field is emitted even when `per_task` is present: a ratio drawn
  from 2 of 30 rows needs the same disclosure as one drawn from none. Assessed
  zeroes stay out of `with_evidence` and out of every ratio — they explain the
  null, they do not populate it.
- **Session windows are NOT disjoint, and `trend` must say so.** The evidence
  producer assigns a bead to every session whose `[started, ended]` contains
  its transition (section 2). Windows in one workspace overlap routinely — a
  session left open across a break, a `/clear` that mints a new id while the
  earlier window stays open, or an `ended` that is only the last transcript
  entry — so a long session claims the work of every session nested inside it
  and divides its own cost by an inflated count. Measured across 60 local
  transcripts on 2026-08-25: windows of 409h and 313h carrying near-zero
  actual activity. The failure is not loud; it reads as *efficiency*, because
  the most inflated row is the cheapest per task.

  `trend` therefore computes `window_overlap` per row, lists every affected
  row under `window_overlaps`, and **excludes overlapped rows from the
  `per_task` medians** the same way rows without evidence are excluded, with
  the count named in `per_task_basis`. The focus block carries the row own
  list plus a caveat on `per_task_basis`, so a per-row ratio cannot be taken
  at face value.

  Three properties of that calculation, each load-bearing:
  - It is computed at **read** time, never stored on the row. An enveloping
    session starts earlier and ends later, so at append time the nested row
    either sees no envelope row at all or a stale one. Only `trend` sees every
    row at once, and it recomputes on each call, so it cannot go stale.
  - It is scoped by **cwd**. Two sessions in different workspaces read
    different bead databases and cannot be claiming the same task.
  - An unreadable window yields `null`, not `[]`. That is *unknown* overlap,
    and it is excluded from the ratios rather than trusted into them — the
    same absent-is-not-zero rule as everywhere else in this section.

  This is disclosure, not a repair: the assignment itself is still wrong, and
  genuinely interleaved concurrent sessions can both legitimately fall inside
  each other windows. Narrowing the join from the window to actual session
  activity is tracked separately.

---

## 4. Preferences store

What the user already answered, so a wrap-up does not re-ask it every session.
Read and written **only** by `../scripts/config.sh`.

**Nothing stored here authorizes an action.** A preference seeds how a gate is
worded and pre-selected; the gate still fires. Outward-facing or irreversible
actions — a tracker write, publishing a report — confirm every time, even when
the stored preference says yes. That is what makes the store safe to be wrong.

### Location

```
${LASTCALL_CONFIG:-~/.claude/lastcall/config.json}
```

Beside `ledger.jsonl`, `evidence/` and `statusline/`, with the same env-override
idiom as `LASTCALL_LEDGER`, `LASTCALL_EVIDENCE_DIR`, `LASTCALL_STATUSLINE_DIR`,
`LASTCALL_RATES` and `CLAUDE_PROJECTS`.

**Not in the repository.** Fathom keeps `.fathom/config.md` in-tree because
base-branch and state-mapping are facts about a *project* and belong to
everyone who clones it. "Do I want a report published" is one person's taste,
and committing it would impose it on every clone.

### Keyed on git origin, not cwd

```
origin  = git config --local --get remote.origin.url
root    = dirname of (git rev-parse --git-common-dir), absolutised
```

A cwd key fails twice on an ordinary machine, and both failures were measured
here rather than assumed. `~/.claude/projects/` currently holds **both**
`-Users-ryanuesato-code-agent-skill-wrapup` and
`-Users-ryanuesato-code-agent-skill-lastcall` — one repository, renamed — and
**both** `-Users-ryanuesato-code-ima-app` and
`-Users-ryanuesato-code-ima-app--claude-worktrees-feat-ui-refinement` — one
repository, plus a worktree. A cwd-keyed preference is lost by the rename and
invisible from the worktree. This is the same pair of failures section 2 cites
for keying evidence on session id; session id is unusable here because a
preference has to **outlive** the session.

`--git-common-dir`, **not** `--show-toplevel`. Verified against the real
worktree at `~/code/ima-app/.claude/worktrees/`: `--show-toplevel` returns the
worktree path, while `--git-common-dir` returns
`/Users/ryanuesato/code/ima-app/.git`, so its dirname is the main checkout and a
worktree session shares the main repository entry. It returns a path **relative
to cwd** when run inside the main checkout (measured: bare `.git` at the root,
`../../../.git` three levels down), so it must be absolutised, not used as-is.

Matching order is **origin first, then `repo_root`**. On an origin hit with a
stale `repo_root`, the entry is rewritten in place, so a rename self-heals — the
same staleness `emit-evidence-beads.sh` already defends against on recorded cwd,
where 5 of 26 sessions carry a path that no longer exists. A repository with no
remote can only be keyed on its path, and a rename does lose its entry; that is
unavoidable, and it is why origin is preferred wherever one exists.

### Shape

```jsonc
{
  "schema": "lastcall.config/1",

  // A SNAPSHOT of the built-ins in force the day this file was created, written
  // once and never rewritten. See "Adding a key" below.
  "defaults": {
    "memories": true, "ledger": true, "report": false, "file_issues": false
  },

  "projects": [
    {
      "origin":    "git@github.com:you/project.git",  // null for a repo with no remote
      "repo_root": "/Users/you/code/project",         // rewritten on a rename
      "configured_at":    "2026-08-23T20:53:15Z",     // when setup last RAN
      "lastcall_version": "0.3.1",                    // null means unmeasured
      "cc_version":       "2.1.241",                  // null means unmeasured
      "prefs": { "report": true }                     // ONLY keys actually answered
    }
  ]
}
```

`lastcall_version` and `cc_version` exist so the upgrade path can tell a config
written by an older setup flow from a current one. Without them, version drift
is invisible and an existing user stays frozen on whatever the setup screen
happened to ask the first time. They are stamped by `config.sh init` — which
means *setup ran* — and on the creation of a new entry. A plain `set` does not
restamp them: changing one answer is not a setup run.

### Resolution

For every key in the closed vocabulary, in order:

```
project entry prefs  ->  stored defaults  ->  built-in
```

The built-ins **are v0.3.1 behaviour**, so a value missing at every level still
produces an answer and a caller never has to handle "absent". `config.sh get`
returns the resolved value plus a `sources` map naming which level supplied it.

`project.configured` is true only when an entry exists — it is what the
first-run screen turns on, **not** any preference value. A preference can equal
its built-in and still never have been answered.

### Rules

- **Missing resolves as ABSENT, never as false.** The acceptance test for the
  whole feature is that `rm`-ing this file makes lastcall behave exactly as
  v0.3.1. Nothing may read a missing file as a "no".
- **Unparseable is treated as absent, with a warning to stderr — never an
  abort.** A preferences file is not worth failing a wrap-up over. Same call
  the meter makes on an unparseable statusline capture, and `ledger.sh` on an
  unparseable evidence file. An unrecognised `schema` is handled the same way.
- **Reads degrade; writes refuse.** Treating a damaged file as absent and then
  writing over it would destroy whatever it held — including a config written
  by a *newer* lastcall, which reads here as unknown-schema. Writes stop and
  name the path (exit 4) rather than clobber.
- **Adding a key is additive and must not flip an existing user.** A new key is
  absent from every existing config, so it falls through to its built-in, and
  that built-in has to describe what lastcall already does. The stored
  `defaults` snapshot is what makes this mechanical rather than a promise: a
  later release changing a built-in cannot move a user who already has a
  config, because their answer is pinned. New keys the snapshot lacks still
  fall through to the new built-in.
- **Unknown keys are an error, on read and on write.** A typo must not resolve
  as "absent" and quietly take the built-in — a preference silently not
  applying is the exact failure this store exists to remove.
- **`config.sh` writes `$LASTCALL_CONFIG` and nothing else.** Every mutation
  goes through one writer that takes no path argument, and the atomic-rename
  temp lives in the config directory rather than `$TMPDIR` — same-filesystem, so
  the rename is atomic, and the write stays inside the one directory. The
  `allowed-tools` grant that lets a skill run this script depends on that.

---

## 5. Environment probe

Produced by `../scripts/detect.sh`. Consumed by the first-run setup screen.

It answers **"what is available here, and can it actually be reached"** — the
probe half of the routing split. Probe when the question has one right answer;
prompt when it is a matter of taste. Nothing in this contract decides anything,
and `detect.sh` writes nothing anywhere.

### Cost, and why it is first-run only

The reachability stage runs `claude mcp list`, measured 2026-08-23 at **3.66s**
from this repo and **3.81s** from `~/code/pharmgkb-mobile`; end to end, with the
`gh` round trip, a full `detect.sh` run is **4.99s**. That is a fifth of a whole
wrap-up spent on a question whose answer changes about once a month, so it must
not run on every session close. `--cheap` is the per-session path — **0.70s**
measured in the same place: it keeps every config-derived finding and downgrades
every reachability to `unknown`.

### Shape

```jsonc
{
  "schema": "lastcall.detect/1",
  "cwd": "/Users/you/code/project",

  "harness": {
    "claude_code": true,        // is `claude` on PATH at all
    "cc_version":  "2.1.241",   // null means unmeasured, never "old"
    "mcp_probe_cmd": "claude mcp list"   // null where no such command exists
  },

  // PROBE ONLY, NEVER A PROMPT. See the routing rule below.
  "memory": {
    "backend": "claude-native",
    "path":    "~/.claude/projects/<slug>/memory",
    "state":   "present",       // "present" | "absent"
    "entries": 12, "has_index": true,
    "available": true,          // ALWAYS true; absent means never used here
    "promptable": false
  },

  "tasks": {
    "system": "beads",
    "root":    "/Users/you/code/project",  // null when absent
    "version": "1.1.0",                    // null means unmeasured
    "state":   "present",       // "present" | "absent" | "broken"
    "blocking": false           // true only for "broken"
  },

  // Reachability-filtered. Only "connected" is eligible to OFFER.
  "trackers": [
    { "id": "linear",           // recognised family, see the table below
      "name": "linear-server",  // the MCP server name, or the forge host
      "via":  "mcp:linear-server",
      "target": "https://mcp.linear.app/mcp (HTTP)",
      "sources": ["project-config", "mcp-runtime"],
      "state": "needs-auth",    // connected | needs-auth | failed | pending | unknown
      "detail": "! Needs authentication",
      "eligible_to_offer": false,
      "capability": "unverified",
      "remediation": "run /mcp to connect" }
  ],

  "forge": {
    "id": "github",             // github | gitlab | bitbucket | null
    "host": "github.com",
    "remote": "git@github.com:you/project.git",
    "via": "gh",
    "state": "authenticated"    // authenticated | unauthenticated | absent | unknown
  },

  "mcp": {
    "probe": "ran",             // ran | skipped | unavailable | timeout | error | unparsed
    "reachability": "measured", // "measured" only when probe == "ran"
    "wall_ms": 3802,            // null when unmeasured
    "note": null,
    "servers": [ /* every server seen, tracker or not, with a `tracker` field */ ]
  },

  "caveats": ["..."]            // human-readable, always present, often empty
}
```

### Invariants

Each of these is the difference between a true statement and a confident false
one, which is the only kind of error a setup screen cannot recover from.

1. **Fail to `unknown`, never to `absent`.** If `claude` is missing, the probe
   times out, exits non-zero, or prints something the parser does not
   recognise, every reachability becomes `unknown` and every candidate found in
   config is still reported. Dropping a configured tracker because a parser
   broke tells the user they have no tracker — a confident false statement.
   `unknown` is a true one. Same discipline as invariant 11 on `native`: a
   missing field means unmeasured, never zero.
2. **Only `connected` is eligible to offer.** `needs-auth`, `pending`, `failed`
   and `unknown` are REPORTED, each with a remediation. "Linear is configured
   but needs authentication; run `/mcp`" is useful, and is the opposite of
   silently omitting it. `eligible_to_offer` is computed, not stored — a
   consumer must never derive eligibility from `state` itself.
3. **Connection is not capability.** A `connected` server has an open
   transport. It has not been shown to expose any issue-*writing* tool. Every
   tracker row carries `capability: "unverified"` for that reason, and a
   consumer must corroborate against its own tool list before offering to file
   anything.
4. **The tracker list is a floor whenever `reachability != "measured"`.**
   Plugin-provided MCP servers appear in neither `~/.claude.json` nor
   `.mcp.json`, so a config-only pass cannot see them — measured here
   2026-08-23 as six servers with the probe and one without. A consumer must
   not read a short list as a census; `caveats` says so explicitly.
5. **Memory is probed, never prompted.** Claude Code carries its own memory
   subsystem and it is always available, so `available` is unconditionally
   true and `state: "absent"` means *never used in this project*. Storing a
   backend SELECTION would recreate the failure where the selection outlives
   the backend it named. `bd remember` is deliberately not offered as an
   alternative: it takes a content string plus a key and cannot carry type,
   description, or cross-links, so it is a lossy sink for the same data rather
   than a second backend.
6. **`tasks.state: "broken"` is a stop-and-tell.** A `.beads` directory with no
   `bd` on PATH means the issues exist and cannot be read from here. It must
   never fall back to "no task system": that would drop real tracked work out
   of the wrap-up with no error anywhere. `blocking` is true only in this case.
7. **`cc_version` is recorded so a stale parse is diagnosable.** The probe rides
   undocumented output; when it eventually breaks, the version that broke it is
   the first thing anyone will want.

### The parse, and why it is written defensively

`claude mcp list` has **no `--json`** — verified 2026-08-23, it answers
`error: unknown option '--json'`. So this rides human-readable output that is
not a documented contract, exactly the hazard the project notes for transcripts.
Three consequences, each verified rather than assumed:

- **It is cwd-sensitive, correctly so.** Run from this repo the Linear line is
  absent; run from `~/code/pharmgkb-mobile` it is present. A candidate found in
  config but not listed by the probe is therefore `unknown` with a detail that
  says so — not `absent`.
- **It shares its stream with SDK diagnostics**, e.g.
  `[mcp-sdk] SEP-2352: stored OAuth credential has no issuer stamp`. The parser
  is line-oriented and skips any line it does not recognise, rather than
  treating a surprise line as a failure.
- **Four observable states**, matched on the English status text and not on the
  glyph. The glyphs are the part most likely to move — a theme, a non-UTF-8
  terminal, a Windows console — and a status matched on a glyph that changed
  silently becomes `unknown` for every server at once:

  | Output | `state` |
  |---|---|
  | `✔ Connected` | `connected` |
  | `! Needs authentication` | `needs-auth` |
  | `✘ Failed to connect — <why>` | `failed` |
  | `⏸ Pending approval` | `pending` |

Exit status is not a health signal: a run where two servers failed still exits
0. It distinguishes only "the command ran" from "it did not". An empty result is
a real measurement in exactly one case, the literal line
`No MCP servers configured.`; any other unrecognised output is `unparsed`, which
is `unknown`, not "none".

### Tracker family recognition

`id` comes from a conservative, deliberately short table matched against the
server name and its url or command together: `linear`, `jira` (also matching
`atlassian`), `asana`, `notion`, `shortcut`, `clickup`, `trello`, `youtrack`,
`redmine`, `bugzilla`, `basecamp`, `gitlab`, `github`. `height`, `plane` and
`monday` are excluded as ordinary English words that would match unrelated urls.

An unrecognised server is not a tracker as far as this script is concerned, but
it is still emitted under `mcp.servers` with `tracker: null`, so a human or a
consumer can see it and decide. Recognition is a hint, never an authorisation —
invariant 3 still applies.

GitHub Issues is the one candidate that does not come from MCP: it is derived
from the git remote host plus `gh auth status --hostname <host>`, whose exit 0
is a real authenticated round trip rather than a config reading. It appears as
`{"id": "github-issues", "via": "gh"}` and is the only tracker that can be
`connected` without the MCP probe having run.

### Cross-harness

`claude mcp list` exists in Claude Code only. Kiro and Codex — the other two
environments section 0 targets — have no equivalent, and that is a **documented
no-op**, not a failure:

```
mcp.probe        = "unavailable"
mcp.reachability = "unknown"
trackers[].state = "unknown"    // candidates still reported, from config alone
```

It never degrades to `true`. Verified by running with `claude` removed from
`PATH`: the Linear candidate survives from `.projects[<cwd>].mcpServers` with
`state: "unknown"` and `eligible_to_offer: false`.

### Overrides

| Variable | Effect |
|---|---|
| `CLAUDE_PROJECTS` | Root for the memory probe. Same override the meter uses. |
| `LASTCALL_CLAUDE_JSON` | Path to the user-level Claude Code config. Read-only. |
| `LASTCALL_MCP_TIMEOUT_S` | Bound on the probe, default 20. Exceeding it is `unknown`, not an error. |
