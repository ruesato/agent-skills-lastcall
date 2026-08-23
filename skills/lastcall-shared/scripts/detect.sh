#!/usr/bin/env bash
# detect.sh — what integrations exist in THIS working directory, and can they
# actually be reached.
#
#   detect.sh            # full probe, including reachability (~4s, see below)
#   detect.sh --cheap    # config only; every reachability becomes "unknown"
#   detect.sh --help
#
# Feeds the first-run setup screen. It answers "what is possible here", which
# is the probe half of the routing split: probe when the question has one right
# answer, prompt when it is a matter of taste. Nothing here decides anything and
# nothing here writes anything — this script has no side effects at all.
#
# FIRST-RUN ONLY. The reachability probe is `claude mcp list`, measured on this
# machine 2026-08-23 at 3.66s from agent-skill-lastcall and 3.81s from
# pharmgkb-mobile. That is a fifth of a whole wrap-up spent on a question whose
# answer changes about once a month, so it must not run on every session close.
# `--cheap` is the path for anything that runs per-session: it keeps every
# config-derived finding and downgrades every reachability to "unknown".
#
# THE INVARIANT THIS SCRIPT EXISTS TO ENFORCE: fail to "unknown", never to
# "absent". If `claude` is missing, times out, exits non-zero, or prints
# something this parser does not recognise, every reachability becomes
# "unknown" and every candidate found in config is still reported. Dropping a
# configured tracker because a parser broke would tell the user they have no
# tracker, which is a confident false statement; "unknown" is a true one. Same
# discipline as contracts.md invariant 11 on `native` — a missing field means
# unmeasured, never zero.
#
# WHY THE PARSER IS DEFENSIVE. `claude mcp list` has no `--json` (verified
# 2026-08-23: "error: unknown option '--json'"), so this rides human-readable
# output that is not a documented contract, exactly the hazard CLAUDE.md names
# for transcripts. It is also cwd-sensitive, correctly so: run from this repo
# the Linear line is absent, run from ~/code/pharmgkb-mobile it is present. And
# it shares its stream with SDK diagnostics such as
# "[mcp-sdk] SEP-2352: stored OAuth credential has no issuer stamp", so the
# parser is line-oriented and skips anything it does not recognise rather than
# treating a surprise line as a failure.
#
# CONNECTION IS NOT CAPABILITY. A server reported "connected" has an open
# transport. It has not been shown to expose any issue-WRITING tool. Every
# tracker row carries `capability: "unverified"` for that reason; a consumer
# must corroborate against its own tool list before offering to file anything.
#
# CROSS-HARNESS. `claude mcp list` does not exist in Kiro or Codex, the other
# two environments contracts.md section 0 targets. That is a documented no-op:
# the probe records `mcp.probe: "unavailable"`, reachability stays "unknown",
# and detection degrades to the config files. It never degrades to "true".
set -euo pipefail

CHEAP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cheap) CHEAP=1; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCHEMA="lastcall.detect/1"
CWD="$PWD"

# Same override the meter uses, so a test harness can point both at one fixture
# root. See meter-session.sh:12.
PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"

# The user-level Claude Code config. Overridable because the negative tests need
# to point it at a damaged file without rewriting $HOME, and because a harness
# may relocate it. Read-only: nothing in this script ever writes here.
CLAUDE_JSON="${LASTCALL_CLAUDE_JSON:-$HOME/.claude.json}"

# Generous relative to the 3.7-3.8s measured, because a cold stdio server spawn
# (npx, uvx) is slower than a warm one and a bounded-but-wrong answer is worse
# than a slow right one. Exceeding it is not an error, it is "unknown".
MCP_TIMEOUT_S="${LASTCALL_MCP_TIMEOUT_S:-20}"

CAVEATS='[]'
caveat() {
  CAVEATS="$(jq -c --argjson a "$CAVEATS" --arg s "$1" -n '$a + [$s]')"
}

