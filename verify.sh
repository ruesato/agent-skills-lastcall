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

# Never touch the real baseline. A verification run that pollutes the ledger it
# is verifying would corrupt every trend comparison downstream.
LEDGER="$(mktemp -t lastcall-verify)"
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
sessions=0; withsub=0
for f in "$PROJECTS"/*/*.jsonl; do
  [ -f "$f" ] || continue
  sid="$(basename "$f" .jsonl)"
  # The meter resolves its project directory from $PWD, so each session must be
  # metered from the cwd its transcript recorded. Passing a bare id from the
  # wrong directory reports a spurious failure.
  cwd="$(jq -rs 'map(.cwd // empty) | first // empty' "$f" 2>/dev/null)"
  [ -n "$cwd" ] && [ -d "$cwd" ] || continue
  sessions=$((sessions+1))

  out="$(cd "$cwd" && "$S/meter-session.sh" "$sid" 2>/dev/null)"
  if [ -z "$out" ] || ! printf '%s' "$out" | jq -e '.session.id' >/dev/null 2>&1; then
    bad "meter $sid"; continue
  fi
  ok
  [ "$(printf '%s' "$out" | jq '.agents | length')" -gt 0 ] && withsub=$((withsub+1))

  c="$(printf '%s' "$out" | "$S/cost.sh" 2>/dev/null)"
  if printf '%s' "$c" | jq -e '.total_usd >= 0' >/dev/null 2>&1; then ok
  else bad "cost $sid"; fi
  # promo_applied must be a real boolean — it was absent once, and consumers
  # reading a missing key silently dropped the promotional-pricing signal.
  if printf '%s' "$c" | jq -e '.promo_applied | type == "boolean"' >/dev/null 2>&1; then ok
  else bad "cost $sid: promo_applied is not a boolean"; fi

  if (cd "$cwd" && printf '%s' "$out" | "$S/openloops.sh" >/dev/null 2>&1); then ok
  else bad "openloops $sid"; fi
  # Churn must stay inside the project: a scratchpad temp file is not a
  # struggle signature.
  ext="$(cd "$cwd" && printf '%s' "$out" | "$S/openloops.sh" 2>/dev/null \
        | jq --arg c "$cwd" '[.churn_hotspots[]?.file | select(startswith($c) | not)] | length')"
  if [ "${ext:-1}" = "0" ]; then ok; else bad "openloops $sid: churn includes out-of-project files"; fi

  if printf '%s' "$out" | "$S/ledger.sh" append >/dev/null 2>&1; then ok
  else bad "ledger $sid"; fi
done
say "  $sessions sessions ($withsub with subagents)"

# ------------------------------------------------------------ invariants
say "== invariants =="
# One row per session: append replaces in place, so a re-run must not grow it.
rows_before="$(wc -l < "$LEDGER" | tr -d ' ')"
for f in "$PROJECTS"/*/*.jsonl; do
  [ -f "$f" ] || continue
  sid="$(basename "$f" .jsonl)"
  cwd="$(jq -rs 'map(.cwd // empty) | first // empty' "$f" 2>/dev/null)"
  [ -n "$cwd" ] && [ -d "$cwd" ] || continue
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

# ---------------------------------------------------------------- result
echo
if [ "$fail" -eq 0 ]; then
  echo "PASS  $pass checks, $sessions sessions"
else
  echo "FAIL  $fail failed, $pass passed" >&2
fi
exit $(( fail > 0 ? 1 : 0 ))
