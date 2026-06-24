---
name: workspace-setup
description: >
  Sets up a git worktree workspace for a JIRA ticket across two repos — the app code
  repo and the personal detailing repo. Creates both branches, the directory structure
  for detailing docs, and a problem statement template in one shot.
  Trigger on /workspace-setup, or any request like "set up workspace for CAP-xxx",
  "create worktree for ticket", "initialize ticket workspace", "set up a new ticket",
  "prepare workspace for <ticketId>".
---

# Workspace Setup

Sets up an AI-led development workspace for a JIRA ticket. Two things get created:

1. **Detailing worktree** — a branch in the personal detailing repo where arch docs,
   tech detail, test plans, and implementation notes live.
2. **App repo worktree** — a Claude Code worktree in the target code repo where the
   actual fix / feature gets built.

---

## Usage

```
/workspace-setup <ticketId> <title> <appRepo> <quarter>
```

| Parameter  | Description | Example |
|------------|-------------|---------|
| `ticketId` | JIRA ticket ID | `CAP-JUN13` |
| `title`    | Short snake_case slug | `stats_databricks_createdon` |
| `appRepo`  | Folder name under `/Users/saravanankesavan/sara/wsdetail/` | `Luci`, `promotion-engine` |
| `quarter`  | Quarter folder code | `26AMJ`, `Q2_2026` |

**Example invocation:**
```
/workspace-setup CAP-JUN13 stats_databricks_createdon Luci 26AMJ
```

---

## Steps

Parse the four parameters from the invocation args. Derive:
```
slug     = <ticketId>_<title>
wsdetail = /Users/saravanankesavan/sara/wsdetail
detailing_base = <wsdetail>/detailing
app_base       = <wsdetail>/<appRepo>
detailing_wt   = <detailing_base>/.worktrees/<slug>
app_wt         = <app_base>/.claude/worktrees/<slug>
doc_dir        = <detailing_wt>/<appRepo>/<quarter>/<slug>
probstatement  = <doc_dir>/<slug>_probstatement.md
```

Run each step in order. If a step fails, stop and report the exact error and the command that failed — do not continue to the next step.

---

### Step 1 — Detailing worktree

```bash
cd <detailing_base>
git worktree add .worktrees/<slug> -b <slug>
mkdir -p .worktrees/<slug>/<appRepo>/<quarter>/<slug>
```

The `git worktree add` creates the branch and checks it out in `.worktrees/<slug>/`.
The `mkdir -p` creates the nested directory structure for this ticket's docs inside that worktree.

---

### Step 2 — App repo worktree

```bash
cd <app_base>
git worktree add .claude/worktrees/<slug> -b claude/<slug>
```

This creates the feature branch `claude/<slug>` and checks it out in the standard
Claude Code worktree location so Claude Code can open it directly as a project.

---

### Step 3 — Claude settings (bypass permissions)

Create `.claude/settings.json` in both worktrees with full bypass permissions so the
Claude session opens without any permission prompts:

**`<detailing_wt>/.claude/settings.json`** and **`<app_wt>/.claude/settings.json`**:

```json
{
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Edit(*)",
      "Write(*)",
      "MultiEdit(*)",
      "Glob(*)",
      "Grep(*)",
      "WebFetch(*)",
      "WebSearch(*)"
    ],
    "defaultMode": "bypassPermissions"
  }
}
```

Create the `.claude/` directory first if it doesn't exist, then write the file.

---

### Step 4 — Problem statement file

Create `<probstatement>` with this template (fill `<ticketId>` and `<title>` in the heading):

```markdown
# Problem Statement: <ticketId> — <title>

## Symptom
<!-- What is observable? Error, wrong data, latency spike, silent failure? -->

## Scope
<!-- All tenants / specific org / specific flow? -->

## Entry Point
<!-- Which service / endpoint / job is the entry point? -->

## Expected vs Actual Behaviour
<!-- Be precise — what should happen vs what actually happens -->

## Evidence
<!-- Request ID, trace ID, log snippet, or reproduction steps -->
```

---

### Step 5 — Print summary

After all steps succeed, print this summary block (substitute all placeholders):

```
✅  Workspace ready — <slug>

📁  Detailing dir  (write all docs here):
    <doc_dir>

🖥   Repo worktree  (open Claude Code here):
    <app_wt>

📄  Problem statement:
    <probstatement>

🚀  Launch:
    cd <app_wt> && claude

────────────────────────────────────────────
🧹  Cleanup when done

1.  Push detailing docs and raise PR in detailing repo:
      cd <detailing_wt>
      git add .
      git commit -m "CAP: <ticketId> detailing docs"
      git push origin <slug>

2.  Delete the Claude Code session in the desktop app
    → this auto-removes the app repo worktree

3.  Remove detailing worktree:
      cd <detailing_base>
      git worktree remove .worktrees/<slug>
────────────────────────────────────────────
```
