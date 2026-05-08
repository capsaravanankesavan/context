#!/bin/bash
# import-claude.sh
# Copies skills and their associated memory starter files from this context
# repo into your local ~/.claude directory.
#
# SAFE BY DESIGN — nothing is ever overwritten automatically.
# If a file already exists it is skipped.
# To update: delete the file first, then re-run.
#   rm ~/.claude/skills/<name>/skill.md
#   ./import-claude.sh <name>
#
# Usage:
#   ./import-claude.sh --all              Import every skill + all memory files
#   ./import-claude.sh <skill>            Import one skill + its memory file
#   ./import-claude.sh <skill1> <skill2>  Import specific skills + their memory files
#   ./import-claude.sh                    Show this help + available skills

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SKILLS_SRC="$REPO_ROOT/skills/user"
MEMORY_SRC="$REPO_ROOT/memory"
SKILLS_DEST=~/.claude/skills
MEMORY_DEST=~/.claude/memory

# ── Helpers ──────────────────────────────────────────────────────────────────

import_skill() {
  local name="$1"
  local src="$SKILLS_SRC/$name/skill.md"
  local dest_dir="$SKILLS_DEST/$name"
  local dest="$dest_dir/skill.md"

  if [ ! -f "$src" ]; then
    echo "  ⚠️  $name — not found in repo"
    return
  fi
  if [ -f "$dest" ]; then
    echo "  ⏭️  $name skill (exists — skipped)"
    echo "       To update: rm $dest"
    return
  fi
  mkdir -p "$dest_dir"
  cp "$src" "$dest"
  echo "  ✅ $name skill (installed)"
}

import_memory() {
  local fname="$1"
  local src="$MEMORY_SRC/$fname"
  local dest="$MEMORY_DEST/$fname"

  mkdir -p "$MEMORY_DEST"
  if [ ! -f "$src" ]; then
    return   # no memory starter for this skill — silently skip
  fi
  if [ -f "$dest" ]; then
    echo "  ⏭️  $fname (exists — skipped)"
    echo "       To reset: rm $dest"
    return
  fi
  cp "$src" "$dest"
  echo "  ✅ $fname (installed)"
}

available_skills() {
  ls "$SKILLS_SRC" 2>/dev/null | tr '\n' ' '
}

# ── No args — show help ───────────────────────────────────────────────────────
if [ $# -eq 0 ]; then
  echo "Usage:"
  echo "  ./import-claude.sh --all              Import every skill + all memory"
  echo "  ./import-claude.sh <skill>            Import one skill + its memory"
  echo "  ./import-claude.sh <skill1> <skill2>  Import specific skills + their memory"
  echo ""
  echo "Available skills:"
  for skill_dir in "$SKILLS_SRC"/*/; do
    echo "  $(basename "$skill_dir")"
  done
  echo ""
  echo "To update an existing skill: delete it first, then re-import."
  echo "  rm ~/.claude/skills/<name>/skill.md && ./import-claude.sh <name>"
  exit 0
fi

# ── --all ─────────────────────────────────────────────────────────────────────
if [[ "$1" == "--all" ]]; then
  echo "═══════════════════════════════════════"
  echo "  Importing ALL skills + memory"
  echo "  Nothing will be overwritten."
  echo "═══════════════════════════════════════"
  echo ""
  echo "Skills:"
  for skill_dir in "$SKILLS_SRC"/*/; do
    import_skill "$(basename "$skill_dir")"
  done
  echo ""
  echo "Memory:"
  for f in "$MEMORY_SRC"/*.md; do
    import_memory "$(basename "$f")"
  done
  echo ""
  echo "Done. Installed skills: $(ls "$SKILLS_DEST" 2>/dev/null | tr '\n' ' ')"
  exit 0
fi

# ── Specific skill(s) ─────────────────────────────────────────────────────────
echo "═══════════════════════════════════════"
echo "  Importing: $*"
echo "  Nothing will be overwritten."
echo "═══════════════════════════════════════"

for name in "$@"; do
  # Validate the skill exists in the repo
  if [ ! -d "$SKILLS_SRC/$name" ]; then
    echo ""
    echo "  ❌ '$name' not found in repo. Available: $(available_skills)"
    continue
  fi

  echo ""
  echo "── $name ──"
  import_skill "$name"
  import_memory "${name}-learnings.md"
done

echo ""
echo "Done."
echo "To verify: open Claude Code and type /$1 to trigger the skill."
