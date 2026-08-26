#!/usr/bin/env bash
# openloops.sh — what this session started and did not finish.
#
#   meter-session.sh <id> | openloops.sh
#
# The highest-value output of lastcall, and the one thing nothing else in the
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
  GROOT="$CWD"
else
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  # git status prints paths relative to the REPO ROOT, which is not $CWD when
  # the session ran in a subdirectory. Needed to turn them back into absolute
  # paths that match the ones the meter records.
  GROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$CWD")"

  # -z with NUL parsing: filenames can contain spaces, quotes, and newlines,
  # and porcelain quotes them when they do. NUL separation sidesteps all of it.
  DIRTY="$(git status --porcelain -z 2>/dev/null \
    | jq -Rs 'split("\u0000") | map(select(length > 3))
              | map({ status: .[0:2], file: .[3:] })')"

  GIT="$(jq -cn --arg b "$branch" --argjson d "$DIRTY" \
        '{available: true, branch: $b, dirty: (($d | length) > 0)}')"

  # TODO markers introduced in work that is not yet committed. A marker already
  # committed is a backlog item, not an open loop from this session.
  #
  # TWO sources, because a diff is not the whole of "not yet committed". The
  # diffs carry markers added to files git already tracks. An UNTRACKED file
  # appears in neither `git diff` nor `git diff --cached`, so a session that
  # created a new file full of TODOs reported none of them — on the highest
  # value output lastcall produces, with nothing saying the scan was partial.
  # `git status --porcelain` did list the file, which is why it still showed up
  # under `uncommitted`; the marker text inside it was what went missing.
  #
  # The `|| true` matters throughout: grep exits 1 when it finds nothing, and
  # under pipefail a clean tree with no TODOs would kill the whole script.
  todo_re='(TODO|FIXME|XXX|HACK)[: ]'
  # A literal newline cannot be written inside the command substitution below —
  # the substitution is re-parsed and the line ends early — so it is bound here.
  NL=$'\n'

  # Tracked files. git writes a `+++ b/<path>` header before each file section,
  # so the path comes out of the same stream and costs no extra pass. Matching
  # on the uppercased line and then cutting the ORIGINAL from RSTART keeps both
  # the case-insensitivity and the leading-code trim that `grep -oiE` gave.
  todo_tracked="$( { git diff -U0 2>/dev/null; git diff --cached -U0 2>/dev/null; } \
    | awk -v re="$todo_re" '
        /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
        /^\+/       { l = substr($0, 2)
                      if (match(toupper(l), re)) print f "\t" substr(l, RSTART) }
      ' 2>/dev/null || true )"

  # Untracked files, listed from the repo ROOT so their paths are root-relative
  # like the diff headers and like `git status --porcelain` above — the same
  # concept must not arrive in two path shapes. --exclude-standard applies
  # .gitignore, which is what keeps build and vendor trees out of this. -I skips
  # binaries; a marker-shaped byte sequence in a blob is not an open loop.
  todo_untracked="$( git -C "$GROOT" ls-files --others --exclude-standard -z 2>/dev/null \
    | while IFS= read -r -d "" f; do
        # A newline in a filename would split one record into two below.
        # Not a `case`: bash 3.2 mis-parses one inside a command substitution.
        [ "${f#*"$NL"}" = "$f" ] || continue
        [ -f "$GROOT/$f" ] || continue
        grep -I -oiE "$todo_re.*" "$GROOT/$f" 2>/dev/null \
          | awk -v f="$f" '{ print f "\t" $0 }' || true
      done )"

  TODOS="$( { printf '%s\n%s\n' "$todo_tracked" "$todo_untracked" \
      | grep -v '^$' | head -40 || true; } \
    | jq -Rs 'split("\n") | map(select(length > 0))
              | map( (index("\t")) as $i
                     | { file:   (if $i == null then null else .[0:$i]   end),
                         marker: (if $i == null then .    else .[$i+1:] end) } )' )"
fi

jq -n --argjson m "$METER" --argjson git "$GIT" --argjson dirty "$DIRTY" \
      --argjson todos "$TODOS" --argjson cmin "$CHURN_MIN" --argjson ctop "$CHURN_TOP" \
      --arg groot "$GROOT" '
  # git status prints repo-root-relative paths while the meter records absolute
  # ones. Matching on a bare endswith would make a dirty "foo.js" look
  # attributed to an edit of "/elsewhere/barfoo.js", so the separator is part of
  # the test rather than something trimmed off it.
  def matches($d): endswith("/" + $d);
  def abspath($root): $root + "/" + .;

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
  | ( $files | map(.key) ) as $editedfiles
  | {
      git: $git,

      # Uncommitted work overall.
      uncommitted: { count: ($dirty | length), files: $dirty },

      # The sharper signal: files THIS SESSION edited that are still
      # uncommitted — work touched and left unlanded, as distinct from
      # pre-existing drift that was already dirty when the session started.
      session_files_uncommitted:
        ( $editedfiles
          | map(select(. as $f | $dirtyfiles | any(. as $d | $f | matches($d)))) ),

      # Repeated edits to one file are a struggle signature — precisely the
      # thing you have forgotten by tomorrow morning. Project files only.
      churn_hotspots:
        ( $files | map({file: .key, edits: .value})
          | map(select(.edits >= $cmin))
          | sort_by(-.edits) | .[0:$ctop] ),

      # Whether that list can be trusted to be empty. Churn is counted from edit
      # tool calls, so a session that edited through Bash produces no hotspots
      # no matter how much it thrashed. False here means the struggle signal was
      # NOT measured, which is a different report from "no struggle" and must
      # not be collapsed into it.
      # NOT `// true`: jq treats false as empty, so `false // true` is true and
      # the flag would invert exactly when it matters. Older meter output has no
      # files_coverage at all, and that absence is what defaults to true.
      churn_available: ( $m.work.files_coverage.attributed
                         | if . == null then true else . end ),

      # Uncommitted files that no edit tool accounts for. This is the direct
      # evidence that work happened outside what files can see. It is not proof
      # of a Bash edit on its own: a file already dirty when the session started
      # looks identical from here, and the transcript cannot separate them. Read
      # it together with churn_available, which says whether any edit tool ran.
      # Absolute, matching session_files_uncommitted above: the two are read
      # side by side and the same concept must not arrive in two path shapes.
      uncommitted_unattributed:
        ( $dirtyfiles
          | map(select(. as $d
                | ($editedfiles | any(. as $f | $f | matches($d))) | not))
          | map(abspath($groot)) ),

      # How many edited files were outside the project, so the filtering above
      # is visible rather than silent. Not a hotspot list — just a count.
      churn_external_files: $external_files,

      todos_added: $todos,

      # Carried through from the evidence drop-box: open loops the producing
      # skill already knows about (status partial / blocked).
      evidence_open: [ ($m.evidence // [])[]
                       | select(.status == "partial" or .status == "blocked")
                       | { source, id, title, status } ]
    }'
