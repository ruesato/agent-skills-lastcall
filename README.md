# lastcall

Two Claude Code skills for closing out agentic work sessions.

- **`/lastcall`** — wraps up a session. Meters what it cost in tokens, active
  time, and dollars; summarizes what actually landed and what is still open;
  then offers to commit, save memories, publish a report, and update the
  tracker. Every durable action happens only after you approve it.
- **`/tally`** — the mid-session checkpoint. Metering and readout only, no side
  effects, safe to run at any point.

`tally` measures. `lastcall` measures and then acts.

## Install

As a plugin, from the `ruesato-plugins` marketplace:

```
/plugin marketplace add ruesato/plugins
/plugin install lastcall
```

If that `add` fails with `Permission denied (publickey)` — some Claude Code
versions clone `owner/repo` shorthand over SSH, which fails on a machine with
no GitHub SSH key — add the marketplace by its full HTTPS URL instead:

```
/plugin marketplace add https://github.com/ruesato/plugins.git
```

Setting `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` fixes the shorthand the same way,
for every marketplace and plugin on that machine.

Or link this repo directly, which is the better option if you intend to edit
the skills — it symlinks rather than copies, so edits apply live:

```bash
./install.sh                  # auto-detect target(s)
./install.sh --target claude  # ~/.claude/skills
./install.sh --target kiro    # ~/.kiro/skills
./install.sh --uninstall
```

`install.sh` also puts the shared scripts on a fixed path under
`~/.lastcall/bin`, which is how the skills find them in Kiro — it has no
skill-directory variable, so a relative path from a `SKILL.md` cannot be
executed there.

### Kiro

Kiro has no plugin marketplace, so the install is via `install.sh`.
The three skills (`lastcall`, `tally`, `lastcall-shared`) must travel
together — `lastcall` and `tally` resolve their scripts through
`../lastcall-shared/scripts/`, and the `~/.lastcall/bin` fallback covers
the case where that relative path does not resolve.

```bash
# 1. Clone the repo
git clone https://github.com/ruesato/agent-skills-lastcall.git
cd agent-skills-lastcall

# 2. Install the skills into ~/.kiro/skills and the scripts into ~/.lastcall/bin
./install.sh --target kiro

# 3. Verify the meter runs from the installed path
~/.lastcall/bin/meter-session.sh
```

Kiro writes no Claude Code transcripts and sets no session id, so step 3 there
prints a **stub** — a JSON document of the normal shape with every measurement
`null` and a `stub` block saying why. That is the expected result, not a
failure: see "When there is no transcript" below for what still works.

**Confirmed 2026-08-25 on Kiro 1.0.337** (`kiroAgent` 1.0.653): the panel is
real — command palette → "Kiro: Focus on Agent Steering & Skills View" opens
a section literally titled **AGENT STEERING & SKILLS**, and `lastcall`,
`lastcall-shared`, and `tally` all appear under it correctly via the symlinks
`install.sh` creates. `lastcall-shared` is a file container, not invocable.

This was not always true — Kiro versions before 1.0.288 (2026-08-07) have no
skills feature at all; see `docs/kiro-runtime-findings.md` and
`agent-skill-wrapup-h12` for that history if you're on an older install.

To uninstall:

```bash
./install.sh --target kiro --uninstall
```

## How the metering works

`skills/lastcall-shared/scripts/meter-session.sh` reads Claude Code transcripts
from `~/.claude/projects/<slug>/` and emits pure counts as JSON. It deliberately
carries no pricing, so rates come from the `claude-api` skill at runtime and the
meter stays correct when prices change.

Four things silently corrupt session totals, and the meter handles each:

- Streaming writes one assistant entry per chunk, all sharing a response id —
  `requestId` on the first-party API, `message.id` on Bedrock-served
  transcripts. Summing raw entries overcounts by roughly 90%. Both of those are
  field names, so the meter also checks the behaviour they stand in for:
  duplicate chunks repeat their cumulative usage, and surviving duplicates show
  up as adjacent turns with identical usage. A response id written per chunk
  rather than per response would pass the field check and fail this one.
- Subagent turns live in separate `<session>/subagents/*.jsonl` files, so
  metering only the main transcript omits their cost entirely.
- Main threads use a 1h cache TTL while subagents use 5m, and the two price
  differently, so cache writes are never collapsed into one number.
- Wall-clock time is meaningless for a resumed session, which can span days.
  Active time is computed by gap bucketing instead.

### When there is no transcript

The meter emits a **stub** rather than failing when it cannot find one: the same
document shape, every measurement `null`, and a top-level `stub` block giving
the reason. `null` means *unmeasured*, never zero — a stub reporting `active_s:
0` would say the session did nothing, which is a false statement rather than a
missing one.

