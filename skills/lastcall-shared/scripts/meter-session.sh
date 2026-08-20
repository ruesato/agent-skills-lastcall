#!/usr/bin/env bash
# meter-session.sh — roll up one full Claude Code session: main thread + every
# subagent it spawned. Emits pure token/time/work counts as JSON.
#
#   meter-session.sh                  # current session, inferred from $PWD
#   meter-session.sh <session-uuid>   # a specific session
#
# No pricing here on purpose — rates come from the claude-api skill downstream,
# so this stays correct when prices change.
set -euo pipefail

ROOT="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"
IDLE_GAP_S="${IDLE_GAP_S:-300}"

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
if [ $# -ge 1 ]; then
  SID="$1"
elif [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  SID="$CLAUDE_SESSION_ID"
else
  [ -d "$PROJ" ] || { echo "no transcripts for $PWD" >&2; exit 1; }
  SID=$(newest_jsonl "$PROJ")
  [ -n "$SID" ] || { echo "no transcripts in $PROJ" >&2; exit 1; }
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
[ ${#MAINS[@]} -gt 0 ] || { echo "no transcript for $SID under $ROOT" >&2; exit 1; }

# Optional: the statusLine capture written by capture-statusline.sh. It is the
# only local source for rate_limits, which appear nowhere in a transcript, plus
# Claude Code own cost estimate and its API-wait total.
#
# Absence is the NORMAL case, not an error: the capture is opt-in, and even with
# it configured rate_limits only appear for Pro/Max subscribers after the first
# API response. A corrupt or foreign file is treated as absent too. Everything
# downstream omits the native block entirely rather than emitting zeroes — a
# session reporting 0% of the rate limit used would read as plenty of headroom.
CAPFILE="${LASTCALL_STATUSLINE_DIR:-$HOME/.claude/lastcall/statusline}/$SID.json"
CAP=null
if [ -f "$CAPFILE" ]; then
  # The filename is the session id, but the payload is checked against it too:
  # a store copied between machines, or a mangled write, must not be attributed
  # to the session being metered.
  CAP="$(jq -c --arg sid "$SID" \
        'select(.schema == "lastcall.statusline/1" and .payload.session_id == $sid)' \
        "$CAPFILE" 2>/dev/null)" || CAP=null
  [ -n "$CAP" ] || CAP=null
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
  jq -s --arg lane "$2" --argjson gap "$IDLE_GAP_S" '
    # Streaming emits one entry per chunk sharing a requestId. Collapsing each
    # group to its first entry is what stops totals from roughly doubling.
    # <synthetic> entries have a null requestId and all-zero usage; drop them.
    ( map(select(.type == "assistant"
                 and .message.model != "<synthetic>"
                 and .message.usage != null))
      | group_by(.requestId // .uuid) | map(.[0])
    ) as $turns

    # Timestamps carry milliseconds, which fromdateiso8601 rejects.
    | ( map(.timestamp | select(. != null)
            | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) | sort ) as $ts

    # Wall clock is meaningless for a resumed session, which can span days.
    # Only gaps shorter than $gap count as time actually spent working.
    | ( if ($ts | length) < 2 then 0
        else [ range(1; $ts|length) as $i
               | ($ts[$i] - $ts[$i-1]) | select(. <= $gap) ] | add // 0 end
      ) as $active

    # Claude Code writes one turn_duration record per COMPLETED user turn. It is
    # its own measure of how long the agent was busy, with no idle heuristic in
    # it — but the turn in flight has not been written yet, so this undercounts
    # a session metered mid-turn and is 0 for a session that has never finished
    # a turn. Reported beside $active, never instead of it.
    | ( map(select(.type == "system" and .subtype == "turn_duration")) ) as $td

    | ( map(select(.type == "assistant") | .message.content[]?
            | select(.type == "tool_use")) ) as $tools

    | {
        lane: $lane,
        cwd:     (map(.cwd // empty)       | first),
        branch:  (map(.gitBranch // empty) | last),
        first_ts: ($ts | first), last_ts: ($ts | last), active_s: $active,
        agent_s:     (($td | map(.durationMs) | add // 0) / 1000),
        agent_turns: ($td | length),
        # Grouped by the dimensions that change what a request BILLS at. speed
        # (fast mode) and service_tier (priority, batch) both do; collapsing
        # them would price a fast-mode session at standard rates and leave no
        # trace that it happened. Kept as recorded, so null means unrecorded
        # rather than standard.
        usage: ( $turns
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
} | jq -s --arg sid "$SID" --argjson agents "$(agents_json)" --argjson cap "$CAP" '
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

    { session: {
        id: $sid,
        # The LATEST main lane wins, not the first. A split session carries the
        # pre-rename path in its earlier part, and reporting that as the session
        # cwd points every consumer at a directory that no longer exists.
        cwd:    ((map(select(.lane == "main" and .cwd    != null)) | max_by(.last_ts) | .cwd)
                 // (map(.cwd    | select(.)) | first)),
        branch: ((map(select(.lane == "main" and .branch != null)) | max_by(.last_ts) | .branch)
                 // (map(.branch | select(.)) | first)),
        started: (map(.first_ts) | min | todateiso8601),
        ended:   (map(.last_ts) | max | todateiso8601),
        wall_s:  ((map(.last_ts) | max) - (map(.first_ts) | min)),
        # Main-thread active time only: subagents run concurrently, so adding
        # their spans would double-count the same minutes.
        # Summed across main lanes. A split session loses only the gap that
        # straddles the two files, which is the rename itself — seconds, and in
        # the conservative direction.
        active_s: (map(select(.lane=="main") | .active_s) | add // 0),
        # Native agent-busy time. Only the main thread emits turn_duration, and
        # only for turns that have ENDED, so this is a floor: a session metered
        # mid-turn is missing the turn being metered.
        agent_s:     (map(select(.lane=="main") | .agent_s)     | add // 0),
        agent_turns: (map(select(.lane=="main") | .agent_turns) | add // 0)
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
                    web_search: (map(.web_search) | add),
                    web_fetch:  (map(.web_fetch)  | add),
                    efforts:    (map(.efforts) | sum_maps)
                  }) ),
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
                  }) | sort_by(-(.output)) )
      },
      friction: {
        tool_errors: (map(.friction.tool_errors) | add),
        interrupts:  (map(.friction.interrupts)  | add),
        denials:     (map(.friction.denials)     | add)
      },
      # Slot for external work evidence (Fathom et al). Populated downstream.
      evidence: []
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
              rate_limits: ( $p.rate_limits
                | { five_hour: { used_percentage: .five_hour.used_percentage,
                                 resets_at:       .five_hour.resets_at,
                                 resets_at_utc:   (.five_hour.resets_at
                                                   | if . == null then null
                                                     else todateiso8601 end) },
                    seven_day: { used_percentage: .seven_day.used_percentage,
                                 resets_at:       .seven_day.resets_at,
                                 resets_at_utc:   (.seven_day.resets_at
                                                   | if . == null then null
                                                     else todateiso8601 end) } } ),

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
