#!/usr/bin/env bash
# Derive lastcall evidence from a beads workspace.
#
# Reads meter-session.sh output on stdin, writes one lastcall.evidence/1 file
# into the drop-box, and prints the path. Commit SHAs for the session may be
# passed as arguments; they become task artifacts when a commit message names
# the bead.
#
#   meter-session.sh <sid> | emit-evidence-beads.sh [sha ...]
#
# Why a script rather than skill instructions: a producer implemented as
# instructions depends on the agent remembering to run it at every task
# transition, forever. A script cannot forget. And for beads-backed users
# fathom-shared/memory.md:63 writes no per-task file under .fathom/tasks/, so
# there is nothing for a Fathom-side emitter to mirror out — it would have to
# read beads anyway. See contracts.md section 2.
#
# Absence of beads is the NORMAL case and exits 0 silently, the same way the
# statusline capture is treated at meter-session.sh:74-77.
set -euo pipefail

EVIDENCE="${LASTCALL_EVIDENCE_DIR:-$HOME/.claude/lastcall/evidence}"

meter="$(cat)"
sid="$(printf '%s' "$meter" | jq -r '.session.id // empty')"
cwd="$(printf '%s' "$meter" | jq -r '.session.cwd // empty')"
started="$(printf '%s' "$meter" | jq -r '.session.started // empty')"
ended="$(printf '%s' "$meter" | jq -r '.session.ended // empty')"

[ -n "$sid" ] || { echo "emit-evidence-beads: no session id on stdin" >&2; exit 1; }

# The recorded cwd goes STALE. A session keeps the path it started in, so a
# directory rename leaves every later row pointing at a directory that no longer
# exists — measured on this machine, 5 of 26 sessions carry a stale cwd, and
# verify.sh reports the count. Falling back to $PWD is safe because this runs
# inside the session it describes, so $PWD is the live working directory.
if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then cwd="$PWD"; fi

# Resolve the workspace the way bd does: walk up until .beads appears. The
# recorded cwd can be any subdirectory of the repo, so testing only the exact
# path misses a workspace that is plainly there.
find_beads() {
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -d "$d/.beads" ] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

# No workspace, no bd, or no window: nothing to say. Silence, not an error.
command -v bd >/dev/null 2>&1 || exit 0
root="$(find_beads "$cwd")" || exit 0
cwd="$root"
[ -n "$started" ] && [ -n "$ended" ] || exit 0

issues="$(cd "$cwd" && bd list --all --limit 0 --json --skip-labels 2>/dev/null)" || exit 0
[ -n "$issues" ] || exit 0

# Commits are matched to beads by id mentioned in the subject. Attaching every
# session commit to every task would inflate grounding: the point of artifacts
# is that a claim earns trust, so a task nothing references stays empty and is
# reported as unverified. That is the honest outcome, not a gap to paper over.
#
# A SHA git cannot resolve is REPORTED, not swallowed. Silently skipping it
# strips a task of its grounding and reports it unverified with nothing saying
# why — the inverse of the discipline the rest of this codebase keeps, where
# absence is visible (files_coverage.attributed, the native block in
# meter-session.sh, the unparseable-evidence warning). It stays non-fatal: a bad
# SHA should degrade grounding, not lose the evidence file.
commits='[]'
if [ "$#" -gt 0 ] && [ -n "$cwd" ]; then
  commits="$(cd "$cwd" && for sha in "$@"; do
      if ! git rev-parse --verify --quiet "${sha}^{commit}" >/dev/null 2>&1; then
        echo "emit-evidence-beads: cannot resolve commit $sha in $PWD; grounding for any task it names will be missing" >&2
        continue
      fi
      subj="$(git log -1 --format='%s%n%b' "$sha" 2>/dev/null || true)"
      jq -cn --arg sha "$sha" --arg msg "$subj" '{sha: $sha, msg: $msg}'
    done | jq -sc '.')"
fi

# WARNING: no apostrophes in these comments. This jq program is a single-quoted
# shell string, and one apostrophe ends it early, with the error landing far
# from the typo. Write "the row", never the possessive form.
out="$(printf '%s' "$issues" | jq -c \
  --arg sid "$sid" --arg started "$started" --arg ended "$ended" \
  --argjson commits "$commits" '
  # Timestamps may carry milliseconds, which fromdateiso8601 rejects.
  def ts: if . == null or . == "" then null
          else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end;

  ($started | ts) as $t0 | ($ended | ts) as $t1
  # bd list --json changes SHAPE with its flags: a bare array with --status,
  # an object wrapping .issues with --all. Normalize rather than depend on
  # which flag was used, since neither shape is a documented contract.
  | (if type == "object" then (.issues // []) else . end)
  | map(
      . as $i
      # A bead counts for this session only if the transition that makes it
      # evidence happened inside the metered window.
      | (if   $i.status == "closed"      then ($i.closed_at  | ts)
         elif $i.status == "in_progress" then ($i.started_at | ts)
         else null end) as $at
      | select($at != null and $t0 != null and $t1 != null and $at >= $t0 and $at <= $t1)
      | {
          id:    $i.id,
          title: $i.title,
          status: (if $i.status == "closed"      then "completed"
                   elif $i.status == "in_progress" then "partial"
                   elif $i.status == "blocked"     then "blocked"
                   else "partial" end),
          started: $i.started_at,
          ended:   (if $i.status == "closed" then $i.closed_at else null end),
          # Grounding: only commits that name this bead.
          artifacts: [ $commits[] | select(.msg | contains($i.id)) | "commit:" + .sha ],
          notes: ($i.close_reason // null)
        }
    )
  | { schema: "lastcall.evidence/1", source: "beads", session_id: $sid,
      emitted_at: (now | todateiso8601), tasks: . }
')"

count="$(printf '%s' "$out" | jq '.tasks | length')"
[ "$count" -gt 0 ] || exit 0

mkdir -p "$EVIDENCE/$sid"
path="$EVIDENCE/$sid/beads-$(date -u +%Y%m%dT%H%M%SZ).json"
printf '%s\n' "$out" > "$path"
echo "$path"