# ------------------------------------------------------------------- bounding
#
# `timeout` and `gtimeout` are BOTH absent on this machine (verified 2026-08-23:
# macOS ships no GNU coreutils), so the bound is hand-rolled. Three details each
# of which was a real bug in the first version:
#
#   * KILL THE PROCESS GROUP, not the child. `claude` on this machine is a shim
#     that forks a node child, and TERM to the shim leaves the child running.
#     Measured: a bounded run against a shim that spawns `sleep 60` left the
#     sleep alive. `set -m` is what makes the group exist — without job control
#     the background job shares OUR group, so `kill -TERM -$pid` would kill the
#     caller. Leaking a process would be a side effect this script promises not
#     to have.
#   * THE WHOLE THING RUNS IN A SUBSHELL WITH STDERR CLOSED, because `set -m`
#     makes bash announce the kill as "Terminated: 15" on stderr. That line is
#     the shell talking, not the probe, and a consumer parsing this script
#     output should never see it. The command own output is captured to <out>
#     regardless, so nothing informative is lost.
#   * `set +e` inside, because a non-zero exit from the probe is DATA here, not
#     a failure — it is what distinguishes "error" from "unparsed".
run_bounded() {  # run_bounded <secs> <outfile> <cmd...>; 124 on timeout
  local secs="$1" out="$2"; shift 2
  ( set +e; set -m
    "$@" >"$out" 2>&1 &
    local pid=$! i=0 limit=$((secs * 10))
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$i" -ge "$limit" ]; then
        kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
        sleep 0.3
        kill -KILL -"$pid" 2>/dev/null
        wait "$pid"
        exit 124
      fi
      sleep 0.1
      i=$((i + 1))
    done
    wait "$pid"; exit $?
  ) 2>/dev/null
}

# Millisecond clock without assuming bash 5 ($EPOCHREALTIME): macOS still ships
# bash 3.2 and this script has no way to know which bash /usr/bin/env found.
# perl is the most portable of the three; `date +%s` is the floor, and 0 means
# unmeasured, which is what the wall_ms field reports as null.
now_ms() {
  perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000' 2>/dev/null && return 0
  local s; s="$(date +%s 2>/dev/null)" || { echo 0; return 0; }
  echo $((s * 1000))
}

# -------------------------------------------------------------------- harness
#
# Two sources for the Claude Code version, both fallible, absence recorded as
# null — unmeasured, never "old". Duplicated from config.sh rather than shared:
# these scripts are linked onto PATH individually by install.sh and none of them
# sources another, so there is nowhere shared to put it. The setup screen stamps
# this into the config entry (contracts.md section 4) so that a parse which goes
# stale against a future Claude Code is diagnosable instead of mysterious.
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

HAS_CLAUDE=false
command -v claude >/dev/null 2>&1 && HAS_CLAUDE=true
CC_VERSION="$(cc_version || true)"

# --------------------------------------------------------------------- memory
#
# PROBE ONLY, NEVER A CHOICE. Claude Code carries its own memory subsystem and
# it is always available, so there is no backend question to ask: an absent
# directory means "never used in this project", not "unavailable". Storing a
# backend SELECTION would recreate the failure where the selection outlives the
# backend it named.
#
# `bd remember` is deliberately NOT offered as an alternative. It takes a
# content string plus a key and cannot carry type, description, or cross-links,
# so it is a lossy sink for the same data, not a second backend.
#
# Slug is the meter own: every character that is not alphanumeric or "-" becomes
# "-". Kept identical on purpose — a divergence here would look at a different
# directory than the one the transcripts live in.
slug() { printf '%s' "$1" | sed 's|[^a-zA-Z0-9-]|-|g'; }

MEM_DIR="$PROJECTS/$(slug "$CWD")/memory"
MEM_STATE=absent
MEM_ENTRIES=0
if [ -d "$MEM_DIR" ]; then
  MEM_STATE=present
  MEM_ENTRIES="$(find "$MEM_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
fi
MEM_INDEX=false
[ -f "$MEM_DIR/MEMORY.md" ] && MEM_INDEX=true

# ---------------------------------------------------------------------- tasks
#
# `.beads/` walked up from cwd, because a session started in a subdirectory of
# the repo still belongs to the repo tracker.
#
# `.beads` present with `bd` missing is BROKEN, and broken is a stop-and-tell.
# It must never fall back to "no task system": the issues exist, the user is
# tracking work in them, and silently pretending otherwise would drop that work
# out of the wrap-up with no error anywhere.
find_up() {  # find_up <name>; prints the containing directory, or nothing
  local d="$PWD"
  while :; do
    [ -e "$d/$1" ] && { printf '%s' "$d"; return 0; }
    [ "$d" = "/" ] && return 1
    d="$(dirname "$d")"
  done
}

