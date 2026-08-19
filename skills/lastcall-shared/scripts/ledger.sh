#!/usr/bin/env bash
# ledger.sh — session history, and the baseline that makes ratios mean something.
#
#   meter-session.sh <id> | ledger.sh append [sha ...]   # write/replace this row
#   ledger.sh trend [session-id]                 # baseline, optionally comparing one session
#   ledger.sh list [--cwd PATH]                  # dump rows
#
# Any SHAs passed to `append` land in work.commits — lastcall passes the
# commits its delegation actually created.
#
# Written by lastcall only. tally never writes.
set -euo pipefail

# Resolve through symlinks — see cost.sh for why.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  target="$(readlink "$SELF")"
  case "$target" in /*) SELF="$target" ;; *) SELF="$(dirname "$SELF")/$target" ;; esac
done
HERE="$(cd "$(dirname "$SELF")" && pwd)"
LEDGER="${LASTCALL_LEDGER:-$HOME/.claude/lastcall/ledger.jsonl}"
PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"
COST="$HERE/cost.sh"

slug() { printf '%s' "$1" | sed 's|[^a-zA-Z0-9-]|-|g'; }

# Evidence for a session, reduced to counts. Absent evidence is reported as
# absent, never as zero completed tasks — see contracts.md section 3.
evidence_for() {
  local sid="$1" cwd="$2" dir
  dir="$PROJECTS/$(slug "$cwd")/$sid/evidence"
  if [ ! -d "$dir" ]; then printf '%s' 'null'; return; fi

  local files=("$dir"/*.json)
  [ -e "${files[0]}" ] || { printf '%s' 'null'; return; }

  # Skip unparseable files with a warning rather than aborting.
  local ok=() f
  for f in "${files[@]}"; do
    if jq -e . "$f" >/dev/null 2>&1; then ok+=("$f")
    else echo "ledger: skipping unparseable evidence $f" >&2; fi
  done
  [ ${#ok[@]} -gt 0 ] || { printf '%s' 'null'; return; }

  jq -s '
    # Dedupe on (source, task.id), keeping the highest emitted_at: a task
    # re-emitted as completed supersedes its earlier partial.
    ( map(. as $d | (.tasks // [])[] | {source: $d.source, emitted_at: $d.emitted_at} + .)
      | group_by([.source, .id])
      | map(max_by(.emitted_at))
    ) as $t
    | { sources:    (map(.source) | unique),
        completed:  ($t | map(select(.status=="completed"))  | length),
        partial:    ($t | map(select(.status=="partial"))    | length),
        blocked:    ($t | map(select(.status=="blocked"))    | length),
        abandoned:  ($t | map(select(.status=="abandoned"))  | length),
        # A completed task with no artifacts is unverified, not counted.
        unverified: ($t | map(select(.status=="completed" and ((.artifacts // []) | length) == 0)) | length)
      }' "${ok[@]}"
}

cmd_append() {
  local meter cost sid cwd ev row commits
  # Commits created by lastcall's delegation, if any. Passed in rather than
  # derived: only the caller knows which commits belong to this session.
  commits="$(printf '%s\n' "$@" | jq -Rs 'split("\n") | map(select(length > 0))')"
  meter="$(cat)"
  cost="$(printf '%s' "$meter" | "$COST")"
  sid="$(printf '%s' "$meter" | jq -r '.session.id')"
  cwd="$(printf '%s' "$meter" | jq -r '.session.cwd')"
  ev="$(evidence_for "$sid" "$cwd")"

  row=$(jq -cn --argjson m "$meter" --argjson c "$cost" --argjson e "$ev" \
              --argjson commits "$commits" '
    { schema: "lastcall.ledger/1",
      session_id: $m.session.id,
      metered_at: (now | todateiso8601),
      cwd: $m.session.cwd, branch: $m.session.branch,
      started: $m.session.started, ended: $m.session.ended,
      active_s: $m.session.active_s,
      # promo state is recorded per row because a promo expiry moves the cost
      # of every later row without any behavior changing. Without it, a trend
      # spanning the boundary shows a step change that cannot be attributed.
      # No apostrophes here: the whole program is single-quoted in sh.
      cost: { usd: $c.total_usd, by_model: $c.by_model,
              pricing_source: $c.pricing_source,
              promo_applied: $c.promo_applied, promo_models: $c.promo_models },
      tokens: $m.tokens,
      work: { tool_calls: ($m.work.tools | to_entries | map(.value) | add // 0),
              files_changed: ($m.work.files | length),
              commits: $commits },
      friction: $m.friction,
      # null, not zeroes: "no evidence" and "zero tasks done" are different claims.
      evidence: $e }')

  mkdir -p "$(dirname "$LEDGER")"
  touch "$LEDGER"
  # Replace this session's row in place rather than appending a duplicate.
  # Keyed on session_id alone — metered_at is freshness, not identity.
  local tmp; tmp="$(mktemp)"
  jq -c --arg sid "$sid" 'select(.session_id != $sid)' "$LEDGER" > "$tmp" 2>/dev/null || true
  printf '%s\n' "$row" >> "$tmp"
  mv "$tmp" "$LEDGER"        # atomic; a torn ledger loses the whole baseline
  printf '%s\n' "$row"
}

cmd_list() {
  [ -f "$LEDGER" ] || return 0
  if [ "${1:-}" = "--cwd" ]; then jq -c --arg c "${2:?--cwd needs a path}" 'select(.cwd == $c)' "$LEDGER"
  else jq -c . "$LEDGER"; fi
}

cmd_trend() {
  local focus="${1:-}"
  [ -f "$LEDGER" ] || { echo '{"sessions":0,"note":"no ledger yet"}'; return; }

  jq -s --arg focus "$focus" '
    def pct($p): if length == 0 then null
                 else sort | .[ (((length - 1) * $p) | floor) ] end;
    def r2: if . == null then null else (.*100|round)/100 end;

    . as $all
    # Per-task ratios need evidence. Rows without it stay in the per-session
    # stats but are excluded here — inferring tasks from token burn would
    # reward thrashing.
    | (map(select(.evidence != null and .evidence.completed > 0))) as $withev

    | { sessions: ($all | length),
        with_evidence: ($withev | length),

        per_session: {
          usd_median:        ($all | map(.cost.usd) | pct(0.5) | r2),
          usd_p90:           ($all | map(.cost.usd) | pct(0.9) | r2),
          active_min_median: ($all | map(.active_s/60) | pct(0.5) | r2),
          friction_per_100_median:
            ($all | map(
               (.friction.tool_errors + .friction.interrupts + .friction.denials)
               / (if .work.tool_calls > 0 then .work.tool_calls else 1 end) * 100)
             | pct(0.5) | r2)
        },

        per_task: (if ($withev | length) == 0 then null else {
          usd_median:        ($withev | map(.cost.usd / .evidence.completed) | pct(0.5) | r2),
          active_min_median: ($withev | map((.active_s/60) / .evidence.completed) | pct(0.5) | r2)
        } end),

        pricing_sources: ($all | map(.cost.pricing_source) | unique),

        # A promo expiring re-prices every later session without anything about
        # the work changing. Say so, rather than letting a reader attribute the
        # step to their own behavior. Rows written before promo state was
        # recorded carry null, which is "unknown", not "no promo".
        pricing_regimes:
          (($all | map(.cost.promo_applied)) as $p
           | { promotional: ($p | map(select(. == true))  | length),
               full_rate:   ($p | map(select(. == false)) | length),
               unknown:     ($p | map(select(. == null))  | length) }
           | . + (if (.promotional > 0 and .full_rate > 0)
                  then { note: "these rows span a pricing change — a step in this trend may be a rate change, not a behavior change" }
                  else {} end))
      }
    # A single row is not a baseline. Say so rather than reporting a "median"
    # of one and letting a reader treat it as typical.
    + (if ($all | length) < 5
       then { baseline_note: "only \($all|length) session(s) — too few for a meaningful baseline" }
       else {} end)
    + (if $focus == "" then {} else
        ($all | map(select(.session_id == $focus)) | first) as $s
        | if $s == null then { focus: { error: "session \($focus) not in ledger" } }
          else
            # Compare against PEERS, not against every row. Including the focus
            # session in its own baseline drags the median toward itself, and at
            # small n the median can land exactly on it — which produced a
            # confident "1x" that meant nothing. Stay silent below the same
            # threshold that triggers baseline_note: a ratio against one or two
            # other sessions is noise presented as a finding.
            ($all | map(select(.session_id != $focus))) as $peers
          | { focus: {
              session_id: $s.session_id,
              usd: $s.cost.usd,
              vs_median_usd:
                (($peers | map(.cost.usd) | pct(0.5)) as $m
                 | if $m == null or $m == 0 or ($peers | length) < 5 then null
                   else "\((($s.cost.usd / $m)*10|round)/10)x" end),
              vs_median_basis:
                (if ($peers | length) < 5
                 then "suppressed — only \($peers|length) other session(s) to compare against"
                 else "median of \($peers|length) other sessions" end),
              per_task_usd: (if $s.evidence != null and $s.evidence.completed > 0
                             then ($s.cost.usd / $s.evidence.completed | r2) else null end)
            } } end
       end)
  ' "$LEDGER"
}

case "${1:-}" in
  append) shift; cmd_append "$@" ;;
  trend)  shift; cmd_trend "$@" ;;
  list)   shift; cmd_list "$@" ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
