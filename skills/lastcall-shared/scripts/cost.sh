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

  # Reasoning is billed once as output and then re-read as cache on every later
  # turn of the same context, so its true cost is not the output line. The meter
  # supplies the token-weight of that carry; this is the only place a rate is
  # applied to it. Cache reads bill at the cache_read multiplier of input, NOT
  # at a per-model dollar constant — a constant taken from one model silently
  # misprices every other lane.
  #
  # null, never 0, when no token row carries the field: that is meter output
  # written before this existed, which is unmeasured.
  | ( if ($priced | map(has("thinking_carry")) | any)
      then ($priced | map((.thinking_carry // 0) * .p.input * $mult.cache_read)
            | add // 0 | . / 1000000 | r4)
      else null end ) as $tcarry

  # What the cache re-establishment events actually cost. Rewrites bill at 1.25x
  # (5m) or 2.00x (1h) input where a read bills at 0.10x, which is the whole
  # reason the events are worth separating out of the cache_w_* aggregate.
  #
  # ABSENT and ZERO are different answers and the test keeps them apart. A
  # session that had no re-establishment events measured zero of them, which is
  # good news worth reporting; meter output predating this block measured
  # nothing at all. Testing the block for emptiness would collapse the first
  # into the second and report a clean session as unmeasured.
  | ( ($m.cache_reestablish // null) as $cr
      | if ($m | has("cache_reestablish") | not) or $cr == null then null
        else ( $cr.by_model | map(. + { p: (.model | eff($rates; $when)) })
               | map((((.tokens_5m // 0) * $mult.cache_write_5m
                     + (.tokens_1h // 0) * $mult.cache_write_1h) * .p.input))
               | add // 0 | . / 1000000 | r4 ) as $u
             | { events:         $cr.events,
                 tokens:         $cr.tokens,
                 usd:            $u,
                 writing_turns:  $cr.writing_turns,
                 threshold_ratio: $cr.threshold_ratio,
                 largest: ( $cr.largest
                            | if . == null then null
                              else . + { usd: (((((.tokens_5m // 0) * $mult.cache_write_5m
                                                + (.tokens_1h // 0) * $mult.cache_write_1h)
                                                * (.model | eff($rates; $when)).input)
                                               / 1000000) | r4) } end ),
                 detail: ($cr.detail // []) }
        end ) as $reest

  # What each tool put in the window, and what carrying it cost. APPROXIMATE by
  # construction: payload sizes are chars/4 with a flat figure for images, and
  # carry assumes every later turn re-read the whole prefix.
  # Same absent-vs-empty rule as cache_reestablish above: a session that called
  # no tools has an empty table, which is a fact; an older meter row has none.
  | ( ($m.work.tool_context // null) as $tc
      | if (($m.work // {}) | has("tool_context") | not) or $tc == null then null
        else $tc
             | map(. + { _carry_usd: ((.carry_tokens // 0)
                                      * (.model | eff($rates; $when)).input
                                      * $mult.cache_read / 1000000) })
             | group_by(.tool)
             | map({ tool: .[0].tool,
                     calls:          (map(.calls) | add),
                     payload_tokens: (map(.payload_tokens) | add),
                     carry_usd:      (map(._carry_usd) | add | r4) })
             | map(. + { avg_tokens: ((.payload_tokens / .calls) | round) })
             | sort_by(-(.carry_usd))
        end ) as $toolctx

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
      # The streaming dedup groups on the first of requestId / message.id
      # present, falling back to uuid, which is unique per entry. rid 0 with a
      # positive mid_coverage is the Bedrock envelope handled by the fallback:
      # silent. rid 0 with mid 0 means NEITHER identifier was found and nothing
      # was collapsed -- either the transcript genuinely has one entry per
      # turn, or the identifier moved to a field this version does not know
      # and totals are inflated by the duplicate chunks. A null mid_coverage
      # is meter JSON saved before the field existed; warn there too, because
      # pre-fix Bedrock rows are exactly the ones already inflated. Explicit
      # null tests, not //: coverage of 0 is exactly the value being looked
      # for and // would discard it.
      + ( ($m.session.dedup // null) as $d
          | if $d == null or $d.rid_coverage == null then []
            elif $d.rid_coverage == 0
                 and ($d.mid_coverage == null or $d.mid_coverage == 0) then
              ["no assistant entry in this transcript carries requestId, and none measurably carries message.id, so the streaming dedup fell through to uuid for all \($d.entries) of them and collapsed nothing -- if the response identifier moved to a field this version does not know, this total is inflated by the duplicate chunks"]
            else [] end )
      # A tool_result whose tool_use is not in the transcript cannot be attributed
      # to a tool, so the tool_context table covers less than the session did.
      # Said out loud, because a short table otherwise reads as light tool usage.
      + ( ($m.work.tool_context_coverage // null) as $c
          | if $c == null or ($c.unmatched // 0) == 0 then []
            else ["\($c.unmatched) of \($c.results) tool results could not be matched to the call that produced them, so tool_context covers only part of this session"]
            end )
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
      #
      # usd_per_turn is here because the raw usd invites a misreading: a row is
      # dominated by how many turns the skill held attribution times how much
      # context was resident, so a cheap skill invoked deep into a large session
      # outscores an expensive one invoked early. Per-turn normalizes the first
      # of those. Neither figure answers "what does this skill cost to load" —
      # work.skill_load[].load_tokens is the metric for that.
      by_skill: ($skilled
                 | map({ skill, plugin, model, turns, usd: (usd(.p; $mult) | r4) }
                        | . + { usd_per_turn: (if (.turns // 0) > 0
                                               then (.usd / .turns | r4) else null end) })
                 | sort_by(-.usd)),

      # Reasoning share of output. A subset of output spend, never an addition
      # to it — reported so a jump in output tokens can be told apart from a
      # jump in thinking.
      thinking_tokens: ([ $m.tokens[] | .thinking // 0 ] | add // 0),

      # Effort mix, straight from the meter. Claude Code has recorded reasoning
      # effort per turn all along and nothing downstream has ever said so out
      # loud. It is a pricing lever the user controls, unlike most of this row.
      effort: ($m.session.effort // null),

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
    # Each of the three below is absent rather than zero when the meter did not
    # supply its input — meter output written before these existed is unmeasured,
    # and a zero here would read as "this cost nothing".
    + (if $tcarry  == null then {} else { thinking_carry_usd: $tcarry } end)
    + (if $reest   == null then {} else { cache_reestablish: $reest } end)
    + (if $toolctx == null then {} else { tool_context: $toolctx } end)
' -
