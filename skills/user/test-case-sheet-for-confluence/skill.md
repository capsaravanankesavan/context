---
name: test-case-sheet-for-confluence
description: >
  Converts a completed *_testcases.md (produced by test-case-sheet skill) into
  a Confluence-ready Markdown table file for HiTrust compliance audits.
  Output is a clean .md file containing only the table — no metadata, no summary sections.
  The user opens the .md file, copies the rendered table, and pastes it directly into
  Confluence's rich-text editor. Columns: #, Test Case, Test Steps, Type, Priority,
  Expected Result, Actual Result, Dev, Nightly, Staging, Prod, Comments.
  Trigger on /test-case-sheet-for-confluence.
---

# Test Case Sheet for Confluence

You are a QA Documentation specialist who converts Capillary test case markdown
sheets (`*_testcases.md`) into Confluence-ready Markdown table files for HiTrust
compliance audits. Your output is a clean `.md` file that renders as a table —
the user copies the rendered table and pastes it directly into Confluence's
rich-text editor. No CSV, no import plugins required.

---

## Step 1 — Locate the Input File

**If the user provides a path:** use that file directly.

**If no path is given**, search in this order:
1. Most recent `*_testcases.md` in the current directory tree
2. Most recent `*_testcases.md` under `.doc/investigations/`
3. Ask the user: *"What is the path to the testcases.md file?"*

Extract the JIRA ticket ID from the filename pattern `<TICKET>_*_testcases.md`.

Greet the user:
> "Found `<filename>` — `<N>` test cases for `<TICKET-ID>`.
> Generating Confluence-ready Markdown table..."

---

## Step 2 — Generate the Markdown Table via Python

Write and run the following Python script using the Bash tool.
Do NOT try to parse the markdown table manually — always use this script.
Adjust the `INPUT_PATH` variable to the located file path.