This is the ordinary path in Kiro, and it also covers a transcript the harness
has rotated away, a session too new to have been flushed, and a session id that
does not resolve.

What still works, because it never came from the transcript in the first place:
open loops (branch, uncommitted files, TODOs added, churn availability) and the
evidence drop-box, and with them the commit, memories, report and tracker
delegations. What does not: cost, tokens, active time and friction are reported
as unmeasured, and no ledger row is written — a row with no measurements in it
would poison the baseline rather than extend it.

Set `LASTCALL_REQUIRE_TRANSCRIPT=1` to get the old hard failure back.

Every claim in a summary must trace to an artifact — a file path, a commit SHA,
a task id, a test result. Transcripts are full of intentions that never landed,
so nothing is ever summarized from conversational narrative alone.

### Offline, air-gapped, and enterprise environments

**Nothing in the evidence path needs a network, by design.** This is a property
of the architecture, not an accident of the shipped producer, so it holds for
restricted environments without any special mode:

- `emit-evidence-beads.sh` makes no network call. Its only external command is
  `bd list` against a local Dolt DB. Beads' sync is a separate, optional,
  user-initiated action — the producer works with the NIC unplugged.
- The drop-box's *intended* path, push producers, is offline by construction.
  A skill that does real work writes a JSON file at its own task transitions,
  and nothing needs to invoke it. The drop-box is a local filesystem
  rendezvous; see `contracts.md` section 2.

So for an air-gapped environment the answer is **use beads, or write a push
producer**, and both work today with no changes.

**Where the only thing available is a git remote and no API** — plain
self-hosted git, Bitbucket Server, Perforce Swarm — the honest answer is that
there is no defensible task signal, and `lastcall` says so by staying silent
rather than inventing one. A producer that does not apply writes nothing and
exits 0; it does not write an empty document, because that would claim an
assessment it never made.

Four candidates were considered for that case and rejected, all for the same
reason — they would require reading intent out of prose, which is exactly what
the grounding rule forbids: merge commits on an integration branch (task
identity is still a subject line, and rebase-only shops produce none),
annotated tags (releases, not tasks), `git notes` (structurally fine,
effectively unused), and `Closes #123` trailers (written at commit time, so
they assert intent rather than outcome). Cost, tokens, active time, open loops
and the commit/memory/report delegations are all unaffected — only the
per-task denominator goes unmeasured, and it is reported as unmeasured.

## Optional: capture the status line

Two things Claude Code knows about a session appear nowhere in a transcript:
how much of your **5-hour and 7-day rate-limit windows** you have consumed, and
Claude Code's own estimate of what the session cost. Both arrive on stdin to
whatever command you configure as your status line.

`capture-statusline.sh` is a pass-through filter. It writes that payload where
the meter can find it and copies stdin to stdout unchanged, so it **composes
with a status line you already have** rather than replacing it:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.lastcall/bin/capture-statusline.sh | ~/.claude/statusline.sh"
  }
}
```

If you have no status line and only want the capture, send its output to
`/dev/null` — a status line that prints nothing still runs:

```json
{ "statusLine": { "type": "command",
                  "command": "~/.lastcall/bin/capture-statusline.sh > /dev/null" } }
