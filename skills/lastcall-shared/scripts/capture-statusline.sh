#!/usr/bin/env bash
# capture-statusline.sh — pass-through capture of the Claude Code statusLine payload.
#
# Add it to a status line you ALREADY own, as the first stage of a pipe:
#
#   "statusLine": { "type": "command",
#                   "command": "~/.lastcall/bin/capture-statusline.sh | ~/.claude/statusline.sh" }
#
# It writes the payload where meter-session.sh can find it and copies stdin to
# stdout unchanged, so the status line you already have keeps printing exactly
# what it printed before.
#
# This is the only local source for rate_limits.five_hour / seven_day, which
# appear nowhere in a transcript. install.sh never writes settings.json: a
# statusLine is a single object per settings file and a higher-precedence scope
# replaces it wholesale, so installing one would silently destroy a status line
# the user built, and giving a status line to someone who had none suppresses
# footer keyboard hints including "esc to interrupt". Opting in is one line the
# user adds themselves.
#
# NOT set -e. This runs on every assistant message in every session; a failure
# here must degrade to "no capture", never to a broken status line. Every error
# path falls through to the pass-through and exit 0.
set -uo pipefail

DIR="${LASTCALL_STATUSLINE_DIR:-$HOME/.claude/lastcall/statusline}"
KEEP_DAYS="${LASTCALL_STATUSLINE_KEEP_DAYS:-7}"

# stdin lands in a real file rather than a shell variable so the copy to stdout
# is byte-identical: $(cat) eats trailing newlines, and the contract here is
# that the next stage sees exactly what Claude Code sent.
# An explicit template, not `mktemp -t`: GNU coreutils requires at least three
# trailing X and rejects a bare prefix, which would make mktemp fail on Linux.
# The script would still pass stdin through and exit 0 — the fail-safe holds —
# but the capture would silently never be written, with no diagnostic anywhere.
TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"
IN="$(mktemp "$TMP/lastcall-statusline.XXXXXX" 2>/dev/null)" || IN=""
[ -n "$IN" ] || { exec cat; }
trap 'rm -f "$IN" "${OUT:-/nonexistent}" 2>/dev/null' EXIT HUP INT TERM
cat > "$IN"

emit() { cat "$IN"; exit 0; }   # every failure path ends here

mkdir -p "$DIR" 2>/dev/null || emit

# One jq call, not two. This runs on every assistant message, so the payload is
# parsed once: the session id and the envelope come back on a single line
# separated by a tab, which no session id can contain.
LINE="$(jq -rc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    (.session_id // "")
    + "\t"
    + ({ schema: "lastcall.statusline/1", captured_at: $at, payload: . } | tojson)
  ' < "$IN" 2>/dev/null)" || emit

SID="${LINE%%$'\t'*}"
ENV="${LINE#*$'\t'}"
[ -n "$SID" ] && [ "$SID" != "$LINE" ] || emit

# The session id becomes a filename, so it is constrained rather than trusted.
# Claude Code sends a UUID; anything else does not get to name a path.
case "$SID" in
  *[!A-Za-z0-9_-]*|"") emit ;;
esac
[ "${#SID}" -le 128 ] || emit

# Claude Code CANCELS an in-flight status line script when a new update fires,
# so a plain redirect can leave a half-written file that the meter then has to
# defend against. Write a temp beside the destination (same filesystem, so the
# rename is atomic) and move it into place.
OUT="$DIR/.capture.$$.json"
printf '%s\n' "$ENV" > "$OUT" 2>/dev/null || emit
mv -f "$OUT" "$DIR/$SID.json" 2>/dev/null || emit
OUT=""

# One file per session id accumulates forever otherwise. Also sweeps temps
# stranded by a cancel that outran the trap. Pruned before the copy to stdout,
# which can block on a slow next stage.
find "$DIR" -maxdepth 1 -type f \
  \( -name '*.json' -mtime "+$KEEP_DAYS" -o -name '.capture.*' -mmin +60 \) \
  -delete 2>/dev/null || true

emit
