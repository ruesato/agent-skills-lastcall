#!/usr/bin/env bash
# meter-session.sh — roll up one full Claude Code session: main thread + every
# subagent it spawned. Emits pure token/time/work counts as JSON.
#
#   meter-session.sh                  # current session, inferred from $PWD
#   meter-session.sh <session-uuid>   # a specific session
#
# No pricing here on purpose — rates come from the claude-api skill downstream,
# so this stays correct when prices change.
#
# With no transcript to read it emits a STUB rather than failing: same document
# shape, every measurement null, a `stub` block at the top level saying why.
# Set LASTCALL_REQUIRE_TRANSCRIPT=1 to get the hard failure back. See the stub
# emitter below and contracts.md section 1.
set -euo pipefail

ROOT="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"
IDLE_GAP_S="${IDLE_GAP_S:-300}"

# A cache write counts as a re-establishment when it rewrites this fraction of
# what was already resident. A FRACTION, never a constant: local baseline
# resident context is median 37.6K with a 28.9K-59.5K range (bin/baselines.sh,
# 2026-08-22), so it varies ~2x across sessions and any fixed token cutoff is
# tuned to one of them. The distribution is strongly bimodal — p50 0.006, p95
# 0.053, then p99 0.892 — so 0.25 and 0.50 select 60 and 59 turns out of 2909.
# That insensitivity is the reason a fraction is the right shape here.
REEST_RATIO="${LASTCALL_REESTABLISH_RATIO:-0.5}"

# How many turns after a skill takes attribution to look for the context jump
# that loading it caused. One turn is the WRONG window and not by a little:
# measured on session 31221561, claude-api reads +0.6K at one turn and +29.5K at
# two. The max over the window is taken, never the first delta.
LOAD_WINDOW="${LASTCALL_LOAD_WINDOW:-4}"

# Flat estimate for an image in a tool_result. Its base64 payload is ~1.4 bytes
# per token of actual cost, so measuring it by string length reports a Read of a
# screenshot as a six-figure-token call and turns the whole tool table into
# fiction. An estimate that is roughly right beats a measurement that is wildly
# wrong; it is declared as an estimate in contracts.md.
IMAGE_TOKENS="${LASTCALL_IMAGE_TOKENS:-1600}"

# How this meter COUNTED, not what it emits. Bump only when a change moves the
# numbers a previous version would have produced for the same transcript --
# a new field is additive and does not qualify. It rides into the ledger row so
# a stored row can be told apart from one measured under different arithmetic,
# which is what makes the re-meter repair path in contracts.md section 3
# executable: without it, an inflated row and a correct one are identical on
# disk. A row written before this existed carries no meter_version at all, and
# that absence means "unknown", never "version 1".
#   2 -- 2026-08-24: dedup falls back to message.id, so Bedrock-served
#        transcripts collapse their streaming chunks instead of counting every
#        chunk as a turn (~2x inflation on those sessions).
METER_VERSION=2

# Project dir slug: every character that is not alphanumeric or "-" becomes
# "-". Covers "/", ".", and "+" (worktree branch names like "feat+ui-refinement").
slug() { printf '%s' "$1" | sed 's|[^a-zA-Z0-9-]|-|g'; }

PROJ="$ROOT/$(slug "$PWD")"

