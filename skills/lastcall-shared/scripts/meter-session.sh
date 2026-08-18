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
[ -d "$PROJ" ] || { echo "no transcripts for $PWD" >&2; exit 1; }

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
  SID=$(newest_jsonl "$PROJ")
  [ -n "$SID" ] || { echo "no transcripts in $PROJ" >&2; exit 1; }
fi

MAIN="$PROJ/$SID.jsonl"
[ -f "$MAIN" ] || { echo "no transcript: $MAIN" >&2; exit 1; }
SUBS=("$PROJ/$SID/subagents"/*.jsonl)
[ -e "${SUBS[0]}" ] || SUBS=()

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

    | ( map(select(.type == "assistant") | .message.content[]?
            | select(.type == "tool_use")) ) as $tools

    | {
        lane: $lane,
        cwd:     (map(.cwd // empty)       | first),
        branch:  (map(.gitBranch // empty) | last),
        first_ts: ($ts | first), last_ts: ($ts | last), active_s: $active,
        usage: ( $turns | group_by(.message.model) | map({
                   model: .[0].message.model,
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

{ meter_file "$MAIN" main
  # The trailing "true" matters: with pipefail, a session that spawned no
  # subagents would otherwise leave this block's status at 1 and fail the
  # pipeline despite jq having produced correct output.
  for f in "${SUBS[@]:-}"; do
    [ -f "$f" ] && meter_file "$f" subagent
  done
  true
} | jq -s --arg sid "$SID" --argjson agents "$(agents_json)" '
    { session: {
        id: $sid,
        cwd:    (map(.cwd    | select(.)) | first),
        branch: (map(.branch | select(.)) | first),
        started: (map(.first_ts) | min | todateiso8601),
        ended:   (map(.last_ts) | max | todateiso8601),
        wall_s:  ((map(.last_ts) | max) - (map(.first_ts) | min)),
        # Main-thread active time only: subagents run concurrently, so adding
        # their spans would double-count the same minutes.
        active_s: (map(select(.lane=="main") | .active_s) | add // 0)
      },
      # Grouped by (model, lane) because the two lanes use different cache TTLs.
      tokens: ( map(.lane as $l | .usage[] | . + {lane: $l})
                | group_by([.model, .lane]) | map({
                    model: .[0].model, lane: .[0].lane,
                    turns:      (map(.turns)      | add),
                    input:      (map(.input)      | add),
                    output:     (map(.output)     | add),
                    cache_read: (map(.cache_read) | add),
                    cache_w_5m: (map(.cache_w_5m) | add),
                    cache_w_1h: (map(.cache_w_1h) | add)
                  }) ),
      agents: $agents,
      # NB: object "+" overwrites duplicate keys rather than summing them, so
      # merging per-lane counts has to go through entries and add explicitly.
      work: {
        tools: (map(.tools) | [.[] | to_entries[]] | group_by(.key)
                | map({ (.[0].key): (map(.value) | add) }) | add // {}),
        files: (map(.files) | [.[] | to_entries[]] | group_by(.key)
                | map({ (.[0].key): (map(.value) | add) }) | add // {})
      },
      friction: {
        tool_errors: (map(.friction.tool_errors) | add),
        interrupts:  (map(.friction.interrupts)  | add),
        denials:     (map(.friction.denials)     | add)
      },
      # Slot for external work evidence (Fathom et al). Populated downstream.
      evidence: []
    }'
