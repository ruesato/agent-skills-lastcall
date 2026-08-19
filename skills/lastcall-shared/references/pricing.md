# Pricing

How token counts become dollars. The meter deliberately does not do this —
token counts never change, rates do.

- `../scripts/rates.json` — the data
- `../scripts/cost.sh` — the computation

## The formula

Per model, per lane:

```
usd = ( input      × Pin
      + cache_read × Pin × 0.10
      + cache_w_5m × Pin × 1.25
      + cache_w_1h × Pin × 2.00
      + output     × Pout
      ) / 1_000_000
```

The three multipliers are **structural** — they're defined as ratios of the
model's base input price and don't vary by model. `Pin`/`Pout` are per-model
and come from the rate table.

## Why cache dominates

Applied to a real measured session, in dollars rather than tokens:

```
cache_write  $8.36   49%
cache_read   $5.57   33%
output       $2.99   18%
input        $0.00    0%
             ─────
             $16.93
```

**82% of the bill was cache traffic.** A cost layer that prices only the
visible input and output tokens describes under a fifth of the spend. This is
why `meter-session.sh` keeps five separate buckets instead of two, and why
`cache_w_5m` and `cache_w_1h` are never summed — they bill at different
multipliers, and main threads and subagents use different TTLs.

## What this formula does not price

Two kinds of spend exist in the meter output and have **no rate in the table**.
`cost.sh` reports them under `caveats` rather than folding them in, because a
total that silently omits them looks complete:

- **Server tools.** `web_search` and `web_fetch` requests bill **per request,
  not per token**, so no token bucket can express them. The meter counts them;
  `cost.sh` names the count and excludes it from `total_usd`.
- **Non-standard pricing dimensions.** `speed` (fast mode) and `service_tier`
  (priority, batch) change what a request bills at, and `rates.json` has no axis
  for either. Such a row is priced at standard rates **and flagged**. Never
  quietly accept the standard-rate figure for it.

`thinking` is the opposite case: it is already inside `output` and priced there.
Never add it to a total.

## Skill attribution

Claude Code writes `attributionSkill` / `attributionPlugin` onto assistant turns,
so `cost.sh` can report `by_skill` — what each skill cost — with the same rate
table. The row with `skill: null` is the unattributed remainder; keep it, or the
parts stop summing to the whole. `verify.sh` asserts that sum.

## Rules

**Never hardcode rates.** They live in `rates.json`, refreshed from the
`claude-api` skill. Never edit that file from memory — the whole point of the
indirection is that it is refreshed from a source of truth.

**Fail loudly on an unknown model.** `cost.sh` errors rather than guessing:

```
jq: error: unknown model claude-nonexistent-9 — add it to rates.json
```

A guessed rate is worse than no figure, because it silently poisons every
ledger comparison downstream. Ledger rows are only comparable if their
`pricing_source` is known — hence the required field on every row.

**Bill against the session's end date, not today.** Tokens burned under a
promotional rate stay billed at that rate after the promo lapses. `cost.sh`
compares `session.ended` to each promo's `until`:

| Session ended | Sonnet 5, 1M in + 1M out | Rate |
|---|---|---|
| 2026-08-17 | $12.00 | promo ($2 / $10) |
| 2026-09-01 | $18.00 | list ($3 / $15) |

⚠️ **Sonnet 5's introductory pricing ends 2026-08-31.** Sessions after that
date bill 50% higher. Any trend line spanning the boundary will show a step
change that is a *pricing* change, not a behavior change — `pricing_source`
and `promo_applied` are what let a reader tell those apart.

**Dated model ids normalize.** Transcripts carry
`claude-haiku-4-5-20251001`; the rate table is keyed on the bare alias. The
trailing `-YYYYMMDD` is stripped before lookup.

## Refreshing the table

Load the `claude-api` skill and ask for current per-model input/output rates
plus the cache multipliers. Update `rates.json`, and bump `verified_on` —
that date is what `pricing_source` reports into the ledger, so a stale table
is at least an *identifiable* stale table.

Rates last verified: see `verified_on` in `rates.json`.
