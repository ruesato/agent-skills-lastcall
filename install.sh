#!/usr/bin/env bash
# install.sh — link the lastcall skills into a Claude Code or Kiro skills root.
#
#   ./install.sh                  # auto-detect target(s)
#   ./install.sh --target claude  # ~/.claude/skills
#   ./install.sh --target kiro    # ~/.kiro/skills
#   ./install.sh --target ./.kiro/skills
#   ./install.sh --uninstall
#
# Symlinks rather than copies, so editing this repo updates the installed
# skills immediately. Claude Code picks up skill edits live.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS=(lastcall tally lastcall-shared)

# Every script a skill invokes by bare name. rates.json is NOT listed: cost.sh
# resolves its own symlink and reads the rate table from beside the real file.
# capture-statusline.sh is here so a user who opts in has a stable path to point
# their status line at. Putting it on PATH is the whole of the install: this
# script never reads or writes settings.json. A statusLine is a single object
# per settings file and a higher-precedence scope replaces it wholesale, so
# writing one would destroy a status line the user built, and giving one to a
# user who had none suppresses footer keyboard hints including "esc to
# interrupt". Opting in is one line the user adds themselves — see the README.
BINSCRIPTS=(meter-session.sh cost.sh ledger.sh openloops.sh doctrine-check.sh
            capture-statusline.sh emit-evidence-beads.sh config.sh detect.sh)

# Fixed absolute home for the scripts. Kiro has no skill-directory variable, so
# a relative path from a SKILL.md cannot be executed there — the skills fall
# back to this path. See references/contracts.md section 0.
BIN="$HOME/.lastcall/bin"

TARGETS=()
MODE=install

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      case "${2:?--target needs a value}" in
        claude) TARGETS+=("$HOME/.claude/skills") ;;
        kiro)   TARGETS+=("$HOME/.kiro/skills") ;;
        *)      TARGETS+=("$2") ;;
      esac
      shift 2 ;;
    --uninstall) MODE=uninstall; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Auto-detect: install wherever a skills root already exists.
if [ ${#TARGETS[@]} -eq 0 ]; then
  for d in "$HOME/.claude/skills" "$HOME/.kiro/skills"; do
    [ -d "$d" ] && TARGETS+=("$d")
  done
  if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "No skills root found. Create ~/.claude/skills or ~/.kiro/skills," >&2
    echo "or pass --target <path>." >&2
    exit 1
  fi
fi

link() {  # link <src> <dest>; refuses to clobber anything that is not our link
  local src="$1" dest="$2"
  if [ -L "$dest" ]; then
    [ "$(readlink "$dest")" = "$src" ] && { echo "  ok      $dest"; return; }
    rm "$dest"
  elif [ -e "$dest" ]; then
    echo "  SKIP    $dest (exists and is not a symlink — remove it first)" >&2
    return
  fi
  ln -s "$src" "$dest"
  echo "  linked  $dest"
}

if [ "$MODE" = uninstall ]; then
  for t in "${TARGETS[@]}"; do
    echo "$t"
    for s in "${SKILLS[@]}"; do
      d="$t/$s"
      if [ -L "$d" ] && [[ "$(readlink "$d")" == "$SRC"/* ]]; then
        rm "$d"; echo "  removed $d"
      fi
    done
  done
  # `if`, not `[ -L … ] && …`: under set -e a false test as the loop's last
  # command exits the script, silently skipping the rest of the uninstall.
  for s in "${BINSCRIPTS[@]}"; do
    if [ -L "$BIN/$s" ]; then rm "$BIN/$s"; echo "  removed $BIN/$s"; fi
  done
  echo "Uninstalled. Left ~/.claude/lastcall/ledger.jsonl and config.json in place."
  exit 0
fi

for t in "${TARGETS[@]}"; do
  mkdir -p "$t"
  echo "$t"
  for s in "${SKILLS[@]}"; do
    # Skip skills that have no SKILL.md yet, so partially-built phases do not
    # install as empty directories.
    if [ ! -f "$SRC/skills/$s/SKILL.md" ]; then
      echo "  pending $s (no SKILL.md yet)"
      continue
    fi
    link "$SRC/skills/$s" "$t/$s"
  done
done

mkdir -p "$BIN"
echo "$BIN"
for s in "${BINSCRIPTS[@]}"; do
  link "$SRC/skills/lastcall-shared/scripts/$s" "$BIN/$s"
done

echo
echo "Verifying meter runs from the installed path..."
if "$BIN/meter-session.sh" >/dev/null 2>&1; then
  echo "  ok"
else
  echo "  meter exited non-zero here — expected if this directory has no transcripts yet." >&2
fi
echo
echo "Done. Try /tally, or ask 'how much has this session cost?'"
