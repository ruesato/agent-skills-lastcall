#!/usr/bin/env bash
# verify.sh — run every script against every local transcript.
#
#   ./verify.sh              # sweep all transcripts
#   ./verify.sh -q           # only report failures and the summary
#
# Sessions with and without subagents exercise different code paths, and the
# only corpus that covers both is the transcripts already on this machine. So
# the suite is a sweep rather than fixtures: it runs the real scripts over real
# data and checks that nothing errors and that a few invariants hold.
#
# Exits non-zero if anything fails, so it works as a pre-commit gate.
set -uo pipefail        # NOT -e: a failing check must be counted, not fatal

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/skills/lastcall-shared/scripts"
PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"
# Trailing slash stripped: TMPDIR carries one on macOS and every template below
# would otherwise produce a doubled separator, which then fails exact-path
# comparisons in the fixtures.
TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"

# Never touch the real baseline. A verification run that pollutes the ledger it
# is verifying would corrupt every trend comparison downstream.
LEDGER="$(mktemp "$TMP/lastcall-verify.XXXXXX")"
export LASTCALL_LEDGER="$LEDGER"
trap 'rm -f "$LEDGER"' EXIT

QUIET=0
[ "${1:-}" = "-q" ] && QUIET=1

pass=0; fail=0
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$1"; }
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1" >&2; }

