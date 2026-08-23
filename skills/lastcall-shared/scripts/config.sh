#!/usr/bin/env bash
# config.sh — lastcall preferences: what the user already answered, so a wrap-up
# does not have to re-ask it every session.
#
#   config.sh get                  # resolved prefs for this repo, as JSON
#   config.sh get <key>            # one resolved value, bare (true/false)
#   config.sh set <key> <value>    # record a pref for this repo
#   config.sh init                 # stamp this repo as set up, on this version
#   config.sh drift                # has setup gained options since? read-only
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

# When each slot in that vocabulary first became a question setup could ask.
# `drift` reads this to answer "does this config predate something the setup
# screen would ask today" without re-running setup at the user to find out.
#
# A row means: a config stamped OLDER than `version` predates these slots.
#
# SEEDED FROM WHAT ACTUALLY SHIPPED, and it has to stay that way. No release
# before the one below had a config store at all, so all four slots arrive
# together and every config in existence today reports NO drift. That is the
# honest answer, not a missing feature — the table is here for the NEXT slot,
# and adding a row is the whole cost of wiring one into the upgrade offer.
#
# The version below is the earliest a config can claim, not a guess at the
# release this lands in: entries written by this code stamp whatever
# plugin.json says, so keying the slots to that same value is what makes a
# config written today read as current rather than as instantly drifted.
SLOT_HISTORY='[
  { "version": "0.3.1",
    "slots": ["memories", "ledger", "report", "file_issues"] }
]'

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
# The free half, split out because `drift` runs on every close and must not
# spawn a process to fill in a field that never changes its answer.
cc_version_fast() {
  local p="${CLAUDE_CODE_EXECPATH:-}" v
  v="$(basename "$p" 2>/dev/null || true)"
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) printf '%s' "$v" ;;
  esac
}

