#!/usr/bin/env bash
# ledger.sh — session history, and the baseline that makes ratios mean something.
#
#   meter-session.sh <id> | ledger.sh append [sha ...]   # write/replace this row
#   ledger.sh trend [session-id]                 # baseline, optionally comparing one session
#   ledger.sh list [--cwd PATH]                  # dump rows
#
# work.commits is discovered from the metered window, so commits made by another
# skill during the session are counted. Any SHAs passed to `append` are unioned
# in on top of that.
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
# The evidence drop-box. Mirrors the statusline store (meter-session.sh:78),
# including the env override, so both of lastcall own stores live under a
# directory lastcall controls rather than inside the harness transcript tree.
EVIDENCE="${LASTCALL_EVIDENCE_DIR:-$HOME/.claude/lastcall/evidence}"
COST="$HERE/cost.sh"


# Evidence for a session, reduced to counts. Absent evidence is reported as
# absent, never as zero completed tasks — see contracts.md section 3.
#
# Keyed on the session id ALONE. It used to resolve $PROJECTS/<cwd-slug>/$sid,
# which broke in two ways that both lose evidence silently. A session outliving
# a directory rename splits across two project dirs under one id, so picking one
# drops the other (the same hazard meter-session.sh:46-56 documents, measured
# there at 822 lines counted and 63 ignored). And `claude --worktree` sets cwd
# to .claude/worktrees/<name>, which slugs to a different project dir than the
# repo root, so a worktree session and its evidence could never find each other
# — the normal path for a worktree-per-branch workflow, not an edge case.
# Storing under a directory lastcall owns removes both, and stops the drop-box
# squatting in a tree the harness manages and rotates.
evidence_for() {
  local sid="$1" dir
  dir="$EVIDENCE/$sid"
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
    # Merge on task.id ALONE. The SOURCE used to be part of the key, and that
    # double-counted every task two producers both described -- evidence from
    # fathom and from linear each naming ONC-5 reported completed 2 for one
    # task. That is the configuration epic 626 drives toward, so it had to be
    # settled before a second producer ships. See contracts.md section 2.
    #
    # The most recent observation decides status, which is the old single-source
    # rule generalized: a task re-emitted as completed still supersedes its
    # earlier partial, whoever emitted it. Artifacts union, so a task grounded
    # by one producer is not reported unverified because the other saw no
    # commit. Only artifacts are merged onto the task here -- this reader emits
    # counts, so sources and artifact_matches would be carried and dropped;
    # meter-session.sh, which emits the tasks themselves, merges those too.
    # No apostrophes in this program: it is single-quoted in sh.
    ( map(. as $d | (.tasks // [])[] | {source: $d.source, emitted_at: $d.emitted_at} + .)
      | group_by(.id)
      | map( sort_by([.emitted_at, .source]) as $g
             | ($g | last)
               + { artifacts: ($g | map(.artifacts // []) | add | unique) } )
    ) as $t
    | { sources:    (map(.source) | unique),
        completed:  ($t | map(select(.status=="completed"))  | length),
        partial:    ($t | map(select(.status=="partial"))    | length),
        blocked:    ($t | map(select(.status=="blocked"))    | length),
        abandoned:  ($t | map(select(.status=="abandoned"))  | length),
        # A completed task with no artifacts is unverified. It IS counted in
        # completed above -- this is a subset of that, not a separate bucket,
        # and the earlier wording here ("not counted") described an intent the
        # code did not keep: every per-task ratio divided by completed until
        # trend was moved onto the grounded denominator below.
        unverified: ($t | map(select(.status=="completed" and ((.artifacts // []) | length) == 0)) | length)
      }' "${ok[@]}"
}

# Task ids claimed by each session, read from the DROP-BOX rather than from the
# ledger. A ledger row carries evidence COUNTS and not the task ids, so the ids
# exist nowhere else, and cmd_trend needs them to see a claim that crosses a
# workspace boundary.
#
# Limited to sessions the ledger has a row for, which bounds the read to the
# size of the baseline instead of the size of the drop-box, and skips evidence
# for sessions that were never appended. Unparseable files are skipped with a
# warning, the same as evidence_for. A task with no id is skipped rather than
# folded in: null is a valid group key, so keeping it would manufacture a
# shared claim between two producers that each simply forgot the field.
dropbox_claims() {
  local sids="$1" files=() d f sid
  [ -d "$EVIDENCE" ] || { printf '%s' '[]'; return; }
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    d="$EVIDENCE/$sid"
    [ -d "$d" ] || continue
    for f in "$d"/*.json; do
      [ -e "$f" ] || continue
      if jq -e . "$f" >/dev/null 2>&1; then files+=("$f")
      else echo "ledger: skipping unparseable evidence $f" >&2; fi
    done
  done <<CLAIMS
$sids
CLAIMS
  [ ${#files[@]} -gt 0 ] || { printf '%s' '[]'; return; }
  jq -s -c '[ .[] | .session_id as $s | (.tasks // [])[]
              | select(.id != null)
              | { id: .id, session_id: $s } ] | unique' "${files[@]}"
}

cmd_append() {
  local meter cost sid ev row commits repo t0 t1
  meter="$(cat)"

  # A stub meter read no transcript (meter-session.sh), so there is nothing here
  # for a BASELINE to be built from: no cost, no active time, no token rows. Two
  # separate harms follow from writing the row anyway, which is why this refuses
  # rather than storing nulls.
  #
  # It would poison `trend`. Its medians take `.cost.usd` and `.active_s / 60`
  # straight off every row; a null sorts below every number in jq, and null
  # divided by a number aborts the program outright.
  #
  # And it would DESTROY history. Rows are replaced on session_id alone, and a
  # stub id is derived from the working directory, so the second stub session in
  # a directory would silently overwrite the first — a directory-keyed id is not
  # a session identity, it is a rendezvous point for the evidence drop-box.
  #
  # Exit 0, not an error: nothing went wrong, there is simply nothing to record.
  if printf '%s' "$meter" | jq -e '.stub != null' >/dev/null 2>&1; then
    echo "ledger: stub meter (no transcript) — no measurements to add to the baseline, row not written" >&2
    return 0
  fi

  # Session commits, discovered from the metered window and unioned with any
  # SHAs the caller passed. The old comment here said only the caller knows
  # which commits belong to this session, which was true when lastcall was the
  # only committer; it is not true once another skill commits during the run,
  # and that session then recorded an empty commit list. Same query and same
  # caveats as emit-evidence-beads.sh: --since/--until filter on COMMITTER
  # date, so a rebase inside the window can sweep in older work, and any commit
  # made in this checkout during the window is counted whoever authored it.
  # LASTCALL_COMMIT_DISCOVERY=0 falls back to the passed SHAs alone.
  repo="$(printf '%s' "$meter" | jq -r '.session.cwd // empty')"
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then repo="$PWD"; fi
  t0="$(printf '%s' "$meter" | jq -r '.session.started // empty')"
  t1="$(printf '%s' "$meter" | jq -r '.session.ended // empty')"
  # Both sources are normalized to the abbreviated form before the union, or a
  # full SHA passed by the caller would survive dedupe beside the short one the
  # window query returns and the row would carry the same commit twice.
  commits="$( { if git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        for sha in ${1+"$@"}; do
          git -C "$repo" rev-parse --verify --quiet --short "${sha}^{commit}" \
            || printf '%s\n' "$sha"
        done
        if [ "${LASTCALL_COMMIT_DISCOVERY:-1}" != "0" ] && [ -n "$t0" ] && [ -n "$t1" ]; then
          git -C "$repo" log --since="$t0" --until="$t1" --no-merges --format='%h' 2>/dev/null || true
        fi
      else
        printf '%s\n' ${1+"$@"}
      fi
    } | jq -Rs 'split("\n") | map(select(length > 0)) | unique')"
  cost="$(printf '%s' "$meter" | "$COST")"
  sid="$(printf '%s' "$meter" | jq -r '.session.id')"
  ev="$(evidence_for "$sid")"

  row=$(jq -cn --argjson m "$meter" --argjson c "$cost" --argjson e "$ev" \
              --argjson commits "$commits" '
    { schema: "lastcall.ledger/1",
      session_id: $m.session.id,
      metered_at: (now | todateiso8601),
      cwd: $m.session.cwd, branch: $m.session.branch,
      started: $m.session.started, ended: $m.session.ended,
      active_s: $m.session.active_s,
      # When the session was actually WORKING, as [start, end] epoch pairs,
      # merged across main lanes. The session window is a loose proxy -- a
      # window of 409h carrying near-zero activity is a real measurement here
      # -- so trend uses these to test overlap when both rows carry them.
      # Absent on rows written before spans existed, which is UNKNOWN, and
      # trend then falls back to the window rather than assuming disjointness.
      spans: $m.session.spans,
      # How this row was COUNTED. Without it an inflated row and a corrected
      # one are byte-indistinguishable, which made the re-meter repair rule in
      # contracts.md section 3 undocumentable in practice: you could state that
      # affected rows must be re-metered but not find them. Absent on rows
      # written before it existed, and that absence is UNKNOWN, not version 1.
      # dedup rides along as the evidence behind it -- coverage says which
      # response-id field was present, adj_dup_share says whether collapsing
      # actually happened, and together they say which envelope this row was
      # measured under. No apostrophes in this program: it is single-quoted.
      meter_version: $m.session.meter_version,
      dedup: $m.session.dedup,
      # Claude Code own measure of agent-busy time, beside the gap-bucketed
      # figure. Absent on rows written before it existed, so it is recorded
      # but never used in trend math — a null there means unmeasured, not zero.
      agent_s: $m.session.agent_s,
      # promo state is recorded per row because a promo expiry moves the cost
      # of every later row without any behavior changing. Without it, a trend
      # spanning the boundary shows a step change that cannot be attributed.
      # No apostrophes here: the whole program is single-quoted in sh.
      cost: { usd: $c.total_usd, by_model: $c.by_model,
              pricing_source: $c.pricing_source,
              promo_applied: $c.promo_applied, promo_models: $c.promo_models,
              # What each skill cost, from the attribution Claude Code writes
              # into the transcript. Sums to usd, including the null row that
              # holds everything unattributed.
              by_skill: $c.by_skill,
              # Anything that makes usd an understatement — an unpriceable
              # service tier, or per-request tool spend this table cannot
              # price. A row with caveats is not comparable to one without.
              caveats: $c.caveats },
      tokens: $m.tokens,
      work: { tool_calls: ($m.work.tools | to_entries | map(.value) | add // 0),
              files_changed: ($m.work.files | length),
              commits: $commits },
      friction: $m.friction,
      # null, not zeroes: "no evidence" and "zero tasks done" are different claims.
      evidence: $e }')

  local dir; dir="$(dirname "$LEDGER")"
  mkdir -p "$dir"
  touch "$LEDGER"

  # Replace this session's row in place rather than appending a duplicate.
  # Keyed on session_id alone — metered_at is freshness, not identity.
  #
  # Read with -R so jq takes each line as TEXT and decodes it itself. Letting jq
  # parse the file directly aborts on the first unparseable line, having already
  # written every row above it to the temp — and with the parse error discarded
  # and the exit swallowed, that truncated temp was promoted over the ledger,
  # silently deleting every row below the bad one. One corrupt byte cost the
  # whole baseline below it, in the documented repair path.
  #
  # Same problem evidence_for handles one layer up, so it gets the same answer:
  # an unparseable line is warned about, not aborted over. It is carried through
  # verbatim rather than skipped, because dropping it would be exactly the
  # destruction this guard exists to prevent — append removes one row, the row
  # it is replacing, and nothing else.
  local bad
  bad="$(jq -R -r 'select(length > 0)
                   | select((try (fromjson | "ok") catch "bad") == "bad")' \
         "$LEDGER" 2>/dev/null | grep -c . || true)"
  [ "${bad:-0}" -eq 0 ] || echo "ledger: $bad unparseable line(s) in $LEDGER left untouched — repair them by hand" >&2

  # The temp lives beside the ledger, not in $TMPDIR, so the rename is
  # same-filesystem and therefore atomic. A cross-device mv is a copy, and a
  # torn ledger loses the whole baseline. config.sh:254 and
  # capture-statusline.sh:70 do the same, for the same reason. $$ is enough of a
  # uniqueness token because append is the only writer and runs serially.
  local tmp; tmp="$dir/.ledger.$$.jsonl"
  jq -R -r --arg sid "$sid" '
    # No apostrophes in this program: it is single-quoted in sh.
    . as $line
    | (try (fromjson) catch null) as $o
    | if ($o | type) == "object" and $o.session_id == $sid then empty else $line end
  ' "$LEDGER" > "$tmp"
  printf '%s\n' "$row" >> "$tmp"
  mv -f "$tmp" "$LEDGER"
  printf '%s\n' "$row"
}

cmd_list() {
  [ -f "$LEDGER" ] || return 0
  if [ "${1:-}" = "--cwd" ]; then jq -c --arg c "${2:?--cwd needs a path}" 'select(.cwd == $c)' "$LEDGER"
  else jq -c . "$LEDGER"; fi
}

cmd_trend() {
  local focus="${1:-}" sids claims
  [ -f "$LEDGER" ] || { echo '{"sessions":0,"note":"no ledger yet"}'; return; }

  # Read with -R for the same reason append does: one unparseable line must not
  # decide what the rest of the ledger says.
  sids="$(jq -R -r '(try (fromjson) catch null)
                    | if type == "object" then (.session_id // empty) else empty end' \
          "$LEDGER" 2>/dev/null || true)"
  claims="$(dropbox_claims "$sids")"

  jq -s --arg focus "$focus" --argjson claims "$claims" '
    def pct($p): if length == 0 then null
                 else sort | .[ (((length - 1) * $p) | floor) ] end;
    def r2: if . == null then null else (.*100|round)/100 end;
    # Timestamps may carry milliseconds, which fromdateiso8601 rejects.
    def ts: if . == null or . == "" then null
            else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end;

    . as $all0
    # Session windows in one workspace are NOT disjoint, and the evidence
    # producer assigns a bead to every session whose window contains its
    # transition. So a long session claims the work of every session nested
    # inside it, and each divides its own cost by its own inflated count.
    # Three ordinary things produce the long window: a session left open
    # across a break, a /clear that mints a new id while the earlier window
    # stays open, and any session whose ended is just the last transcript
    # entry. Measured across 60 local transcripts, windows of 409h and 313h
    # exist carrying near-zero actual activity.
    #
    # Computed HERE rather than stored on the row, because append time cannot
    # see it. An enveloping session starts EARLIER and ends LATER, so when the
    # nested row is written the envelope has no row yet, or a stale row whose
    # ended has not reached the nested session. Only trend sees every row at
    # once, and it recomputes on every call so it can never go stale.
    #
    # Scoped by cwd: two sessions in different workspaces read different bead
    # databases and cannot be claiming the same task.
    | ($all0 | map(. + { _t0: (.started | ts), _t1: (.ended | ts) })) as $stamped
    # Two sessions overlap when their ACTIVITY intersects, not merely when one
    # window contains the other. A session left open across a break has a
    # window covering the whole break and no activity in it, so a window test
    # calls that an overlap and discards a row that was never in conflict.
    # Falls back to the window whenever either row predates spans: the window
    # is a SUPERSET of the activity, so the fallback is the stricter, more
    # conservative answer and can only over-report, never under-report.
    | def ivx($a; $b): any($a[]; . as $x | any($b[]; $x[0] <= .[1] and .[0] <= $x[1]));
      ($stamped | map(
        . as $r
        # The rows this one is actually compared AGAINST. Named, because the
        # basis below has to describe the tests that ran, and which test runs
        # depends on what the peer carries as much as on what this row does.
        | ($stamped | map(select(.session_id != $r.session_id
                                 and .cwd == $r.cwd
                                 and ._t0 != null and ._t1 != null))) as $peers
        | ($peers | map(select(((.spans // []) | length) == 0)) | length) as $nospan
        | . + { window_overlap:
                 # null, not [], when the window is unreadable. That is
                 # UNKNOWN overlap, and it must not read as "disjoint".
                 (if $r._t0 == null or $r._t1 == null then null
                  else [ $peers[]
                         | select(if (($r.spans // []) | length) > 0
                                     and ((.spans   // []) | length) > 0
                                  then ivx($r.spans; .spans)
                                  else (._t0 <= $r._t1 and ._t1 >= $r._t0) end)
                         | .session_id ]
                  end),
                # Which test produced that answer. A reader comparing two
                # ledgers needs to know whether the tighter one was available,
                # and an UPGRADING reader needs to know whether it is still
                # pending: spans live on the row and are written at append
                # time, so a ledger of older rows keeps falling back until it
                # is re-metered. Emitted in window_overlaps, in the focus
                # block, and counted in overlap_regimes -- computing it and
                # then dropping it left the one reader who needed it with no
                # way to find out.
                #
                # Reports the tests that actually RAN, not merely whether this
                # row carries spans. The fallback is per PAIR: a row with spans
                # compared against one without still falls back, and calling
                # that "activity spans" would over-claim the tighter test.
                window_overlap_basis:
                 (if $r._t0 == null or $r._t1 == null
                  then "not tested (this session window could not be read)"
                  elif ($peers | length) == 0
                  then "no other session in this workspace to compare against"
                  elif (($r.spans // []) | length) == 0
                  then "session window (spans not recorded on this row)"
                  elif $nospan == 0 then "activity spans"
                  else "mixed — activity spans against \(($peers | length) - $nospan) session(s), session window against \($nospan) with no spans recorded"
                  end) }
        | del(._t0, ._t1))) as $all

    # Per-task ratios need evidence. Rows without it stay in the per-session
    # stats but are excluded here — inferring tasks from token burn would
    # reward thrashing.
    | ($all | map(select(.evidence != null and .evidence.completed > 0))) as $withev
    # And they need a window that is actually this session alone. An
    # overlapped row counts tasks its neighbours also counted, which shows up
    # as apparent efficiency — the cheapest rows are the most inflated ones.
    # Excluded the same way rows without evidence are, rather than silently
    # averaged in. An unreadable window is excluded too: unknown is not safe.
    | ($withev | map(select(.window_overlap != null
                            and (.window_overlap | length) == 0))) as $clean
    # And the denominator has to be work that can actually be POINTED AT.
    # evidence_for computes unverified -- a completed task carrying no
    # artifact -- and the comment beside it has always said such a task is
    # "not counted", but completed counts it anyway and every ratio here
    # divided by completed. So the promise was never kept.
    #
    # It matters because the two failure modes bias the SAME way. Overlapping
    # windows inflated the denominator with other sessions beads; ungrounded
    # completions inflate it with beads nothing points at. Removing the first
    # concentrates the second, and the signature is a session that closes a
    # batch of beads at the end with no commit naming any of them.
    #
    # A row where nothing is grounded is EXCLUDED, not divided by zero: jq
    # aborts the whole program on a zero or null denominator, which would cost
    # the entire trend over one unusable row.
    | ($clean | map(select((.evidence.unverified // null) != null
                           and (.evidence.completed - .evidence.unverified) > 0)))
        as $grounded

    # Cross-WORKSPACE task claims. window_overlap above is scoped per cwd, on
    # the correct grounds that two sessions in different workspaces read
    # different bead databases and cannot be claiming the same task. One gap
    # that leaves: a task id is not globally unique -- "#123" is unique per
    # repo, not per planet -- and the drop-box is keyed on session id ALONE,
    # deliberately, so a directory rename or a worktree session still finds its
    # own evidence. Evidence from two workspaces therefore does land in one
    # directory, and when the ids collide both rows count the task in per_task
    # with nothing excluding or flagging it. contracts.md section 2 warns about
    # the namespacing hazard; until now only verify.sh asserted the invariant,
    # as a test fixture, never at wrap-up time where a user would see it.
    #
    # DISCLOSED, not excluded. Excluding would move the baseline on a signal
    # nobody has yet observed in the wild, and surface-do-not-fold is the rule
    # the rest of this file keeps. Exclusion is the follow-up if it turns out
    # to be common.
    | ($all | map({ (.session_id): .cwd }) | add // {}) as $cwd_of
    | ( $claims
        | map(select($cwd_of[.session_id] != null)
              | . + { cwd: $cwd_of[.session_id] })
        | group_by(.id)
        | map(select((map(.cwd) | unique | length) > 1))
        | map({ task: .[0].id,
                workspaces: (map(.cwd) | unique),
                sessions:   (map(.session_id) | unique) }) ) as $xws

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

        per_task: (if ($grounded | length) == 0 then null else {
          # Grounded completions, because a completion with no artifact is the
          # exact thing the grounding rule exists to distrust, and spending it
          # in a cost ratio contradicts that rule.
          usd_median:        ($grounded | map(.cost.usd / (.evidence.completed - .evidence.unverified)) | pct(0.5) | r2),
          active_min_median: ($grounded | map((.active_s/60) / (.evidence.completed - .evidence.unverified)) | pct(0.5) | r2),
          denominator: "grounded completions (completed - unverified)",
          # Beside with_evidence, which counts a different population. The two
          # sit close together and a reader will pair them, so say which rows
          # these numbers actually came from.
          rows: ($grounded | length),
          # The OTHER bound. Neither denominator is the truth: dividing by
          # completed treats an unverifiable completion as confirmed, and
          # dividing by grounded charges the whole session to the subset that
          # can be pointed at. The real figure is between them, so publish
          # both rather than folding an unknown into whichever bucket is
          # convenient -- section 3 forbids exactly that fold. Equal to the
          # headline when nothing is ungrounded, which is the common case.
          usd_median_counting_unverified:
            ($grounded | map(.cost.usd / .evidence.completed) | pct(0.5) | r2),
          active_min_median_counting_unverified:
            ($grounded | map((.active_s/60) / .evidence.completed) | pct(0.5) | r2)
        } end),

        # Disclosure, not just exclusion. A reader who sees a per_task drawn
        # from 3 of 12 rows needs to know which 9 were dropped and why, and a
        # consumer needs it structured rather than parsed out of prose. Empty
        # when nothing overlaps, so a healthy ledger says so plainly.
        window_overlaps:
          ([ $all[]
             | select(.window_overlap != null and (.window_overlap | length) > 0)
             | { session_id, cwd, overlaps: .window_overlap,
                 # Which test produced this row answer. An exclusion resting on
                 # the window fallback is not the same finding as one the span
                 # test confirmed, and the reader cannot tell them apart from
                 # the id list alone.
                 basis: .window_overlap_basis } ]),

        # The axis window_overlaps cannot reach, reported in the same shape and
        # for the same reason: a reader who is told rows were excluded needs to
        # know which ones were NOT, and why. Empty on a healthy ledger, which
        # is the normal answer and worth being able to see.
        cross_workspace_claims: $xws,

        # The migration signal. Span-based overlap needs the row to CARRY
        # spans, and spans are written at append time, so upgrading changes
        # nothing at all until the rows are re-metered and re-appended. With
        # this field absent the upgrade reads as a no-op -- same exclusions,
        # same per_task, and nothing in the output saying the tighter test is
        # still pending. Same shape as pricing_regimes and meter_regimes
        # below, one layer further down: a step in this trend can come from
        # the TEST changing rather than from the work changing.
        overlap_regimes:
          (($all | map(select(.window_overlap != null))) as $tested
           | { spans_recorded:
                 ($tested | map(select(((.spans // []) | length) > 0)) | length),
               spans_missing:
                 ($tested | map(select(((.spans // []) | length) == 0)) | length),
               window_unreadable: (($all | length) - ($tested | length)) }
           | . + (if .spans_missing > 0
                  then { note: "\(.spans_missing) row(s) record no activity spans, so every comparison involving them falls back to the session window — a superset of the activity, which can only over-report overlap. Re-meter and re-append those rows to apply the tighter test; until then some exclusions here are pending rather than settled." }
                  else {} end)),

        # A null per_task used to mean three different things at once, and the
        # reader could not tell which: no producer exists in these workspaces,
        # a producer ran and matched nothing, or rows were repaired without one.
        # Since the beads producer writes an empty-tasks marker, a row that was
        # assessed and came back zero is distinguishable from a row that was
        # never assessed, so say which populations are in play. Emitted even
        # when per_task is present, because a ratio drawn from 2 of 30 rows
        # deserves the same disclosure as one drawn from none.
        per_task_basis:
          (($all | map(select(.evidence == null)) | length) as $noev
           | ($all | map(select(.evidence != null and .evidence.completed == 0))
                   | length) as $empty
           | ($withev | map(select(.window_overlap != null
                                    and (.window_overlap | length) > 0)) | length) as $ovl
           | ($withev | map(select(.window_overlap == null)) | length) as $unk
           | ($clean | map(select((.evidence.unverified // null) != null
                                   and (.evidence.completed - .evidence.unverified) <= 0))
                     | length) as $nogr
           | ($clean | map(select((.evidence.unverified // null) == null)) | length) as $unkgr
           | ($grounded | map(.evidence.completed) | add // 0) as $tot
           | ($grounded | map(.evidence.unverified) | add // 0) as $ung
           | ($all | map(select(((.spans // []) | length) == 0)) | length) as $nospan
           | "\($grounded|length) row(s) with a grounded completion and a window no other session overlaps, \($ovl) excluded for overlapping another session in the same workspace, \($unk) excluded for an unreadable window, \($nogr) excluded for no grounded completion, \($unkgr) excluded for an unreadable grounding count, \($empty) where a producer ran and matched none, \($noev) not assessed — denominator is grounded completions, \($ung) of \($tot) completions in these rows excluded as unverified"
             # The overlap exclusions above are only as tight as the test that
             # produced them, and that test is still the wide one wherever a
             # row predates spans. Said HERE because this is where a reader
             # asks why the count is what it is.
             + (if $ovl > 0 and $nospan > 0
                then " — \($nospan) of these rows record no activity spans, so some overlap exclusions rest on the wider window test and may lift on a re-meter (see overlap_regimes)"
                else "" end)
             # And the exclusions above are per WORKSPACE. A task id claimed
             # across two of them is counted twice and excluded by neither.
             + (if ($xws | length) > 0
                then " — \($xws | length) task id(s) are claimed by sessions in DIFFERENT workspaces (see cross_workspace_claims), so those rows may each be counting the other work. Task ids are not globally unique; these rows are disclosed, not excluded"
                else "" end)),

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
                  else {} end)),

        # The same hazard as pricing_regimes, one layer down: a fix to how the
        # meter COUNTS moves every later row without anything about the work
        # changing, and reading that step as behavior is exactly the mistake.
        # Reported the same way — counts always, note only when there is
        # evidence the change actually bit.
        #
        # The note is deliberately NOT fired on a version span alone. Whether
        # the 2026-08-24 dedup fix moved a given row depends on its envelope:
        # measured zero drift on first-party transcripts, ~2x on Bedrock ones.
        # Firing on every span would put a permanent false alarm on every
        # first-party ledger, and an alarm that is always on is not read.
        #
        # So the trigger is an INFERENCE, and is labeled as one: unversioned
        # rows recorded no envelope, so their exposure cannot be read off the
        # row. What can be read is the envelope of the versioned rows on the
        # same machine, and a machine whose recent sessions are Bedrock-served
        # very likely produced Bedrock rows earlier too. That is evidence, not
        # proof, and the note says so rather than asserting the rows are wrong.
        meter_regimes:
          (($all | map(.meter_version)) as $mv
           | ($all | map(.dedup | select(. != null))
                   | map(if   (.rid_coverage // 0) > 0 then "requestId"
                         elif (.mid_coverage // 0) > 0 then "message.id"
                         else "none" end)
                   | unique) as $env
           | { by_version: ($mv | group_by(.)
                                | map({ version: .[0], rows: length })),
               unversioned: ($mv | map(select(. == null)) | length),
               envelopes: $env }
           | . + (if (.unversioned > 0 and ($env | index("message.id")))
                  then { note: "these rows span a metering change — rows with no meter_version were measured before the 2026-08-24 dedup fix, and this ledger contains Bedrock-envelope sessions, which is the envelope that fix corrected by roughly 2x; a step here may be the fix rather than a behavior change, and the older rows should be re-metered (contracts section 3). Their own envelope was not recorded, so this is inferred from the later rows, not confirmed per row" }
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
              # null means the window was unreadable, so overlap is UNKNOWN.
              window_overlap: $s.window_overlap,
              # And which test produced it. Same reason as window_overlaps
              # above: an overlap found by the wide window test may not
              # survive a re-meter, and the id list alone does not say.
              window_overlap_basis: $s.window_overlap_basis,
              vs_median_usd:
                (($peers | map(.cost.usd) | pct(0.5)) as $m
                 | if $m == null or $m == 0 or ($peers | length) < 5 then null
                   else "\((($s.cost.usd / $m)*10|round)/10)x" end),
              vs_median_basis:
                (if ($peers | length) < 5
                 then "suppressed — only \($peers|length) other session(s) to compare against"
                 else "median of \($peers|length) other sessions" end),
              # Same denominator as the medians above, or the two are not
              # comparable. null when nothing in the row is grounded, which is
              # a real state and not a zero.
              per_task_usd:
                (if $s.evidence != null and $s.evidence.unverified != null
                    and ($s.evidence.completed - $s.evidence.unverified) > 0
                 then ($s.cost.usd / ($s.evidence.completed - $s.evidence.unverified) | r2)
                 else null end),
              per_task_usd_counting_unverified:
                (if $s.evidence != null and $s.evidence.completed > 0
                 then ($s.cost.usd / $s.evidence.completed | r2) else null end),
              # Same three-way split as per_task_basis above, for the one row.
              per_task_basis:
                (if $s.evidence == null
                 then "not assessed — no evidence producer ran for this session"
                 elif $s.evidence.completed == 0
                 then "assessed by \($s.evidence.sources | join(", ")) — no completed task matched"
                 else "\($s.evidence.completed) completed task(s) from \($s.evidence.sources | join(", "))"
                      + (if $s.evidence.unverified == null
                         then " — grounding was not recorded for this row, so the per-task figure divides by every completion"
                         elif $s.evidence.unverified >= $s.evidence.completed
                         then " — NONE of them grounded: no commit or artifact points at any, so no per-task figure is reported"
                         elif $s.evidence.unverified > 0
                         then " — \($s.evidence.unverified) of them unverified (no artifact points at the task), so the per-task figure divides by the \($s.evidence.completed - $s.evidence.unverified) that are grounded"
                         else "" end)
                      + (if $s.window_overlap == null
                         then " — this window could not be read, so whether another session overlaps it is unknown"
                         elif ($s.window_overlap | length) > 0
                         then " — WINDOW OVERLAP: \($s.window_overlap | length) other session(s) in this workspace run inside this window, so some of these tasks are very likely counted by them too and this ratio understates the true cost per task"
                         else "" end) end)
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