BEADS_ROOT="$(find_up .beads || true)"
BD_VERSION=""
if [ -n "$BEADS_ROOT" ]; then
  if command -v bd >/dev/null 2>&1; then
    TASK_STATE=present
    # `bd version` prints "bd version 1.1.0 (Homebrew)" — the last field is the
    # packaging note, not the version. Take the first dotted token rather than
    # trusting a column position. An unreadable version is null, not a failure:
    # bd being on PATH is what "present" claims, and the version is a detail.
    BD_VERSION="$(bd version 2>/dev/null | tr ' ' '\n' \
      | grep -E '^[0-9]+\.[0-9]+' | head -1 || true)"
  else
    TASK_STATE=broken
  fi
else
  TASK_STATE=absent
fi

TASK_NOTE=""
case "$TASK_STATE" in
  broken) TASK_NOTE="A .beads directory exists at $BEADS_ROOT but bd is not on PATH. Stop and tell the user: the issues are real and unreadable from here. Do not treat this as having no task system." ;;
  absent) TASK_NOTE="No .beads directory at or above the working directory." ;;
esac

# ---------------------------------------------------------------------- forge
#
# Host from the git remote, authentication from `gh auth status`. Exit 0 there
# means a token is present AND accepted, which is a real reachability signal
# rather than a config reading — unlike the MCP candidates below, this one needs
# no second probe. `--hostname` scopes it, verified 2026-08-23: exit 0 for
# github.com and exit 1 for gitlab.com on this machine.
# Computed here rather than inside the config block below, so that a damaged or
# missing ~/.claude.json cannot leave it unset for the .mcp.json loop. Empty in
# a non-git directory, which every consumer below already tolerates.
GITROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"

FORGE_REMOTE="$(git remote get-url origin 2>/dev/null || true)"
FORGE_HOST=""
FORGE_ID=""
case "$FORGE_REMOTE" in
  "") ;;
  *github.com*)  FORGE_HOST=github.com;  FORGE_ID=github ;;
  *gitlab.com*)  FORGE_HOST=gitlab.com;  FORGE_ID=gitlab ;;
  *bitbucket.org*) FORGE_HOST=bitbucket.org; FORGE_ID=bitbucket ;;
  *)
    # ssh (git@host:path) and https (https://host/path) both, without assuming
    # which. Anything unrecognised keeps the host and drops the id: naming a
    # forge family we cannot verify would be a guess presented as a finding.
    FORGE_HOST="$(printf '%s' "$FORGE_REMOTE" \
      | sed -E 's|^[a-z+]+://||; s|^[^@]*@||; s|[:/].*$||')"
    ;;
esac

FORGE_STATE=unknown
GH_OK=false
if [ -z "$FORGE_REMOTE" ]; then
  FORGE_STATE=absent
elif ! command -v gh >/dev/null 2>&1; then
  FORGE_STATE=unknown
elif [ -z "$FORGE_ID" ]; then
  FORGE_STATE=unknown
elif gh auth status --hostname "$FORGE_HOST" >/dev/null 2>&1; then
  FORGE_STATE=authenticated; GH_OK=true
else
  FORGE_STATE=unauthenticated
fi

# ----------------------------------------------------------- mcp candidates
#
# STAGE ONE: what is configured. Three files, none of which says anything about
# whether the server answers. A candidate found here and missing from stage two
# is "unknown", not "absent" — see the merge below.
CANDIDATES='[]'
add_cands() {  # add_cands <source> <json array of names>
  CANDIDATES="$(jq -c --argjson c "$CANDIDATES" --argjson n "${2:-[]}" --arg s "$1" -n \
    '$c + ($n | map({name: ., source: $s}))')"
}

read_keys() {  # read_keys <file> <jq path expression>; [] on any failure
  local f="$1" expr="$2"
  [ -f "$f" ] || { printf '[]'; return 0; }
  jq -c "$expr // {} | keys" "$f" 2>/dev/null || { printf '[]'; return 1; }
}

if [ -f "$CLAUDE_JSON" ]; then
  if ! jq -e . "$CLAUDE_JSON" >/dev/null 2>&1; then
    # Unparseable config is the same call config.sh makes on a damaged
    # preferences file: degrade, warn, never abort — and never let the damage
    # read as "no servers configured".
    caveat "$CLAUDE_JSON did not parse; MCP candidates from the user config are unmeasured, not absent."
  else
    add_cands user-config "$(read_keys "$CLAUDE_JSON" '.mcpServers')"
    # Project-scoped servers are keyed on the directory the session started in.
    # Check cwd and the repo root, because a session started in a subdirectory
    # has a different key than the one the user configured against.
    for d in "$CWD" "$GITROOT"; do
      [ -n "$d" ] || continue
      add_cands project-config "$(jq -c --arg d "$d" \
        '.projects[$d].mcpServers // {} | keys' "$CLAUDE_JSON" 2>/dev/null || echo '[]')"
    done
  fi
