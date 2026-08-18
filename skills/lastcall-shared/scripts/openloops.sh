#!/usr/bin/env bash
# openloops.sh — what this session started and did not finish.
#
#   meter-session.sh <id> | openloops.sh
#
# The highest-value output of last-call, and the one thing nothing else in the
# toolchain produces. Reports only signals that are definitively checkable —
# git state and edit counts. Test-failure state is deliberately NOT inferred
# here; see references/summary.md for why.
set -euo pipefail

CHURN_MIN="${CHURN_MIN:-3}"      # edits to one file before it counts as a hotspot
CHURN_TOP="${CHURN_TOP:-8}"

METER="$(cat)"
CWD="$(printf '%s' "$METER" | jq -r '.session.cwd // empty')"
[ -n "$CWD" ] && [ -d "$CWD" ] || { echo '{"error":"session cwd not available"}'; exit 0; }

cd "$CWD"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  GIT='{"available":false}'
  DIRTY='[]'
  TODOS='[]'
else
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

  # -z with NUL parsing: filenames can contain spaces, quotes, and newlines,
  # and porcelain quotes them when they do. NUL separation sidesteps all of it.
  DIRTY="$(git status --porcelain -z 2>/dev/null \
    | jq -Rs 'split("\u0000") | map(select(length > 3))
              | map({ status: .[0:2], file: .[3:] })')"

  GIT="$(jq -cn --arg b "$branch" --argjson d "$DIRTY" \
        '{available: true, branch: $b, dirty: (($d | length) > 0)}')"

  # TODO markers introduced in work that is not yet committed. A marker already
  # committed is a backlog item, not an open loop from this session.
  # The `|| true` matters: grep exits 1 when it finds nothing, and under
  # pipefail a clean tree with no TODOs would kill the whole script.
  TODOS="$( { { git diff -U0 2>/dev/null; git diff --cached -U0 2>/dev/null; } \
    | grep -E '^\+' | grep -vE '^\+\+\+' \
    | grep -oiE '(TODO|FIXME|XXX|HACK)[: ].*' \
    | head -40 || true; } \
    | jq -Rs 'split("\n") | map(select(length > 0)) | map({marker: .})' )"
fi

jq -n --argjson m "$METER" --argjson git "$GIT" --argjson dirty "$DIRTY" \
      --argjson todos "$TODOS" --argjson cmin "$CHURN_MIN" --argjson ctop "$CHURN_TOP" '
  ( $m.session.cwd ) as $cwd
  # The meter records every edited path, including ones outside the project:
  # scratchpad temp files, memory files under ~/.claude. Those are not project
  # work, and a churn line pointing at a temp file wastes the attention of
  # whoever reads the summary. Trailing slash matters — a bare prefix test
  # would also match a sibling directory like "<cwd>-other".
  # No apostrophes in these comments: the whole program is single-quoted in sh.
  | ( def inproject: . == $cwd or startswith($cwd + "/");
      $m.work.files // {} | to_entries | map(select(.key | inproject)) ) as $files
  | ( ($m.work.files // {} | to_entries | length)
      - ($files | length) ) as $external_files
  | ( $dirty | map(.file) ) as $dirtyfiles
  | {
      git: $git,

      # Uncommitted work overall.
      uncommitted: { count: ($dirty | length), files: $dirty },

      # The sharper signal: files THIS SESSION edited that are still
      # uncommitted — work touched and left unlanded, as distinct from
      # pre-existing drift that was already dirty when the session started.
      session_files_uncommitted:
        ( $files | map(.key)
          | map(select(. as $f | $dirtyfiles | any(. as $d | $f | endswith($d)))) ),

      # Repeated edits to one file are a struggle signature — precisely the
      # thing you have forgotten by tomorrow morning. Project files only.
      churn_hotspots:
        ( $files | map({file: .key, edits: .value})
          | map(select(.edits >= $cmin))
          | sort_by(-.edits) | .[0:$ctop] ),

      # How many edited files were outside the project, so the filtering above
      # is visible rather than silent. Not a hotspot list — just a count.
      churn_external_files: $external_files,

      todos_added: $todos,

      # Carried through from the evidence drop-box: open loops the producing
      # skill already knows about (status partial / blocked).
      evidence_open: ($m.evidence // [])
    }'