# ---------------------------------------------------------------- static
say "== syntax =="
for f in "$S"/*.sh "$HERE"/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok; else bad "bash -n $(basename "$f")"; fi
done
# rates.json must parse and carry the fields the ledger contract requires.
if jq -e '.verified_on and .source and .multipliers and .models' "$S/rates.json" >/dev/null 2>&1
then ok; else bad "rates.json missing required fields"; fi
say "  $pass ok"

# ---------------------------------------------------------------- sweep
say "== transcripts =="
sessions=0; metered=0; withsub=0; stale_cwd=0; seen=""
for f in "$PROJECTS"/*/*.jsonl; do
  [ -f "$f" ] || continue
  sid="$(basename "$f" .jsonl)"
  # A session that outlived a directory rename has its transcript in TWO project
  # dirs under one id. The meter reads both, so metering it once per file would
  # just repeat the same check against the same combined output.
  case " $seen " in *" $sid "*) continue ;; esac
  seen="$seen $sid"
  sessions=$((sessions+1))

  # The recorded cwd is a lossy round trip. Rename a project directory and every
  # transcript that recorded the old path points at nothing, and this sweep used
  # to `continue` on exactly that condition — dropping those transcripts
  # silently, counting them as neither pass nor fail, and still printing a clean
  # result on a reduced corpus. Observed 2026-08-19 right after this project was
  # renamed: 31 transcripts, 26 swept, 5 skipped, and all 5 skipped ones were
  # this project. The suite the meter was tuned against went invisible to the
  # suite that verifies it, and the output said nothing.
  #
  # The fix is to stop needing a cwd. A session id resolves against every project
  # directory, so meter by id and use the recorded cwd only when it still exists,
  # which keeps the $PWD resolution path exercised. Count the rest instead of
  # dropping them.
  cwd="$(jq -rs 'map(.cwd // empty) | first // empty' "$f" 2>/dev/null)"
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then runcwd="$cwd"
  else runcwd="$HERE"; stale_cwd=$((stale_cwd+1)); fi

  out="$(cd "$runcwd" && "$S/meter-session.sh" "$sid" 2>/dev/null)"
  if [ -z "$out" ] || ! printf '%s' "$out" | jq -e '.session.id' >/dev/null 2>&1; then
    bad "meter $sid"; continue
  fi
  ok
  metered=$((metered+1))
  [ "$(printf '%s' "$out" | jq '.agents | length')" -gt 0 ] && withsub=$((withsub+1))

  # Native agent-busy time. Always present, always a number, and it cannot
  # exceed wall clock — it is a sum of completed turns inside that span.
  if printf '%s' "$out" | jq -e '.session.agent_s | type == "number"' >/dev/null 2>&1 \
     && printf '%s' "$out" | jq -e '.session.agent_s <= (.session.wall_s + 1)' >/dev/null 2>&1
  then ok; else bad "meter $sid: agent_s missing or exceeds wall_s"; fi

  c="$(printf '%s' "$out" | "$S/cost.sh" 2>/dev/null)"
  if printf '%s' "$c" | jq -e '.total_usd >= 0' >/dev/null 2>&1; then ok
  else bad "cost $sid"; fi
  # promo_applied must be a real boolean — it was absent once, and consumers
  # reading a missing key silently dropped the promotional-pricing signal.
  if printf '%s' "$c" | jq -e '.promo_applied | type == "boolean"' >/dev/null 2>&1; then ok
  else bad "cost $sid: promo_applied is not a boolean"; fi

  # Skill attribution partitions the same spend, so the parts must sum to the
  # whole. The null skill row is the unattributed remainder and carries the
  # difference; dropping it is what would break this.
  if printf '%s' "$c" | jq -e '(([.by_skill[].usd] | add // 0) - .total_usd | fabs) < 0.01' \
       >/dev/null 2>&1; then ok
  else bad "cost $sid: by_skill does not sum to total_usd"; fi

  # A re-establishment event is a cache WRITE, so it can never outnumber the
  # turns that wrote cache, and its dollars are a slice of the total. Both
  # bounds are structural: violating either means the event scan drifted off
  # the turns it is supposed to be scanning.
  if printf '%s' "$c" | jq -e 'if has("cache_reestablish") then
         (.cache_reestablish | .events <= .writing_turns and .usd >= 0) else true end' \
       >/dev/null 2>&1; then ok
  else bad "cost $sid: cache_reestablish events exceed writing turns"; fi

  # Thinking carry is re-reading output that was already billed once, so it is
  # bounded by the total. A carry larger than the whole session means the carry
  # weight is being multiplied by the wrong turn count.
  if printf '%s' "$c" | jq -e 'if has("thinking_carry_usd") then
         (.thinking_carry_usd >= 0 and .thinking_carry_usd <= .total_usd + 0.01) else true end' \
       >/dev/null 2>&1; then ok
  else bad "cost $sid: thinking_carry_usd out of bounds"; fi

  # Every tool_result must be attributable to the call that produced it. This
  # caught a real defect: the id map was read off the DEDUPED turns, whose first
  # streaming chunk usually holds no tool_use block, and 266 of 318 results went
  # unmatched while the table just looked like light tool usage.
  if printf '%s' "$out" | jq -e '.work.tool_context_coverage
         | .matched + .unmatched == .results and .unmatched == 0' >/dev/null 2>&1; then ok
  else bad "meter $sid: tool_context left tool results unmatched"; fi

  # load_tokens is null or positive, NEVER zero. Zero would claim a skill loaded
  # for free, where the truth is that the deltas were degenerate.
  if printf '%s' "$out" | jq -e '[.work.skill_load[]? | .load_tokens
         | select(. != null and . <= 0)] | length == 0' >/dev/null 2>&1; then ok
  else bad "meter $sid: skill_load reports a zero load_tokens instead of null"; fi

  # openloops.sh cds into the cwd the METER reports, so the caller location is
  # irrelevant — and the metered cwd is the live one even for a split session,
  # while the cwd recorded at the top of the file may be the pre-rename path.
  if printf '%s' "$out" | "$S/openloops.sh" >/dev/null 2>&1; then ok
  else bad "openloops $sid"; fi
  # Churn must stay inside the project: a scratchpad temp file is not a
  # struggle signature.
  mcwd="$(printf '%s' "$out" | jq -r '.session.cwd // empty')"
  ext="$(printf '%s' "$out" | "$S/openloops.sh" 2>/dev/null \
        | jq --arg c "$mcwd" '[.churn_hotspots[]?.file | select(startswith($c) | not)] | length')"
  if [ "${ext:-1}" = "0" ]; then ok; else bad "openloops $sid: churn includes out-of-project files"; fi

  # Activity spans are the SAME gap bucketing as active_s, kept as intervals
  # instead of summed away, so the two must never drift: they would otherwise
  # be describing different sessions, and the join reads one while the readout
  # reports the other. Also asserts the list is disjoint and ascending, which
  # is what lets a consumer run a containment test without sorting it first.
  if printf '%s' "$out" | jq -e '
        (.session.spans // []) as $sp
        | (([$sp[] | .[1] - .[0]] | add // 0) == (.session.active_s // 0))
          and all($sp[]; .[0] <= .[1])
          and ([range(1; $sp|length) as $i | select($sp[$i][0] <= $sp[$i-1][1])] | length == 0)
      ' >/dev/null 2>&1; then ok
  else bad "meter $sid: spans do not sum to active_s, or are not disjoint and ascending"; fi

  if printf '%s' "$out" | "$S/ledger.sh" append >/dev/null 2>&1; then ok
  else bad "ledger $sid"; fi
done
say "  $sessions sessions ($withsub with subagents, $stale_cwd with a stale recorded cwd)"

# Every distinct session id on disk must have produced valid meter output. This
# is the check the rename evaded: the corpus shrank by a sixth and the run still
# printed PASS, which is worse than a failure because it looks identical to the
# day before.
#
# It counts SUCCESSFUL meters, not loop iterations. Comparing the iteration
# count against the same glob it came from is true by construction and would
# assert nothing; this way a transcript that is skipped, or that meters into
# garbage, moves the number.
ondisk="$(for f in "$PROJECTS"/*/*.jsonl; do [ -f "$f" ] && basename "$f" .jsonl; done \
          | sort -u | wc -l | tr -d ' ')"
if [ "$metered" = "$ondisk" ]; then ok
else bad "metered $metered of $ondisk session ids on disk — transcripts are being dropped"; fi

# ------------------------------------------------------------ invariants
say "== invariants =="
# One row per session: append replaces in place, so a re-run must not grow it.
rows_before="$(wc -l < "$LEDGER" | tr -d ' ')"
for f in "$PROJECTS"/*/*.jsonl; do
  [ -f "$f" ] || continue
  sid="$(basename "$f" .jsonl)"
  # Same as the sweep: meter by id, never gate on a cwd that a rename can strand.
  cwd="$(jq -rs 'map(.cwd // empty) | first // empty' "$f" 2>/dev/null)"
  [ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$HERE"
  (cd "$cwd" && "$S/meter-session.sh" "$sid" 2>/dev/null) | "$S/ledger.sh" append >/dev/null 2>&1
done
rows_after="$(wc -l < "$LEDGER" | tr -d ' ')"
if [ "$rows_before" = "$rows_after" ]; then ok
else bad "ledger not idempotent: $rows_before rows became $rows_after"; fi

if [ "$(jq -s 'map(.session_id) | (length - (unique | length))' "$LEDGER")" = "0" ]; then ok
else bad "ledger contains duplicate session_ids"; fi

if "$S/ledger.sh" trend >/dev/null 2>&1; then ok; else bad "trend"; fi
# A thin baseline must not emit a confident ratio.
thin="$(jq -s '.[0:2][]' "$LEDGER" > "$LEDGER.thin"; LASTCALL_LEDGER="$LEDGER.thin" \
        "$S/ledger.sh" trend "$(jq -rs '.[0].session_id' "$LEDGER")" \
        | jq -r '.focus.vs_median_usd // "null"')"
if [ "$thin" = "null" ]; then ok
else bad "trend emitted a ratio ($thin) on a 2-row baseline"; fi
rm -f "$LEDGER.thin"

if "$S/doctrine-check.sh" "$HERE" | jq -e '.status' >/dev/null 2>&1; then ok
else bad "doctrine-check"; fi
# memory_system is a label for the host harness store, so it must follow the
# override rather than assert one this environment may not use.
if [ "$(LASTCALL_MEMORY_SYSTEM=zz/store.md "$S/doctrine-check.sh" "$HERE" \
        | jq -r '.memory_system')" = "zz/store.md" ]; then ok
else bad "doctrine-check: memory_system ignores LASTCALL_MEMORY_SYSTEM"; fi
if [ "$("$S/doctrine-check.sh" "$HERE" | jq -r '.memory_system')" = "memory/MEMORY.md" ]; then ok
else bad "doctrine-check: memory_system default changed"; fi

# memory-check.sh must catch each way a memory write silently fails to land.
# Built as a table because the value of this script is entirely in what it
# REJECTS — a version that returns ok:true for everything would pass a smoke
# test and cover nothing.
mem="$(mktemp -d "$TMP/lastcall-mem.XXXXXX")"
printf -- '- [Good](good.md) — hook\n' > "$mem/MEMORY.md"
printf -- '---\nname: good\ndescription: d\nmetadata:\n  type: project\n---\n\nBody.\n' > "$mem/good.md"
printf -- '---\nname: unindexed\ndescription: d\nmetadata:\n  type: project\n---\n\nBody.\n' > "$mem/unindexed.md"
printf -- 'no frontmatter\n' > "$mem/nofm.md"
printf -- '---\nname: bad\ndescription: d\nmetadata:\n  type: bogus\n---\n\nBody.\n' > "$mem/badtype.md"
for case in "good:true" "unindexed:false" "nofm:false" "badtype:false" "missing:false"; do
  want="${case#*:}"; f="${case%%:*}"
  got="$("$S/memory-check.sh" --store "$mem" "$mem/$f.md" | jq -r '.ok')"
  if [ "$got" = "$want" ]; then ok
  else bad "memory-check: $f reported ok=$got, expected $want"; fi
done
# Claiming nothing is a legitimate outcome and must not read as a failure.
if [ "$("$S/memory-check.sh" | jq -r '.ok, .claimed' | tr '\n' ' ')" = "true 0 " ]; then ok
else bad "memory-check: no-files case is not a clean pass"; fi
rm -rf "$mem"
say "  invariants checked"

# ---------------------------------------------------------------- fixtures
# The sweep above is only as good as the corpus on this machine. Two failure
# modes are real but incidental to any given corpus, so they are pinned here
# with fixtures that are always present.

# 1. A session metered before its first assistant turn lands has no token rows
# at all. That made `map(...) | add` return null, and null * 10000 aborts jq,
# which took down cost.sh and, through it, ledger.sh append.
zero='{"session":{"id":"fixture-zero-token","cwd":"/","branch":"main",
  "started":"1970-01-01T00:00:00Z","ended":"1970-01-01T00:00:01Z",
  "wall_s":1,"active_s":1},"tokens":[],"agents":[],
  "work":{"tools":{},"files":{}},
  "friction":{"tool_errors":0,"interrupts":0,"denials":0},"evidence":[]}'
zc="$(printf '%s' "$zero" | "$S/cost.sh" 2>/dev/null)"
if printf '%s' "$zc" | jq -e '.total_usd == 0
      and (.promo_applied | type == "boolean")
      and ([.by_bucket[] | select(. != 0)] | length) == 0' >/dev/null 2>&1
then ok; else bad "cost on a zero-token session"; fi
if printf '%s' "$zero" | LASTCALL_LEDGER="$LEDGER.zero" "$S/ledger.sh" append \
     >/dev/null 2>&1
then ok; else bad "ledger append on a zero-token session"; fi
rm -f "$LEDGER.zero"

# 1b. speed and service_tier change what a request bills at, and rates.json has
# no axis for either. Such a row must come back flagged rather than quietly
# priced at standard rates — the same failure pricing_source exists to prevent.
tier='{"session":{"id":"fixture-fast-mode","cwd":"/","branch":"main",
  "started":"2026-08-01T00:00:00Z","ended":"2026-08-01T00:00:01Z",
  "wall_s":1,"active_s":1,"agent_s":0,"agent_turns":0},
  "tokens":[{"model":"claude-opus-5","lane":"main","speed":"fast",
    "service_tier":"priority","turns":1,"input":100,"output":100,
    "cache_read":0,"cache_w_5m":0,"cache_w_1h":0,"thinking":0,
    "web_search":3,"web_fetch":0,"efforts":{"high":1}}],
  "agents":[],"work":{"tools":{},"files":{},"skills":[]},
  "friction":{"tool_errors":0,"interrupts":0,"denials":0},"evidence":[]}'
tc="$(printf '%s' "$tier" | "$S/cost.sh" 2>/dev/null)"
if printf '%s' "$tc" | jq -e '[.caveats[] | select(test("speed=fast"))] | length == 1' \
     >/dev/null 2>&1
then ok; else bad "cost did not flag a non-standard speed/service_tier"; fi
# Server-tool requests bill per request, so they belong in a caveat too rather
# than being absorbed into a token total that cannot express them.
if printf '%s' "$tc" | jq -e '.server_tools.web_search_requests == 3
      and ([.caveats[] | select(test("web search"))] | length == 1)' >/dev/null 2>&1
then ok; else bad "cost did not surface unpriced web search requests"; fi

# 2. A session keeps writing to the project directory it started in, so
# renaming the working directory strands the transcript under the old slug.
# Resolution by id has to reach across project directories to find it.
# Explicit template: GNU mktemp rejects the bare prefix `-t` takes.
FROOT="$(mktemp -d "$TMP/lastcall-fixture.XXXXXX")"
mkdir -p "$FROOT/-fixture-old-slug"
jq -cn --arg cwd "$PWD" '{sessionId: "fixture-renamed", cwd: $cwd,
    gitBranch: "main", type: "user", timestamp: "1970-01-01T00:00:00Z"}' \
  > "$FROOT/-fixture-old-slug/fixture-renamed.jsonl"
if CLAUDE_PROJECTS="$FROOT" "$S/meter-session.sh" fixture-renamed 2>/dev/null \
     | jq -e '.session.id == "fixture-renamed"' >/dev/null 2>&1
then ok; else bad "meter cannot resolve a transcript under a renamed project dir"; fi
# The same lookup must still be LOUD about an id that exists nowhere. It used to
# assert a non-zero exit; it now asserts a stub, because the exit code stopped
# being the way that is said — see the stub block in meter-session.sh. What the
# check is really protecting is unchanged: a failed resolution must never come
# back looking like a measurement. A stub cannot be mistaken for one, since
# every count in it is null and cost.sh refuses to produce a total.
if CLAUDE_PROJECTS="$FROOT" "$S/meter-session.sh" fixture-absent 2>/dev/null \
     | jq -e '.stub != null and .session.id == "fixture-absent" and (.tokens | length) == 0' \
     >/dev/null 2>&1
then ok; else bad "meter did not emit a stub for a nonexistent session id"; fi
# And a caller that wants a measurement or nothing can still demand one.
if CLAUDE_PROJECTS="$FROOT" LASTCALL_REQUIRE_TRANSCRIPT=1 \
     "$S/meter-session.sh" fixture-absent >/dev/null 2>&1
then bad "LASTCALL_REQUIRE_TRANSCRIPT did not restore the hard failure"; else ok; fi

# 2b. That rename can also SPLIT one session across two project dirs under the
# same id, and resolution that stops at the first match drops the other part
# entirely — silently, since a partial transcript looks exactly like a short
# session. Every count must combine, and the reported cwd must be the LATEST
# one: the pre-rename path in the earlier part no longer exists, and consumers
# cd into it.
# Named so the STALE part globs FIRST. Otherwise glob order alone can make
# the cwd assertion pass, and it would stop testing anything.
mkdir -p "$FROOT/-fixture-split-1-stale" "$FROOT/-fixture-split-2-live"
turn() {  # turn <requestId> <ts> <output-tokens> <cwd>
  jq -cn --arg r "$1" --arg t "$2" --argjson o "$3" --arg c "$4" \
    '{type: "assistant", requestId: $r, timestamp: $t, cwd: $c, gitBranch: "main",
      message: {model: "claude-opus-5",
                usage: {input_tokens: 10, output_tokens: $o, cache_read_input_tokens: 0,
                        speed: "standard", service_tier: "standard"}}}'
}
{ turn r1 "2026-08-19T09:00:00.000Z" 100 /gone-after-the-rename
  turn r2 "2026-08-19T09:00:30.000Z" 200 /gone-after-the-rename; } > "$FROOT/-fixture-split-1-stale/fixture-split.jsonl"
{ turn r3 "2026-08-19T09:01:00.000Z" 400 "$PWD"; } > "$FROOT/-fixture-split-2-live/fixture-split.jsonl"
split_out="$(CLAUDE_PROJECTS="$FROOT" "$S/meter-session.sh" fixture-split 2>/dev/null)"
# 700 output tokens over 3 turns: every part counted, none double-counted.
if printf '%s' "$split_out" | jq -e '([.tokens[].output] | add) == 700
      and ([.tokens[].turns] | add) == 3' >/dev/null 2>&1
then ok; else bad "meter dropped part of a session split across two project dirs"; fi
# The later part wins the cwd, so openloops does not cd into a path that a
# rename removed.
if printf '%s' "$split_out" | jq -e --arg c "$PWD" '.session.cwd == $c' >/dev/null 2>&1
then ok; else bad "meter reported the pre-rename cwd for a split session"; fi
rm -rf "$FROOT"

# 2c. NO transcript at all, and no session id from anywhere. On Kiro that is the
# ordinary path rather than an edge case — nothing there writes a transcript and
# nothing sets CLAUDE_SESSION_ID — and the sweep above structurally cannot reach
# it, since every session it finds has a transcript by construction. It also
# covers a transcript the harness has rotated away, which does happen: measured
# 2026-08-22, five of eight ledger rows had no transcript left on disk.
SROOT="$(mktemp -d "$TMP/lastcall-stub.XXXXXX")"
SEV="$SROOT/evidence"
mkdir -p "$SROOT/work"
stub_meter() { ( cd "$SROOT/work" && CLAUDE_PROJECTS="$SROOT/none" \
                 LASTCALL_EVIDENCE_DIR="$SEV" "$S/meter-session.sh" 2>/dev/null ); }
sm="$(stub_meter)"
# The fields openloops.sh reads, plus the marker that says why they are empty.
# attributed must be present and FALSE, never absent — absence there means
# "output from an older meter", and openloops then defaults churn_available to
# true, claiming the struggle signal was measured when nothing was.
if printf '%s' "$sm" | jq -e --arg w "$SROOT/work" '
      .stub.id_source == "cwd" and .session.cwd == $w
      and .work.files == {} and .work.files_coverage.attributed == false' >/dev/null 2>&1
then ok; else bad "stub meter is missing the fields openloops reads"; fi
# Unmeasured, not zero. A stub reporting active_s 0 would read as a session in
# which nothing happened, which is a confident false statement.
if printf '%s' "$sm" | jq -e '.session.active_s == null and .session.wall_s == null
      and .friction.tool_errors == null' >/dev/null 2>&1
then ok; else bad "stub meter reported zeroes where it measured nothing"; fi
# An empty token list prices to exactly $0.00, which is the one answer cost.sh
# must never give here.
sc="$(printf '%s' "$sm" | "$S/cost.sh" 2>/dev/null)"
if printf '%s' "$sc" | jq -e '.total_usd == null
      and ([.by_bucket[] | select(. != null)] | length) == 0
      and ([.caveats[] | select(test("UNMEASURED"))] | length) == 1
      and (.pricing_source | type == "string")' >/dev/null 2>&1
then ok; else bad "cost on a stub reported a figure instead of unmeasured"; fi
# The point of the whole exercise: open loops still work with no transcript.
so="$(printf '%s' "$sm" | "$S/openloops.sh" 2>/dev/null)"
if printf '%s' "$so" | jq -e '.churn_available == false
      and .git.available == false' >/dev/null 2>&1
then ok; else bad "openloops did not run on a stub meter"; fi
# The baseline must not absorb a row with no measurements in it — see the
# refusal in ledger.sh for the two ways that goes wrong.
if printf '%s' "$sm" | LASTCALL_LEDGER="$LEDGER.stub" "$S/ledger.sh" append >/dev/null 2>&1 \
     && [ ! -s "$LEDGER.stub" ]
then ok; else bad "ledger stored a stub row in the baseline"; fi
rm -f "$LEDGER.stub"
if printf '%s' "$sm" | "$S/emit-evidence-beads.sh" >/dev/null 2>&1
then ok; else bad "evidence producer errored on a stub meter"; fi
# And the drop-box survives, which is what keeps the commit, memories and
# tracker delegations alive on a host with no transcripts. The second meter run
# finding a file written under the id the first one reported is also the proof
# that a cwd-derived id is stable — that stability is the whole reason a
# producer and this reader can agree on one with no handshake between them.
ssid="$(printf '%s' "$sm" | jq -r '.session.id')"
mkdir -p "$SEV/$ssid"
jq -cn '{schema: "lastcall.evidence/1", source: "fixture",
         session_id: "recorded-but-not-used-for-lookup",
         emitted_at: "2026-08-24T00:00:00Z",
         tasks: [{id: "F-1", title: "left half done", status: "partial",
                  artifacts: []}]}' > "$SEV/$ssid/fixture-1.json"
sm2="$(stub_meter)"
if printf '%s' "$sm2" | jq -e '(.evidence | length) == 1' >/dev/null 2>&1 \
     && printf '%s' "$sm2" | "$S/openloops.sh" 2>/dev/null \
        | jq -e '[.evidence_open[] | select(.id == "F-1")] | length == 1' >/dev/null 2>&1
then ok; else bad "stub meter lost the evidence drop-box"; fi
rm -rf "$SROOT"

# 3. The statusLine capture. Both paths matter and only one of them shows up in
# the sweep: almost no session has a capture, so "absent" is well covered by
# accident and "present" is covered by nothing. The dangerous direction is a
# session with no capture reporting 0% of a rate-limit window, which reads as a
# full window left rather than as unmeasured.
CAPD="$(mktemp -d "$TMP/lastcall-cap.XXXXXX")"
CAPSID="$(jq -rs '.[0].session_id' "$LEDGER" 2>/dev/null)"
if [ -n "$CAPSID" ] && [ "$CAPSID" != "null" ]; then
  # No cd. An earlier draft ran this from the session recorded cwd, which is the
  # very thing this suite now proves is unreliable — and it duly broke the
  # moment that directory was removed, taking five checks with it while the
  # sweep beside it reported the same class of staleness as normal. The meter
  # resolves a session id across every project directory, so a cwd is not
  # needed and must not be depended on.
  meter_cap() {  # meter_cap <capture-dir>; meters CAPSID with that store
    LASTCALL_STATUSLINE_DIR="$1" "$S/meter-session.sh" "$CAPSID" 2>/dev/null
  }

  # Absent capture: the block must be missing entirely, not present and empty.
  if meter_cap "$CAPD" | jq -e 'has("native") | not' >/dev/null 2>&1; then ok
  else bad "meter emitted a native block with no capture present"; fi

  # Present capture: every field lands, and rate_limits survives intact.
  jq -cn --arg sid "$CAPSID" '{schema: "lastcall.statusline/1",
      captured_at: "2026-08-19T23:00:00Z",
      payload: {session_id: $sid, version: "0.0.0",
        cost: {total_cost_usd: 1.25, total_duration_ms: 60000,
               total_api_duration_ms: 1000, total_lines_added: 5,
               total_lines_removed: 1},
        rate_limits: {five_hour: {used_percentage: 23.5, resets_at: 1738425600},
                      seven_day: {used_percentage: 41.2, resets_at: 1738857600}}}}' \
    > "$CAPD/$CAPSID.json"
  if meter_cap "$CAPD" | jq -e '.native.cost_usd == 1.25
        and .native.rate_limits.five_hour.used_percentage == 23.5
        and .native.rate_limits.seven_day.resets_at_utc == "2025-02-06T16:00:00Z"' \
       >/dev/null 2>&1
  then ok; else bad "meter did not read a present statusline capture"; fi

  # A payload with no rate_limits must drop the key rather than zero it. This is
  # the API-key user, who legitimately has nothing here.
  jq -cn --arg sid "$CAPSID" '{schema: "lastcall.statusline/1",
      captured_at: "2026-08-19T23:00:00Z",
      payload: {session_id: $sid, cost: {total_cost_usd: 1.25}}}' > "$CAPD/$CAPSID.json"
  if meter_cap "$CAPD" | jq -e '(.native | has("rate_limits")) | not' >/dev/null 2>&1
  then ok; else bad "meter zeroed an absent rate_limits instead of omitting it"; fi

  # A corrupt capture must not take the meter down with it.
  printf '{"schema":"lastcall.statusline/1","captu' > "$CAPD/$CAPSID.json"
  if meter_cap "$CAPD" | jq -e '.session.id and (has("native") | not)' >/dev/null 2>&1
  then ok; else bad "a corrupt statusline capture broke the meter"; fi

  # A capture belonging to another session must be ignored, not attributed.
  jq -cn '{schema: "lastcall.statusline/1", captured_at: "2026-08-19T23:00:00Z",
      payload: {session_id: "someone-else", cost: {total_cost_usd: 999}}}' \
    > "$CAPD/$CAPSID.json"
  if meter_cap "$CAPD" | jq -e 'has("native") | not' >/dev/null 2>&1
  then ok; else bad "meter attributed another session capture to this one"; fi
  rm -f "$CAPD/$CAPSID.json"
fi

# 3b. Regressions found in review of the split-transcript change, each of which
# took down the WHOLE meter over one unreadable field.
#
# An empty stub file beside a real one. Collecting every matching file made this
# reachable: jq sorts null below every number, so min over a lane with no
# timestamps returns null and todateiso8601 then aborts. A rename leaving a stub
# under the stale slug is exactly how it happens in the field.
SROOT="$(mktemp -d "$TMP/lastcall-stub.XXXXXX")"
mkdir -p "$SROOT/-fixture-stub-1" "$SROOT/-fixture-stub-2"
: > "$SROOT/-fixture-stub-1/fixture-stub.jsonl"
jq -cn '{type: "assistant", requestId: "s1", timestamp: "2026-08-19T09:00:00.000Z",
    cwd: "/", gitBranch: "main",
    message: {model: "claude-opus-5", usage: {input_tokens: 1, output_tokens: 7}}}' \
  > "$SROOT/-fixture-stub-2/fixture-stub.jsonl"
if CLAUDE_PROJECTS="$SROOT" "$S/meter-session.sh" fixture-stub 2>/dev/null \
     | jq -e '([.tokens[].output] | add) == 7 and .session.started != null' >/dev/null 2>&1
then ok; else bad "an empty transcript stub beside a real one took down the meter"; fi
# No timestamps anywhere is unmeasured, not epoch zero and not a crash.
: > "$SROOT/-fixture-stub-2/fixture-notime.jsonl"
printf '{"type":"user"}\n' > "$SROOT/-fixture-stub-1/fixture-notime.jsonl"
if CLAUDE_PROJECTS="$SROOT" "$S/meter-session.sh" fixture-notime 2>/dev/null \
     | jq -e '.session.started == null and .session.wall_s == 0' >/dev/null 2>&1
then ok; else bad "a session with no timestamps did not report unmeasured"; fi
rm -rf "$SROOT"

# A capture field of the WRONG TYPE must be unmeasured, exactly like an absent
# one. These fields are undocumented external input; a resets_at that arrives as
# a string rather than epoch seconds must not cost the session its token counts.
TROOT="$(mktemp -d "$TMP/lastcall-badcap.XXXXXX")"
mkdir -p "$TROOT/proj" "$TROOT/cap"
jq -cn '{type: "assistant", requestId: "t1", timestamp: "2026-08-19T09:00:00.000Z",
    cwd: "/", gitBranch: "main",
    message: {model: "claude-opus-5", usage: {input_tokens: 1, output_tokens: 3}}}' \
  > "$TROOT/proj/fixture-badcap.jsonl"
jq -cn '{schema: "lastcall.statusline/1", captured_at: "2026-08-19T23:00:00Z",
    payload: {session_id: "fixture-badcap",
      rate_limits: {five_hour: {used_percentage: 12, resets_at: "2026-01-01T00:00:00Z"}}}}' \
  > "$TROOT/cap/fixture-badcap.json"
if CLAUDE_PROJECTS="$TROOT" LASTCALL_STATUSLINE_DIR="$TROOT/cap" \
     "$S/meter-session.sh" fixture-badcap 2>/dev/null \
     | jq -e '([.tokens[].output] | add) == 3
              and (.native.rate_limits.five_hour | has("resets_at") | not)' >/dev/null 2>&1
then ok; else bad "a wrong-typed resets_at took down the meter instead of being dropped"; fi
# Two JSON documents in one capture file: jq exits 0 emitting both, and passing
# two values to --argjson aborts the meter. Slurping is what prevents it.
jq -cn '{schema: "lastcall.statusline/1", captured_at: "2026-08-19T23:00:00Z",
    payload: {session_id: "fixture-badcap", cost: {total_cost_usd: 2}}}' > "$TROOT/one.json"
cat "$TROOT/one.json" "$TROOT/one.json" > "$TROOT/cap/fixture-badcap.json"
if CLAUDE_PROJECTS="$TROOT" LASTCALL_STATUSLINE_DIR="$TROOT/cap" \
     "$S/meter-session.sh" fixture-badcap 2>/dev/null \
     | jq -e '.session.id == "fixture-badcap"' >/dev/null 2>&1
then ok; else bad "a multi-document capture file took down the meter"; fi
rm -rf "$TROOT"

# 3c. Compaction and the session title. Both are transcript facts that decide
# how much of a session a summary can honestly claim to cover, so both are
# pinned in each direction.
CROOT="$(mktemp -d "$TMP/lastcall-compact.XXXXXX")"
mkdir -p "$CROOT/-fixture-ctx"
{ jq -cn '{type: "assistant", requestId: "c1", timestamp: "2026-08-19T09:00:00.000Z",
      cwd: "/", gitBranch: "main",
      message: {model: "claude-opus-5", usage: {input_tokens: 1, output_tokens: 5}}}'
  jq -cn '{type: "ai-title", aiTitle: "Fixture session title"}'
  jq -cn '{type: "system", subtype: "compact_boundary", timestamp: "2026-08-19T09:00:10.000Z",
      compactMetadata: {trigger: "manual", preTokens: 100, postTokens: 10,
                        cumulativeDroppedTokens: 90, durationMs: 5}}'
} > "$CROOT/-fixture-ctx/fixture-ctx.jsonl"
ctx_out="$(CLAUDE_PROJECTS="$CROOT" "$S/meter-session.sh" fixture-ctx 2>/dev/null)"
if printf '%s' "$ctx_out" | jq -e '.context.compactions == 1
      and .context.dropped_tokens == 90
      and .context.triggers == ["manual"]
      and .session.ai_title == "Fixture session title"' >/dev/null 2>&1
then ok; else bad "meter did not report compaction or the session title"; fi
# No compaction is a MEASUREMENT, not an absence: the whole transcript was read
# and none was found, so zero is the honest answer and the key must be present.
# An absent title is the opposite - unmeasured, so null.
printf '%s\n' "$(jq -cn '{type: "assistant", requestId: "c2",
    timestamp: "2026-08-19T09:00:00.000Z", cwd: "/", gitBranch: "main",
    message: {model: "claude-opus-5", usage: {input_tokens: 1, output_tokens: 5}}}')" \
  > "$CROOT/-fixture-ctx/fixture-plain.jsonl"
if CLAUDE_PROJECTS="$CROOT" "$S/meter-session.sh" fixture-plain 2>/dev/null \
     | jq -e '.context.compactions == 0 and .context.dropped_tokens == 0
              and .session.ai_title == null' >/dev/null 2>&1
then ok; else bad "meter did not report an uncompacted session as measured zero"; fi
rm -rf "$CROOT"

# The doctrine that acts on those fields has to actually be present, in both
# skills and in the shared reference. This is a documentation check on purpose:
# the fix for a silently-degrading summary IS the instruction, and a fixture
# that only pinned the meter fields would pass with the guidance deleted.
for doc in skills/lastcall/SKILL.md skills/lastcall-shared/references/summary.md; do
  if grep -q 'CLAUDE_SESSION_ID' "$HERE/$doc" && grep -q 'compact' "$HERE/$doc"
  then ok; else bad "$doc lost the self-metering or compaction guidance"; fi
done
# summary.md must not claim a transcript source that nothing supplies. The
# conversation row has to name context as its origin, not a file.
if grep -q 'own context only' "$HERE/skills/lastcall-shared/references/summary.md"
then ok; else bad "summary.md no longer marks the conversation as context-only"; fi

# 4. Bash-only editing. work.files is built from edit tool calls, so a session
# that edits through Bash reports {} — and an empty map has to be readable as
# "unmeasured" rather than "nothing was touched". The flag is what carries that
# distinction, and it has to survive the jq trap that `false // true` is true.
bashonly="$(jq -cn '{type: "assistant", requestId: "b1", timestamp: "2026-08-19T09:00:00.000Z",
    cwd: "/", gitBranch: "main",
    message: {model: "claude-opus-5",
      usage: {input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0},
      content: [{type: "tool_use", name: "Bash", input: {command: "true"}}]}}')"
BROOT="$(mktemp -d "$TMP/lastcall-bashonly.XXXXXX")"
mkdir -p "$BROOT/-fixture-bash"
printf '%s\n' "$bashonly" > "$BROOT/-fixture-bash/fixture-bash.jsonl"
bout="$(CLAUDE_PROJECTS="$BROOT" "$S/meter-session.sh" fixture-bash 2>/dev/null)"
if printf '%s' "$bout" | jq -e '.work.files == {}
      and .work.files_coverage.bash_calls == 1
      and .work.files_coverage.edit_tool_calls == 0
      and .work.files_coverage.attributed == false' >/dev/null 2>&1
then ok; else bad "meter did not flag a Bash-only session as unattributed"; fi
# openloops must carry the flag through as false. `// true` would invert it here
# — jq treats false as empty — and the readout would then claim no churn.
if printf '%s' "$bout" | "$S/openloops.sh" 2>/dev/null \
     | jq -e '.churn_available == false' >/dev/null 2>&1
then ok; else bad "openloops reported churn as available for a Bash-only session"; fi
# Meter output predating files_coverage must still default to available, so an
# older ledger row does not start claiming its churn was unmeasured.
if printf '%s' "$bout" | jq 'del(.work.files_coverage)' | "$S/openloops.sh" 2>/dev/null \
     | jq -e '.churn_available == true' >/dev/null 2>&1
then ok; else bad "openloops did not default churn_available to true when absent"; fi
rm -rf "$BROOT"

# 4b. Attribution matches on a path SEPARATOR, not a bare suffix. Without the
# anchor a dirty "foo.js" counts as accounted for by an edit to
# "/elsewhere/barfoo.js", and it silently drops off the unattributed list.
# pwd -P: on macOS /var is a symlink to /private/var and git rev-parse resolves
# it, so an unresolved path here would never equal what openloops reports.
OROOT="$(mktemp -d "$TMP/lastcall-suffix.XXXXXX")"
OROOT="$(cd "$OROOT" && pwd -P)"
( cd "$OROOT" && git init -q . && mkdir -p sub \
  && printf 'x\n' > foo.js && printf 'x\n' > sub/barfoo.js \
  && git add -A && git commit -qm seed && printf 'y\n' >> foo.js ) >/dev/null 2>&1
sfx="$(jq -cn --arg c "$OROOT" '{session: {id: "fixture-suffix", cwd: $c, branch: "main",
      started: "2026-01-01T00:00:00Z", ended: "2026-01-01T00:00:01Z",
      wall_s: 1, active_s: 1},
    tokens: [], agents: [],
    work: {tools: {Edit: 1}, files: {($c + "/sub/barfoo.js"): 1},
           files_coverage: {edit_tool_calls: 1, bash_calls: 0, attributed: true}},
    friction: {tool_errors: 0, interrupts: 0, denials: 0}, evidence: []}' \
  | "$S/openloops.sh" 2>/dev/null)"
if printf '%s' "$sfx" | jq -e --arg c "$OROOT" \
     '.uncommitted_unattributed == [$c + "/foo.js"]' >/dev/null 2>&1
then ok; else bad "openloops matched an unattributed file on a bare suffix"; fi
rm -rf "$OROOT"

# The capture script itself, independent of any session. It sits in the status
# line of whoever opts in, so the contract is that it cannot break one: stdin
# reaches stdout byte for byte, and every failure path still exits 0.
CAPPAY='{"session_id":"fixture-cap","cost":{"total_cost_usd":0.5}}'
if printf '%s' "$CAPPAY" | LASTCALL_STATUSLINE_DIR="$CAPD" \
     "$S/capture-statusline.sh" 2>/dev/null | diff -q - <(printf '%s' "$CAPPAY") >/dev/null
then ok; else bad "capture-statusline.sh altered the byte stream passing through"; fi
if jq -e '.schema == "lastcall.statusline/1" and .payload.session_id == "fixture-cap"' \
     "$CAPD/fixture-cap.json" >/dev/null 2>&1
then ok; else bad "capture-statusline.sh did not write a well-formed capture"; fi
# Garbage in, and an id that would escape the store, must both exit 0 writing
# nothing. A status line that dies on malformed input is worse than no capture.
if printf 'not json' | LASTCALL_STATUSLINE_DIR="$CAPD" "$S/capture-statusline.sh" \
     >/dev/null 2>&1; then ok
else bad "capture-statusline.sh exited non-zero on unparseable stdin"; fi
if printf '%s' '{"session_id":"../../escaped"}' \
     | LASTCALL_STATUSLINE_DIR="$CAPD" "$S/capture-statusline.sh" >/dev/null 2>&1 \
   && [ ! -e "$CAPD/../../escaped.json" ]
then ok; else bad "capture-statusline.sh let a session id escape the store"; fi
rm -rf "$CAPD"

# 5. The streaming dedup key chain: requestId first, then message.id, then
# uuid. Bedrock-served transcripts carry message.id only — requestId is absent
# on every entry — and a key that misses both falls through to uuid, which is
# unique per entry, so nothing collapses and totals inflate by the duplicate
# chunks (the external report behind this change measured ~2x across an 11-row
# ledger). Three shapes pinned: the Bedrock envelope collapses and stays
# silent, an unknown format with neither id collapses nothing and warns, and
# legacy meter JSON with no mid_coverage still warns.
DROOT="$(mktemp -d "$TMP/lastcall-dedup.XXXXXX")"
mkdir -p "$DROOT/-fixture-bedrock" "$DROOT/-fixture-unknown"
bchunk() {  # bchunk <message.id> <ts> <out-tokens> <content-json>
  # Content is a required argument: a JSON default inside ${4:-...} misparses
  # on its own braces, appending literal tail fragments to the expansion.
  jq -cn --arg m "$1" --arg t "$2" --argjson o "$3" --argjson c "$4" \
    '{type: "assistant", timestamp: $t, cwd: "/", gitBranch: "main",
      message: {id: $m, model: "claude-opus-5", content: $c,
                usage: {input_tokens: 5, output_tokens: $o,
                        cache_read_input_tokens: 100}}}'
}
{ bchunk msg_b1 "2026-08-19T09:00:00.000Z" 206 '[{"type":"text","text":"hi"}]'
  bchunk msg_b1 "2026-08-19T09:00:01.000Z" 206 \
    '[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"true"}}]'
  bchunk msg_b1 "2026-08-19T09:00:02.000Z" 206 \
    '[{"type":"tool_use","id":"tu_2","name":"Bash","input":{"command":"true"}}]'
  jq -cn '{type: "user", timestamp: "2026-08-19T09:00:03.000Z",
      cwd: "/", gitBranch: "main",
      message: {content: [{type: "tool_result", tool_use_id: "tu_1", content: "okokokok"},
                          {type: "tool_result", tool_use_id: "tu_2", content: "okokokok"}]}}'
  bchunk msg_b2 "2026-08-19T09:00:04.000Z" 100 '[{"type":"text","text":"hi"}]'
} > "$DROOT/-fixture-bedrock/fixture-bedrock.jsonl"
bkout="$(CLAUDE_PROJECTS="$DROOT" "$S/meter-session.sh" fixture-bedrock 2>/dev/null)"
# The Bedrock envelope collapses on message.id: 4 entries become 2 turns and
# usage sums once per reply (306 output, not the 718 the raw lines would give).
# The coverage pair says which envelope carried it: rid 0, mid 1.
if printf '%s' "$bkout" | jq -e '.session.dedup.entries == 4
      and .session.dedup.turns == 2
      and .session.dedup.collapsed == 2
      and .session.dedup.rid_coverage == 0
      and .session.dedup.mid_coverage == 1
      and ([.tokens[].output] | add) == 306' >/dev/null 2>&1
then ok; else bad "meter did not collapse a Bedrock-envelope transcript on message.id"; fi
# The tool-context join must key on the SAME chain as the dedup: both tool_use
# blocks live in non-first chunks of msg_b1, so a join still keyed on
# requestId or uuid alone would drop them here.
if printf '%s' "$bkout" | jq -e '([.work.tool_context[]
      | select(.tool == "Bash") | .calls] | add) == 2
      and .work.tool_context_coverage.matched == 2' >/dev/null 2>&1
then ok; else bad "tool_context join dropped non-first chunks of a collapsed group"; fi
# A handled message.id envelope must NOT raise the missing-identifier caveat —
# it would fire on every Bedrock session forever, on a correct total.
if printf '%s' "$bkout" | "$S/cost.sh" 2>/dev/null | jq -e \
     '[.caveats[] | select(test("fell through to uuid"))] | length == 0' >/dev/null 2>&1
then ok; else bad "cost warned about a handled message.id envelope"; fi

# Neither identifier present (uuid only): nothing collapses, totals equal the
# raw sums — the honest behavior for a format this version does not know.
nchunk() {  # nchunk <uuid> <ts>
  jq -cn --arg u "$1" --arg t "$2" \
    '{type: "assistant", uuid: $u, timestamp: $t, cwd: "/", gitBranch: "main",
      message: {model: "claude-opus-5", content: [{type: "text", text: "hi"}],
                usage: {input_tokens: 5, output_tokens: 50,
                        cache_read_input_tokens: 0}}}'
}
{ nchunk u1 "2026-08-19T09:00:00.000Z"
  nchunk u2 "2026-08-19T09:00:01.000Z"
  nchunk u3 "2026-08-19T09:00:02.000Z"
} > "$DROOT/-fixture-unknown/fixture-unknown.jsonl"
unout="$(CLAUDE_PROJECTS="$DROOT" "$S/meter-session.sh" fixture-unknown 2>/dev/null)"
if printf '%s' "$unout" | jq -e '.session.dedup.turns == 3
      and .session.dedup.collapsed == 0
      and .session.dedup.rid_coverage == 0
      and .session.dedup.mid_coverage == 0
      and ([.tokens[].output] | add) == 150' >/dev/null 2>&1
then ok; else bad "meter collapsed or miscounted a transcript with no known identifier"; fi
# ...and the caveat FIRES, because this is exactly the next-format-moved shape.
if printf '%s' "$unout" | "$S/cost.sh" 2>/dev/null | jq -e \
     '[.caveats[] | select(test("fell through to uuid"))] | length == 1' >/dev/null 2>&1
then ok; else bad "cost stayed silent when neither identifier was found"; fi
# Legacy meter JSON has rid_coverage but no mid_coverage. Pre-fix Bedrock rows
# are precisely the ones already inflated, so stripping the key must not
# silence the warning.
if printf '%s' "$unout" | jq 'del(.session.dedup.mid_coverage)' \
     | "$S/cost.sh" 2>/dev/null | jq -e \
     '[.caveats[] | select(test("fell through to uuid"))] | length == 1' >/dev/null 2>&1
then ok; else bad "cost stopped warning on legacy meter JSON with no mid_coverage"; fi
# The blind spot the coverage pair structurally cannot see: an envelope that
# writes its response id PER CHUNK. mid_coverage is a full 1, so the
# missing-identifier caveat is correctly silent, nothing collapses, and every
# total is inflated — the same failure one field along. The name-independent
# check catches it: duplicate chunks repeat their cumulative usage, so
# surviving duplicates show up as adjacent turns with identical usage.
mkdir -p "$DROOT/-fixture-perchunk"
pchunk() {  # pchunk <message.id> <ts> <in> <out> <cache-read>
  jq -cn --arg m "$1" --arg t "$2" --argjson i "$3" --argjson o "$4" --argjson c "$5" \
    '{type: "assistant", timestamp: $t, cwd: "/", gitBranch: "main",
      message: {id: $m, model: "claude-opus-5", content: [{type: "text", text: "hi"}],
                usage: {input_tokens: $i, output_tokens: $o,
                        cache_read_input_tokens: $c}}}'
}
{ pchunk msg_c1 "2026-08-19T09:00:01.000Z" 5 200 100
  pchunk msg_c2 "2026-08-19T09:00:02.000Z" 5 200 100
  pchunk msg_c3 "2026-08-19T09:00:03.000Z" 5 200 100
  pchunk msg_c4 "2026-08-19T09:00:04.000Z" 7 300 400
  pchunk msg_c5 "2026-08-19T09:00:05.000Z" 7 300 400
  pchunk msg_c6 "2026-08-19T09:00:06.000Z" 7 300 400
} > "$DROOT/-fixture-perchunk/fixture-perchunk.jsonl"
pcout="$(CLAUDE_PROJECTS="$DROOT" "$S/meter-session.sh" fixture-perchunk 2>/dev/null)"
# 4 of 5 adjacent pairs repeat their usage; only the 3->4 boundary differs.
if printf '%s' "$pcout" | jq -e '.session.dedup.mid_coverage == 1
      and .session.dedup.collapsed == 0
      and .session.dedup.adj_pairs == 5
      and .session.dedup.adj_dup == 4
      and .session.dedup.adj_dup_share == 0.8' >/dev/null 2>&1
then ok; else bad "meter did not measure surviving duplicates on a per-chunk response id"; fi
if printf '%s' "$pcout" | "$S/cost.sh" 2>/dev/null | jq -e \
     '[.caveats[] | select(test("byte-identical usage"))] | length == 1' >/dev/null 2>&1
then ok; else bad "cost stayed silent on a per-chunk response id (full coverage, nothing collapsed)"; fi
# The healthy fixtures must NOT trip it — a false positive here would fire on
# every session. Measured 0.0 across all 55 local transcripts.
if printf '%s' "$bkout" | jq -e '.session.dedup.adj_dup == 0' >/dev/null 2>&1 \
   && printf '%s' "$bkout" | "$S/cost.sh" 2>/dev/null | jq -e \
     '[.caveats[] | select(test("byte-identical usage"))] | length == 0' >/dev/null 2>&1
then ok; else bad "the duplicate cross-check fired on a correctly collapsed transcript"; fi
# Absent on meter JSON written before the check existed: unmeasured, silent.
if printf '%s' "$pcout" | jq 'del(.session.dedup.adj_dup_share)' \
     | "$S/cost.sh" 2>/dev/null | jq -e \
     '[.caveats[] | select(test("byte-identical usage"))] | length == 0' >/dev/null 2>&1
then ok; else bad "cost warned about adjacent duplicates on meter JSON that never measured them"; fi
rm -rf "$DROOT"

# 6. Ledger provenance: a row records HOW it was counted, so a re-metering
# repair can find the rows it applies to and trend can tell a measurement fix
# apart from a change in behavior. Before this, an inflated row and a corrected
# one were byte-identical on disk.
LROOT="$(mktemp -d "$TMP/lastcall-prov.XXXXXX")"
LJ="$LROOT/ledger.jsonl"
mrow() {  # mrow <session-id> <meter_version-json> <rid-cov-json> <mid-cov-json>
  jq -cn --arg s "$1" --argjson v "$2" --argjson r "$3" --argjson d "$4" \
    '{schema: "lastcall.ledger/1", session_id: $s, metered_at: "2026-08-19T09:00:00Z",
      cwd: "/tmp/p", branch: "main", started: "2026-08-19T09:00:00Z",
      ended: "2026-08-19T10:00:00Z", active_s: 3600, agent_s: 1800,
      cost: {usd: 1, by_model: [], pricing_source: "t", promo_applied: false,
             promo_models: [], by_skill: [], caveats: []},
      tokens: [], work: {tool_calls: 1, files_changed: 1, commits: []},
      friction: {tool_errors: 0, interrupts: 0, denials: 0}, evidence: null}
     | if $v == null then . else . + {meter_version: $v} end
     | if $r == null then . else . + {dedup: {rid_coverage: $r, mid_coverage: $d}} end'
}
# Legacy rows plus a first-party row: versions span, but the fix moved
# first-party totals by zero, so a note here would be a permanent false alarm.
{ mrow s1 null null null; mrow s2 null null null; mrow s3 2 1 1; } > "$LJ"
if LASTCALL_LEDGER="$LJ" "$S/ledger.sh" trend | jq -e '
      .meter_regimes.unversioned == 2
      and (.meter_regimes.envelopes == ["requestId"])
      and (.meter_regimes.note == null)' >/dev/null 2>&1
then ok; else bad "trend flagged a metering span on a ledger the fix could not have moved"; fi
# Same span, but a Bedrock-envelope row present: the legacy rows are the ones
# that fix corrected ~2x, so say so.
{ mrow s1 null null null; mrow s2 null null null; mrow s3 2 0 1; } > "$LJ"
if LASTCALL_LEDGER="$LJ" "$S/ledger.sh" trend | jq -e '
      (.meter_regimes.envelopes == ["message.id"])
      and (.meter_regimes.note | test("re-metered"))
      and (.meter_regimes.note | test("inferred"))' >/dev/null 2>&1
then ok; else bad "trend stayed silent on a metering span with Bedrock-envelope rows"; fi
# A ledger written entirely by one meter version has no span to report.
{ mrow s1 2 1 1; mrow s2 2 1 1; } > "$LJ"
if LASTCALL_LEDGER="$LJ" "$S/ledger.sh" trend | jq -e '
      .meter_regimes.unversioned == 0 and (.meter_regimes.note == null)' >/dev/null 2>&1
then ok; else bad "trend reported a metering span on a single-version ledger"; fi

# 3d-bis. Window overlap. Session windows in one workspace are NOT disjoint:
# a session left open across a break, a /clear that mints a new id while the
# earlier window stays open, or an ended that is only the last transcript
# entry all yield a long window CONTAINING shorter ones. The evidence producer
# assigns a bead to every session whose window holds its transition, so the
# enveloping session claims the work of every session nested inside it and
# divides its own cost by an inflated count -- which surfaces as apparent
# efficiency, the cheapest rows being the most inflated. trend cannot fix the
# assignment, but it must not average those rows into a baseline silently.
orow() { # sid t0 t1 cwd usd completed
  jq -cn --arg s "$1" --arg t0 "$2" --arg t1 "$3" --arg c "$4" \
         --argjson u "$5" --argjson n "$6" \
    '{schema: "lastcall.ledger/1", session_id: $s, cwd: $c, branch: "main",
      started: (if $t0 == "" then null else $t0 end), ended: $t1,
      active_s: 3600, meter_version: 2,
      dedup: {rid_coverage: 1, mid_coverage: 1},
      cost: {usd: $u, by_model: [], pricing_source: "t", promo_applied: false,
             promo_models: [], by_skill: [], caveats: []},
      tokens: [], work: {tool_calls: 10, files_changed: 1, commits: []},
      friction: {tool_errors: 0, interrupts: 0, denials: 0},
      evidence: {sources: ["beads"], completed: $n, partial: 0, blocked: 0,
                 abandoned: 0, unverified: 0}}'
}
LROOT2="$(mktemp -d)"; LJ2="$LROOT2/led"
# env envelopes a and b; far is disjoint; oth overlaps in TIME but sits in a
# different workspace, so it reads a different bead database and cannot be
# claiming the same task.
{ orow env "2026-08-01T00:00:00Z" "2026-08-01T20:00:00Z" /repo  30 31
  orow a   "2026-08-01T02:00:00Z" "2026-08-01T04:00:00Z" /repo   4  4
  orow b   "2026-08-01T06:00:00Z" "2026-08-01T08:00:00Z" /repo   6  3
  orow far "2026-08-05T00:00:00Z" "2026-08-05T01:00:00Z" /repo   5  2
  orow oth "2026-08-01T03:00:00Z" "2026-08-01T05:00:00Z" /other  7  2
} > "$LJ2"
if LASTCALL_LEDGER="$LJ2" "$S/ledger.sh" trend | jq -e '
      ([.window_overlaps[].session_id] | sort == ["a","b","env"])
      and ((.window_overlaps[] | select(.session_id == "env") | .overlaps | sort)
           == ["a","b"])' >/dev/null 2>&1
then ok; else bad "trend did not report the enveloping and nested sessions as overlapping"; fi
# The different-workspace row must NOT be flagged, and must still count.
if LASTCALL_LEDGER="$LJ2" "$S/ledger.sh" trend | jq -e '
      ([.window_overlaps[].session_id] | index("oth")) == null' >/dev/null 2>&1
then ok; else bad "trend flagged an overlap across two different workspaces"; fi
# Overlapped rows are EXCLUDED from the per-task medians, the same way rows
# without evidence already are. Only far and oth survive here.
if LASTCALL_LEDGER="$LJ2" "$S/ledger.sh" trend | jq -e '
      .per_task.usd_median == 2.5
      and (.per_task_basis | test("2 row\\(s\\) with a grounded completion and a window no other session overlaps"))
      and (.per_task_basis | test("3 excluded for overlapping"))' >/dev/null 2>&1
then ok; else bad "trend averaged window-overlapped rows into the per-task median"; fi
# The envelope divides 30 USD by 31 claimed tasks, so leaving it in would drag
# the median toward 0.97 -- the double-count showing up as apparent efficiency.
if LASTCALL_LEDGER="$LJ2" "$S/ledger.sh" trend | jq -e '
      .per_task.usd_median > 1' >/dev/null 2>&1
then ok; else bad "the inflated enveloping row reached the per-task median"; fi
# Focus on the envelope carries the caveat, so a reader cannot take its
# per-task figure at face value.
if LASTCALL_LEDGER="$LJ2" "$S/ledger.sh" trend env | jq -e '
      (.focus.window_overlap | sort == ["a","b"])
      and (.focus.per_task_basis | test("WINDOW OVERLAP"))' >/dev/null 2>&1
then ok; else bad "focus on an enveloping session reported its per-task figure with no caveat"; fi
# A ledger whose windows are all disjoint reports none, and excludes none.
{ orow p "2026-08-01T00:00:00Z" "2026-08-01T01:00:00Z" /repo 4 2
  orow q "2026-08-02T00:00:00Z" "2026-08-02T01:00:00Z" /repo 6 2
} > "$LJ2"
if LASTCALL_LEDGER="$LJ2" "$S/ledger.sh" trend | jq -e '
      .window_overlaps == [] and (.per_task_basis | test("0 excluded for overlapping"))
      and .per_task != null' >/dev/null 2>&1
then ok; else bad "trend reported an overlap on a ledger with disjoint windows"; fi
# An unreadable window is UNKNOWN overlap, not disjoint: null rather than [],
# and excluded from the medians rather than trusted into them.
{ orow n ""                     "2026-08-01T01:00:00Z" /repo 4 2
  orow q "2026-08-02T00:00:00Z" "2026-08-02T01:00:00Z" /repo 6 2
} > "$LJ2"
if LASTCALL_LEDGER="$LJ2" "$S/ledger.sh" trend n | jq -e '
      .focus.window_overlap == null
      and (.focus.per_task_basis | test("unknown"))' >/dev/null 2>&1
then ok; else bad "a row with an unreadable window did not report its overlap as unknown"; fi
if LASTCALL_LEDGER="$LJ2" "$S/ledger.sh" trend | jq -e '
      .per_task_basis | test("1 excluded for an unreadable window")' >/dev/null 2>&1
then ok; else bad "a row with an unreadable window was counted as having a disjoint one"; fi

# 3d-quater. Overlap is tested against ACTIVITY, not the bare window. A session
# left open across a break has a window covering the whole break and no
# activity in it; a window test calls that an overlap and discards a row that
# was never in conflict. Measured across 60 local transcripts, windows of 409h
# and 313h carry near-zero activity, so this is the common case, not an edge.
srow() { # sid t0 t1 cwd usd completed  spans-as-ISO-pairs-JSON
  jq -cn --arg s "$1" --arg t0 "$2" --arg t1 "$3" --arg c "$4" \
         --argjson u "$5" --argjson n "$6" --argjson sp "$7" '
    def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    {schema: "lastcall.ledger/1", session_id: $s, cwd: $c, branch: "main",
     started: $t0, ended: $t1, active_s: 3600, meter_version: 2,
     dedup: {rid_coverage: 1, mid_coverage: 1},
     spans: (if $sp == null then null else [$sp[] | [(.[0]|ts), (.[1]|ts)]] end),
     cost: {usd: $u, by_model: [], pricing_source: "t", promo_applied: false,
            promo_models: [], by_skill: [], caveats: []},
     tokens: [], work: {tool_calls: 10, files_changed: 1, commits: []},
     friction: {tool_errors: 0, interrupts: 0, denials: 0},
     evidence: {sources: ["beads"], completed: $n, partial: 0, blocked: 0,
                abandoned: 0, unverified: 0}}'
}
LROOT4="$(mktemp -d)"; LJ4="$LROOT4/led"
# env holds a 20h window but only WORKS in the first and last hour. a and b run
# inside the idle gap and are not in conflict with it; c genuinely works at the
# same time as the second span and IS.
ENVSP='[["2026-08-01T00:00:00Z","2026-08-01T01:00:00Z"],["2026-08-01T19:00:00Z","2026-08-01T20:00:00Z"]]'
{ srow env "2026-08-01T00:00:00Z" "2026-08-01T20:00:00Z" /w1 30 6 "$ENVSP"
  srow a   "2026-08-01T02:00:00Z" "2026-08-01T04:00:00Z" /w1  4 4 '[["2026-08-01T02:00:00Z","2026-08-01T04:00:00Z"]]'
  srow b   "2026-08-01T06:00:00Z" "2026-08-01T08:00:00Z" /w1  6 3 '[["2026-08-01T06:00:00Z","2026-08-01T08:00:00Z"]]'
  srow c   "2026-08-01T19:30:00Z" "2026-08-01T19:45:00Z" /w1  5 2 '[["2026-08-01T19:30:00Z","2026-08-01T19:45:00Z"]]'
} > "$LJ4"
if LASTCALL_LEDGER="$LJ4" "$S/ledger.sh" trend | jq -e '
      ([.window_overlaps[].session_id] | sort == ["c","env"])
      and ((.window_overlaps[] | select(.session_id == "env") | .overlaps) == ["c"])' >/dev/null 2>&1
then ok; else bad "sessions running inside an idle window were still reported as overlapping"; fi
# The two rows that were never in conflict are returned to the per-task median.
if LASTCALL_LEDGER="$LJ4" "$S/ledger.sh" trend | jq -e '
      .per_task.rows == 2' >/dev/null 2>&1
then ok; else bad "rows working inside an idle envelope were excluded from the per-task median"; fi
# And a genuinely concurrent session is still caught -- the tighter test must
# not simply stop reporting overlaps.
if LASTCALL_LEDGER="$LJ4" "$S/ledger.sh" trend c | jq -e '
      .focus.window_overlap == ["env"]' >/dev/null 2>&1
then ok; else bad "a genuinely concurrent session was no longer reported as overlapping"; fi
# Rows predating spans fall back to the WINDOW, which is a superset of the
# activity -- so the fallback can only over-report, never under-report. All
# four are flagged here, which is the pre-span answer.
jq -c 'del(.spans)' "$LJ4" > "$LJ4.n" && mv "$LJ4.n" "$LJ4.none"
if LASTCALL_LEDGER="$LJ4.none" "$S/ledger.sh" trend | jq -e '
      ([.window_overlaps[].session_id] | sort == ["a","b","c","env"])
      and (.per_task == null)' >/dev/null 2>&1
then ok; else bad "a ledger with no spans did not fall back to the window overlap test"; fi
# The basis says WHICH test produced the answer, so two ledgers can be compared.
if LASTCALL_LEDGER="$LJ4.none" "$S/ledger.sh" trend a | jq -e '
      .focus.window_overlap == ["env"]' >/dev/null 2>&1
then ok; else bad "a span-less row did not fall back to the window for its own overlap"; fi
# MIXED: the fallback is per PAIR, not per ledger. a has no spans, so env-a
# falls back and is flagged, while env-b still uses spans and is not.
jq -c 'if .session_id == "a" then del(.spans) else . end' "$LJ4" > "$LJ4.m"
if LASTCALL_LEDGER="$LJ4.m" "$S/ledger.sh" trend | jq -e '
      ((.window_overlaps[] | select(.session_id == "env") | .overlaps | sort) == ["a","c"])' >/dev/null 2>&1
then ok; else bad "a mixed ledger did not fall back per pair"; fi
rm -rf "$LROOT4"

rm -rf "$LROOT2"

# 3d-ter. The DENOMINATOR has to be grounded work. evidence_for computes
# unverified -- a completed task carrying no artifact -- and the comment beside
# it has always said such a task is "not counted", but completed counts it and
# every per-task ratio divided by completed, so the promise was never kept.
#
# It matters because the two denominator inflations bias the SAME way: the
# window overlap filled it with other sessions beads, and removing that only
# concentrates the ungrounded ones. The signature is a session that closes a
# batch of beads at the end with no commit naming any of them.
#
# Nothing here asserted this before, so per_task could ignore unverified
# entirely and stay green. These fixtures close that.
grow() { # sid t0 t1 cwd usd active_min completed unverified
  jq -cn --arg s "$1" --arg t0 "$2" --arg t1 "$3" --arg c "$4" \
         --argjson u "$5" --argjson am "$6" --argjson n "$7" --argjson v "$8" \
    '{schema: "lastcall.ledger/1", session_id: $s, cwd: $c, branch: "main",
      started: $t0, ended: $t1, active_s: ($am * 60), meter_version: 2,
      dedup: {rid_coverage: 1, mid_coverage: 1},
      cost: {usd: $u, by_model: [], pricing_source: "t", promo_applied: false,
             promo_models: [], by_skill: [], caveats: []},
      tokens: [], work: {tool_calls: 10, files_changed: 1, commits: []},
      friction: {tool_errors: 0, interrupts: 0, denials: 0},
      evidence: {sources: ["beads"], completed: $n, partial: 0, blocked: 0,
                 abandoned: 0, unverified: $v}}'
}
LROOT3="$(mktemp -d)"; LJ3="$LROOT3/led"
# Disjoint windows in one workspace, so the overlap filter excludes nothing and
# grounding is the only thing under test. Ratios: 4.48/1, 54.12/3, 41.14/3
# -> 4.48, 18.04, 13.71, median 13.71. Dividing by completed instead gives
# 0.75, 1.93, 5.88, median 1.93 -- a 7.1x difference, so the assertion cannot
# pass by accident.
{ grow a "2026-08-01T00:00:00Z" "2026-08-01T01:00:00Z" /w1  4.48  22  6  5
  grow b "2026-08-02T00:00:00Z" "2026-08-02T02:00:00Z" /w1 54.12 109 28 25
  grow c "2026-08-03T00:00:00Z" "2026-08-03T02:00:00Z" /w1 41.14  82  7  4
} > "$LJ3"
if LASTCALL_LEDGER="$LJ3" "$S/ledger.sh" trend | jq -e '
      .per_task.usd_median == 13.71
      and .per_task.usd_median_counting_unverified == 1.93' >/dev/null 2>&1
then ok; else bad "per_task divided by every completion instead of the grounded ones"; fi
# Both bounds are published. Neither denominator is the truth -- dividing by
# completed treats an unverifiable completion as confirmed, dividing by
# grounded charges the whole session to the subset that can be pointed at --
# so folding the unknown into either one silently is the thing section 3
# forbids. rows names the population, because with_evidence counts a
# different one and sits close enough to be misread as this one.
if LASTCALL_LEDGER="$LJ3" "$S/ledger.sh" trend | jq -e '
      .per_task.rows == 3 and (.per_task.denominator | test("grounded"))
      and (.per_task_basis | test("34 of 41 completions in these rows excluded as unverified"))' >/dev/null 2>&1
then ok; else bad "trend did not disclose the grounded denominator or the excluded completions"; fi
# A row where every completion is ungrounded is EXCLUDED, never divided by
# zero: jq aborts the whole program on a zero denominator, which would cost
# the entire trend over one unusable row.
{ grow a "2026-08-01T00:00:00Z" "2026-08-01T01:00:00Z" /w1 4.48 22 6 5
  grow z "2026-08-04T00:00:00Z" "2026-08-04T01:00:00Z" /w1 9.00 30 4 4
} > "$LJ3"
if LASTCALL_LEDGER="$LJ3" "$S/ledger.sh" trend | jq -e '
      .per_task.rows == 1 and .per_task.usd_median == 4.48
      and (.per_task_basis | test("1 excluded for no grounded completion"))' >/dev/null 2>&1
then ok; else bad "a row with no grounded completion was not excluded from the per-task median"; fi
if LASTCALL_LEDGER="$LJ3" "$S/ledger.sh" trend z | jq -e '
      .focus.per_task_usd == null
      and (.focus.per_task_basis | test("NONE of them grounded"))' >/dev/null 2>&1
then ok; else bad "focus on a row with no grounded completion reported a per-task figure anyway"; fi
# The focus figure uses the SAME denominator as the medians, or the two are
# not comparable, and it says how many it dropped.
{ grow b "2026-08-02T00:00:00Z" "2026-08-02T02:00:00Z" /w1 54.12 109 28 25; } > "$LJ3"
if LASTCALL_LEDGER="$LJ3" "$S/ledger.sh" trend b | jq -e '
      .focus.per_task_usd == 18.04
      and .focus.per_task_usd_counting_unverified == 1.93
      and (.focus.per_task_basis | test("25 of them unverified"))' >/dev/null 2>&1
then ok; else bad "focus per-task figure did not use the grounded denominator"; fi
# A row that never recorded a grounding count is UNKNOWN, not fully grounded.
# jq aborts on number-minus-null, so this also pins that trend survives it.
{ grow a "2026-08-01T00:00:00Z" "2026-08-01T01:00:00Z" /w1 4.48 22 6 5
  grow u "2026-08-05T00:00:00Z" "2026-08-05T01:00:00Z" /w1 8.00 20 4 0
} > "$LJ3"
jq -c 'if .session_id == "u" then .evidence |= del(.unverified) else . end' "$LJ3" > "$LJ3.x" && mv "$LJ3.x" "$LJ3"
if LASTCALL_LEDGER="$LJ3" "$S/ledger.sh" trend | jq -e '
      .per_task.rows == 1
      and (.per_task_basis | test("1 excluded for an unreadable grounding count"))' >/dev/null 2>&1
then ok; else bad "a row with no recorded grounding count was treated as fully grounded"; fi
rm -rf "$LROOT3"
rm -rf "$LROOT"

# 3e. Commit discovery and the match keys. lastcall offers its commit
# delegation only when the tree is dirty, so a session whose commits were made
# by another skill passed ZERO SHAs to the producer and earned zero grounding —
# the matcher never ran a comparison at all. Discovery from the metered window
# closes that. Each match carries the key that earned it, because a commit that
# names the bead and one that merely shares its time range are not equally
# strong evidence and a reader has to be able to tell them apart.
#
# Needs a real bd and a real git repo; both are skipped rather than failed when
# bd is absent, the same way the producer itself treats a missing bd.
if command -v bd >/dev/null 2>&1; then
  GROOT="$(mktemp -d "$TMP/lastcall-commits.XXXXXX")"
  gid() { grep -oE 'vx-[a-z0-9.]+' | head -1; }
  (
    cd "$GROOT" || exit 1
    git init -q . && git config user.email v@v.test && git config user.name V
    bd init --prefix vx >/dev/null 2>&1 || exit 1
    A="$(bd create --title="A" --description=d --type=task --priority=2 2>&1 | gid)"
    B="$(bd create --title="B" --description=d --type=task --priority=2 \
           --external-ref="ONC-5" 2>&1 | gid)"
    C="$(bd create --title="C" --description=d --type=task --priority=2 2>&1 | gid)"
    D="$(bd create --title="D" --description=d --type=task --priority=2 2>&1 | gid)"
    [ -n "$A" ] && [ -n "$B" ] && [ -n "$C" ] && [ -n "$D" ] || exit 1
    printf '%s %s %s %s\n' "$A" "$B" "$C" "$D" > ids

    # Dated well before C becomes active, so they land in the SESSION window
    # without falling inside the bead own range. That is what keeps the window
    # key from silently passing on commits an exact key already claimed.
    early="$(date -u -r $(( $(date +%s) - 1800 )) +%Y-%m-%dT%H:%M:%SZ)"
    echo a > f; git add f
    GIT_COMMITTER_DATE="$early" git commit -q --date="$early" -m "fix: a. Closes $A"
    echo b > f
    GIT_COMMITTER_DATE="$early" git commit -qa --date="$early" -m "feat(ONC-5): b"
    echo c > f
    GIT_COMMITTER_DATE="$early" git commit -qa --date="$early" -m "docs: names nothing"

    # C is the window case: commit stamped exactly at started_at, which the
    # inclusive bound accepts, and closed afterwards. Reading started_at back
    # from bd rather than guessing a clock keeps this deterministic.
    bd update "$C" --status in_progress >/dev/null 2>&1
    cs="$(bd list --all --limit 0 --json --skip-labels 2>/dev/null \
          | jq -r --arg c "$C" '(if type == "object" then (.issues // []) else . end)
                                | map(select(.id == $c))[0].started_at // empty')"
    [ -n "$cs" ] || exit 1
    echo d > f
    GIT_COMMITTER_DATE="$cs" git commit -qa --date="$cs" -m "chore: inside the C range"
    bd close "$A" "$B" "$C" "$D" >/dev/null 2>&1
  )
  if [ -s "$GROOT/ids" ]; then
    read -r fA fB fC fD < "$GROOT/ids"
    gt0="$(date -u -r $(( $(date +%s) - 3600 )) +%Y-%m-%dT%H:%M:%SZ)"
    gt1="$(date -u -r $(( $(date +%s) + 3600 )) +%Y-%m-%dT%H:%M:%SZ)"
    gmeter="$(jq -cn --arg cwd "$GROOT" --arg t0 "$gt0" --arg t1 "$gt1" \
      '{session: {id: "fixture-commit-keys", cwd: $cwd, branch: "main",
                  started: $t0, ended: $t1, active_s: 1},
        tokens: [], agents: [], work: {tools: {}, files: {}, skills: []},
        friction: {tool_errors: 0, interrupts: 0, denials: 0}, evidence: []}')"
    GEV="$GROOT/evidence"
    gout="$(printf '%s' "$gmeter" \
            | LASTCALL_EVIDENCE_DIR="$GEV" "$S/emit-evidence-beads.sh" 2>/dev/null)"
    if [ -s "$gout" ] && jq -e --arg a "$fA" --arg b "$fB" --arg c "$fC" --arg d "$fD" '
          (.tasks | map({key: .id, value: .artifact_matches}) | from_entries) as $m
          | ([$m[$a][].key] == ["id"])
            and ([$m[$b][].key] == ["tracker"])
            and ([$m[$c][].key] == ["window"])
            and (($m[$d] | length) == 0)' "$gout" >/dev/null 2>&1
    then ok; else bad "commit discovery did not label the id/tracker/window keys"; fi
    # Zero SHAs passed is the whole point: the bug was that argv was the only
    # source. Grounding must appear without the caller handing anything over.
    if [ -s "$gout" ] && jq -e '[.tasks[].artifacts[]] | length >= 3' "$gout" >/dev/null 2>&1
    then ok; else bad "commit discovery found no artifacts with zero SHAs passed"; fi
    # And turning discovery off must return the old behavior exactly.
    goff="$(printf '%s' "$gmeter" | LASTCALL_EVIDENCE_DIR="$GEV.off" \
            LASTCALL_COMMIT_DISCOVERY=0 "$S/emit-evidence-beads.sh" 2>/dev/null)"
    if [ -s "$goff" ] && jq -e '[.tasks[].artifacts[]] | length == 0' "$goff" >/dev/null 2>&1
    then ok; else bad "LASTCALL_COMMIT_DISCOVERY=0 still discovered commits"; fi
    # ledger work.commits rides on the same window, and a full SHA passed by the
    # caller must not survive dedupe beside the short one the query returns.
    gfull="$(git -C "$GROOT" log --format=%H -1)"
    gshort="$(git -C "$GROOT" rev-parse --short "$gfull")"
    # Count is >= the four commits made here rather than exact: bd init writes a
    # commit of its own, and pinning that would test bd rather than discovery.
    if printf '%s' "$gmeter" | LASTCALL_LEDGER="$GROOT/led" "$S/ledger.sh" append \
         "$gfull" >/dev/null 2>&1 \
       && jq -e --arg s "$gshort" '(.work.commits | length) >= 4
                 and (.work.commits | length) == (.work.commits | unique | length)
                 and ([.work.commits[] | select(. == $s)] | length) == 1' \
            "$GROOT/led" >/dev/null 2>&1
    then ok; else bad "ledger did not discover or dedupe the session commits"; fi

    # THE BACKFILL PATH. emit-evidence-beads.sh has one call site, in the skill;
    # nothing inside ledger.sh writes the drop-box, it only reads it. So a row
    # produced by a direct `ledger.sh append` repair carries evidence: null
    # forever, and re-metering never fixes it — the external report arrived with
    # 13 of 14 rows in that state from a single repair pass, which is why
    # with_evidence read 0. The capability was already promised in contracts.md;
    # only the recipe was missing. This pins the recipe the README now carries.
    #
    # First half: reproduce the failure. Same meter, empty drop-box, null row.
    # The SESSION JOIN tier. A bead whose transition lands inside real session
    # activity is a much stronger claim than one that merely falls between the
    # first and last timestamp -- the window is a loose proxy, and windows of
    # 409h carrying near-zero activity are real measurements here.
    gnow="$(date +%s)"
    gspan_all="[[$(( gnow - 3600 )), $(( gnow + 3600 ))]]"
    gspan_none="[[$(( gnow - 3600 )), $(( gnow - 3500 ))]]"
    gm_span="$(printf '%s' "$gmeter" | jq -c --argjson sp "$gspan_all"  '.session.spans = $sp')"
    gm_win="$(printf  '%s' "$gmeter" | jq -c --argjson sp "$gspan_none" '.session.spans = $sp')"
    gs1="$(printf '%s' "$gm_span" | LASTCALL_EVIDENCE_DIR="$GROOT/ev-span" \
             "$S/emit-evidence-beads.sh" 2>/dev/null)"
    if [ -n "$gs1" ] && jq -e '[.tasks[].session_join] | length > 0 and all(. == "span")' \
         "$gs1" >/dev/null 2>&1
    then ok; else bad "producer did not report a span join for beads closed inside session activity"; fi
    # A transition in the window but in NO span is still emitted, tagged with
    # the weaker tier. Dropping it would turn an over-claim into a silent
    # UNDER-claim: a bead closed during an idle gap, or from a plain CLI, would
    # be claimed by nobody at all.
    gs2="$(printf '%s' "$gm_win" | LASTCALL_EVIDENCE_DIR="$GROOT/ev-win" \
             "$S/emit-evidence-beads.sh" 2>/dev/null)"
    if [ -n "$gs2" ] && jq -e '[.tasks[].session_join] | length > 0 and all(. == "window")' \
         "$gs2" >/dev/null 2>&1
    then ok; else bad "producer dropped or mis-tiered a bead that fell outside every activity span"; fi
    # Same task set either way -- the tier changes, the population does not.
    if [ -n "$gs1" ] && [ -n "$gs2" ] \
       && [ "$(jq -c '[.tasks[].id] | sort' "$gs1")" = "$(jq -c '[.tasks[].id] | sort' "$gs2")" ]
    then ok; else bad "the span tier changed which beads were emitted, not just how they were joined"; fi
    # A meter with no spans at all degrades to the weaker tier rather than
    # claiming a strength it cannot support.
    gs3="$(printf '%s' "$gmeter" | LASTCALL_EVIDENCE_DIR="$GROOT/ev-nospan" \
             "$S/emit-evidence-beads.sh" 2>/dev/null)"
    if [ -n "$gs3" ] && jq -e '[.tasks[].session_join] | all(. == "window")' \
         "$gs3" >/dev/null 2>&1
    then ok; else bad "producer claimed a span join on a meter that recorded no spans"; fi

    GBF="$GROOT/backfill"
    if printf '%s' "$gmeter" | LASTCALL_LEDGER="$GBF/led" LASTCALL_EVIDENCE_DIR="$GBF/ev" \
         "$S/ledger.sh" append >/dev/null 2>&1 \
       && jq -e '.evidence == null' "$GBF/led" >/dev/null 2>&1
    then ok; else bad "append with an empty drop-box did not record evidence as null"; fi
    # Second half: run the producer into that same drop-box and append again.
    # The row must GAIN evidence and be replaced, not duplicated — the repair is
    # keyed on session_id, so a second row would split the session in trend.
    if printf '%s' "$gmeter" | LASTCALL_EVIDENCE_DIR="$GBF/ev" \
         "$S/emit-evidence-beads.sh" >/dev/null 2>&1 \
       && printf '%s' "$gmeter" | LASTCALL_LEDGER="$GBF/led" LASTCALL_EVIDENCE_DIR="$GBF/ev" \
            "$S/ledger.sh" append >/dev/null 2>&1 \
       && [ "$(jq -s length "$GBF/led")" = "1" ] \
       && jq -e '.evidence != null and .evidence.completed == 4
                 and (.evidence.sources == ["beads"])' "$GBF/led" >/dev/null 2>&1
    then ok; else bad "backfill recipe did not re-derive evidence for an existing row"; fi
    # And the row is now countable in trend, which is the whole point: the
    # baseline excludes rows without evidence, so a null row is invisible there.
    if [ "$(LASTCALL_LEDGER="$GBF/led" "$S/ledger.sh" trend | jq -r '.with_evidence')" = "1" ]
    then ok; else bad "backfilled row still did not count toward with_evidence"; fi

    # THE EMPTY-PRODUCER MARKER. A producer that ran and matched nothing used
    # to be indistinguishable from no producer at all: both reached the ledger
    # as evidence: null and both showed per_task: null. Same fixture workspace,
    # same beads, but a session window in 2019 that no bead can fall inside.
    GMK="$GROOT/marker"
    mkmeter="$(printf '%s' "$gmeter" | jq -c '.session.id = "fixture-marker"
      | .session.started = "2019-01-01T00:00:00Z"
      | .session.ended   = "2019-01-02T00:00:00Z"')"
    mkout="$(printf '%s' "$mkmeter" | LASTCALL_EVIDENCE_DIR="$GMK/ev" \
             "$S/emit-evidence-beads.sh" 2>/dev/null)"
    if [ -s "$mkout" ] && jq -e '.schema == "lastcall.evidence/1"
          and .source == "beads" and (.tasks | length) == 0' "$mkout" >/dev/null 2>&1
    then ok; else bad "producer matched no beads and wrote no marker file"; fi
    # The marker must reach the ledger as an ASSESSED zero, not as absence.
    if printf '%s' "$mkmeter" | LASTCALL_LEDGER="$GMK/led" LASTCALL_EVIDENCE_DIR="$GMK/ev" \
         "$S/ledger.sh" append >/dev/null 2>&1 \
       && jq -e '.evidence != null and .evidence.completed == 0
                 and (.evidence.sources == ["beads"])' "$GMK/led" >/dev/null 2>&1
    then ok; else bad "empty marker did not record as assessed-zero evidence"; fi
    # And it must not buy its way into the per-task ratios: completed is 0, so
    # the row stays out of with_evidence while still explaining the null.
    mktrend="$(LASTCALL_LEDGER="$GMK/led" "$S/ledger.sh" trend "fixture-marker")"
    if [ "$(printf '%s' "$mktrend" | jq -r '.with_evidence')" = "0" ] \
       && [ "$(printf '%s' "$mktrend" | jq -r '.per_task')" = "null" ] \
       && printf '%s' "$mktrend" | jq -e '(.per_task_basis | test("a producer ran and matched none"))
             and (.focus.per_task_basis | test("^assessed by beads"))' >/dev/null 2>&1
    then ok; else bad "trend did not distinguish an assessed zero from an unassessed row"; fi
    # The other half of the split: no producer at all still reads as absent.
    if printf '%s' "$mkmeter" | LASTCALL_LEDGER="$GMK/led2" LASTCALL_EVIDENCE_DIR="$GMK/none" \
         "$S/ledger.sh" append >/dev/null 2>&1 \
       && LASTCALL_LEDGER="$GMK/led2" "$S/ledger.sh" trend "fixture-marker" \
          | jq -e '.focus.per_task_basis | test("^not assessed")' >/dev/null 2>&1
    then ok; else bad "a row with no producer did not report itself as not assessed"; fi
  else
    say "  commit-discovery fixture skipped (bd workspace not created)"
  fi
  rm -rf "$GROOT"

# ---- cross-row: no bead may be claimed by two sessions -------------------
# Every check above this line is WITHIN one row or one file, and that is
# exactly how the window-overlap defect survived a green suite: each evidence
# file was internally valid and correctly derived, and the defect existed only
# in the relationship BETWEEN files. Disjointness of claimed beads is a
# cross-row property, so nothing here could see it.
#
# Scoped to a single drop-box rather than by workspace, because evidence files
# carry session_id and NOT cwd. Bead ids are workspace-prefixed in practice, so
# a cross-workspace collision would be a genuine finding too.
crossrow_dupes() { # <evidence-dir> -> "<bead-id> <sid>,<sid>" per shared bead
  local dir="$1" files
  [ -d "$dir" ] || return 0
  files="$(/usr/bin/find "$dir" -name '*.json' 2>/dev/null)"
  [ -n "$files" ] || return 0
  # shellcheck disable=SC2086
  jq -s -r '
    [ .[] | .session_id as $s | (.tasks // [])[] | {id: .id, sid: $s} ]
    | group_by(.id)
    | map(select((map(.sid) | unique | length) > 1))
    | .[] | "\(.[0].id) \(map(.sid) | unique | join(","))"' $files 2>/dev/null
}
# The check must be able to FAIL, or it asserts nothing. Plant the defect.
XR="$(mktemp -d "$TMP/lastcall-crossrow.XXXXXX")"
mkdir -p "$XR/sess-one" "$XR/sess-two"
jq -cn '{schema:"lastcall.evidence/1", source:"beads", session_id:"sess-one",
         emitted_at:"2026-08-01T00:00:00Z",
         tasks:[{id:"shared-bead-1", title:"t", status:"completed", artifacts:[]},
                {id:"only-in-one",   title:"t", status:"completed", artifacts:[]}]}'   > "$XR/sess-one/beads.json"
jq -cn '{schema:"lastcall.evidence/1", source:"beads", session_id:"sess-two",
         emitted_at:"2026-08-01T01:00:00Z",
         tasks:[{id:"shared-bead-1", title:"t", status:"completed", artifacts:[]}]}'   > "$XR/sess-two/beads.json"
xr_out="$(crossrow_dupes "$XR")"
if printf '%s' "$xr_out" | grep -q '^shared-bead-1 '    && printf '%s' "$xr_out" | grep -q 'sess-one'    && printf '%s' "$xr_out" | grep -q 'sess-two'    && [ "$(printf '%s\n' "$xr_out" | grep -c .)" = "1" ]
then ok; else bad "cross-row check did not catch a bead claimed by two sessions"; fi
rm -rf "$XR"
# And the real drop-box must be clean. This is the assertion that would have
# caught the defect the first time two rows carried evidence.
real_dupes="$(crossrow_dupes "${LASTCALL_EVIDENCE_DIR:-$HOME/.claude/lastcall/evidence}")"
if [ -z "$real_dupes" ]; then ok
else bad "a bead is claimed by more than one session: $(printf '%s' "$real_dupes" | tr '\n' ';')"; fi
fi

# 3f. An in_progress bead whose started_at is absent. bd omits that key
# entirely from most rows — 46 of 85 in the lastcall workspace, measured
# 2026-08-24 — and jq returns null for a missing key, so the window select used
# to drop the bead outright: a claimed-but-unfinished task could never be
# reported as partial, and the evidence file looked complete without it. Closed
# beads were never affected, because they read closed_at instead. The fallback
# is updated_at, which also supplies the range start the window key needs.
#
# bd import is the only way to build the row, since bd update --status
# in_progress stamps started_at itself. Skipped, not failed, when bd is absent.
if command -v bd >/dev/null 2>&1; then
  VROOT="$(mktemp -d "$TMP/lastcall-nostart.XXXXXX")"
  (
    cd "$VROOT" || exit 1
    git init -q . && git config user.email v@v.test && git config user.name V
    bd init --prefix vy >/dev/null 2>&1 || exit 1
    vu="$(date -u -r $(( $(date +%s) - 60 )) +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"title":"P","status":"in_progress","issue_type":"task","priority":2,"updated_at":"%s"}\n' \
      "$vu" | bd import - >/dev/null 2>&1 || exit 1
    # Read the row back rather than trust what import stored. The test only
    # means anything while started_at is genuinely absent, and the commit below
    # has to land on the timestamp bd actually kept.
    bd list --all --limit 0 --json --skip-labels 2>/dev/null \
      | jq -r '(if type == "object" then (.issues // []) else . end)
               | map(select(.status == "in_progress"))[0]
               | "\(.id) \((has("started_at")) and (.started_at != null)) \(.updated_at)"' > row
    read -r vid vhas vupd < row
    [ -n "$vid" ] && [ -n "$vupd" ] && [ "$vupd" != "null" ] || exit 1
    # Stamped exactly at updated_at, which the inclusive range bound accepts.
    echo p > f; git add f
    GIT_COMMITTER_DATE="$vupd" git commit -q --date="$vupd" -m "chore: inside the range"
  )
  if [ -s "$VROOT/row" ]; then
    read -r vid vhas vupd < "$VROOT/row"
    if [ "$vhas" = "true" ]; then
      say "  no-started_at fixture skipped (bd now stamps started_at on import)"
    else
      vt0="$(date -u -r $(( $(date +%s) - 3600 )) +%Y-%m-%dT%H:%M:%SZ)"
      vt1="$(date -u -r $(( $(date +%s) + 3600 )) +%Y-%m-%dT%H:%M:%SZ)"
      vmeter="$(jq -cn --arg cwd "$VROOT" --arg t0 "$vt0" --arg t1 "$vt1" \
        '{session: {id: "fixture-no-started-at", cwd: $cwd, branch: "main",
                    started: $t0, ended: $t1, active_s: 1},
          tokens: [], agents: [], work: {tools: {}, files: {}, skills: []},
          friction: {tool_errors: 0, interrupts: 0, denials: 0}, evidence: []}')"
      vout="$(printf '%s' "$vmeter" | LASTCALL_EVIDENCE_DIR="$VROOT/evidence" \
              "$S/emit-evidence-beads.sh" 2>/dev/null)"
      # started stays null on the way out: updated_at decides inclusion, it does
      # not get reported as a start time nobody observed.
      if [ -s "$vout" ] && jq -e --arg i "$vid" '
            (.tasks | map(select(.id == $i))) as $t
            | ($t | length) == 1
              and ($t[0].status == "partial")
              and ($t[0].started == null)' "$vout" >/dev/null 2>&1
      then ok; else bad "in_progress bead with absent started_at was dropped from the evidence file"; fi
      # The same fallback gives the bead a range start, so the window key can
      # still ground it. Only the keys are pinned, not the count: bd init writes
      # a commit of its own that falls in the same range.
      if [ -s "$vout" ] && jq -e --arg i "$vid" '
            [.tasks[] | select(.id == $i) | .artifact_matches[].key] as $k
            | ($k | length) >= 1 and ($k | all(. == "window"))' "$vout" >/dev/null 2>&1
      then ok; else bad "in_progress bead with absent started_at earned no window grounding"; fi
    fi
  else
    say "  no-started_at fixture skipped (bd workspace not created)"
  fi
  rm -rf "$VROOT"
fi

# 7. scan-skills.sh: a CRITICAL finding must not be reported as a crash
# (agent-skill-wrapup-5tb). skillspector exits non-zero for both a genuine
# crash and a CRITICAL finding, and the two used to be indistinguishable —
# the JSON report was discarded either way and both were blamed on "the
# install and provider credentials". A fake skillspector on PATH stands in
# for the real one so this is a test of scan-skills.sh's own exit-code/report
# handling, not of skillspector itself.
FAKESS="$(mktemp -d "$TMP/lastcall-fakess.XXXXXX")"
cat > "$FAKESS/skillspector" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "skillspector 0.0.0-fake"; exit 0; fi
out=""; prev=""
for a in "$@"; do [ "$prev" = "--output" ] && out="$a"; prev="$a"; done
case "${FAKE_SS_MODE:-clean}" in
  critical)
    # A real CRITICAL finding still exits non-zero, but writes a full report.
    jq -n '{risk_assessment: {score: 95, severity: "critical", recommendation: "block"},
            issues: [{id: "P4", pattern: "kill-a-person", severity: "CRITICAL",
                      finding: "kill a person", explanation: "matched span",
                      remediation: "reword",
                      location: {file: "SKILL.md", start_line: 7}}],
            suppressed: [], suppressed_count: 0}' > "$out"
    exit 1 ;;
  crash)
    # A genuine crash writes no report at all.
    exit 1 ;;
esac
FAKE
chmod +x "$FAKESS/skillspector"

RDIR="$(mktemp -d "$TMP/lastcall-ssreport.XXXXXX")"
# The finding is reported, not swallowed as a crash: the JSON report survives
# with its matched span, and stderr never claims a crash.
ss_out="$(PATH="$FAKESS:$PATH" FAKE_SS_MODE=critical REPORT_DIR="$RDIR" \
          "$HERE/bin/scan-skills.sh" tally 2>&1)"
if [ -s "$RDIR/tally.json" ] \
   && jq -e '.issues[0].finding == "kill a person"' "$RDIR/tally.json" >/dev/null 2>&1 \
   && ! printf '%s' "$ss_out" | grep -qi "crashed"
then ok; else bad "scan-skills.sh mislabeled a CRITICAL finding as a crash"; fi
rm -f "$RDIR/tally.json" "$RDIR/tally.md"

# A genuine crash — no report written at all — must still report as a crash,
# so a skill that was never assessed is never reported as passing.
ss_crash="$(PATH="$FAKESS:$PATH" FAKE_SS_MODE=crash REPORT_DIR="$RDIR" \
            "$HERE/bin/scan-skills.sh" tally 2>&1)"
if [ ! -e "$RDIR/tally.json" ] \
   && printf '%s' "$ss_crash" | grep -qi "crashed while scanning tally"
then ok; else bad "scan-skills.sh did not report a genuine crash correctly"; fi
rm -rf "$RDIR" "$FAKESS"

# 8. Two producers describing the SAME task. Latent while only one producer
# exists and guaranteed the moment a second lands, which is the configuration
# epic 626 drives toward. The old key was (source, task.id), so evidence from
# `fathom` and from `linear` both naming ONC-5 survived dedupe and reported
# completed 2 for one task — confirmed empirically before the fix, not inferred.
#
# Both readers are exercised against ONE drop-box, deliberately. The merge rule
# lives in two places (meter-session.sh emits the tasks, ledger.sh:evidence_for
# emits the counts) and they are never called together at runtime, so nothing
# else would notice them drifting apart. Here a disagreement is a failure.
MROOT="$(mktemp -d "$TMP/lastcall-merge.XXXXXX")"
MSID="merge-fixture"
mkdir -p "$MROOT/ev/$MSID" "$MROOT/work"
# a: an UNGROUNDED completed claim, emitted first, plus a task left partial.
jq -cn --arg s "$MSID" '{schema: "lastcall.evidence/1", source: "a", session_id: $s,
  emitted_at: "2026-08-25T09:00:00Z",
  tasks: [{id: "T-1", title: "claimed", status: "completed", artifacts: []},
          {id: "T-2", title: "half",    status: "partial",   artifacts: []}]}' \
  > "$MROOT/ev/$MSID/a.json"
# b: the same two tasks, later, with grounding — and one only b can see.
jq -cn --arg s "$MSID" '{schema: "lastcall.evidence/1", source: "b", session_id: $s,
  emitted_at: "2026-08-25T10:00:00Z",
  tasks: [{id: "T-1", title: "claimed", status: "completed", artifacts: ["commit:beef"]},
          {id: "T-2", title: "half",    status: "completed", artifacts: ["commit:cafe"]},
          {id: "T-3", title: "only b",  status: "blocked",   artifacts: []}]}' \
  > "$MROOT/ev/$MSID/b.json"
# c: the empty-tasks marker. It says c ran; it must retract nothing.
jq -cn --arg s "$MSID" '{schema: "lastcall.evidence/1", source: "c", session_id: $s,
  emitted_at: "2026-08-25T12:00:00Z", tasks: []}' > "$MROOT/ev/$MSID/c.json"

mev="$( cd "$MROOT/work" && CLAUDE_PROJECTS="$MROOT/none" CLAUDE_SESSION_ID="$MSID" \
        LASTCALL_EVIDENCE_DIR="$MROOT/ev" "$S/meter-session.sh" 2>/dev/null \
        | jq -c '.evidence' )"
# Three tasks, not five. T-1 carries both sources, and the newest observation
# supplies the scalar fields. T-3 is untouched by the merge.
if printf '%s' "$mev" | jq -e '
      length == 3
      and ([.[] | select(.id == "T-1")] | length) == 1
      and (.[] | select(.id == "T-1") | .sources) == ["a", "b"]
      and (.[] | select(.id == "T-1") | .source)  == "b"
      and (.[] | select(.id == "T-3") | .sources) == ["b"]' >/dev/null 2>&1
then ok; else bad "meter counted one task twice for two producers"; fi
# Artifacts UNION. T-1 is grounded by b alone, and merging is what stops it
# being reported unverified on the strength of the ungrounded claim from a.
# artifact_matches stays ABSENT when no record carried it — [] there would
# assert an empty labeling that was never observed.
if printf '%s' "$mev" | jq -e '
      (.[] | select(.id == "T-1") | .artifacts) == ["commit:beef"]
      and (.[] | select(.id == "T-1") | has("artifact_matches")) == false' >/dev/null 2>&1
then ok; else bad "meter did not union artifacts across producers"; fi
# A partial superseded by a completed from a DIFFERENT source still supersedes.
if printf '%s' "$mev" | jq -e '
      (.[] | select(.id == "T-2") | .status) == "completed"' >/dev/null 2>&1
then ok; else bad "a cross-source completed did not supersede an earlier partial"; fi

# The counts reader must agree, task for task, on the same drop-box.
mrow="$( printf '%s' '{"session":{"id":"merge-fixture","cwd":"/","branch":"main",
  "started":"1970-01-01T00:00:00Z","ended":"1970-01-01T00:00:01Z","wall_s":1,
  "active_s":1,"meter_version":1,"dedup":null,"agent_s":null},"tokens":[],
  "agents":[],"work":{"tools":{},"files":{}},
  "friction":{"tool_errors":0,"interrupts":0,"denials":0},"evidence":[]}' \
  | LASTCALL_LEDGER="$LEDGER.merge" LASTCALL_EVIDENCE_DIR="$MROOT/ev" \
    LASTCALL_COMMIT_DISCOVERY=0 "$S/ledger.sh" append 2>/dev/null )"
# completed 2 (T-1, T-2), blocked 1 (T-3), unverified 0 — the grounding from b
# reaches T-1. Before the merge this row read completed 3 and unverified 1.
# `c` appears in sources with no task of its own: assessed, nothing found.
if printf '%s' "$mrow" | jq -e '.evidence.completed == 2
      and .evidence.partial == 0 and .evidence.blocked == 1
      and .evidence.unverified == 0
      and .evidence.sources == ["a", "b", "c"]' >/dev/null 2>&1
then ok; else bad "ledger counts disagree with the meter on a merged drop-box"; fi
rm -f "$LEDGER.merge"
rm -rf "$MROOT"

say "  fixtures checked"

# ---------------------------------------------------------------- result
echo
if [ "$fail" -eq 0 ]; then
  echo "PASS  $pass checks, $sessions sessions"
else
  echo "FAIL  $fail failed, $pass passed" >&2
fi
exit $(( fail > 0 ? 1 : 0 ))
