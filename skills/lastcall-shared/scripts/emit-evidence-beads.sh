#!/usr/bin/env bash
# Derive lastcall evidence from a beads workspace.
#
# Reads meter-session.sh output on stdin, writes one lastcall.evidence/1 file
# into the drop-box, and prints the path. Session commits are discovered from
# the metered window; SHAs may also be passed as arguments and are unioned in.
# A commit becomes a task artifact when it names the bead, and failing that
# when its time falls inside the bead active range.
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

# Session commits are DISCOVERED from the metered window, not only handed in.
# lastcall offers its commit delegation only when the tree is dirty, so a
# session whose commits were made by some other skill passed zero SHAs here and
# earned zero grounding — the matcher never ran a comparison at all. Argv SHAs
# are still honored, because the caller knows what it created, and discovery is
# unioned on top of them and deduped by full SHA. Set LASTCALL_COMMIT_DISCOVERY=0
# to fall back to argv alone.
#
# Two limits of the window query, recorded rather than hidden. --since/--until
# filter on COMMITTER date, verified by dating a commit 2020 and committing it
# today: it appears under a 2026 window and is absent from a 2020 one. So a
# rebase inside the window resets timestamps and can sweep in older work. And
# any commit made in this checkout during the window lands in it, whoever
# authored it.
#
# A SHA git cannot resolve is REPORTED, not swallowed. Silently skipping it
# strips a task of its grounding and reports it unverified with nothing saying
# why — the inverse of the discipline the rest of this codebase keeps, where
# absence is visible (files_coverage.attributed, the native block in
# meter-session.sh, the unparseable-evidence warning). It stays non-fatal: a bad
# SHA should degrade grounding, not lose the evidence file.
n_argv="$#"
n_found=0
has_git=0
commits='[]'
full_shas=""
if [ -n "$cwd" ] && (cd "$cwd" && git rev-parse --git-dir >/dev/null 2>&1); then
  has_git=1
  for sha in ${1+"$@"}; do
    full="$(cd "$cwd" && git rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null || true)"
    if [ -z "$full" ]; then
      echo "emit-evidence-beads: cannot resolve commit $sha in $cwd; grounding for any task it names will be missing" >&2
      continue
    fi
    case " $full_shas " in *" $full "*) ;; *) full_shas="$full_shas $full" ;; esac
  done

  if [ "${LASTCALL_COMMIT_DISCOVERY:-1}" != "0" ]; then
    while IFS= read -r full; do
      [ -n "$full" ] || continue
      n_found=$((n_found + 1))
      case " $full_shas " in *" $full "*) ;; *) full_shas="$full_shas $full" ;; esac
    done <<EOF
