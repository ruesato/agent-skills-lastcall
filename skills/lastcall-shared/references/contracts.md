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
    "started":  "2026-08-03T01:34:38Z",
    "ended":    "2026-08-06T08:46:49Z",
    "wall_s":   285131,   // first to last timestamp; near-meaningless if resumed
    "active_s": 7754      // sum of inter-event gaps <= IDLE_GAP_S (default 300)
  },

  // One row per (model, lane). Never collapse these: main threads and subagents
  // use different cache TTLs, which price differently.
  "tokens": [
    { "model": "claude-opus-5", "lane": "main",     // "main" | "subagent"
      "turns": 211, "input": 396, "output": 148499,
      "cache_read": 35035360, "cache_w_5m": 0, "cache_w_1h": 1107741 }
  ],

  "agents": [ { "agentType": "Explore", "description": "...", "spawnDepth": 1 } ],

  "work": {
    "tools": { "Bash": 150, "Edit": 61 },            // name -> call count
    "files": { "/abs/path.md": 14 }                  // path -> edit count (churn)
  },

  "friction": { "tool_errors": 7, "interrupts": 1, "denials": 0 },

  "evidence": []                                     // filled from contract 2
}
```

### Invariants the meter guarantees

Each of these silently corrupts totals if a reimplementation drops it:

1. **Deduped by `requestId`.** Streaming writes one entry per chunk sharing a
   `requestId`. Summing raw entries overcounts by roughly 90%.
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

---

## 2. Evidence drop-box

**This is the Fathom seam.** Any skill that completes real work contributes here.
`lastcall` globs the directory — it holds no per-skill integration code, so new
producers need no changes on the consumer side.

### Location

```
<project-transcripts>/<session-id>/evidence/<source>-<timestamp>.json
```

One file per emitting run. Never modify or overwrite another producer's file.

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

  "cost": {
    "usd": 4.18,
    "by_model": [ { "model": "claude-opus-5", "lane": "main", "usd": 3.91 } ],
    "pricing_source": "claude-api@2026-08-18",  // which rate table produced this
    "promo_applied": true,                      // any lane billed at a promo rate
    "promo_models": ["claude-sonnet-5"]         // which ones
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
- **Absent evidence is recorded as absent**, never as zero completed tasks.
  A session with no evidence files reports "not assessed" — inferring
  productivity from token burn rewards thrashing.
