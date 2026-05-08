#!/bin/bash
# export-claude.sh
# Copies your local ~/.claude skills and memory files into this context repo.
# Run this whenever you update a skill or want to snapshot your memory files.
#
# Usage: ./export-claude.sh

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DEST="$REPO_ROOT/skills/user"
MEMORY_DEST="$REPO_ROOT/memory"
SKILLS_SRC=~/.claude/skills
MEMORY_SRC=~/.claude/memory

echo "═══════════════════════════════════════"
echo "  Exporting Claude skills + memory"
echo "  → $REPO_ROOT"
echo "═══════════════════════════════════════"

# ── Skills ──────────────────────────────────────────────────────────────────
echo ""
echo "Skills:"
for skill_dir in "$SKILLS_SRC"/*/; do
  name=$(basename "$skill_dir")
  src="$skill_dir/skill.md"
  dest_dir="$SKILLS_DEST/$name"
  dest="$dest_dir/skill.md"

  if [ ! -f "$src" ]; then
    echo "  ⚠️  $name — skill.md not found, skipping"
    continue
  fi

  mkdir -p "$dest_dir"
  cp "$src" "$dest"
  echo "  ✅ $name"
done

# ── Memory ───────────────────────────────────────────────────────────────────
# Copies learnings files only. Skips *-inbox.md files — those are transient
# inter-skill signals that get cleared at startup and should not be shared.
echo ""
echo "Memory:"
for f in "$MEMORY_SRC"/*.md; do
  fname=$(basename "$f")

  # Skip inbox files — transient, not meant to be shared
  if [[ "$fname" == *"-inbox.md" ]]; then
    echo "  ⏭️  $fname (inbox — skipped)"
    continue
  fi

  cp "$f" "$MEMORY_DEST/$fname"
  echo "  ✅ $fname"
done

echo ""
echo "Done. Commit and push to share:"
echo "  cd $REPO_ROOT"
echo "  git add skills/user memory"
echo "  git commit -m 'chore: update claude skills and memory'"
echo "  git push"
