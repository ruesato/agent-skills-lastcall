#!/usr/bin/env bash
# cost.sh — turn meter-session.sh output into dollars.
#
#   ./meter-session.sh | ./cost.sh
#   ./cost.sh < metered.json
#
# Deliberately separate from the meter: the meter counts tokens (which never
# change), this applies rates (which do). See ../references/pricing.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RATES="${LASTCALL_RATES:-$HERE/rates.json}"
[ -f "$RATES" ] || { echo "no rate table at $RATES" >&2; exit 1; }

jq -s --slurpfile r "$RATES" '
  .[0] as $m | $r[0] as $rates

  # Token spend is dated: a rate that was promotional when the tokens were
  # burned still applies, even if the promo has since lapsed. Bill against the
  # session end date, not today.
  | ($m.session.ended // "1970-01-01") as $when

  | ($rates.multipliers) as $mult
  | ($m.tokens | map(
      # Transcripts carry dated model ids (claude-haiku-4-5-20251001); the rate
      # table is keyed on the bare alias.
      ( .model
        | sub("-20[0-9]{6}$"; "")
      ) as $key
      | ($rates.models[$key]) as $rate
      | if $rate == null then
          # Fail loudly. A guessed rate is worse than no number at all,
          # because it silently poisons every ledger comparison downstream.
          error("unknown model \(.model) (normalized: \($key)) — add it to rates.json from the claude-api skill")
        else . end

      # Promotional rates apply only while the promo is live.
      | (if $rate.promo != null and $when <= ($rate.promo.until + "T23:59:59Z")
         then { input: $rate.promo.input, output: $rate.promo.output, promo: true }
         else { input: $rate.input, output: $rate.output, promo: false } end) as $p

      | . + {
          usd: ( ( .input      * $p.input
                 + .cache_read * $p.input * $mult.cache_read
                 + .cache_w_5m * $p.input * $mult.cache_write_5m
                 + .cache_w_1h * $p.input * $mult.cache_write_1h
                 + .output     * $p.output
                 ) / 1000000 ),
          promo_applied: $p.promo
        }
    )) as $priced

  | {
      total_usd: ($priced | map(.usd) | add | .*10000 | round / 10000),
      by_model:  ($priced | map({model, lane, usd: (.usd*10000|round/10000), promo_applied})),

      # Where the money actually went, in dollars rather than tokens.
      by_bucket: {
        input:       ($priced | map(.input      * (if .promo_applied then $rates.models[(.model|sub("-20[0-9]{6}$";""))].promo.input else $rates.models[(.model|sub("-20[0-9]{6}$";""))].input end)) | add / 1000000),
        cache_read:  ($priced | map(.cache_read * (if .promo_applied then $rates.models[(.model|sub("-20[0-9]{6}$";""))].promo.input else $rates.models[(.model|sub("-20[0-9]{6}$";""))].input end) * $mult.cache_read) | add / 1000000),
        cache_write: ($priced | map((.cache_w_5m * $mult.cache_write_5m + .cache_w_1h * $mult.cache_write_1h) * (if .promo_applied then $rates.models[(.model|sub("-20[0-9]{6}$";""))].promo.input else $rates.models[(.model|sub("-20[0-9]{6}$";""))].input end)) | add / 1000000),
        output:      ($priced | map(.output     * (if .promo_applied then $rates.models[(.model|sub("-20[0-9]{6}$";""))].promo.output else $rates.models[(.model|sub("-20[0-9]{6}$";""))].output end)) | add / 1000000)
      } | with_entries(.value |= (.*10000|round/10000)),

      # Required by the ledger contract: a cost figure whose rate table is
      # unknown cannot be compared against other rows.
      pricing_source: "\($rates.source)@\($rates.verified_on)"
    }
' -
