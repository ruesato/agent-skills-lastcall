#!/usr/bin/env bash
# doctrine-check.sh — detect instructions that contradict the memory system
# last-call depends on.
#
#   doctrine-check.sh [project-dir]     # defaults to $PWD
#
# Why this exists: beads ships guidance that says "Do NOT use MEMORY.md files".
# That instruction is correct for a beads-only workspace and wrong here, where
# `memory/MEMORY.md` is authoritative and last-call's memories delegation
# writes to it. If that rule takes effect, last-call is told to bypass exactly
# the system it depends on, and the failure is silent — memories simply stop
# being written, with no error.
#
# Two vectors reinstate it, and only one is a file:
#
#   1. The beads-managed block in CLAUDE.md / AGENTS.md, which `bd init` and
#      beads upgrades regenerate, discarding hand edits inside the markers.
#   2. `bd prime` output, emitted fresh every session by the beads plugin's
#      SessionStart hook. This is compiled into the binary — there is no file
#      to correct, so an override outside the managed block is the only fix.
#
# Exits 0 even when it finds conflicts: this is an advisory for a human, not a
# gate. Callers read the JSON.
set -euo pipefail

DIR="${1:-$PWD}"

# grep exits 1 on no match, which under `set -e` would kill the script on the
# healthy path. Scope `|| true` to each call. See the recurring trap noted in
# CLAUDE.md.
scan() {  # scan <label> <file-or-"-"> ; reads stdin when file is "-"
  local label="$1" src="$2" body
  # Both branches emit "<lineno>: <text>", so grep runs without -n below and
  # never double-prefixes.
  if [ "$src" = "-" ]; then body="$(awk '{print FNR": "$0}')"; else
    [ -f "$src" ] || return 0
    # Only the beads-managed blocks. The project override lives OUTSIDE the
    # markers and necessarily quotes the rule in order to countermand it —
    # scanning the whole file flags that override as a conflict, which is
    # backwards. Keep real line numbers so a finding is locatable.
    body="$(awk '/BEGIN BEADS/{inblk=1} inblk{print FNR": "$0} /END BEADS/{inblk=0}' "$src")"
  fi
  printf '%s' "$body" \
    | grep -iE 'do not use MEMORY\.md|not use MEMORY\.md|do NOT use TodoWrite' \
    | head -10 \
    | jq -Rs --arg v "$label" 'split("\n") | map(select(length > 0))
        | map({vector: $v, line: .})' \
    || true
}

FINDINGS='[]'
add() { FINDINGS="$(jq -c --argjson a "$FINDINGS" --argjson b "${1:-[]}" -n '$a + $b')"; }

for f in CLAUDE.md AGENTS.md; do
  add "$(scan "$f" "$DIR/$f")"
done

# The live vector: what a session in DIR actually gets told at startup. Run bd
# from DIR, not the caller cwd — `bd prime` output is workspace-dependent, and
# scanning DIR's files while priming somewhere else would mix two projects.
if command -v bd >/dev/null 2>&1; then
  add "$( (cd "$DIR" 2>/dev/null && bd prime 2>/dev/null) | scan 'bd prime (plugin hook)' - || true)"
fi

jq -n --argjson f "$FINDINGS" '
  { memory_system: "memory/MEMORY.md",
    conflicts: $f,
    status: (if ($f | length) == 0 then "clear" else "conflicts-present" end),
    # An override outside the managed markers is what makes this survivable.
    override_documented: true,
    note: (if ($f | length) == 0 then
             "No contradicting instruction found."
           else
             "Contradicting guidance is live. The override in CLAUDE.md outside the beads markers takes precedence: memory/MEMORY.md is authoritative here. Do not follow the quoted lines."
           end) }'
