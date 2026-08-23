#!/usr/bin/env bash
# config.sh — lastcall preferences: what the user already answered, so a wrap-up
# does not have to re-ask it every session.
#
#   config.sh get                  # resolved prefs for this repo, as JSON
#   config.sh get <key>            # one resolved value, bare (true/false)
#   config.sh set <key> <value>    # record a pref for this repo
#   config.sh init                 # stamp this repo as set up, on this version
#   config.sh forget               # drop this repo entry; other repos untouched
#   config.sh path                 # where the config lives
#
# Preferences, not team facts. This deliberately does NOT live in the repo the
# way Fathom keeps .fathom/config.md: base-branch and state-mapping are facts
# about a project and belong to everyone who clones it, whereas "do I want a
# report published" is one person taste and would be wrong to impose on a clone.
#
# NOTHING HERE AUTHORIZES AN ACTION. A stored preference only seeds how a gate
# is worded and pre-selected; the gate still fires. That is why a missing config
# is safe: with no config at all, every value falls through to a built-in that
# equals v0.3.1 behaviour, so lastcall behaves exactly as it did before this
# file existed. Deleting the config is a supported way to reset.
set -euo pipefail

# Resolve through symlinks — install.sh links this onto PATH, and plugin.json
# lives beside the real file, not beside the link. `readlink -f` is GNU-only,
# so walk the chain by hand. Same idiom as cost.sh.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  target="$(readlink "$SELF")"
  case "$target" in /*) SELF="$target" ;; *) SELF="$(dirname "$SELF")/$target" ;; esac
done
HERE="$(cd "$(dirname "$SELF")" && pwd)"

# The ONLY path this script ever writes. Everything below funnels through
# write_config, which cannot be pointed anywhere else — the allowed-tools grant
# that lets lastcall run this script has to stay that narrow.
# Matches the five existing overrides: LASTCALL_LEDGER, LASTCALL_EVIDENCE_DIR,
# LASTCALL_STATUSLINE_DIR, LASTCALL_RATES, CLAUDE_PROJECTS.
CONFIG="${LASTCALL_CONFIG:-$HOME/.claude/lastcall/config.json}"
SCHEMA="lastcall.config/1"

# The closed vocabulary, and the built-in fallback for each slot. These values
# ARE v0.3.1 behaviour — a user with no config resolves entirely to this table,
# so changing a value here changes what an unconfigured user gets. A NEW key
# added here must be additive: its built-in has to describe what lastcall
# already does, or adding it flips behaviour for every existing user, which is
# exactly what the 9cx.5 blast-radius rule forbids.
BUILTINS='{
  "memories":    true,
  "ledger":      true,
  "report":      false,
  "file_issues": false
}'

# ------------------------------------------------------------------ repo key
#
# KEYED ON GIT ORIGIN, NOT CWD. A cwd key fails twice on an ordinary machine,
# measured here rather than assumed: ~/.claude/projects/ currently holds BOTH
# -Users-ryanuesato-code-agent-skill-wrapup and -...-agent-skill-lastcall (one
# repo, renamed), and BOTH -Users-ryanuesato-code-ima-app and
# -...-ima-app--claude-worktrees-feat-ui-refinement (one repo, plus a worktree).
# A cwd-keyed preference would be lost by the rename and would not be seen from
# the worktree. Same pair of failures contracts.md section 2 cites for keying
# evidence on session id; session id is unusable here because a preference must
# OUTLIVE the session.
repo_origin() {
  git config --local --get remote.origin.url 2>/dev/null || true
}

# --git-common-dir, not --show-toplevel. Verified from the real worktree at
# ~/code/ima-app/.claude/worktrees/: --show-toplevel returns the worktree path,
# --git-common-dir returns /Users/ryanuesato/code/ima-app/.git, so its dirname
# is the main checkout and a worktree session shares the main repo entry.
# It returns a path relative to cwd when run inside the main checkout (measured:
# plain `.git` at the root, `../../../.git` three levels down), so the result is
# absolutised with cd+pwd rather than used as-is.
repo_root() {
  local gcd
  gcd="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
  [ -n "$gcd" ] || return 0
  (cd "$(dirname "$gcd")" 2>/dev/null && pwd -P) || return 0
}

ORIGIN="$(repo_origin)"
ROOT="$(repo_root)"

# ------------------------------------------------------------------ versions
#
# Stamped into every project entry so the upgrade path can tell a config written
# by an older setup flow from a current one. Without them, version drift is
# invisible and an existing user is frozen on whatever the first setup screen
# happened to ask.
lastcall_version() {
  local m="$HERE/../../../.claude-plugin/plugin.json"
  [ -f "$m" ] || return 0
  jq -r '.version // empty' "$m" 2>/dev/null || true
}

# Two sources, both fallible, and absence is recorded as null — unmeasured,
# never "old". CLAUDE_CODE_EXECPATH is free and names the binary actually
# running; `claude` on PATH may be a wrapper shim pointing somewhere else
# (measured on this machine, it is). Neither is a documented contract, so both
# are read defensively.
cc_version() {
  local p="${CLAUDE_CODE_EXECPATH:-}" v
  v="$(basename "$p" 2>/dev/null || true)"
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) printf '%s' "$v"; return 0 ;;
  esac
  command -v claude >/dev/null 2>&1 || return 0
  v="$(claude --version 2>/dev/null | awk 'NR==1{print $1}')" || return 0
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) printf '%s' "$v" ;;
  esac
}

# ------------------------------------------------------------------ read side
#
# CFG is the parsed config or the JSON literal null; STATE says WHY it is null,
# because "you have never set up" and "your config is damaged" are different
# things to tell a user.
CFG='null'
STATE='absent'

load() {
  [ -f "$CONFIG" ] || { CFG='null'; STATE='absent'; return 0; }

  local parsed
  if ! parsed="$(jq -c 'if type == "object" then . else error("not an object") end' \
                 "$CONFIG" 2>/dev/null)"; then
    # Degrade, never abort. A preferences file is not worth failing a wrap-up
    # over — the same call meter-session.sh makes on an unparseable statusline
    # capture, and ledger.sh on an unparseable evidence file.
    echo "config: $CONFIG is unparseable — treating as absent, using built-in defaults" >&2
    CFG='null'; STATE='unreadable'; return 0
  fi

  local s; s="$(printf '%s' "$parsed" | jq -r '.schema // ""')"
  if [ "$s" != "$SCHEMA" ]; then
    echo "config: $CONFIG carries schema \"$s\", expected $SCHEMA — treating as absent" >&2
    CFG='null'; STATE='unreadable'; return 0
  fi

  CFG="$parsed"; STATE='ok'
}

# Resolve the effective prefs for this repo. Fall-through order is
# project entry -> stored defaults -> built-in, and a value missing at every
# level still produces an answer, so a caller never has to handle "absent".
resolve() {
  jq -n --argjson cfg "$CFG" --argjson b "$BUILTINS" \
        --arg origin "$ORIGIN" --arg root "$ROOT" \
        --arg path "$CONFIG" --arg state "$STATE" '
    # WARNING: no apostrophes anywhere in this program, comments included. It is
    # a single-quoted shell string and one apostrophe ends it early, with the
    # error landing far from the typo. Write "the row", never the possessive.

    # Match on origin when there is one. A repo with no remote can only be keyed
    # on its path, which means a rename loses its entry — unavoidable, and the
    # reason origin is preferred wherever it exists.
    (($cfg.projects // [])
     | if $origin != ""
       then map(select(.origin == $origin))
       elif $root != ""
       then map(select(((.origin // "") == "") and .repo_root == $root))
       else [] end
     | first) as $p

    | ($b | keys_unsorted) as $keys
    | [ $keys[]
        | . as $k
        # `//` CANNOT default a boolean here: `false // x` is x in jq, which
        # collapses exactly the stored value being read. Test against null.
        | ($p.prefs[$k]) as $pv
        | ($cfg.defaults[$k]) as $dv
        | if   $pv != null then { key: $k, value: $pv, source: "project"  }
          elif $dv != null then { key: $k, value: $dv, source: "defaults" }
          else                   { key: $k, value: $b[$k], source: "builtin" } end
      ] as $rows

    | { schema: "lastcall.config/1",
        path:  $path,
        # absent = never set up. unreadable = damaged, and already warned about.
        state: $state,
        repo: {
          origin:   (if $origin == "" then null else $origin end),
          root:     (if $root   == "" then null else $root   end),
          keyed_by: (if $origin != "" then "origin"
                     elif $root != "" then "repo_root" else null end)
        },
        project: {
          # The first-run screen turns on THIS, not on any pref value: a pref
          # can equal its built-in and still never have been answered.
          configured:       ($p != null),
          configured_at:    $p.configured_at,
          lastcall_version: $p.lastcall_version,
          cc_version:       $p.cc_version
        },
        # `add` overwrites duplicate keys rather than merging them. Safe here
        # only because the keys come from `keys_unsorted` and are unique.
        prefs:   ($rows | map({ (.key): .value  }) | add // {}),
        sources: ($rows | map({ (.key): .source }) | add // {}) }
  '
}

# ----------------------------------------------------------------- write side

# The single writer. Every mutation goes through here, and it takes no path
# argument, so this script is structurally incapable of writing anywhere but
# $CONFIG and a temp beside it.
#
# The temp lives in the config directory rather than $TMPDIR so the rename is
# same-filesystem and therefore atomic — a cross-device `mv` is a copy, and a
# torn config would be read as damaged. capture-statusline.sh does the same,
# for the same reason.
write_config() {
  local json="$1" dir tmp
  dir="$(dirname "$CONFIG")"
  mkdir -p "$dir"
  tmp="$dir/.config.$$.json"
  printf '%s\n' "$json" > "$tmp"
  mv -f "$tmp" "$CONFIG"
}

# Reads degrade; writes refuse. Treating a damaged file as absent and then
# writing over it would destroy whatever it held — including a config written by
# a NEWER lastcall, which reads as unknown-schema here. Name the path and stop.
guard_writable() {
  # A $CONFIG that exists but is not a regular file — a directory, most
  # plausibly from a mistyped override — would make `mv` move the temp INSIDE
  # it, which is a write to a path other than $CONFIG. Refuse before that.
  if [ -e "$CONFIG" ] && [ ! -f "$CONFIG" ]; then
    echo "config: $CONFIG exists and is not a regular file — refusing to write." >&2
    exit 4
  fi
  if [ -f "$CONFIG" ] && [ "$STATE" != "ok" ]; then
    echo "config: refusing to overwrite $CONFIG — it is unreadable and may hold" >&2
    echo "        settings this version does not understand. Inspect or remove it." >&2
    exit 4
  fi
}

require_repo() {
  [ -n "$ROOT" ] && return 0
  echo "config: not inside a git repository — there is nothing to key a preference to." >&2
  echo "        Reads still work and fall through to built-in defaults." >&2
  exit 3
}

# Create or update this repo entry. $patch merges into prefs; $restamp records
# that setup RAN, which is the signal the upgrade path reads, so a single `set`
# must not claim it.
upsert_entry() {
  local patch="$1" restamp="$2" lv cv now out
  lv="$(lastcall_version)"; cv="$(cc_version)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  out="$(jq -n --argjson cfg "$CFG" --argjson b "$BUILTINS" \
               --argjson patch "$patch" --argjson restamp "$restamp" \
               --arg origin "$ORIGIN" --arg root "$ROOT" \
               --arg lv "$lv" --arg cv "$cv" --arg now "$now" '
    # WARNING: no apostrophes in this program or its comments. See resolve.
    def blank: if . == "" then null else . end;

    (if $cfg == null
     # `defaults` is written ONCE, as a snapshot of the built-ins in force the
     # day the config was created. That is what makes the blast-radius rule
     # mechanical rather than a promise: a later release changing a built-in
     # cannot move an existing user, because their answer is already pinned
     # here. New built-ins still fall through for keys this snapshot lacks.
     then { schema: "lastcall.config/1", defaults: $b, projects: [] }
     else $cfg end)
    | .defaults = (.defaults // $b)
    | .projects = (.projects // [])

    | ([ .projects | to_entries[]
         | select(if $origin != ""
                  then .value.origin == $origin
                  else ((.value.origin // "") == "") and .value.repo_root == $root end)
         | .key ] | first) as $i

    | if $i == null
      then .projects += [ { origin:           ($origin | blank),
                            repo_root:        $root,
                            configured_at:    $now,
                            # A brand new entry is always stamped: whatever
                            # wrote it was running this version.
                            lastcall_version: ($lv | blank),
                            cc_version:       ($cv | blank),
                            prefs:            $patch } ]
      # Matched on origin, so a stale repo_root here is a rename or a move.
      # Rewriting it is the self-heal.
      else .projects[$i] |= ( .repo_root = $root
                              # Object + overwrites on the right, which is the
                              # intended merge for a set. Not `add`.
                              | .prefs = ((.prefs // {}) + $patch)
                              | if $restamp
                                then .configured_at    = $now
                                   | .lastcall_version = ($lv | blank)
                                   | .cc_version       = ($cv | blank)
                                else . end )
      end
  ')"
  write_config "$out"
  printf '%s\n' "$out" | jq -c --arg origin "$ORIGIN" --arg root "$ROOT" '
    .projects
    | if $origin != "" then map(select(.origin == $origin))
      else map(select(((.origin // "") == "") and .repo_root == $root)) end
    | first'
}

# Rewrite a stale repo_root when the entry was found by origin. A rename would
# otherwise leave the entry pointing at a directory that no longer exists, which
# is the failure emit-evidence-beads.sh already measures on recorded cwd (5 of
# 26 sessions carry a stale one). Best effort: a read must never fail because
# the config is read-only or the disk is full.
self_heal() {
  [ "$STATE" = "ok" ] || return 0
  [ -n "$ORIGIN" ] && [ -n "$ROOT" ] || return 0

  local stale
  stale="$(printf '%s' "$CFG" | jq -r --arg o "$ORIGIN" --arg r "$ROOT" '
    .projects // [] | map(select(.origin == $o)) | first
    | if . == null or .repo_root == $r then "" else (.repo_root // "") end')"
  [ -n "$stale" ] || return 0

  local out
  out="$(printf '%s' "$CFG" | jq --arg o "$ORIGIN" --arg r "$ROOT" '
    .projects |= map(if .origin == $o then .repo_root = $r else . end)')" || return 0
  if write_config "$out" 2>/dev/null; then
    CFG="$out"
    echo "config: repo moved ($stale -> $ROOT); updated the entry in place" >&2
  fi
}

# -------------------------------------------------------------------- helpers

known_keys() { printf '%s' "$BUILTINS" | jq -r 'keys_unsorted | join(", ")'; }

# A typo must not read as "absent" and silently take the built-in — that is a
# preference quietly not applying, which is the failure mode this whole feature
# exists to avoid. Unknown keys are an error on both get and set.
check_key() {
  if ! printf '%s' "$BUILTINS" | jq -e --arg k "$1" 'has($k)' >/dev/null 2>&1; then
    echo "config: unknown key \"$1\" — known keys: $(known_keys)" >&2
    exit 2
  fi
}

# Validate against the slot type declared by the built-in, so the vocabulary
# table stays the single source of truth when a non-boolean slot is added.
coerce() {
  local key="$1" val="$2" t
  t="$(printf '%s' "$BUILTINS" | jq -r --arg k "$key" '.[$k] | type')"
  case "$t" in
    boolean)
      case "$val" in
        true)  printf 'true'  ;;
        false) printf 'false' ;;
        *) echo "config: $key is a boolean — pass true or false, not \"$val\"" >&2; exit 2 ;;
      esac ;;
    *) printf '%s' "$val" | jq -Rs . ;;
  esac
}

# ------------------------------------------------------------------- commands

cmd_get() {
  load; self_heal
  local key="${1:-}"
  if [ -z "$key" ]; then resolve | jq .; return 0; fi
  check_key "$key"
  resolve | jq -r --arg k "$key" '.prefs[$k] | tostring'
}

cmd_set() {
  local key="${1:?set needs a key}" val="${2:?set needs a value}" jval
  check_key "$key"
  jval="$(coerce "$key" "$val")"
  require_repo; load; guard_writable
  upsert_entry "$(jq -cn --arg k "$key" --argjson v "$jval" '{ ($k): $v }')" false
}

cmd_init() {
  require_repo; load; guard_writable
  upsert_entry '{}' true
}

cmd_forget() {
  require_repo; load; guard_writable
  [ "$STATE" = "ok" ] || { echo "config: nothing to forget — no config at $CONFIG" >&2; return 0; }
  write_config "$(printf '%s' "$CFG" | jq --arg o "$ORIGIN" --arg r "$ROOT" '
    .projects = ((.projects // [])
      | map(select(if $o != "" then .origin != $o
                   else (((.origin // "") != "") or .repo_root != $r) end)))')"
}

cmd_path() { printf '%s\n' "$CONFIG"; }

case "${1:-}" in
  get)    shift; cmd_get "$@" ;;
  set)    shift; cmd_set "$@" ;;
  init)   shift; cmd_init "$@" ;;
  forget) shift; cmd_forget "$@" ;;
  path)   shift; cmd_path "$@" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