fi

for d in "$CWD" "$GITROOT"; do
  [ -n "$d" ] || continue
  [ -f "$d/.mcp.json" ] || continue
  if ! jq -e . "$d/.mcp.json" >/dev/null 2>&1; then
    caveat "$d/.mcp.json did not parse; MCP candidates from it are unmeasured, not absent."
    continue
  fi
  add_cands mcp-json "$(read_keys "$d/.mcp.json" '.mcpServers')"
done

# --------------------------------------------------------- mcp reachability
#
# STAGE TWO: which of them answer. Four observable states, all verified against
# real output rather than assumed:
#
#   ✔ Connected                 -> connected   (the ONLY state eligible to offer)
#   ! Needs authentication      -> needs-auth  (report, with remediation)
#   ✘ Failed to connect — <why> -> failed      (report, with the reason)
#   ⏸ Pending approval          -> pending     (report, with remediation)
#
# Matched on the English status TEXT, not on the glyph. The glyphs are the part
# most likely to move — a theme, a non-UTF-8 terminal, a Windows console — and
# a status matched on a glyph that changed silently becomes "unknown" for every
# server at once.
PROBE_STATE=skipped
PROBE_WALL_MS=null
PROBED='[]'
PROBE_NOTE=""

parse_mcp_list() {  # stdin: raw output; stdout: name<TAB>target<TAB>state<TAB>detail
  awk '
    # SDK diagnostics ride the same stream, e.g.
    # "[mcp-sdk] SEP-2352: stored OAuth credential has no issuer stamp".
    # They contain ": " and would otherwise parse as a server named [mcp-sdk].
    /^\[/ { next }
    {
      # The name/target separator is COLON-SPACE, which is what makes a name
      # like "plugin:figma:figma" survive: its internal colons are not followed
      # by a space, so the first colon-space is the real separator. It also
      # handles "claude.ai GitHub MCP (Official)", where the name has spaces.
      p = index($0, ": ")
      if (p == 0) next
      name = substr($0, 1, p - 1)
      rest = substr($0, p + 2)
      q = index(rest, " - ")
      if (q == 0) next
      target = substr(rest, 1, q - 1)
      tail   = substr(rest, q + 3)
      st = "unknown"
      if      (index(tail, "Needs authentication")) st = "needs-auth"
      else if (index(tail, "Failed to connect"))    st = "failed"
      else if (index(tail, "Pending approval"))     st = "pending"
      else if (index(tail, "Connected"))            st = "connected"
      gsub(/\t/, " ", name); gsub(/\t/, " ", target); gsub(/\t/, " ", tail)
      print name "\t" target "\t" st "\t" tail
    }'
}

if [ "$CHEAP" = 1 ]; then
  PROBE_STATE=skipped
  PROBE_NOTE="--cheap: reachability not probed. Run without --cheap on first-run setup."
elif [ "$HAS_CLAUDE" != true ]; then
  # The documented cross-harness no-op. Kiro and Codex have no `claude mcp
  # list`; detection degrades to the config files above and every reachability
  # stays unknown.
  PROBE_STATE=unavailable
  PROBE_NOTE="claude is not on PATH. This is the expected path in Kiro and Codex, which have no equivalent command. Candidates come from config only and reachability is unknown, never assumed true."
else
  OUT="$(mktemp "${TMPDIR:-/tmp}/lastcall-detect.XXXXXX")"
  trap 'rm -f "$OUT"' EXIT
  T0="$(now_ms)"
  RC=0
  run_bounded "$MCP_TIMEOUT_S" "$OUT" claude mcp list || RC=$?
  T1="$(now_ms)"
  [ "$T0" != 0 ] && PROBE_WALL_MS=$((T1 - T0))

  ROWS="$(parse_mcp_list <"$OUT" || true)"
  if [ "$RC" = 124 ]; then
    PROBE_STATE=timeout
    PROBE_NOTE="claude mcp list did not finish within ${MCP_TIMEOUT_S}s. Reachability is unknown."
  elif [ "$RC" != 0 ]; then
    PROBE_STATE=error
    PROBE_NOTE="claude mcp list exited $RC. Reachability is unknown."
  elif [ -n "$ROWS" ]; then
    PROBE_STATE=ran
  elif grep -qi 'no mcp servers configured' "$OUT"; then
    # The one way an empty result is a real measurement rather than a parse
    # failure. Verified 2026-08-23 against a clean HOME: the exact line is
    # "No MCP servers configured. Use `claude mcp add` to add a server."
    PROBE_STATE=ran
  else
    # Exit 0 and nothing recognisable: the output moved, or was truncated. This
    # is the case the whole script is built around. It is NOT "no servers".
    PROBE_STATE=unparsed
    PROBE_NOTE="claude mcp list exited 0 but produced no line this parser recognises. The output format may have changed; cc_version is recorded so this is diagnosable. Reachability is unknown."
  fi

  if [ -n "$ROWS" ]; then
    PROBED="$(printf '%s\n' "$ROWS" | jq -R -s '
      split("\n") | map(select(length > 0)) | map(split("\t"))
      | map({name: .[0], target: .[1], state: .[2], detail: .[3]})' 2>/dev/null || echo '[]')"
  fi
  rm -f "$OUT"
  trap - EXIT
fi

REACHABILITY=unknown
[ "$PROBE_STATE" = ran ] && REACHABILITY=measured
# Fires on --cheap too, and that is the point. Without the probe the tracker
# list is a FLOOR, not a census: plugin-provided servers never appear in
# ~/.claude.json or .mcp.json, so a config-only pass sees none of them. Measured
# here 2026-08-23 — six servers with the probe, one without. A consumer that
# read the short list as "no trackers" would be wrong in exactly the direction
# this script exists to prevent.
if [ "$REACHABILITY" != measured ]; then
  caveat "MCP reachability is unmeasured (probe: $PROBE_STATE). Every tracker listed is reported as unknown rather than dropped, and the list itself is a floor: plugin-provided servers are invisible without the probe."
fi

# ------------------------------------------------------------------ assemble
#
# The gh-derived GitHub Issues candidate. Unlike an MCP row, its state comes
# from an actual authenticated round trip, so it can be "connected" without a
# second probe. Capability is still unverified: a token with `repo` scope is not
# proof the consumer has an issue-filing tool wired up.
GH_TRACKER='[]'
if [ "$GH_OK" = true ] && [ "$FORGE_ID" = github ]; then
  GH_TRACKER="$(jq -c -n --arg host "$FORGE_HOST" --arg remote "$FORGE_REMOTE" '
    [{ id: "github-issues", name: $host, via: "gh", target: $remote,
       sources: ["gh"], state: "connected", detail: "gh auth status exited 0",
       eligible_to_offer: true, capability: "unverified", remediation: null }]')"
fi

# No apostrophes in these comments: the whole program is single-quoted in sh.
jq -n \
  --arg schema "$SCHEMA" \
  --arg cwd "$CWD" \
  --arg cc "$CC_VERSION" \
  --argjson has_claude "$HAS_CLAUDE" \
  --arg mem_dir "$MEM_DIR" \
  --arg mem_state "$MEM_STATE" \
  --argjson mem_entries "$MEM_ENTRIES" \
  --argjson mem_index "$MEM_INDEX" \
  --arg task_state "$TASK_STATE" \
  --arg task_root "$BEADS_ROOT" \
  --arg task_version "$BD_VERSION" \
  --arg task_note "$TASK_NOTE" \
  --arg forge_id "$FORGE_ID" \
  --arg forge_host "$FORGE_HOST" \
  --arg forge_remote "$FORGE_REMOTE" \
  --arg forge_state "$FORGE_STATE" \
  --argjson cand "$CANDIDATES" \
  --argjson probed "$PROBED" \
  --argjson gh "$GH_TRACKER" \
  --arg probe "$PROBE_STATE" \
  --arg probe_note "$PROBE_NOTE" \
  --argjson probe_ms "$PROBE_WALL_MS" \
  --arg reach "$REACHABILITY" \
  --argjson caveats "$CAVEATS" '

  def nz: if . == "" then null else . end;

  # Which tracker family a server belongs to, matched against its name and its
  # url or command together. A conservative, DOCUMENTED list: an unrecognised
  # server is not a tracker as far as this script is concerned, but it is still
  # emitted under mcp.servers so a human or a consumer can see it and decide.
  # Deliberately excluded as too generic to match safely: height, plane, monday.
  def family($hay):
    [ ["linear","linear"], ["atlassian","jira"], ["jira","jira"],
      ["asana","asana"], ["notion","notion"], ["shortcut","shortcut"],
      ["clickup","clickup"], ["trello","trello"], ["youtrack","youtrack"],
      ["redmine","redmine"], ["bugzilla","bugzilla"], ["basecamp","basecamp"],
      ["gitlab","gitlab"], ["github","github"] ]
    # The pair is bound before the pipe. Inside `$hay | contains(...)` the dot
    # has already been rebound to $hay, so a bare .[0] there indexes the string
    # rather than the pair — jq reports it as "Cannot index string with number".
    | map(. as $pair | select($hay | contains($pair[0]))) | first
    | if . == null then null else .[1] end;

  # THE MERGE, and the place the fail-to-unknown rule actually lives. The row
  # set is the UNION of config candidates and probed servers. A candidate the
  # probe did not report keeps its row and takes state "unknown" — it is never
  # dropped, and it is never "absent".
  ( ($cand | map(.name)) + ($probed | map(.name)) | unique ) as $names
  | ( $names | map(
        . as $n
        | ($cand   | map(select(.name == $n))) as $cs
        | ($probed | map(select(.name == $n)) | first) as $p
        | (($p.target // "") | tostring) as $tgt
        | { name:    $n,
            target:  ($tgt | nz),
            sources: ((($cs | map(.source))
                       + (if $p == null then [] else ["mcp-runtime"] end)) | unique),
            state:   (if $p == null then "unknown" else $p.state end),
            detail:  (if $p != null then $p.detail
                      elif $reach == "measured" then
                        "configured but not listed by the probe in this working directory; claude mcp list is cwd-sensitive"
                      else "reachability not measured" end),
            tracker: family(($n + " " + $tgt) | ascii_downcase) }
      ) ) as $servers

  | ( $servers | map(select(.tracker != null)) | map(
        { id: .tracker,
          name: .name,
          via: ("mcp:" + .name),
          target: .target,
          sources: .sources,
          state: .state,
          detail: .detail,
          # ONLY connected is eligible. needs-auth, pending, failed and unknown
          # are all REPORTED with remediation, which is the useful behaviour and
          # the opposite of silently omitting them.
          eligible_to_offer: (.state == "connected"),
          # An open transport is not an issue-writing tool. The consumer must
          # corroborate against its own tool list before offering to file.
          capability: "unverified",
          remediation:
            (if   .state == "connected"  then null
             elif .state == "needs-auth" then "run /mcp to connect"
             elif .state == "pending"    then "run /mcp and approve this server"
             elif .state == "failed"     then "run /mcp to reconnect"
             else "reachability unmeasured; verify with /mcp before offering" end) })
    ) as $trackers

  | { schema: $schema,
      cwd: $cwd,
      harness: { claude_code: $has_claude,
                 cc_version: ($cc | nz),
                 # Recorded so a parse that goes stale against a future Claude
                 # Code is diagnosable rather than mysterious. The setup screen
                 # stamps it into the config entry, contracts.md section 4.
                 mcp_probe_cmd: (if $has_claude then "claude mcp list" else null end) },

      memory: { backend: "claude-native",
                path: $mem_dir,
                state: $mem_state,
                entries: $mem_entries,
                has_index: $mem_index,
                # PROBE ONLY. Absence means never used here, not unavailable.
                available: true,
                promptable: false,
                note: (if $mem_state == "present"
                       then "Claude Code native memory, already in use in this project."
                       else "Claude Code native memory is available here; this project has simply never written to it. This is not a reason to ask the user to pick a backend." end) },

      tasks: { system: "beads",
               root: ($task_root | nz),
               version: ($task_version | nz),
               state: $task_state,
               # broken is a stop-and-tell, never a silent fallback to "none".
               blocking: ($task_state == "broken"),
               note: ($task_note | nz) },

      trackers: ($trackers + $gh),

      forge: { id: ($forge_id | nz),
               host: ($forge_host | nz),
               remote: ($forge_remote | nz),
               via: (if $forge_id == "" then null else "gh" end),
               state: $forge_state },

      mcp: { probe: $probe,
             reachability: $reach,
             wall_ms: $probe_ms,
             note: ($probe_note | nz),
             servers: $servers },

      caveats: $caveats }'