cc_version() {
  local v
  v="$(cc_version_fast)"
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
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
# The schema string the file actually carries, kept even when it does not match.
# STATE collapses every unreadable config to one value, but telling an OLDER
# schema from a NEWER one is the difference between something that might be
# migrated and something that must not be touched, so the raw string survives.
SEEN_SCHEMA=''

load() {
  SEEN_SCHEMA=''
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
  SEEN_SCHEMA="$s"
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
          configured:       (if $p == null then false
                             elif $p.setup_ran == null then false
                             else $p.setup_ran end),
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
                            # setup_ran distinguishes "the setup screen ran" from
                            # "an entry exists". A bare `set` creates an entry
                            # without the user ever having seen setup, and
                            # treating that as configured would skip first run
                            # forever. Only `init` asserts it.
                            setup_ran:        $restamp,
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
                                   | .setup_ran        = true
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

# Does this project config predate something setup would ask today?
#
# READ-ONLY, and that is the entire point. It reports; it never re-runs setup,
# never writes, never applies a new default. An upgrade must not change
# behaviour under a user who never asked for it, so the upgrade path can only
# ever be an OFFER, and this is what decides whether that offer is honest.
#
# `self_heal` is deliberately not called here even though every other read
# calls it: it writes, and a repaired repo_root is not worth making a read into
# a write. `get` already heals; a close that runs `drift` will have run `get`.
#
# TWO KINDS OF DRIFT, and they are not symmetric:
#   version — the stamp predates a release that ADDED a slot. Offerable.
#   schema  — the stored shape is not this one. An older shape might one day be
#             migrated; a NEWER one was written by software this code does not
#             understand, and the only safe answer is unknown. Writes already
#             refuse on an unknown schema and drift must not become a way round
#             that, so it recommends nothing there.
#
# ENVIRONMENT DRIFT IS NOT MEASURED HERE. A tracker that was unreachable at
# setup and is now reachable shows up in the session tool list, which the model
# already has for nothing; `claude mcp list` costs ~3.9s and must not run on
# every close.
cmd_drift() {
  load
  local lv cv
  lv="$(lastcall_version)"
  cv="$(cc_version_fast)"

  jq -n --argjson cfg "$CFG" --argjson hist "$SLOT_HISTORY" --argjson b "$BUILTINS" \
        --arg state "$STATE" --arg seen "$SEEN_SCHEMA" --arg schema "$SCHEMA" \
        --arg lv "$lv" --arg cv "$cv" \
        --arg origin "$ORIGIN" --arg root "$ROOT" --arg path "$CONFIG" '
    # WARNING: no apostrophes anywhere in this program, comments included. It is
    # a single-quoted shell string and one apostrophe ends it early, with the
    # error landing far from the typo. Write "the row", never the possessive.
    def blank: if . == "" then null else . end;

    # Numeric compare, never string compare: "0.10.0" sorts BEFORE "0.9.0" as
    # text and after it as a version. A pre-release suffix is dropped, so
    # 0.4.0-rc1 counts as 0.4.0 — which errs toward NOT offering, the safe
    # direction for something that only ever produces an offer.
    def vparse: (. // "") | tostring | split("-") | .[0] | split(".")
                | map(tonumber? // 0) | (. + [0, 0, 0]) | .[0:3];
    # A version that cannot be read is UNMEASURED, never old. Treating it as old
    # would put an upgrade prompt in front of someone on nothing at all.
    def vknown: (. // "") | tostring | test("^[0-9]+\\.[0-9]+");

    # "lastcall.config/1" splits into a family and an integer, which is what
    # lets an older schema be told from a newer one. Anything not shaped like
    # that is unrecognized, and unrecognized is never upgradable.
    def sfam: (. // "") | split("/") | (.[0] // null);
    def snum: (. // "") | split("/") | (.[1] // "") | (tonumber? // null);

    ($seen | sfam) as $sf | ($seen | snum) as $sn
    | ($schema | sfam) as $cf | ($schema | snum) as $cn
    | (if   $seen == ""      then null
       elif $seen == $schema then "same"
       elif $sf == $cf and $sn != null and $cn != null
       then (if $sn > $cn then "newer" else "older" end)
       else "unrecognized" end) as $rel

    # Same match rule as resolve: origin where there is one, path otherwise.
    | (($cfg.projects // [])
       | if $origin != ""
         then map(select(.origin == $origin))
         elif $root != ""
         then map(select(((.origin // "") == "") and .repo_root == $root))
         else [] end
       | first) as $p

    | ($p.lastcall_version // "") as $sv
    | ($b | keys_unsorted) as $known

    # A slot is new to THIS config when the stamp predates the release that
    # introduced it. Two filters keep the offer honest: a slot that has since
    # left the vocabulary is not offered, and neither is one the user has
    # already answered with `set`, because the stamp only moves on `init` and an
    # answered slot would otherwise resurface forever. `has`, not `//` — a
    # stored false is a real answer, and `false // x` is x.
    | ([ $hist[]
         | select(($sv | vknown) and (($sv | vparse) < (.version | vparse)))
         | .slots[]
         | select(. as $s | $known | index($s))
         | select(. as $s | ($p.prefs // {}) | has($s) | not) ]
       | unique) as $new

    | (if   $state == "absent"
       then { s: "absent", r: "first_run",
              why: ("no config at " + $path
                    + "; nothing here has ever been set up, which is a first run and not an upgrade") }
       elif $rel == "newer" or $rel == "unrecognized"
       then { s: "unknown", r: "none",
              why: ("the stored schema is " + $seen + ", not " + $schema
                    + "; it may have been written by a newer lastcall, so nothing is offered and nothing is rewritten") }
       # Before the generic unreadable branch: an unknown schema is unreadable
       # by definition, and the DIRECTION is the whole point. Drifted, but with
       # nothing to recommend, because a write here would be the overwrite the
       # write side already refuses.
       elif $rel == "older"
       then { s: "drifted", r: "none",
              why: ("the stored schema " + $seen + " predates " + $schema
                    + " and this version carries no migration for it, so the file has to be inspected or removed by hand") }
       elif $state != "ok"
       then { s: "unknown", r: "none",
              why: ("the config at " + $path
                    + " could not be read, so drift is unmeasured rather than absent") }
       elif $p == null
       then { s: "absent", r: "first_run",
              why: "the config holds no entry for this project, so this is a first run here and not an upgrade" }
       # An entry can exist without setup ever having run: a bare `set` creates
       # one. That user has not seen the setup screen, so they belong to the
       # first-run population, not the upgrade one. Explicit null test rather
       # than `//`, because setup_ran is a boolean and `false // true` is `true`.
       elif (if $p.setup_ran == null then false else $p.setup_ran end) | not
       then { s: "absent", r: "first_run",
              why: "this project has preferences but never went through setup, so it is a first run and not an upgrade" }
       elif ($sv | vknown | not)
       then { s: "unknown", r: "none",
              why: "the entry carries no readable lastcall_version, so what it predates cannot be told" }
       elif ($lv | vknown | not)
       then { s: "unknown", r: "none",
              why: "the running lastcall version could not be read, so there is nothing to compare the stamp against" }
       elif ($sv | vparse) > ($lv | vparse)
       then { s: "unknown", r: "none",
              why: ("the entry was written by lastcall " + $sv + ", which is newer than the " + $lv
                    + " reading it; nothing is offered") }
       elif ($new | length) > 0
       then { s: "drifted", r: "rerun_setup",
              why: ("setup has gained " + ($new | length | tostring)
                    + " option(s) since this project was configured on lastcall " + $sv) }
       else { s: "current", r: "none",
              why: ("configured on lastcall " + $sv + " and setup has asked nothing new since") }
       end) as $v

    | { state: $v.s,
        # An OFFER and never an instruction. rerun_setup is the ONLY value that
        # means there is anything to put in front of the user at all; first_run
        # routes to the first-run screen, which is a different population.
        recommend: $v.r,
        schema_relation: $rel,
        path: $path,
        stored:  { lastcall_version: $p.lastcall_version,
                   # Recorded, never decisive. A Claude Code upgrade does not
                   # add lastcall slots, so it cannot produce an offer.
                   cc_version:       $p.cc_version,
                   schema:           ($seen | blank),
                   configured_at:    $p.configured_at },
        current: { lastcall_version: ($lv | blank),
                   cc_version:       ($cv | blank),
                   schema:           $schema },
        # Only ever populated for version drift, and only with slots that still
        # exist and that this config has never answered.
        new_slots: (if $v.r == "rerun_setup" then $new else [] end),
        reason: $v.why }
  '
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
  drift)  shift; cmd_drift "$@" ;;
  forget) shift; cmd_forget "$@" ;;
  path)   shift; cmd_path "$@" ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