$(cd "$cwd" && git log --since="$started" --until="$ended" --no-merges --format='%H' 2>/dev/null || true)
EOF
  fi

  # %ct rather than %cI: fromdateiso8601 rejects a numeric offset, and an epoch
  # needs no parsing at all. One git call per commit keeps the multi-line body
  # out of any delimiter scheme, and a session holds commits in the dozens.
  commits="$(cd "$cwd" && for full in $full_shas; do
      # Every fallback here degrades one commit rather than aborting the run:
      # an empty --argjson is a jq error, and under set -e that would cost the
      # whole evidence file over a single unreadable commit. A commit that
      # lands at epoch 0 simply fails the window bound and can still match on
      # its message.
      jq -cn --arg sha "$(git rev-parse --short "$full" 2>/dev/null || printf '%s' "$full")" \
             --arg msg "$(git log -1 --format='%s%n%b' "$full" 2>/dev/null || true)" \
             --argjson at "$(git log -1 --format='%ct' "$full" 2>/dev/null || echo 0)" \
             '{sha: $sha, msg: $msg, at: $at}'
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
      # started_at is NOT reliably present. bd omits the key entirely from most
      # rows — 46 of 85 in this workspace, measured 2026-08-24 — and jq yields
      # null for a missing key, so an in_progress bead with no start timestamp
      # failed the window select and could never be counted as partial at all.
      # Closed beads were unaffected because they read closed_at instead.
      #
      # updated_at is the closest thing bd guarantees. It moves on the status
      # change that made the bead in_progress, so it is a real transition time,
      # only a coarser one: any later edit drags it forward. It is used for
      # INCLUSION and for the range start below, never reported as the start
      # time — the started field keeps whatever bd actually recorded, so a null
      # there still says the start was never observed rather than asserting one.
      | (($i.started_at | ts) // ($i.updated_at | ts)) as $b0
      # A bead counts for this session only if the transition that makes it
      # evidence happened inside the metered window.
      | (if   $i.status == "closed"      then ($i.closed_at | ts)
         elif $i.status == "in_progress" then $b0
         else null end) as $at
      | select($at != null and $t0 != null and $t1 != null and $at >= $t0 and $at <= $t1)

      # JOIN KEYS, strongest first. An EXACT match is a commit that names the
      # bead: its id, or the tracker ref that bd records in external_ref, which
      # is what a conventional-commit scope carries in a Fathom run. The WINDOW
      # key is weaker — a commit whose time falls inside the bead own active
      # range — and it applies only when no exact match exists, so a task with
      # an earned commit is never diluted by everything committed beside it.
      | ($i.external_ref // "") as $ref
      | ([ $commits[]
           | select((.msg | contains($i.id))
                    or ($ref != "" and (.msg | contains($ref))))
           | { ref: ("commit:" + .sha),
               key: (if (.msg | contains($i.id)) then "id" else "tracker" end) }
         ]) as $exact
      # An open bead has no closed_at, so its range ends at the session end.
      | ((if $i.status == "closed" then $i.closed_at else $ended end) | ts) as $b1
      | ([ $commits[]
           | select($b0 != null and $b1 != null and .at >= $b0 and .at <= $b1)
           | { ref: ("commit:" + .sha), key: "window" }
         ]) as $win
      | (if ($exact | length) > 0 then $exact else $win end) as $matches
      | {
          id:    $i.id,
          title: $i.title,
          status: (if $i.status == "closed"      then "completed"
                   elif $i.status == "in_progress" then "partial"
                   elif $i.status == "blocked"     then "blocked"
                   else "partial" end),
          started: $i.started_at,
          ended:   (if $i.status == "closed" then $i.closed_at else null end),
          # Grounding. artifacts stays a flat list of strings because the
          # tiering of that field is decided elsewhere; the label rides beside
          # it in a new field, which contract 2 allows and consumers ignore.
          artifacts:        [ $matches[] | .ref ],
          artifact_matches: $matches,
          notes: ($i.close_reason // null)
        }
    )
  | { schema: "lastcall.evidence/1", source: "beads", session_id: $sid,
      emitted_at: (now | todateiso8601), tasks: . }
')"

count="$(printf '%s' "$out" | jq '.tasks | length')"
[ "$count" -gt 0 ] || exit 0

# Completed work that nothing points at is the silent failure of this producer:
# the evidence file looks healthy, and every task inside it reports unverified
# with nothing saying why. Both commit discovery and any external producer are
# best effort, so name the cause once on stderr and continue. Symmetrical with
# the unresolvable-SHA report above, and non-fatal for the same reason: a gap in
# grounding should be visible, not cost the evidence file.
read -r n_done n_art <<<"$(printf '%s' "$out" | jq -r '
  . as $o
  | ([ $o.tasks[] | select(.status == "completed") ] | length) as $d
  | ([ $o.tasks[].artifacts[] ] | length) as $a
  | "\($d) \($a)"')"

if [ "$n_done" -gt 0 ] && [ "$n_art" -eq 0 ]; then
  n_commits="$(printf '%s' "$commits" | jq 'length')"
  if [ "$has_git" -eq 0 ]; then
    why="$cwd is not a git repository, so no commit can be discovered"
  elif [ "$n_commits" -eq 0 ] && [ "$n_argv" -eq 0 ]; then
    why="no commits fall in the session window and none were passed"
  elif [ "$n_commits" -eq 0 ]; then
    why="none of the $n_argv SHAs passed resolve in $cwd, and no commits fall in the session window"
  else
    why="none of the $n_commits commits in scope ($n_found from the window) names a bead id or falls inside a bead active range"
  fi
  echo "emit-evidence-beads: $n_done completed tasks, 0 artifacts. ${why}. A commit grounds a task by naming it — a Closes <bead-id> trailer, or the issue ref in the conventional-commit scope. Grounding for this session is unmeasured, not absent." >&2
fi

mkdir -p "$EVIDENCE/$sid"
path="$EVIDENCE/$sid/beads-$(date -u +%Y%m%dT%H%M%SZ).json"
printf '%s\n' "$out" > "$path"
echo "$path"
