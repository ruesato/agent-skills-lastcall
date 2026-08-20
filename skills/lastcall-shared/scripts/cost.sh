#!/usr/bin/env bash
# cost.sh — turn meter-session.sh output into dollars.
#
#   ./meter-session.sh | ./cost.sh
#   ./cost.sh < metered.json
#
# Deliberately separate from the meter: the meter counts tokens (which never
# change), this applies rates (which do). See ../references/pricing.md.
set -euo pipefail

# Resolve through symlinks: install.sh links this onto PATH, and rates.json
# lives beside the real file, not beside the link. `readlink -f` is GNU-only,
# so walk the chain by hand.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  target="$(readlink "$SELF")"
  case "$target" in /*) SELF="$target" ;; *) SELF="$(dirname "$SELF")/$target" ;; esac
done
HERE="$(cd "$(dirname "$SELF")" && pwd)"
RATES="${LASTCALL_RATES:-$HERE/rates.json}"
[ -f "$RATES" ] || { echo "no rate table at $RATES" >&2; exit 1; }

# WARNING: no apostrophes in the comments below. This jq program is a
# single-quoted shell string, and one apostrophe ends it early — the error then
# lands far from the typo. Write "the row", never a possessive.
DRIFT_PCT="${LASTCALL_COST_DRIFT_PCT:-25}"

jq -s --slurpfile r "$RATES" --argjson drift "$DRIFT_PCT" '
  # Transcripts carry dated model ids (claude-haiku-4-5-20251001); the rate
  # table is keyed on the bare alias.
  def norm: sub("-20[0-9]{6}$"; "");

  # Effective rate for a model id at a point in time. Token spend is dated: a
  # rate that was promotional when the tokens were burned still applies, even
  # if the promo has since lapsed.
  def eff($rates; $when):
    . as $model
    | ($rates.models[$model|norm]) as $rate
    | if $rate == null then
        # Fail loudly. A guessed rate is worse than no number at all, because
        # it silently poisons every ledger comparison downstream.
        error("unknown model \($model) (normalized: \($model|norm)) — add it to rates.json from the claude-api skill")
      else . end
    | if $rate.promo != null and $when <= ($rate.promo.until + "T23:59:59Z")
      then { input: $rate.promo.input, output: $rate.promo.output, promo: true }
      else { input: $rate.input,       output: $rate.output,       promo: false } end;

  # Dollars for one token row, given its rate and the structural multipliers.
  def usd($p; $mult):
    ( (.input      // 0) * $p.input
    + (.cache_read // 0) * $p.input * $mult.cache_read
    + (.cache_w_5m // 0) * $p.input * $mult.cache_write_5m
    + (.cache_w_1h // 0) * $p.input * $mult.cache_write_1h
    + (.output     // 0) * $p.output
    ) / 1000000;

  def r4: . * 10000 | round / 10000;
  def r1: . * 10 | round / 10;

  .[0] as $m | $r[0] as $rates
  | ($m.session.ended // "1970-01-01") as $when
  | ($rates.multipliers) as $mult

  | ($m.tokens | map(. + { p: (.model | eff($rates; $when)) })) as $priced

  # Skill attribution comes from the transcript, so it prices with the same
  # table. Rows lacking the pricing dimensions price at list rates.
  | (($m.work.skills // []) | map(. + { p: (.model | eff($rates; $when)) })) as $skilled

  | ($priced | map(usd(.p; $mult)) | add // 0 | r4) as $total

  # Advisory cross-check against the figure Claude Code computed for itself,
  # captured from the statusLine. Two independently derived numbers over the
  # same session should roughly agree; when they do not, a stale rates.json is
  # the likely cause, which is the failure pricing_source exists to expose but
  # cannot detect on its own.
  #
  # ADVISORY ONLY. Never substitute their number and never correct ours: theirs
  # is documented as a client-side estimate that may differ from the actual
  # bill, and it has no visible handling of fast mode or service tiers, which
  # this table does track.
  | ($m.native // null) as $n
  | ( if $n == null or $n.cost_usd == null then null
      else
        (($n.wall_ms // null) | if . == null then null else . / 1000 end) as $nwall
        | ($m.session.wall_s // 0) as $owall
        # Comparability is decided by the SPANS, not by guessing at resume
        # semantics. Their clock resets when /clear starts a new session, and
        # whether it survives a resume is unmeasured. Their capture is also only
        # as fresh as the last status line render. Both failures look the same
        # from here: their clock covers less time than the transcript does, so
        # their cost covers less work than ours. One test catches both, and it
        # stays correct whichever way the resume question resolves.
        | ($nwall != null and $owall > 0 and ($nwall >= ($owall * 0.9))) as $ok
        | { native_usd: $n.cost_usd, ours_usd: $total, comparable: $ok,
            native_captured_at: $n.captured_at }
          + ( if $ok | not then
                { skipped_reason: (if $nwall == null
                    then "no wall clock in the capture"
                    else "the Claude Code clock covers \($nwall | floor)s of a \($owall | floor)s transcript span — a resumed session or a stale capture, so the two figures do not cover the same work"
                    end) }
              elif $total <= 0 or $n.cost_usd <= 0 then
                { skipped_reason: "one of the two figures is zero" }
              else
                ((($total - $n.cost_usd) | fabs) / ([$total, $n.cost_usd] | max) * 100 | r1) as $d
                | { delta_pct: $d, diverged: ($d > $drift) }
              end )
      end ) as $xcheck

  # Anything that makes this total an understatement or an approximation says
  # so here, rather than being folded silently into the number.
  | ( [ $m.tokens[]
        | select((.speed // "standard") != "standard"
                 or (.service_tier // "standard") != "standard")
        | "\(.model) (\(.lane)): speed=\(.speed // "unrecorded") service_tier=\(.service_tier // "unrecorded") — priced at standard rates; rates.json has no tier axis"
      ]
      + ( ([ $m.tokens[] | .web_search // 0 ] | add // 0)
          | if . > 0 then
              ["\(.) web search calls carry per-request spend that no token bucket expresses — NOT in this total"]
            else [] end )
      # Divergence names both numbers and points at the rate table. It never
      # says which one is right, because this cannot know.
      + ( if ($xcheck.diverged // false) then
            ["this total is $\($total) but Claude Code own estimate for the same session is $\($xcheck.native_usd) (\($xcheck.delta_pct)% apart) — rates.json (\($rates.source)@\($rates.verified_on)) may be stale; refresh it from the claude-api skill"]
          else [] end )
    ) as $caveats

  | {
      total_usd: $total,
      by_model:  ($priced | map({ model, lane, speed, service_tier,
                                  usd: (usd(.p; $mult) | r4),
                                  promo_applied: .p.promo })),

      # Rollup, because consumers read the top level. Without this the key was
      # absent entirely, so `.promo_applied` came back null on a session that
      # really did bill at promotional rates, and the readout dropped it.
      # True when ANY lane billed at a promo: a mixed session is the common
      # case, and promo_models says which, so "partly promotional" is
      # reportable instead of collapsing to a misleading yes/no.
      promo_applied: ($priced | map(.p.promo) | any),
      promo_models:  ($priced | map(select(.p.promo) | .model) | unique),

      # Where the money actually went, in dollars rather than tokens.
      by_bucket: {
        input:       ($priced | map((.input      // 0) * .p.input) | add // 0),
        cache_read:  ($priced | map((.cache_read // 0) * .p.input * $mult.cache_read) | add // 0),
        cache_write: ($priced | map(((.cache_w_5m // 0) * $mult.cache_write_5m
                                   + (.cache_w_1h // 0) * $mult.cache_write_1h) * .p.input) | add // 0),
        output:      ($priced | map((.output     // 0) * .p.output) | add // 0)
      } | with_entries(.value |= (. / 1000000 | r4)),

      # What each skill cost. The null skill is the unattributed remainder —
      # kept, because without it the parts stop summing to the whole.
      by_skill: ($skilled
                 | map({ skill, plugin, model, turns, usd: (usd(.p; $mult) | r4) })
                 | sort_by(-.usd)),

      # Reasoning share of output. A subset of output spend, never an addition
      # to it — reported so a jump in output tokens can be told apart from a
      # jump in thinking.
      thinking_tokens: ([ $m.tokens[] | .thinking // 0 ] | add // 0),

      # Per-request tool spend. No token bucket can express it, so this
      # total does not price it — see caveats.
      server_tools: {
        web_search_requests: ([ $m.tokens[] | .web_search // 0 ] | add // 0),
        web_fetch_requests:  ([ $m.tokens[] | .web_fetch  // 0 ] | add // 0)
      },

      caveats: $caveats,

      # Required by the ledger contract: a cost figure whose rate table is
      # unknown cannot be compared against other rows.
      pricing_source: "\($rates.source)@\($rates.verified_on)"
    }
    # Absent whenever no statusLine capture supplied a native figure, which is
    # the normal case. Absent means unchecked, never means agreed.
    + (if $xcheck == null then {} else { cross_check: $xcheck } end)
' -
