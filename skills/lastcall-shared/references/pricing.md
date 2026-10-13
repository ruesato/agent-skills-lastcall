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

The cache-write multipliers are **structural** — ratios of the model's base
input price that hold for every model on the pricing page. The cache-read
multiplier is 0.10 for most models, but the page lists **0.05 for Opus 5.5 and
Sonnet 5.5 and 0.025 for Fable 5.1**, so a model in `rates.json` may carry its
own `cache_read` and the table-wide 0.10 is only the fallback. Using 0.10 for
Sonnet 5.5 overstates its cache reads by 2x, and on a long session cache reads
are a third of the bill. `Pin`/`Pout` are per-model and come from the rate
table.

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
  quietly accept the standard-rate figure for it. (Fast mode on the pricing page
  is $8 in / $40 out for Opus 5.5 and $10 / $50 for Opus 5 and 4.8, as of
  2026-10-12.)
- **Prompt-length pricing.** Haiku 5.5 bills a request at higher rates when its
  prompt is over 100,000 tokens, cache reads and writes included. The meter keeps
  token totals per lane, not prompt size per request, so `cost.sh` prices Haiku
  5.5 at the base rate, flags it from the model's `long_prompt` entry, and the
  figure can only understate.

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

`rates.json` has **no promotional rate at the moment**, but the mechanism stays:
add a `promo` block with an `until` date to a model and `cost.sh` applies it to
sessions that ended on or before that date.

History worth knowing: Sonnet 5 launched at an introductory $2 / $10 through
2026-08-31, with $3 / $15 scheduled for 2026-09-01. The pricing page now says
that increase **will not occur**, and $2 / $10 is the standard price. Until
2026-10-12 this table still carried the lapsing promo, which would have billed
any later Sonnet 5 session at $3 / $15, 50% too high. No ledger row was affected
(the last Sonnet 5 session ended 2026-08-30), but a trend line that spans a
pricing change should still be read through `pricing_source` and
`promo_applied`.

**Dated model ids normalize.** Transcripts carry
`claude-haiku-4-5-20251001`; the rate table is keyed on the bare alias. The
trailing `-YYYYMMDD` is stripped before lookup.

## Refreshing the table

Read the model table on the pricing page
(`https://platform.claude.com/docs/en/about-claude/pricing`), or load the
`claude-api` skill, for current per-model input and output rates and the
cache multipliers. Check each row's cache-hit price against 0.10x of its input
price, and give any model that differs its own `cache_read`. Update
`rates.json`, and bump `verified_on` and `source` — together they are what
`pricing_source` reports into the ledger, so a stale table is at least an
*identifiable* stale table. The 2026-10-12 refresh read the page directly,
which is why `source` names it instead of `claude-api`.

Rates last verified: see `verified_on` in `rates.json`.
