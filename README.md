# Promotion Engine — Claude Context Repo

Shared Claude Code skills and memory starter files for the Promotion Engine team.
Clone this repo and run `import-claude.sh` to set up your local Claude environment.

---

## Repository Structure

```
context/
  skills/
    user/
      arch-investigator/    skill.md
      tech-detailer/        skill.md
      tech-detail-reviewer/ skill.md
      test-plan-architect/  skill.md
      test-case-sheet/      skill.md
      tdd-developer/        skill.md
      promo-grooming/       skill.md
  memory/
      MEMORY.md
      arch-investigator-learnings.md
      tech-detailer-learnings.md
      test-plan-architect-learnings.md
  export-claude.sh          (maintainer: push local skills → this repo)
  import-claude.sh          (developer: pull skills from this repo → ~/.claude)
  README.md
```

---

## Skills

Skills are Claude Code slash commands that give Claude specialized behaviour for a
specific role in the SDLC. Each skill is a markdown file with a YAML frontmatter
and detailed instructions.

The skills in this repo form a **chain** — each one picks up where the previous left off:

```
/arch-investigator   →   /tech-detailer   →   /tech-detail-reviewer
                                ↓
                     /test-plan-architect
                                ↓
                       /test-case-sheet
                                ↓
                        /tdd-developer
```

| Skill | Trigger | Purpose |
|-------|---------|---------|
| `arch-investigator` | `/arch-investigator` | Root cause analysis and solution design for production issues |
| `tech-detailer` | `/tech-detailer` | Translates investigation handoff into a low-level technical spec |
| `tech-detail-reviewer` | `/tech-detail-reviewer` | Reviews a completed tech detail for gaps, risks, and design issues |
| `test-plan-architect` | `/test-plan-architect` | Produces a structured, prioritised test plan from the tech detail |
| `test-case-sheet` | `/test-case-sheet` | Expands the test plan into a step-level SDLC test case sheet |
| `tdd-developer` | `/tdd-developer` | Implements tasks from the tech detail one by one using TDD |
| `promo-grooming` | `/promo-grooming` | PRD grooming assistant for sprint planning and feature discussions |

---

## Memory Files

Memory files accumulate session learnings across the chain. Each skill reads from
memory at startup and writes back at the end of a session — so the team's collective
knowledge improves over time.

| File | Written by | Read by |
|------|-----------|---------|
| `arch-investigator-learnings.md` | arch-investigator | tech-detailer, test-plan-architect, tdd-developer |
| `tech-detailer-learnings.md` | tech-detailer | test-plan-architect, tdd-developer |
| `test-plan-architect-learnings.md` | test-plan-architect | tdd-developer |
| `tdd-developer-learnings.md` | tdd-developer | tdd-developer (own sessions) |

> **Memory files in this repo are starter templates only.**
> Your personal `~/.claude/memory/` files accumulate your own session history
> and are never overwritten by `import-claude.sh`.

---

## Setup (Developer — one time)

```bash
git clone <this-repo-url>
cd context
./import-claude.sh --all
```

This installs all skills into `~/.claude/skills/` and all memory starters into
`~/.claude/memory/` — skipping any files that already exist.

### Import a specific skill only

```bash
./import-claude.sh tdd-developer
```

Installs the `tdd-developer` skill and its associated memory starter file.
You can list multiple skills in one command:

```bash
./import-claude.sh tdd-developer tech-detailer
```

### See what is available

```bash
./import-claude.sh
```

Prints usage and the full list of available skills.

### Updating a skill

Skills are never overwritten automatically. To pull the latest version of a skill:

```bash
rm ~/.claude/skills/tdd-developer/skill.md
./import-claude.sh tdd-developer
```

---

## Maintaining This Repo (Maintainer)

When you update a skill locally and want to share it with the team:

```bash
# 1. Export your local skills and memory into the repo
./export-claude.sh

# 2. Commit and push
git add skills/user memory
git commit -m "chore: update tdd-developer skill — <what changed>"
git push
```

`export-claude.sh` always copies the latest version of every skill from your
`~/.claude/skills/` into the repo. Memory inbox files (`*-inbox.md`) are
intentionally excluded — those are transient inter-skill signals, not shared state.
