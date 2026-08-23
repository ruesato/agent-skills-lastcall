# Contracts

The three interfaces that must not drift. Everything else in this project is
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
    "ai_title": "Support multiple code forges in skill project"
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
    "skills": [
      { "skill": "claude-api", "plugin": null, "model": "claude-opus-5",
        "turns": 8, "input": 16, "output": 11340,
        "cache_read": 4049677, "cache_w_5m": 0, "cache_w_1h": 361355 }
    ]
  },

  // How much of the session is still visible to whoever is summarizing it.
  // Unlike `native`, ZERO here is a measurement, not an absence: every entry of
  // every transcript was read and no compaction boundary was found. Read from
  // system/compact_boundary records. Main lanes only — a subagent compacting
  // its own context costs the main thread nothing.
  "context": { "compactions": 1, "dropped_tokens": 260337,
               "triggers": ["manual"] },

  "friction": { "tool_errors": 7, "interrupts": 1, "denials": 0 },

  "evidence": [],                                    // filled from contract 2

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

### Invariants the meter guarantees

Each of these silently corrupts totals if a reimplementation drops it:

1. **Deduped by `requestId`.** Streaming writes one entry per chunk sharing a
   `requestId`, and every chunk in a group repeats the same cumulative `usage`,
   so the group collapses to its first entry. Summing raw entries overcounts by
   roughly 90%. **This guard is load-bearing, not vestigial.** Measured
   2026-08-22 over 27 local transcripts: `requestId` present on 5629 of 5630
   assistant entries, ~50% of entries duplicates, and the most common group size
   is *three*, not two. A 2026-08-22 external review sampled this as absent from
   100% of turns, concluded the guard was inert, and proposed changing the
   grouping key; on this corpus that would have inflated every total by ~2.3x.
   So the meter now MEASURES what the key did rather than assuming it, and
   reports it as `session.dedup` — `entries`, `turns`, `collapsed`, and
   `rid_coverage`. A `rid_coverage` of 0 means the fallback to `uuid` carried
   the whole file and nothing was collapsed; `cost.sh` raises a caveat, because
   that is the signal the transcript format moved. Do not delete the guard on
   the strength of a session that happens to need no collapsing.
2. **Subagents included.** Their turns live in
   `<project>/<session-id>/subagents/*.jsonl`, not in the main transcript.
   Metering only the main file silently omits all subagent cost.
3. **`<synthetic>` entries excluded.** They carry a null `requestId` and all-zero
   usage.
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
   `message.content` exactly twice and both are filtered to structure —
   `tool_use` names and paths, and `tool_result.is_error`. No prompts, no
   assistant prose, no tool output bodies. Any narrative in a summary comes
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
- Unknown fields are preserved and ignored. Add fields freely; never repurpose
  an existing one.
- Bump `schema` on any breaking change. Consumers reject unknown major versions
  loudly rather than guessing.

### Rules for consumers

- Glob all `*.json`; skip unparseable files with a warning rather than aborting.
- Dedupe on `(source, task.id)`, keeping the highest `emitted_at`. A task
  re-emitted as `completed` supersedes its earlier `partial`.

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

  "cost": {
    "usd": 4.18,
    "by_model": [ { "model": "claude-opus-5", "lane": "main", "usd": 3.91 } ],
    "by_skill": [ { "skill": "claude-api", "plugin": null, "usd": 0.27 } ],
    "pricing_source": "claude-api@2026-08-18",  // which rate table produced this
    "promo_applied": true,                      // any lane billed at a promo rate
    "promo_models": ["claude-sonnet-5"],        // which ones
    "caveats": []                               // why usd may understate; see below
  },

  "tokens":   { /* contract 1 `tokens`, verbatim */ },
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
