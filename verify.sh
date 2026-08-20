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
# The same lookup must still fail loudly for an id that exists nowhere.
if CLAUDE_PROJECTS="$FROOT" "$S/meter-session.sh" fixture-absent >/dev/null 2>&1
then bad "meter succeeded on a nonexistent session id"; else ok; fi

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

say "  fixtures checked"

# ---------------------------------------------------------------- result
echo
if [ "$fail" -eq 0 ]; then
  echo "PASS  $pass checks, $sessions sessions"
else
  echo "FAIL  $fail failed, $pass passed" >&2
fi
exit $(( fail > 0 ? 1 : 0 ))