# Newest .jsonl by mtime, without shelling out to `ls`: `ls` is commonly
# aliased or shadowed (eza, exa), and those replacements reject `-t`.
newest_jsonl() {
  local f t best="" bt=0
  for f in "$1"/*.jsonl; do
    [ -f "$f" ] || continue
    t=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) || continue
    [ "$t" -gt "$bt" ] && { bt="$t"; best="$f"; }
  done
  [ -n "$best" ] && basename "$best" .jsonl
}

# Resolution order matters. Falling back to "newest transcript" picks the WRONG
# session whenever two sessions share a project directory, which is common —
# so an explicitly supplied id, and then CLAUDE_SESSION_ID, both win over it.
#
# The last rung is the STUB identity, used when no id is available from any
# source — the Kiro case, where nothing sets CLAUDE_SESSION_ID and there is no
# transcript tree to pick a newest file out of. It is derived from $PWD rather
# than generated so that a producer writing into the evidence drop-box and this
# script reading it arrive at the same id with no handshake between them. The
# cost of that choice is stated where it bites: contracts.md section 2.
STUB_REASON=""
if [ $# -ge 1 ]; then
  SID="$1"
  ID_SOURCE=argument
elif [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  SID="$CLAUDE_SESSION_ID"
  ID_SOURCE=environment
elif [ -d "$PROJ" ] && SID="$(newest_jsonl "$PROJ")" && [ -n "$SID" ]; then
  ID_SOURCE=newest
else
  SID="stub$(slug "$PWD")"
  ID_SOURCE=cwd
  STUB_REASON="no session id was available and no transcript directory exists for $PWD under $ROOT"
fi

# A session keeps writing to the project directory it STARTED in, so renaming
# the working directory strands the transcript under the old slug while $PWD
# now hashes to a new one. A session id is globally unique, so widening the
# search to every project directory is unambiguous.
#
# It can land in BOTH. A session that outlives a rename has its transcript split
# across two project dirs under the same id, and stopping at the first match
# silently drops every entry in the other one — measured on
# 24dc7f38-0a55-4d14-80db-4e9b52210f37: 822 lines counted, 63 ignored, with no
# indication anything was missing. So collect every match rather than picking
# one. Each part is metered as its own main lane and the rollup sums them.
MAINS=()
SUBS=()
for d in "$ROOT"/*/; do
  [ -f "$d$SID.jsonl" ] || continue
  MAINS+=("$d$SID.jsonl")
  # Subagents live beside the main file, so they follow the split too.
  for sf in "$d$SID/subagents"/*.jsonl; do
    [ -f "$sf" ] && SUBS+=("$sf")
  done
done
# No transcript anywhere. This used to exit 1, and every stage downstream then
# failed transitively — the whole wrap-up died over the one input that is
# missing by construction on a host Claude Code does not write transcripts for.
# So emit a STUB instead: a document of the same shape carrying no measurements,
# marked as such at the top level. See the stub emitter at the bottom of this
# file for what it does and does not claim.
#
# Loudness is preserved without the exit code, which is the part that mattered:
# the warning below, the `stub` block, and cost.sh refusing to produce a total.
# LASTCALL_REQUIRE_TRANSCRIPT=1 restores the hard failure for a caller that
# wants a measurement or nothing.
STUB=0
if [ ${#MAINS[@]} -eq 0 ]; then
  [ -n "$STUB_REASON" ] || STUB_REASON="no transcript for $SID under $ROOT"
  if [ "${LASTCALL_REQUIRE_TRANSCRIPT:-0}" = "1" ]; then
    echo "meter: $STUB_REASON" >&2
    exit 1
  fi
  STUB=1
  echo "meter: $STUB_REASON — emitting a stub; nothing in this session is metered" >&2
fi

# Optional: the statusLine capture written by capture-statusline.sh. It is the
# only local source for rate_limits, which appear nowhere in a transcript, plus
# Claude Code own cost estimate and its API-wait total.
#
# Absence is the NORMAL case, not an error: the capture is opt-in, and even with
# it configured rate_limits only appear for Pro/Max subscribers after the first
# API response. A corrupt or foreign file is treated as absent too. Everything
# downstream omits the native block entirely rather than emitting zeroes — a
# session reporting 0% of the rate limit used would read as plenty of headroom.
# The evidence drop-box (contracts.md section 2). Same pattern as CAPFILE above:
# a lastcall-owned store, absent by default, skipped silently when it is not
# there. Read here rather than left for a downstream caller because the slot at
# the bottom of this file was documented as "filled from contract 2" and nothing
# ever filled it -- openloops.sh reads $m.evidence, so partial and blocked tasks
# were recorded in the ledger counts and silently dropped from the report the
# user actually reads. Merged on task.id ALONE, per the consumer rules in
# contracts.md section 2: the SOURCE is deliberately not part of the key, so two
# producers describing one task yield one task rather than two. Artifacts union
# and the most recent observation decides status. ledger.sh:evidence_for applies
# the same rule to produce counts, and verify.sh pins the two against each other
# -- a merge rule that holds in one reader and not the other is worse than none.
EVDIR="${LASTCALL_EVIDENCE_DIR:-$HOME/.claude/lastcall/evidence}/$SID"
EV='[]'
if [ -d "$EVDIR" ]; then
  evfiles=("$EVDIR"/*.json)
  if [ -e "${evfiles[0]}" ]; then
    evok=()
    for f in "${evfiles[@]}"; do
      if jq -e . "$f" >/dev/null 2>&1; then evok+=("$f")
      else echo "meter: skipping unparseable evidence $f" >&2; fi
    done
    if [ ${#evok[@]} -gt 0 ]; then
      # No apostrophes in this program: it is single-quoted in sh.
      # sort_by([.emitted_at, .source]) rather than max_by(.emitted_at): with
      # two producers a tie on emitted_at is reachable, and glob order is not a
      # tiebreak anyone can reason about. Source name breaks it the same way on
      # every machine. artifact_matches is set only when some record carried it,
      # because absent there means unlabeled and [] would assert more than was
      # observed.
      EV="$(jq -s -c '
        map(. as $d | (.tasks // [])[] | {source: $d.source, emitted_at: $d.emitted_at} + .)
        | group_by(.id)
        | map( sort_by([.emitted_at, .source]) as $g
               | ($g | map(.artifact_matches // []) | add | unique) as $am
               | ($g | last)
                 + { sources:   ($g | map(.source) | unique),
                     artifacts: ($g | map(.artifacts // []) | add | unique) }
                 + (if ($am | length) > 0 then {artifact_matches: $am} else {} end) )
        ' "${evok[@]}")" || EV='[]'
    fi
  fi
fi

CAPFILE="${LASTCALL_STATUSLINE_DIR:-$HOME/.claude/lastcall/statusline}/$SID.json"
CAP=null
if [ -f "$CAPFILE" ]; then
  # The filename is the session id, but the payload is checked against it too:
  # a store copied between machines, or a mangled write, must not be attributed
  # to the session being metered.
  # -s, and `first`, because jq exits 0 while emitting N documents: a file that
  # somehow holds two captures would otherwise hand --argjson two JSON values
  # and abort the meter. Slurping collapses that to one or to nothing.
  CAP="$(jq -c -s --arg sid "$SID" \
        'map(select(.schema == "lastcall.statusline/1"
                    and .payload.session_id == $sid)) | first // empty' \
        "$CAPFILE" 2>/dev/null)" || CAP=null
  [ -n "$CAP" ] || CAP=null
fi

# ------------------------------------------------------------------ stub
# Same document shape, no measurements. Every count that a real run would
# derive from the transcript is null here, and null means UNMEASURED — the same
# rule contracts.md invariant 11 applies to `native`, applied to the whole
# document. The two exceptions are deliberate:
#
#   work.files {}         — an object, because openloops.sh iterates it, and {}
#                           is already the shape that means "unmeasured" there.
#   files_coverage.attributed false
#                         — set EXPLICITLY, never omitted. openloops.sh defaults
#                           churn_available to true when files_coverage is
#                           absent, because absence there means "output from an
#                           older meter" rather than "nothing was attributed".
#                           A stub that left the field out would claim the
#                           struggle signal was measured when it was not.
#
# The evidence drop-box is carried through, so the open-loop report, and the
# commit / memories / tracker delegations that read it, survive on a host with
# no transcripts at all. That is the whole point of the stub.
#
# No `native` block, even when a statusLine capture happens to exist for this
# id: every figure in it is only meaningful beside the transcript-derived one it
# is a cross-check on, and there is no such figure here.
if [ "$STUB" = 1 ]; then
  jq -n --arg sid "$SID" --arg cwd "$PWD" --arg reason "$STUB_REASON" \
        --arg idsrc "$ID_SOURCE" --argjson ev "$EV" --argjson mver "$METER_VERSION" '
    { stub: { reason: $reason, id_source: $idsrc },
      session: { id: $sid, meter_version: $mver, cwd: $cwd, branch: null,
                 started: null, ended: null, wall_s: null, active_s: null,
                 agent_s: null, agent_turns: null, ai_title: null,
                 effort: null, dedup: null },
      tokens: [], agents: [],
      work: { tools: {}, files: {},
              files_coverage: { edit_tool_calls: null, bash_calls: null,
                                attributed: false },
              skills: [], skill_load: [] },
      context: null,
      friction: { tool_errors: null, interrupts: null, denials: null },
      evidence: $ev }'
  exit 0
fi

# Subagent identities, from the .meta.json sidecars.
agents_json() {
  local out="[]" m
  for f in "${SUBS[@]:-}"; do
    m="${f%.jsonl}.meta.json"
    [ -f "$m" ] || continue
    out=$(jq --slurpfile a "$m" '. + [$a[0] | {agentType, description, spawnDepth}]' <<<"$out")
  done
  printf '%s' "$out"
}

# Per-file metering. $lane distinguishes main-thread from subagent turns, which
# matters because the two use different cache TTLs and so price differently.
#
# WARNING: no apostrophes in these comments. This jq program is a single-quoted
# shell string, and one apostrophe ends it early — the resulting error lands far
# from the typo. Write "the row", never "the row" with a possessive s.
meter_file() {
  jq -s --arg lane "$2" --argjson gap "$IDLE_GAP_S" \
        --argjson rethr "$REEST_RATIO" --argjson loadw "$LOAD_WINDOW" \
        --argjson img "$IMAGE_TOKENS" '
    # Timestamps carry milliseconds, which fromdateiso8601 rejects.
    def tsec: if . == null then null
              else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end;

    # What was resident in the context window for one turn: everything the
    # request was billed for as prefix, whether it was read from cache or
    # written into it. BOTH cache_creation buckets belong here. An earlier
    # ad-hoc pass omitted the 1h bucket and reported the local baseline as 14.3K
    # against a true 37.6K — a 2.6x undercount, and not a rounding error, since
    # 100% of writes on this machine are 1h.
    def resident:
      ((.cache_read_input_tokens // 0)
       + (.cache_creation.ephemeral_5m_input_tokens // 0)
       + (.cache_creation.ephemeral_1h_input_tokens // 0));

    # Size of one tool_result payload, in tokens. An ESTIMATE by construction:
    # chars/4 for text, and a flat figure for images rather than their base64
    # length. Applied to the tool_result blocks directly, never derived by
    # dividing a per-turn context delta among the tools that preceded it — that
    # method loads generic per-turn growth (assistant output, thinking, user
    # text) onto whichever tool is called most often, and produced a $101
    # attribution for Bash against a real payload near 235 tokens per call.
    def payload_tokens:
      if . == null then 0
      elif type == "string" then (length / 4 | floor)
      elif type == "array" then
        ( map(if   .type == "image" then $img
              elif .type == "text"  then ((.text // "") | length / 4 | floor)
              else (tojson | length / 4 | floor) end) | add // 0 )
      else (tojson | length / 4 | floor) end;

    # The response identifier under whichever name this transcript carries it.
    # First-party API writes requestId; Bedrock-served transcripts write
    # message.id instead, with requestId absent on every entry; uuid is the
    # always-present line id and the last resort. The dedup below and the
    # tool-context join further down MUST group on the same expression: if the
    # join keys differ from the dedup keys, every chunk that is not first in
    # its group misses the lookup and tool_context silently goes thin.
    def rkey: .requestId // .message.id // .uuid;

    # Streaming emits one entry per chunk sharing a response id (rkey above),
    # and every chunk in a group carries the SAME cumulative usage. Collapsing
    # each group to its first entry is what stops totals from inflating by the
    # group size. <synthetic> entries are dropped BY MODEL NAME below, which is
    # the only thing that excludes them: they carry no requestId but they DO
    # carry a message.id (measured 2026-08-24: 1 of 1 locally), so since rkey
    # gained its message.id fallback they land in the same key namespace as
    # billed turns rather than falling through to a uuid nothing matches.
    ( map(select(.type == "assistant"
                 and .message.model != "<synthetic>"
                 and .message.usage != null))
    ) as $entries
    | ( $entries | group_by(rkey) | map(.[0]) ) as $turns

    # This guard is load-bearing, and its coverage is MEASURED rather than
    # assumed. The response id goes by different names per provider. On
    # first-party API transcripts requestId is present: 5629 of 5630 entries
    # over 27 local transcripts, most common group size THREE (measured
    # 2026-08-22). On Bedrock-served transcripts requestId is absent (0 of
    # 6148) and message.id is the identifier, which is why rkey falls through
    # to it (measured 2026-08-23 by the external review this caveat caught).
    # That review read requestId 0 as proof the guard was inert; on the
    # first-party corpus changing the key would have inflated every total by
    # ~2.3x, and on Bedrock the missing fallback measurably did inflate them,
    # ~2x across an 11-row ledger. So report what the key actually did, per
    # envelope: rid_coverage 0 with mid_coverage above 0 is the Bedrock
    # envelope handled; BOTH 0 is the signal the format moved again, not proof
    # that nothing needed collapsing.
    | ( { entries: ($entries | length),
          turns:   ($turns   | length),
          rid:     ($entries | map(select(.requestId != null)) | length),
          mid:     ($entries | map(select(.message.id != null)) | length) } ) as $dedup

    # Timestamps carry milliseconds, which fromdateiso8601 rejects.
    | ( map(.timestamp | select(. != null)
            | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) | sort ) as $ts

    # Wall clock is meaningless for a resumed session, which can span days.
    # Only gaps shorter than $gap count as time actually spent working.
    | ( if ($ts | length) < 2 then 0
        else [ range(1; $ts|length) as $i
               | ($ts[$i] - $ts[$i-1]) | select(. <= $gap) ] | add // 0 end
      ) as $active

    # The SAME bucketing, kept as intervals instead of summed away. A session
    # window is a wildly loose proxy for when the session was working: measured
    # across 60 local transcripts, windows of 409h and 313h carry near-zero
    # activity. Anything joining an event to a session by window alone inherits
    # that looseness, so the spans are emitted rather than discarded.
    #
    # sum(spans) == active_s by construction, which verify.sh pins -- the two
    # must never drift, or the join and the reported active time would be
    # describing different sessions.
    #
    # A lone timestamp yields a zero-length span rather than nothing: the
    # session WAS active at that instant, and dropping it would make a
    # single-turn session look like it never ran.
    | ( reduce range(0; $ts|length) as $i ([];
          if $i == 0 or ($ts[$i] - $ts[$i-1]) > $gap
          then . + [[$ts[$i], $ts[$i]]]
          else (.[0:-1] + [[.[-1][0], $ts[$i]]]) end)
      ) as $spans

    # Claude Code writes one turn_duration record per COMPLETED user turn. It is
    # its own measure of how long the agent was busy, with no idle heuristic in
    # it — but the turn in flight has not been written yet, so this undercounts
    # a session metered mid-turn and is 0 for a session that has never finished
    # a turn. Reported beside $active, never instead of it.
    | ( map(select(.type == "system" and .subtype == "turn_duration")) ) as $td

    | ( map(select(.type == "assistant") | .message.content[]?
            | select(.type == "tool_use")) ) as $tools

    # ------------------------------------------------ ordered turn timeline
    # group_by sorts on its KEY, so $turns above comes out in response-id
    # order, not in time order. Everything below is positional — carry, idle gaps,
    # context deltas — so it re-sorts rather than inheriting that ordering.
    | ( $turns | sort_by(.timestamp) ) as $ordered
    | ( $ordered | length ) as $n

    # ------------------------------------------------ did the dedup WORK?
    # rid_coverage and mid_coverage say which FIELD NAME was present. That is a
    # proxy, and it has a blind spot the field cannot see: an envelope whose
    # response id is written per CHUNK rather than per response scores full
    # coverage, collapses nothing, and inflates every total -- the same failure
    # the message.id fallback just fixed, one field along.
    #
    # So measure the property the field name is a proxy FOR. Every chunk of one
    # response repeats the same cumulative usage, so when the key fails to
    # collapse them, chunks survive as separate turns and adjacent turns carry
    # IDENTICAL usage. Real consecutive replies do not: cache_read alone moves
    # every turn as the context grows.
    #
    # Measured 2026-08-24 over all 55 local transcripts (7611 assistant
    # entries): ZERO adjacent-identical pairs with a working key, in every
    # file. Re-keyed on uuid to simulate the break, the same corpus gives
    # 11%-57%. The gap between 0 and 11 is the whole signal, and it does not
    # depend on any field being called anything.
    | ( if $n < 2 then { adj_pairs: 0, adj_dup: 0 }
        else { adj_pairs: ($n - 1),
               adj_dup:
                 ( [ range(0; $n - 1) as $i
                     | if ($ordered[$i].message.usage == $ordered[$i+1].message.usage
                           and $ordered[$i].message.model == $ordered[$i+1].message.model)
                       then 1 else 0 end ] | add // 0 ) }
        end ) as $adjdup
    | ( [ range(0; $n) | $ordered[.].message.usage | resident ] ) as $resid

    # Thinking tokens are billed once as output, then re-read as cache on every
    # later turn of the same context. This is the WEIGHT of that carry: tokens
    # times the number of turns that will re-read them. Pricing it belongs
    # downstream, so this stays a token count. Computed within one transcript
    # part, so a split session loses only the carry that straddles the seam.
    | ( [ range(0; $n) as $i | $ordered[$i] as $t
          | $t + { _carry: (((($t.message.usage.output_tokens_details.thinking_tokens) // 0))
                            * ($n - 1 - $i)) } ] ) as $carried

    # ------------------------------------------- cache re-establishment events
    # When a cached prefix expires, the whole thing is rewritten at the write
    # multiplier instead of read at 0.10x. Aggregated into cache_w_5m/1h, a
    # session that paid for several full rewrites is indistinguishable from one
    # that paid for none. Index 0 is excluded deliberately: establishing the
    # prefix for the first time is unavoidable, and counting it would report an
    # event in every session ever metered. That undercounts a resumed part,
    # which is the conservative direction.
    | ( [ range(1; $n) as $i | $ordered[$i] as $t | ($t.message.usage) as $u
          | (($u.cache_creation.ephemeral_5m_input_tokens // 0)) as $w5
          | (($u.cache_creation.ephemeral_1h_input_tokens // 0)) as $w1
          | ($w5 + $w1) as $w
          | ($u | resident) as $res
          | select($w > 0 and $res > 0 and (($w / $res) >= $rethr))
          | { at: $t.timestamp, model: $t.message.model,
              speed: $u.speed, service_tier: $u.service_tier,
              tokens: $w, tokens_5m: $w5, tokens_1h: $w1,
              ratio: (($w / $res) * 1000 | round / 1000),
              # The gap that preceded it. An expiry is a function of elapsed
              # time, so the gap is the part of the event a person can act on.
              idle_s: ( ($t.timestamp | tsec) as $a
                        | ($ordered[$i-1].timestamp | tsec) as $b
                        | if $a == null or $b == null then null else ($a - $b) end ) }
        ] ) as $reest

    # ------------------------------------------------------- per-skill load
    # A run start is the first turn of a contiguous stretch attributed to one
    # skill. Attribution RELEASES back to null between runs and is not driven by
    # the Skill tool, so runs are found by scanning the attribution column
    # rather than by looking for Skill calls.
    | ( [ range(0; $n) as $i
          | ($ordered[$i].attributionSkill) as $s
          | select($s != null
                   and ($i == 0 or ($ordered[$i-1].attributionSkill) != $s))
          | { skill: $s, idx: $i } ] ) as $starts

    # Context growth attributable to loading each skill. Two failure modes pull
    # in opposite directions and each gets its own correction: a one-turn window
    # reads LOW because the load has not landed yet, so take the max across a
    # wider window; and any window is contaminated by whatever else those turns
    # pulled in, which only ever ADDS, so take the smallest reading across runs.
    # A degenerate measurement emits null, never 0 — unmeasured is not zero,
    # the same discipline the native block and files_coverage keep.
    | ( [ $starts[] | . as $st | $st.idx as $i
          | if $i < 1 then { skill: $st.skill, load: null }
            else ( [ range(1; $loadw + 1) as $w
                     | ($i - 1 + $w) as $j
                     | select($j < $n)
                     | ($resid[$j] - $resid[$i-1]) ] | max ) as $d
                 | { skill: $st.skill,
                     load: (if $d == null or $d <= 0 then null else $d end) }
            end ]
        | group_by(.skill)
        | map({ skill: .[0].skill, runs: length,
                load_tokens: ([ .[] | .load | select(. != null) ] | min) }) ) as $load

    # ------------------------------------------- context growth by tool
    # tool_use blocks carry the pricing dimensions of the turn that issued them,
    # so a payload can be priced with the same rate table as everything else.
    #
    # Built in two steps, and the reason is the dedup. Streaming splits one turn
    # across chunks that share a response id, and the deduped $turns keeps the
    # FIRST chunk — which usually does not hold the tool_use block. Reading the
    # map straight off $ordered matched 52 of 318 tool_results on
    # 0fd5463b-bdc7-4b5a-900d-2dd9093f1bcb and read as thin tool usage rather
    # than as a broken join. So index the turns by request key, then scan every
    # assistant entry for tool_use and look its turn up.
    | ( [ range(0; $n) as $i | $ordered[$i] as $t
          | { key: ($t | rkey),
              value: { idx: $i, model: $t.message.model,
                       speed: $t.message.usage.speed,
                       service_tier: $t.message.usage.service_tier } } ]
        | from_entries ) as $ridmap

    # The <synthetic> filter here is load-bearing, not copied boilerplate. This
    # scan walks the RAW entries, not the filtered $entries, so it is the only
    # place that keeps synthetic entries out of the tool table. It used to get
    # that for free: a synthetic entry has no requestId, so it keyed on its uuid
    # and missed $ridmap. Since rkey gained the message.id fallback that is no
    # longer true -- synthetic entries carry a message.id -- so exclude them by
    # the same model-name test $entries uses rather than by a side effect that
    # has already stopped holding once.
    | ( [ .[] | select(.type == "assistant"
                       and .message.model != "<synthetic>") as $e
          | ($ridmap[($e | rkey)] // null) as $g
          | select($g != null)
          | ($e.message.content[]? | select(.type == "tool_use"))
          | { key: (.id // ""), value: ($g + { name: .name }) } ]
        | from_entries ) as $tumap

    | ( [ .[] | select(.type == "user") | .message.content[]?
          | select(.type == "tool_result")
          | { id: (.tool_use_id // ""), tokens: (.content | payload_tokens) } ]
      ) as $tres

    | ( [ $tres[] | . as $r | ($tumap[$r.id] // null) as $u
          | select($u != null)
          | { tool: $u.name, model: $u.model, speed: $u.speed,
              service_tier: $u.service_tier, tokens: $r.tokens,
              # Same carry weight as thinking: a payload sits in the prefix and
              # is re-read by every later turn.
              carry: ($r.tokens * ([$n - 1 - $u.idx, 0] | max)) } ]
        | group_by([.tool, .model, .speed, .service_tier])
        | map({ tool: .[0].tool, model: .[0].model, speed: .[0].speed,
                service_tier: .[0].service_tier,
                calls: length,
                payload_tokens: (map(.tokens) | add),
                carry_tokens:   (map(.carry)  | add) }) ) as $toolctx

    # Compaction boundaries. Claude Code writes one system/compact_boundary
    # record per compaction, carrying how many tokens were dropped from the
    # context window. This is the only way to know that the agent summarizing a
    # session can no longer SEE all of it - the transcript on disk is complete,
    # the context it is being read from is not.
    | ( map(select(.type == "system" and .subtype == "compact_boundary")) ) as $cb

    | {
        lane: $lane,
        cwd:     (map(.cwd // empty)       | first),
        branch:  (map(.gitBranch // empty) | last),
        # Claude Code own generated title for the session. A LABEL, not content
        # - it names what the session was about without carrying any of the
        # conversation, so it costs nothing to read and cannot be mistaken for
        # evidence that work landed. summary.md points at it for the Headline;
        # this is what makes that instruction real.
        ai_title: (map(select(.type == "ai-title") | .aiTitle // empty) | last),
        dedup: ($dedup + $adjdup),
        first_ts: ($ts | first), last_ts: ($ts | last), active_s: $active,
        spans: $spans,
        agent_s:     (($td | map(.durationMs) | add // 0) / 1000),
        agent_turns: ($td | length),
        # Grouped by the dimensions that change what a request BILLS at. speed
        # (fast mode) and service_tier (priority, batch) both do; collapsing
        # them would price a fast-mode session at standard rates and leave no
        # trace that it happened. Kept as recorded, so null means unrecorded
        # rather than standard.
        usage: ( $carried
                 | group_by([.message.model, .message.usage.speed, .message.usage.service_tier])
                 | map({
                   model:        .[0].message.model,
                   speed:        .[0].message.usage.speed,
                   service_tier: .[0].message.usage.service_tier,
                   turns: length,
                   input:      (map(.message.usage.input_tokens            // 0) | add),
                   output:     (map(.message.usage.output_tokens           // 0) | add),
                   cache_read: (map(.message.usage.cache_read_input_tokens // 0) | add),
                   cache_w_5m: (map(.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) | add),
                   cache_w_1h: (map(.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) | add),
                   # Thinking is a SUBSET of output, not another bucket. Never
                   # add it to a total; it says how much of the output was
                   # reasoning rather than reply.
                   thinking:   (map(.message.usage.output_tokens_details.thinking_tokens // 0) | add),
                   # Token-weight of re-reading this reasoning on every later
                   # turn. Priced downstream at the cache_read multiplier.
                   thinking_carry: (map(._carry) | add),
                   # Server-side tools carry per-request spend, so these counts
                   # are the only trace of it anywhere in the transcript.
                   web_search: (map(.message.usage.server_tool_use.web_search_requests // 0) | add),
                   web_fetch:  (map(.message.usage.server_tool_use.web_fetch_requests  // 0) | add),
                   efforts: (group_by(.effort) | map({ (.[0].effort // "unset"): length }) | add // {})
                 }) ),
        # Per-turn skill and plugin attribution, written by Claude Code itself.
        # Lane is deliberately absent: pricing reads the cache buckets, which
        # are already split, so a skill row prices correctly without it.
        skills: ( $turns | group_by([.attributionSkill, .message.model]) | map({
                   skill:  .[0].attributionSkill,
                   plugin: .[0].attributionPlugin,
                   model:  .[0].message.model,
                   turns: length,
                   input:      (map(.message.usage.input_tokens            // 0) | add),
                   output:     (map(.message.usage.output_tokens           // 0) | add),
                   cache_read: (map(.message.usage.cache_read_input_tokens // 0) | add),
                   cache_w_5m: (map(.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) | add),
                   cache_w_1h: (map(.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) | add)
                 }) ),
        skill_load: $load,
        reest: $reest,
        # Turns that wrote cache at all — the denominator the event count is
        # meaningful against. Index 0 excluded to match $reest above.
        writing_turns: ( [ range(1; $n) as $i
                           | $ordered[$i].message.usage
                           | select((.cache_creation.ephemeral_5m_input_tokens // 0)
                                    + (.cache_creation.ephemeral_1h_input_tokens // 0) > 0) ]
                         | length ),
        tool_context: $toolctx,
        # A tool_result whose tool_use is not in this file — issued before a
        # compaction, or in a part that lives under another slug. Reported, so
        # a thin tool table reads as partial coverage rather than as low usage.
        tool_context_coverage: { results: ($tres | length),
                                 matched: ([ $tres[] | select($tumap[.id] != null) ] | length) },
        tools: ($tools | group_by(.name) | map({ (.[0].name): length }) | add // {}),
        files: ( $tools
                 | map(select(.name == "Edit" or .name == "Write" or .name == "NotebookEdit"))
                 | map(.input.file_path // .input.notebook_path // empty)
                 | group_by(.) | map({ (.[0]): length }) | add // {} ),
        # How much of the editing this session did is even VISIBLE to `files`
        # above, which can only see the edit tools. A file written through Bash
        # leaves no trace there, and some harness modes instruct Bash-first
        # editing, so this is a normal operating condition rather than an edge
        # case. Counts, never a guess: paths are not parsed back out of shell
        # commands, because the common forms are undetectable — a heredoc that
        # pipes into python and writes through open() names no file the
        # transcript can see, and a wrong path in a churn hotspot is worse than
        # an absent one.
        edit_tool_calls: ( $tools
                           | map(select(.name == "Edit" or .name == "Write"
                                        or .name == "NotebookEdit")) | length ),
        bash_calls: ( $tools | map(select(.name == "Bash")) | length ),
        compactions: ($cb | length),
        # cumulativeDroppedTokens is cumulative, so the largest is the total.
        dropped_tokens: ($cb | map(.compactMetadata.cumulativeDroppedTokens // 0) | max // 0),
        compact_triggers: ($cb | map(.compactMetadata.trigger // "unknown") | unique),
        friction: {
          # is_error is tri-state; null means the field is absent, not an error.
          tool_errors: ( map(select(.type=="user") | .message.content[]?
                         | select(.type=="tool_result" and .is_error == true)) | length ),
          interrupts:  ( map(select(.interruptedMessageId != null)) | length ),
          # automode-* denials are harness state, not user friction.
          denials:     ( map(select(.toolDenialKind == "user-rejected")) | length )
        }
      }' "$1"
}

{ for f in "${MAINS[@]}"; do meter_file "$f" main; done
  # The trailing "true" matters: with pipefail, a session that spawned no
  # subagents would otherwise leave this block-s status at 1 and fail the
  # pipeline despite jq having produced correct output.
  for f in "${SUBS[@]:-}"; do
    [ -f "$f" ] && meter_file "$f" subagent
  done
  true
} | jq -s --arg sid "$SID" --argjson agents "$(agents_json)" --argjson cap "$CAP" \
       --argjson ev "$EV" --argjson rethr "$REEST_RATIO" --argjson loadw "$LOAD_WINDOW" \
       --argjson img "$IMAGE_TOKENS" --argjson mver "$METER_VERSION" '
    # Merge a list of {key: count} maps by SUMMING. Object "+" overwrites
    # duplicate keys rather than summing them, which is the trap this exists
    # to avoid — see CLAUDE.md.
    def sum_maps: [ .[] | to_entries[] ] | group_by(.key)
                  | map({ (.[0].key): (map(.value) | add) }) | add // {};

    # Drop keys whose value is null, and objects left empty by that drop. Used
    # only for the native block, where a missing field means UNMEASURED and must
    # vanish rather than surface as a zero. walk is bottom-up, so an object
    # emptied by the inner pass is removed by the outer one.
    def prune: walk(if type == "object"
                    then with_entries(select(.value != null and .value != {}))
                    else . end);

    # A lane with no timestamped entries at all yields a null first_ts, and jq
    # sorts null BELOW every number, so `min` over it returns null and
    # todateiso8601 then aborts the whole meter. That became reachable when
    # MAINS started collecting every matching file: one empty stub left under a
    # stale slug by a rename is enough. Filter before reducing, and treat "no
    # timestamps anywhere" as unmeasured rather than as epoch zero.
    ( map(.first_ts | select(. != null)) | min ) as $t0
    | ( map(.last_ts | select(. != null)) | max ) as $t1

    | { session: {
        id: $sid,
        # How this meter counted -- see METER_VERSION at the top of the script.
        # Rides into the ledger row so a stored figure can be attributed to the
        # arithmetic that produced it.
        meter_version: $mver,
        # The LATEST main lane wins, not the first. A split session carries the
        # pre-rename path in its earlier part, and reporting that as the session
        # cwd points every consumer at a directory that no longer exists.
        cwd:    ((map(select(.lane == "main" and .cwd    != null)) | max_by(.last_ts) | .cwd)
                 // (map(.cwd    | select(.)) | first)),
        branch: ((map(select(.lane == "main" and .branch != null)) | max_by(.last_ts) | .branch)
                 // (map(.branch | select(.)) | first)),
        started: ($t0 | if . == null then null else todateiso8601 end),
        ended:   ($t1 | if . == null then null else todateiso8601 end),
        wall_s:  (if $t0 == null or $t1 == null then 0 else $t1 - $t0 end),
        # Main-thread active time only: subagents run concurrently, so adding
        # their spans would double-count the same minutes.
        # Summed across main lanes. A split session loses only the gap that
        # straddles the two files, which is the rename itself — seconds, and in
        # the conservative direction.
        active_s: (map(select(.lane=="main") | .active_s) | add // 0),
        # When the session was actually WORKING, as [start, end] epoch pairs.
        # Main lanes only, for the same reason active_s is: subagents run
        # concurrently and their spans would double-count the same minutes.
        #
        # Merged across the main lanes of a split session, because a rename
        # produces two files whose spans are separate lists but one timeline.
        # Overlapping or touching intervals are coalesced so a consumer can
        # treat the list as disjoint and ascending -- otherwise a containment
        # test would have to sort it first, and every caller would have to
        # remember to.
        spans:
          ( [ .[] | select(.lane == "main") | .spans[]? ]
            | sort_by(.[0])
            | reduce .[] as $sp ([];
                if (length == 0) or ($sp[0] > (.[-1][1]))
                then . + [$sp]
                else (.[0:-1] + [[.[-1][0], ([.[-1][1], $sp[1]] | max)]]) end) ),
        # Native agent-busy time. Only the main thread emits turn_duration, and
        # only for turns that have ENDED, so this is a floor: a session metered
        # mid-turn is missing the turn being metered.
        agent_s:     (map(select(.lane=="main") | .agent_s)     | add // 0),
        agent_turns: (map(select(.lane=="main") | .agent_turns) | add // 0),
        # null when the session never got a title, which is unmeasured rather
        # than untitled. Latest wins: a split session carries the earlier one.
        ai_title: (map(select(.lane=="main") | .ai_title | select(.)) | last),
        # What the streaming dedup actually did, summed over every lane and
        # every split part. collapsed is how many duplicate chunks were
        # removed; rid_coverage and mid_coverage are the shares of entries
        # carrying each response-id field. Downstream turns rid_coverage == 0
        # with mid_coverage null or 0 into a caveat: it means the grouping
        # silently fell through to uuid for the whole file. rid 0 with mid
        # above 0 is the Bedrock envelope, handled by the fallback.
        #
        # adj_dup_share is the name-independent cross-check described where it
        # is computed: the share of adjacent turn pairs carrying identical
        # usage, which is what a FAILED collapse looks like regardless of what
        # the response id is called. Coverage answers "was the field there",
        # this answers "did collapsing happen". Both are reported because they
        # fail in different directions.
        dedup: ( (map(.dedup) | { entries:   (map(.entries)   | add // 0),
                                  turns:     (map(.turns)     | add // 0),
                                  rid:       (map(.rid)       | add // 0),
                                  mid:       (map(.mid)       | add // 0),
                                  adj_pairs: (map(.adj_pairs) | add // 0),
                                  adj_dup:   (map(.adj_dup)   | add // 0) })
                 | . + { collapsed: (.entries - .turns),
                         rid_coverage: (if .entries == 0 then null
                                        else ((.rid / .entries * 1000 | round) / 1000) end),
                         mid_coverage: (if .entries == 0 then null
                                        else ((.mid / .entries * 1000 | round) / 1000) end),
                         # null, not 0, when there was no pair to compare:
                         # a one-turn session has not shown the dedup working,
                         # it has given it nothing to do.
                         adj_dup_share: (if .adj_pairs == 0 then null
                                         else ((.adj_dup / .adj_pairs * 1000 | round) / 1000) end) } ),
        # Reasoning effort, rolled up so it can be stated without arithmetic
        # over the token rows. Claude Code has recorded it per turn all along
        # and nothing has ever reported it. Measured locally 2026-08-22: high on
        # 100% of 2870 turns, which is the kind of fact that changes behaviour on
        # sight. "unset" is a turn that carried no effort field — unrecorded,
        # not a low setting.
        effort: ( ( map(.usage[].efforts) | sum_maps ) as $mix
                  | ( [ $mix[] ] | add // 0 ) as $tot
                  | { mix: $mix, turns: $tot }
                  + ( ($mix | to_entries | max_by(.value)) as $top
                      | if $top == null or $tot == 0 then { dominant: null, dominant_share: null }
                        else { dominant: $top.key,
                               dominant_share: (($top.value / $tot * 1000 | round) / 1000) } end ) )
      },
      # Grouped by (model, lane, speed, service_tier). The last two are pricing
      # dimensions; the lane split is there because main threads and subagents
      # use different cache TTLs.
      tokens: ( map(.lane as $l | .usage[] | . + {lane: $l})
                | group_by([.model, .lane, .speed, .service_tier]) | map({
                    model: .[0].model, lane: .[0].lane,
                    speed: .[0].speed, service_tier: .[0].service_tier,
                    turns:      (map(.turns)      | add),
                    input:      (map(.input)      | add),
                    output:     (map(.output)     | add),
                    cache_read: (map(.cache_read) | add),
                    cache_w_5m: (map(.cache_w_5m) | add),
                    cache_w_1h: (map(.cache_w_1h) | add),
                    thinking:   (map(.thinking)   | add),
                    thinking_carry: (map(.thinking_carry // 0) | add),
                    web_search: (map(.web_search) | add),
                    web_fetch:  (map(.web_fetch)  | add),
                    efforts:    (map(.efforts) | sum_maps)
                  }) ),
      # Cache re-establishment. A single aggregate cache_w_* figure cannot tell
      # a session that paid for several full prefix rewrites from one that paid
      # for none, and the two bill very differently: a rewrite costs 1.25x or
      # 2.00x input where a read costs 0.10x. Dollars are added downstream; this
      # keeps the token counts and the pricing dimensions to compute them with.
      cache_reestablish: ( ( [ map(.reest) | .[][]? ] ) as $re
        | { threshold_ratio: $rethr,
            events:        ($re | length),
            writing_turns: (map(.writing_turns) | add // 0),
            tokens:        ($re | map(.tokens) | add // 0),
            largest:       ($re | max_by(.tokens)),
            # Each event with the gap that preceded it, largest first and capped
            # so a pathological session cannot flood the row. The pairing is the
            # point: a long gap says the prefix aged out, a short one says it
            # was rebuilt for some other reason — a resume, a context edit — and
            # only the first of those is something a person can change. Both
            # shapes are real. Measured on 31221561, the four events read 13s,
            # 22512s, 25404s and 10285s, all with cache_read pinned near 16.3K,
            # which is the base prompt surviving while the conversation prefix
            # was rewritten.
            detail:        ($re | sort_by(-(.tokens)) | .[0:10]),
            by_model: ($re | group_by([.model, .speed, .service_tier])
                      | map({ model: .[0].model, speed: .[0].speed,
                              service_tier: .[0].service_tier,
                              events: length,
                              tokens_5m: (map(.tokens_5m) | add),
                              tokens_1h: (map(.tokens_1h) | add) })) } ),
      agents: $agents,
      work: {
        tools: (map(.tools) | sum_maps),
        files: (map(.files) | sum_maps),
        # Whether `files` can be read as the whole picture. attributed is false
        # when the session ran Bash but never called an edit tool: work plainly
        # happened and none of it is in `files`, so an empty map there means
        # UNMEASURED, not "nothing was touched". Observed 2026-08-19: six files
        # changed across two repos and seven commits, with files {} and Bash 86.
        # Anything short of that is degraded rather than blind, and the raw
        # counts are here so a consumer can say which.
        files_coverage: ( { edit_tool_calls: (map(.edit_tool_calls) | add // 0),
                            bash_calls:      (map(.bash_calls)      | add // 0) }
                          | . + { attributed: (.bash_calls == 0 or .edit_tool_calls > 0) } ),
        # Attribution is absent on plain conversational turns, which group under
        # a null skill. That null row is the unattributed remainder, and dropping
        # it would make the parts stop summing to the whole.
        skills: ( map(.skills[]) | group_by([.skill, .model]) | map({
                    skill: .[0].skill, plugin: .[0].plugin, model: .[0].model,
                    turns:      (map(.turns)      | add),
                    input:      (map(.input)      | add),
                    output:     (map(.output)     | add),
                    cache_read: (map(.cache_read) | add),
                    cache_w_5m: (map(.cache_w_5m) | add),
                    cache_w_1h: (map(.cache_w_1h) | add)
                  }) | sort_by(-(.output)) ),
        # What a skill COST to load, as distinct from what was spent while it
        # held attribution. Those are different questions and only this one
        # answers "is this skill expensive?" — see the caution on `skills`
        # above. Kept out of the `skills` rows on purpose: load is a property of
        # the skill, not of the (skill, model) pair those rows are keyed on, and
        # repeating one value across them would look like a per-model
        # measurement. null load_tokens means the deltas were degenerate.
        # Smallest across parts, for the contamination reason in meter_file.
        skill_load: ( map(.skill_load[]) | group_by(.skill)
                      | map({ skill: .[0].skill,
                              runs: (map(.runs) | add),
                              load_tokens: ([ .[] | .load_tokens | select(. != null) ] | min),
                              approximate: true }) ),
        # What put the tokens in the window. Cache reads are the majority of the
        # bill and their cost is a function of what is resident, so a report
        # without this can name a total without naming one fixable thing.
        # Keyed on the pricing dimensions so carry can be priced exactly;
        # cost.sh collapses it to one row per tool with dollars attached.
        tool_context: ( map(.tool_context[]) | group_by([.tool, .model, .speed, .service_tier])
                        | map({ tool: .[0].tool, model: .[0].model, speed: .[0].speed,
                                service_tier: .[0].service_tier,
                                calls:          (map(.calls) | add),
                                payload_tokens: (map(.payload_tokens) | add),
                                carry_tokens:   (map(.carry_tokens) | add) })
                        | map(. + { avg_tokens: ((.payload_tokens / .calls) | round) })
                        | sort_by(-(.payload_tokens)) ),
        tool_context_coverage: ( { results: (map(.tool_context_coverage.results) | add // 0),
                                   matched: (map(.tool_context_coverage.matched) | add // 0),
                                   image_tokens_each: $img }
                                 | . + { unmatched: (.results - .matched),
                                         approximate: true } )
      },
      # How much of this session is still VISIBLE to whoever is summarizing it.
      # Unlike the native block, zero here is a measurement rather than an
      # absence: every entry of every transcript was read and no compaction
      # boundary was found. Main lanes only - a subagent compacting its own
      # context does not cost the main thread anything.
      context: {
        compactions:    (map(select(.lane=="main") | .compactions)    | add // 0),
        dropped_tokens: (map(select(.lane=="main") | .dropped_tokens) | max // 0),
        triggers:       ([ map(select(.lane=="main") | .compact_triggers) | .[][]? ] | unique)
      },
      friction: {
        tool_errors: (map(.friction.tool_errors) | add),
        interrupts:  (map(.friction.interrupts)  | add),
        denials:     (map(.friction.denials)     | add)
      },
      # External work evidence, read from the drop-box at the top of this file.
      # [] means no producer wrote anything, which is the normal case.
      evidence: $ev
    }

    # ---------------------------------------------------------------- native
    # Signals Claude Code measured itself, from the statusLine capture. Folded
    # in ONLY when a capture exists and matched; otherwise the key is absent.
    # Never emitted with zeroes — see the CAPFILE comment above.
    | if $cap == null then . else
        . as $out
        | ($cap.payload) as $p
        | ($out.session.agent_s) as $agent
        | (($p.cost.total_api_duration_ms // null)) as $apims
        | . + { native: ({
              source:      "statusline",
              captured_at: $cap.captured_at,
              cc_version:  $p.version,

              # Claude Code own client-side cost estimate. ADVISORY: it is
              # documented as an estimate that may differ from the bill, and it
              # resets to 0 when /clear starts a new session. Never substituted
              # for the figure cost.sh derives from tokens.
              cost_usd:      $p.cost.total_cost_usd,
              wall_ms:       $p.cost.total_duration_ms,
              api_ms:        $apims,
              lines_added:   $p.cost.total_lines_added,
              lines_removed: $p.cost.total_lines_removed,

              # Subscriber-only, and only after the first API response. For a
              # Max plan this is the constraint that actually binds, which no
              # dollar figure expresses. resets_at arrives as epoch seconds.
              # Guarded on TYPE, not just on null. These fields are undocumented
              # external input: a resets_at that arrives as an ISO string rather
              # than epoch seconds would abort the entire meter at
              # todateiso8601, taking token and time counts down with it over a
              # field nothing depends on. A value of the wrong type is
              # unmeasured, which is the same outcome as absent.
              rate_limits: ( $p.rate_limits
                | (def num: if type == "number" then . else null end;
                   def utc: if type == "number" then todateiso8601 else null end;
                   { five_hour: { used_percentage: (.five_hour.used_percentage | num),
                                  resets_at:       (.five_hour.resets_at | num),
                                  resets_at_utc:   (.five_hour.resets_at | utc) },
                     seven_day: { used_percentage: (.seven_day.used_percentage | num),
                                  resets_at:       (.seven_day.resets_at | num),
                                  resets_at_utc:   (.seven_day.resets_at | utc) } }) ),

              # agent_s minus API wait is time spent RUNNING TOOLS — the
              # difference between a slow model and a slow test suite, which no
              # other number here expresses. Both inputs are floors measured at
              # different moments: agent_s omits the turn in flight, api_ms
              # comes from the last status line render. So the split is
              # approximate, and the subtraction can legitimately go negative,
              # which is clamped and flagged rather than reported as nonsense.
              split: ( if $agent != null and $agent > 0 and $apims != null
                       then ($apims / 1000) as $api
                            | { api_s:  ($api      | . * 10 | round / 10),
                                tool_s: ([$agent - $api, 0] | max | . * 10 | round / 10),
                                clamped:     (($agent - $api) < 0),
                                approximate: true }
                       else null end )
            } | prune) }
      end'
