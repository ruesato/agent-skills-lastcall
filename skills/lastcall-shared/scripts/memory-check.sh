#!/usr/bin/env bash
# memory-check.sh — assert that a memory write actually LANDED.
#
#   memory-check.sh <memory-file> [<memory-file> ...]
#   memory-check.sh --store <dir> <memory-file> ...
#
# Why this exists: doctrine-check.sh answers a different question. It checks
# whether the model is about to be TOLD to skip the memory store, which is one
# failure path out of several, and the only one visible before the write. Every
# other way a memory silently fails to appear is uncovered by it:
#
#   - a Write denied by permissions, reported as a refusal the summary then
#     glosses as "saved 2 memories"
#   - a model that decided nothing was durable when something was
#   - a doctrine vector the scan cannot see
#   - a file written with frontmatter the recall step cannot parse
#   - a file written but never indexed in MEMORY.md, so nothing ever loads it
#
# Checking after the fact closes all of them at once, including the ones nobody
# has thought of yet, which is why this is cheaper AND stricter than widening
# the doctrine scan.
#
# Exits 0 even when assertions fail: this is an advisory for a human, like
# doctrine-check.sh. Callers read the JSON and must surface `ok: false` in the
# readout rather than reporting success. That reporting duty is the whole point
# — a check whose failure is swallowed is worse than no check, because it looks
# like coverage.
set -euo pipefail

STORE=""
FILES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --store) STORE="${2:-}"; shift 2 ;;
    *)       FILES+=("$1");  shift ;;
  esac
done

# Nothing claimed is a legitimate outcome, not a failure: a session that taught
# nothing durable is supposed to write nothing. Say so explicitly rather than
# emitting an empty pass that reads as "verified".
if [ "${#FILES[@]}" -eq 0 ]; then
  jq -n '{ ok: true, claimed: 0, checked: [], problems: [],
           note: "No memory files were claimed, so nothing was verified. This is correct only if the memories delegation deliberately wrote nothing." }'
  exit 0
fi

[ -n "$STORE" ] || STORE="$(dirname "${FILES[0]}")"
INDEX="$STORE/MEMORY.md"

RESULTS='[]'
for f in "${FILES[@]}"; do
  problems='[]'
  add_problem() {
    problems="$(jq -c --argjson p "$problems" --arg m "$1" -n '$p + [$m]')"
  }

  exists=false; fm_ok=false; indexed=false; name=""

  if [ -f "$f" ] && [ -s "$f" ]; then
    exists=true
  else
    add_problem "file does not exist or is empty"
  fi

  if [ "$exists" = true ]; then
    # Frontmatter is the contract the recall step reads. A file whose block does
    # not parse is present on disk and invisible to every future session, which
    # is the failure that looks most like success.
    #
    # Parsed with awk rather than a YAML library: the block is three known keys
    # and a nested one, the scripts here take no dependencies, and a malformed
    # block should read as malformed rather than crash a parser.
    fm="$(awk 'NR==1 && $0 != "---" { exit 1 }
               NR==1 { next }
               /^---[[:space:]]*$/ { exit }
               { print }' "$f" 2>/dev/null || true)"

    if [ -z "$fm" ]; then
      add_problem "no parseable YAML frontmatter block delimited by ---"
    else
      name="$(printf '%s\n' "$fm" | awk -F': *' '/^name:/ { print $2; exit }')"
      desc="$(printf '%s\n' "$fm" | awk -F': *' '/^description:/ { print $2; exit }')"
      # metadata.type is indented one level under `metadata:`.
      mtype="$(printf '%s\n' "$fm" | awk -F': *' '/^[[:space:]]+type:/ { print $2; exit }')"

      [ -n "$name" ]  || add_problem "frontmatter has no name:"
      [ -n "$desc" ]  || add_problem "frontmatter has no description:"
      case "$mtype" in
        user|feedback|project|reference) ;;
        "") add_problem "frontmatter has no metadata.type" ;;
        *)  add_problem "metadata.type is \"$mtype\", not one of user|feedback|project|reference" ;;
      esac

      # No problems recorded means the block is well formed.
      [ "$(printf '%s' "$problems" | jq 'length')" -eq 0 ] && fm_ok=true
    fi

    # A memory the index does not point at is never loaded, so writing it
    # accomplished nothing. Matched on the basename inside a markdown link
    # target, which is the shape the index line uses.
    base="$(basename "$f")"
    if [ -f "$INDEX" ] && grep -qF "($base)" "$INDEX" 2>/dev/null; then
      indexed=true
    else
      add_problem "no index line in $INDEX links to $base"
    fi
  fi

  RESULTS="$(jq -c --argjson r "$RESULTS" --argjson p "$problems" \
    --arg path "$f" --arg name "$name" \
    --argjson exists "$exists" --argjson fm "$fm_ok" --argjson ix "$indexed" -n \
    '$r + [{ path: $path, name: (if $name == "" then null else $name end),
             exists: $exists, frontmatter_ok: $fm, indexed: $ix, problems: $p }]')"
done

jq -n --argjson r "$RESULTS" --arg index "$INDEX" '
  # The comparison needs its own parens: a jq object VALUE cannot carry a bare
  # == and the parse error lands on the next line rather than on this one.
  { ok: (([ $r[] | .problems | length ] | add // 0) == 0),
    claimed: ($r | length),
    index: $index,
    checked: $r,
    problems: [ $r[] | . as $c | .problems[] | "\($c.path): \(.)" ] }
  | . + { note: (if .ok
                 then "Every claimed memory exists, parses, and is indexed."
                 else "A claimed memory did not land. Report this in the readout; do NOT report the memories step as successful." end) }'
