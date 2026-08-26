#!/usr/bin/env bash
# doctrine-check.sh — detect instructions that contradict the memory system
# lastcall depends on.
#
#   doctrine-check.sh [project-dir]     # defaults to $PWD
#
# LASTCALL_MEMORY_SYSTEM names the store that is authoritative in the host
# harness; it defaults to memory/MEMORY.md and only labels the advisory.
#
# Why this exists: beads ships guidance that says "Do NOT use MEMORY.md files".
# That instruction is correct for a beads-only workspace and wrong here, where
# `memory/MEMORY.md` is authoritative and lastcall's memories delegation
# writes to it. If that rule takes effect, lastcall is told to bypass exactly
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

# Which store is authoritative is a property of the HOST HARNESS, not of this
# script. install.sh targets Kiro and Codex as well as Claude Code, and the
# lastcall instructions already say to follow "the environment's memory system"
# with MEMORY.md as the parenthetical instance. Emitting the literal would have
# the advisory assert a store the harness may not use. This is a name, not a
# dispatch: nothing downstream branches on it.
MEMORY_SYSTEM="${LASTCALL_MEMORY_SYSTEM:-memory/MEMORY.md}"

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
#
# CACHED, because this runs on every wrap-up and a process spawn on that path
# is the cost discipline detect.sh already applies to its MCP probe. The cache
# is keyed on a FINGERPRINT rather than aged out on a clock: a stale answer
# here would be a confident false "clear" from the one check that exists to
# catch a silent memory failure, which is worse than the spawn it saves.
#
# The fingerprint is what the output actually depends on — the workspace, the
# bd binary (the doctrine rule is compiled into it, which is the whole reason
# this vector has no file to correct), and the mtime of the beads directory,
# which moves when the workspace state behind `bd prime` does. Any of the three
# changing misses the cache and re-primes. LASTCALL_DOCTRINE_CACHE=0 disables
# it outright.
prime_output() {
  local out cache key stamp bdbin
  bdbin="$(command -v bd 2>/dev/null || true)"
  if [ "${LASTCALL_DOCTRINE_CACHE:-1}" = "0" ] || [ -z "$bdbin" ]; then
    (cd "$DIR" 2>/dev/null && bd prime 2>/dev/null) || true
    return 0
  fi
  stamp="$DIR|$bdbin|$(stat -f '%m %z' "$bdbin" 2>/dev/null || stat -c '%Y %s' "$bdbin" 2>/dev/null || echo unknown)|$(stat -f %m "$DIR/.beads" 2>/dev/null || stat -c %Y "$DIR/.beads" 2>/dev/null || echo none)"
  key="$(printf '%s' "$stamp" | (shasum -a 256 2>/dev/null || sha256sum 2>/dev/null) | cut -d" " -f1)"
  # No usable digest tool: prime rather than cache under a guessable key.
  if [ -z "$key" ]; then
    (cd "$DIR" 2>/dev/null && bd prime 2>/dev/null) || true
    return 0
  fi
  cache="${LASTCALL_STATE_DIR:-$HOME/.claude/lastcall}/doctrine/$key"
  if [ -f "$cache" ]; then cat "$cache"; return 0; fi
  out="$( (cd "$DIR" 2>/dev/null && bd prime 2>/dev/null) || true )"
  # Written beside the destination and renamed, so a concurrent wrap-up never
  # reads a half-written cache. A failed write costs a spawn next time, which
  # is the pre-cache behaviour and therefore safe to swallow.
  if mkdir -p "$(dirname "$cache")" 2>/dev/null; then
    printf '%s\n' "$out" > "$cache.$$" 2>/dev/null \
      && mv -f "$cache.$$" "$cache" 2>/dev/null || rm -f "$cache.$$" 2>/dev/null || true
  fi
  printf '%s\n' "$out"
}
if command -v bd >/dev/null 2>&1; then
  add "$(prime_output | scan 'bd prime (plugin hook)' - || true)"
fi

jq -n --argjson f "$FINDINGS" --arg mem "$MEMORY_SYSTEM" '
  { memory_system: $mem,
    conflicts: $f,
    status: (if ($f | length) == 0 then "clear" else "conflicts-present" end),
    # An override outside the managed markers is what makes this survivable.
    override_documented: true,
    note: (if ($f | length) == 0 then
             "No contradicting instruction found."
           else
             "Contradicting guidance is live. The override in CLAUDE.md outside the beads markers takes precedence: " + $mem + " is authoritative here. Do not follow the quoted lines."
           end) }'