```

**`install.sh` will never write this for you.** `statusLine` is a single object
per settings file and a higher-precedence scope replaces it wholesale — only
permission rules merge across scopes — so installing one would silently destroy
a status line you built. And configuring a status line where you had none
suppresses most of the footer's keyboard hints, including `esc to interrupt`. A
metering skill has no business doing either. Adding the line is your call; the
install only puts the script on a stable path.

What it is worth knowing before you opt in:

- **Rate limits are subscriber-only.** They appear for Claude.ai Pro/Max
  accounts, and only after the first API response. On an API key you get the
  cost and timing fields and nothing else.
- **Doing nothing costs you nothing.** With no capture the meter omits the
  `native` block entirely. It is never emitted with zeroes, because "0% of your
  weekly window used" and "we did not measure it" are opposite claims.
- **It runs on every assistant message.** The script writes via a temp file and
  an atomic rename, because Claude Code cancels an in-flight status line script
  when a new update fires; it prunes captures older than a week; and every error
  path exits 0 after passing stdin through, so it cannot break your status line.
- **Captures live in `~/.claude/lastcall/statusline/<session-id>.json`.**

## Development

This is a shell + jq project. There is no `package.json` and no build step.

```bash
S=skills/lastcall-shared/scripts
M=$($S/meter-session.sh <session-uuid>)           # always pass the id
printf '%s' "$M" | $S/cost.sh                     # dollars
printf '%s' "$M" | $S/openloops.sh                # what is unfinished
printf '%s' "$M" | $S/emit-evidence-beads.sh      # fill the drop-box FIRST
printf '%s' "$M" | $S/ledger.sh append [sha ...]  # write/replace this row
$S/ledger.sh trend <session-uuid>                 # baseline + focus comparison
```

The producer line is third for a reason — see below.

Set `LASTCALL_LEDGER` to a scratch path while testing, so the real baseline at
`~/.claude/lastcall/ledger.jsonl` is not polluted.

### Repairing a ledger row

`ledger.sh append` **reads** the evidence drop-box and never writes it.
`emit-evidence-beads.sh` is what writes it, and it is invoked from the skill,
not from `append`. So a row you produce by running `append` yourself carries
`evidence: null` — and re-metering alone never repairs it, because the same
empty drop-box yields the same null row. Rows without evidence are excluded
from every per-task ratio in `ledger.sh trend`, so they are invisible in the
baseline rather than merely incomplete.

Run the producer first, and point both at the same drop-box:

```bash
S=skills/lastcall-shared/scripts       # or ~/.lastcall/bin once installed
M=$($S/meter-session.sh <session-uuid>)
printf '%s' "$M" | $S/emit-evidence-beads.sh
printf '%s' "$M" | $S/ledger.sh append
```

Both steps are idempotent, so this is safe to re-run: the producer writes a new
timestamped file each time and `evidence_for` merges on task id alone, keeping
the newest observation of each task and unioning its artifacts, while `append`
replaces the row keyed on `session_id` alone. What it needs:

- **The transcript still on disk.** `meter-session.sh` reads it; there is no
  other source for the session window.
- **The right working directory.** The producer walks up from the session's
  recorded `cwd` looking for `.beads`, falling back to `$PWD` when that path no
  longer exists — the usual case after a directory rename.
- **`LASTCALL_EVIDENCE_DIR` set the same way for both**, if you override it.
  Producing into one drop-box and appending from another is the failure this
  recipe exists to fix, spelled differently.

Re-derivation is honest, not generous: only beads whose transition falls inside
the session's recorded window come back. A session that closed nothing still
gets an evidence file, carrying an empty `tasks` array. That marker is the
difference between *the producer ran here and found nothing* and *no producer
ran at all* — the second is a machine with no beads workspace, where the
producer writes nothing and exits 0 silently. Both used to reach the ledger as
`evidence: null`; now only the second does, and `ledger.sh trend` reports which
one you are looking at in `per_task_basis`. An assessed zero still stays out of
the per-task ratios: it explains the null rather than populating it.

`./verify.sh` runs every script against every transcript on this machine.
Sessions with and without subagents exercise different code paths, and that
local corpus is the only one covering both, so the suite is a sweep over real
data rather than fixtures. It is local-only and exits non-zero on any failure.

## Security scanning

Every skill under `skills/` is scanned by
[NVIDIA SkillSpector](https://github.com/NVIDIA/SkillSpector) in CI on push and
pull request. **The build fails on any non-suppressed finding.**

This repo ships scripts that run from agent sessions under implicit trust —
they read transcripts, write to a ledger under `~/.claude/`, and read
`CLAUDE.md` and `AGENTS.md`. That is exactly the taint, sink, and persistence
surface SkillSpector's static pass examines.

Run it locally:

```bash
uv tool install git+https://github.com/NVIDIA/skillspector.git
bin/scan-skills.sh            # every skill
bin/scan-skills.sh tally      # one skill
```

Reviewed false positives are suppressed in `.skillspector-baseline.yaml`, each
with a written reason. **Never suppress a finding you have not understood.**
Suppressions are fingerprints bound to the decoded source text and to the
scanner version, so they fail closed: editing the excused text, or bumping the
pinned SkillSpector version in `.github/workflows/skillspector.yml`, brings the
finding back for re-review rather than keeping it silently suppressed.

The LLM semantic stage runs only when `ANTHROPIC_API_KEY` is present and falls
back to static-only otherwise, so the same green check can mean two depths of
scan. `bin/scan-skills.sh` prints the mode it ran in and stamps it into every
uploaded report.

This complements `verify.sh`; it does not replace it. `verify.sh` is a
local-only correctness sweep over transcripts, SkillSpector is the CI security
gate.

## License

MIT — see [LICENSE](LICENSE).

`bin/scan-skills.sh` and `.github/workflows/skillspector.yml` are adapted from
[crodris/skills](https://github.com/crodris/skills) under the MIT License; that
notice is retained in `LICENSE`.