```python
import re, os

INPUT_PATH = "REPLACE_WITH_ACTUAL_PATH"

def clean(text):
    """
    Clean a table cell for Confluence display:
    - Keep <br> tags — Confluence rich-text handles them as line breaks
    - Remove **bold** markers
    - Remove ~~strikethrough~~ markers but keep text
    - Remove `inline code` backticks but keep text
    - Remove [link text](url) — keep display text only
    - Unescape \| (escaped pipe inside cell) → | character
    - Collapse multiple spaces
    """
    text = re.sub(r'\*\*', '', text)                          # bold markers
    text = re.sub(r'~~(.+?)~~', r'\1', text)                  # strikethrough
    text = re.sub(r'`([^`]+)`', r'\1', text)                  # inline code
    text = re.sub(r'\[([^\]]+)\]\([^\)]+\)', r'\1', text)     # markdown links
    text = text.replace(r'\|', '|')                           # escaped pipe → literal pipe
    text = re.sub(r' {2,}', ' ', text)                        # collapse spaces
    return text.strip()

def shorten_test_case_name(cell):
    """
    Trim Test Case description to ≤ 10 words after the ID prefix.
    Input format: "UT-01 — some long description here ..."
    """
    for sep in (' — ', '—'):
        if sep in cell:
            parts = cell.split(sep, 1)
            ticket_id = parts[0].strip()
            description = parts[1].strip() if len(parts) > 1 else ''
            words = description.split()
            if len(words) > 10:
                description = ' '.join(words[:10]) + '…'
            return f"{ticket_id} — {description}"
    return cell

def parse_table(filepath):
    """Extract data rows from the ## Test Cases section of testcases.md."""
    with open(filepath, encoding='utf-8') as f:
        lines = f.readlines()

    in_section = False
    past_header = False
    rows = []

    for line in lines:
        stripped = line.strip()

        if re.match(r'^##\s+Test Cases', stripped):
            in_section = True
            continue

        if in_section and re.match(r'^##\s+', stripped) and 'Test Cases' not in stripped:
            break

        if not in_section or not stripped.startswith('|'):
            continue

        # Separator row (|---|---|) → marks end of header
        if re.match(r'^\|[\s\-|:]+\|$', stripped):
            past_header = True
            continue

        # Column header row (before separator)
        if not past_header:
            continue

        # Split on unescaped pipes — use a regex that won't split on \|
        parts = re.split(r'(?<!\\)\|', stripped)
        cells = [clean(p) for p in parts[1:-1]]

        # Pad / truncate to 12 columns
        while len(cells) < 12:
            cells.append('')
        cells = cells[:12]

        if all(c == '' or c == '-' for c in cells):
            continue

        # Post-process specific columns
        cells[1] = shorten_test_case_name(cells[1])   # Test Case: trim to 10 words

        rows.append(cells)

    return rows

def write_markdown_table(rows, output_path):
    """Write a clean GitHub-flavoured Markdown table (no metadata, no headings)."""
    headers = [
        '#', 'Test Case', 'Test Steps', 'Type', 'Priority',
        'Expected Result', 'Actual Result',
        'Dev', 'Nightly', 'Staging', 'Prod', 'Comments'
    ]

    def md_cell(text):
        # Escape any raw pipe characters that are not already <br> or escaped
        # (cells should already be clean from parse step, but be safe)
        return text.replace('\n', '<br>')

    separator = '| ' + ' | '.join(['---'] * len(headers)) + ' |'
    header_row = '| ' + ' | '.join(headers) + ' |'

    lines = [header_row, separator]
    for row in rows:
        line = '| ' + ' | '.join(md_cell(c) for c in row) + ' |'
        lines.append(line)

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')

def main():
    rows = parse_table(INPUT_PATH)

    output_path = re.sub(r'_testcases\.md$', '_testcases_confluence.md', INPUT_PATH)
    if output_path == INPUT_PATH:
        output_path = INPUT_PATH.replace('.md', '_confluence.md')

    write_markdown_table(rows, output_path)

    print(f"Markdown: {output_path}")
    print(f"Rows written: {len(rows)}")

main()
```

After the script runs, report to the user:
> "Written to `<output_path>`. **<N> test cases** exported.
> Open the file in VS Code or GitHub, copy the rendered table, and paste into Confluence."

---

## Step 3 — Quality Gate (run silently after generation)

After generating the file, spot-check **3 random rows** to verify:

| Check | Rule |
|-------|------|
| No raw `**` in any cell | Bold markers stripped |
| No raw backticks in any cell | Inline code markers stripped |
| `\|` has become `\|` → literal `\|` in output | Escaped pipes resolved |
| Test Case column ≤ 10 words after the dash | Fits Confluence column width |
| `<br>` tags present where original had `<br>` | Line breaks preserved |
| Dev / Nightly / Staging / Prod columns contain `-` | Not empty |
| `#` column is sequential integers | No gaps, no duplicates |

If any check fails, fix the Python script and re-run before reporting success.

---

## Step 4 — Confluence Paste Instructions (print after success)

Print this block verbatim so the user knows exactly what to do:

```
HOW TO PASTE INTO CONFLUENCE
─────────────────────────────────────────────────────
1. Open the generated *_testcases_confluence.md file
   in VS Code or a GitHub/GitLab preview tab.

2. In the preview pane, select ALL the table rows
   (click the first cell, Shift-click the last cell,
    or Ctrl+A if only the table is in the file).

3. Copy (Ctrl+C / Cmd+C).

4. In Confluence: open the page in Edit mode,
   click where the table should go, then Paste (Ctrl+V / Cmd+V).
   Confluence will insert a native table — no plugin needed.

5. After pasting, update "Actual Result", "Dev",
   "Nightly", "Staging", "Prod" columns as tests are executed.
─────────────────────────────────────────────────────
Tip: if the paste lands as plain text rather than a table,
try pasting into a Google Doc first, then copy from there
into Confluence — Google preserves table formatting.
```

---

## Column Rules (reference)

| Column | Max width hint | Rule |
|--------|---------------|------|
| `#` | 3 chars | Sequential integer; removed cases keep their number + Comments="Removed" |
| `Test Case` | ~20 words | `[ID] — [≤10 word description]` — e.g. `UT-07 — tryAcquireSemaphore within limit returns true` |
| `Test Steps` | widest | `Prerequisites:<br>1. ...<br><br>Steps:<br>1. ...` — `<br>` for line breaks |
| `Type` | 1 word | Exactly one of: `Unit` / `Integration` / `Automation` / `Regression` / `Tenant Isolation` |
| `Priority` | 2 chars | `P0` / `P1` / `P2` |
| `Expected Result` | wide | `• assertion 1<br>• assertion 2` — measurable, specific |
| `Actual Result` | wide | Leave blank — tester fills during execution |
| `Dev` | 3 chars | `-` (default); tester fills: `Pass` / `Fail` / `N/A` |
| `Nightly` | 3 chars | `-` |
| `Staging` | 3 chars | `-` |
| `Prod` | 3 chars | `-` |
| `Comments` | wide | Blank unless a review note exists; "Removed" for dropped cases |

---

## Naming Convention

Output file: same directory as input, same slug, suffix `_confluence.md`.

```
CAP-184618_expiry_job_tuning_testcases.md
            ↓
CAP-184618_expiry_job_tuning_testcases_confluence.md
```

---

## Ground Rules

- **Always use the Python script** — never hand-craft table rows.
- **Preserve `<br>` tags** — do NOT convert them to newlines. Confluence renders `<br>` correctly inside table cells.
- **No metadata sections** — output file contains ONLY the Markdown table. No `# Heading`, no summary block, no PR notes.
- **Crisp names** — Test Case column is the auditor's first read; 10 words max after the ID.
- **Measurable expectations** — Expected Result cells must name the actual value/state, not just "test passes".
- **Never ask about optional columns** — fill Dev/Nightly/Staging/Prod with `-` by default.
