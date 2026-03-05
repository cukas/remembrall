# Remembrall v2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enhance remembrall with global config, session journals, git patch snapshots, smart replay, and team handoffs.

**Architecture:** All new features are config-gated via `~/.remembrall/config.json`. Handoffs gain YAML frontmatter for machine-readable metadata. Git patches are stored externally in `~/.remembrall/patches/` (only session-touched files). `/resume` is replaced by `/replay` which verifies state before continuing.

**Tech Stack:** Bash, jq, git, YAML-in-markdown frontmatter

---

## Summary of Changes

| File | Action | Purpose |
|------|--------|---------|
| `hooks/lib.sh` | Modify | Add config reader, YAML parser, git helpers |
| `hooks/context-monitor.sh` | Modify | Add 60% journal nudge |
| `hooks/precompact-handoff.sh` | Modify | Add YAML frontmatter, git patch capture |
| `hooks/session-resume.sh` | Modify | Handle YAML frontmatter, team handoffs dir |
| `hooks/stop-check.sh` | Modify | Read config for thresholds |
| `hooks/handoff-path.sh` | Modify | Support team handoff paths |
| `skills/handoff/SKILL.md` | Modify | YAML frontmatter, git patches, team mode |
| `skills/resume/SKILL.md` | Rewrite | Becomes `/replay` with verification |
| `commands/setup-remembrall.md` | Modify | Add config setup section |
| `commands/remembrall-status.md` | Modify | Show config, patches, team status |
| `scripts/remembrall-status.sh` | Modify | Report new features |
| `.claude-plugin/plugin.json` | Modify | Bump version to 2.0.0 |
| `.claude-plugin/marketplace.json` | Modify | Update description, tags |

---

### Task 1: Global Config System in lib.sh

**Files:**
- Modify: `hooks/lib.sh`

**Step 1: Add config reader function to lib.sh**

Append after the existing `remembrall_estimate_context` function:

```bash
# Read a config value from ~/.remembrall/config.json
# Usage: remembrall_config "key" "default_value"
# Supports dot-notation: remembrall_config "git.enabled" "false"
remembrall_config() {
  local key="$1"
  local default="$2"
  local config_file="$HOME/.remembrall/config.json"

  if [ ! -f "$config_file" ]; then
    echo "$default"
    return
  fi

  local value
  value=$(jq -r --arg k "$key" '.[$k] // empty' "$config_file" 2>/dev/null)

  if [ -z "$value" ]; then
    echo "$default"
  else
    echo "$value"
  fi
}

# Write a config value to ~/.remembrall/config.json
# Creates the file and directory if they don't exist
remembrall_config_set() {
  local key="$1"
  local value="$2"
  local config_file="$HOME/.remembrall/config.json"

  mkdir -p "$(dirname "$config_file")"

  if [ ! -f "$config_file" ]; then
    echo '{}' > "$config_file"
  fi

  local tmp
  tmp=$(jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$config_file")
  printf '%s\n' "$tmp" > "$config_file"
}

# Check if a project is a git repo and git integration is enabled
remembrall_git_enabled() {
  local cwd="$1"
  [ "$(remembrall_config "git_integration" "false")" = "true" ] || return 1
  git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
}

# Compute patches directory for a project
remembrall_patches_dir() {
  local cwd="$1"
  local hash
  hash=$(remembrall_md5 "$cwd") || return 1
  echo "$HOME/.remembrall/patches/$hash"
}

# Check if team handoffs are enabled
remembrall_team_enabled() {
  [ "$(remembrall_config "team_handoffs" "false")" = "true" ]
}

# Compute team handoff directory (project-local)
remembrall_team_handoff_dir() {
  local cwd="$1"
  echo "$cwd/.remembrall/handoffs"
}

# Parse YAML frontmatter from a handoff file
# Outputs the value of a given key from the frontmatter
remembrall_frontmatter_get() {
  local file="$1"
  local key="$2"
  # Extract between --- markers, find key, strip value
  sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null | grep "^${key}:" | sed "s/^${key}: *//"
}
```

**Step 2: Verify lib.sh loads correctly**

Run: `bash -n ${PLUGIN_ROOT}/hooks/lib.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add hooks/lib.sh
git commit -m "feat: add global config system, git helpers, team handoff, frontmatter parsing to lib.sh"
```

---

### Task 2: YAML Frontmatter in Handoff Skill

**Files:**
- Modify: `skills/handoff/SKILL.md`

**Step 1: Rewrite the handoff skill with YAML frontmatter and git patch support**

Replace the entire content of `skills/handoff/SKILL.md` with the new version that:
- Writes YAML frontmatter with machine-readable fields (status, files list, branch, commit)
- Captures git patches for session-touched files when `git_integration` is enabled in config
- Stores patches externally at `~/.remembrall/patches/{hash}/patch-{session}.diff`
- Supports team handoffs: writes to project-local `.remembrall/handoffs/` when `team_handoffs` config is enabled
- Keeps the human-readable markdown body

New handoff format:

```markdown
---
created: 2026-03-05T14:30:00Z
session_id: abc123
project: /Users/me/myproject
status: in_progress
branch: feature/auth
commit: a1b2c3d
patch: ~/.remembrall/patches/abc/patch-abc123.diff
files:
  - src/auth.ts
  - src/middleware.ts
tasks:
  - "Implement token refresh"
  - "Add rate limiting"
team: false
---

# Session Handoff

**Task:** Implement authentication system

## Completed
- [bullet list]

## Remaining
- [numbered list]

## Key Decisions
- [decisions and why]

## Context
[important context]

## Open Questions
- [unresolved items]
```

**Step 2: Verify SKILL.md is valid markdown**

Run: `head -5 ${PLUGIN_ROOT}/skills/handoff/SKILL.md`
Expected: YAML frontmatter with `---` and skill metadata

**Step 3: Commit**

```bash
git add skills/handoff/SKILL.md
git commit -m "feat: handoff skill with YAML frontmatter, git patches, team support"
```

---

### Task 3: Precompact Hook with YAML Frontmatter and Git Patches

**Files:**
- Modify: `hooks/precompact-handoff.sh`

**Step 1: Update precompact-handoff.sh**

Changes:
1. Add YAML frontmatter block at the top of auto-generated handoffs
2. When `git_integration` config is enabled, capture `git diff` for session-touched files and save to `~/.remembrall/patches/{hash}/patch-{session}.diff`
3. Record branch name and HEAD commit in frontmatter
4. When `team_handoffs` is enabled, also write a copy to `{project}/.remembrall/handoffs/`
5. Include the patch file path in frontmatter

The frontmatter extraction: after collecting `FILE_PATHS`, use them with `git diff -- $files` to create the patch. Only capture diffs for files that exist and are tracked by git.

Key code additions:

```bash
# After FILE_PATHS extraction:
BRANCH=""
COMMIT=""
PATCH_FILE=""
if remembrall_git_enabled "$CWD"; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || echo "")
  COMMIT=$(git -C "$CWD" rev-parse --short HEAD 2>/dev/null || echo "")

  # Build file list for targeted git diff (only session-touched files)
  DIFF_FILES=""
  while IFS= read -r fp; do
    [ -z "$fp" ] && continue
    if git -C "$CWD" ls-files --error-unmatch "$fp" >/dev/null 2>&1 || \
       [ -f "$fp" ]; then
      DIFF_FILES="$DIFF_FILES $fp"
    fi
  done <<< "$FILE_PATHS"

  if [ -n "$DIFF_FILES" ]; then
    PATCHES_DIR=$(remembrall_patches_dir "$CWD") || true
    if [ -n "$PATCHES_DIR" ]; then
      mkdir -p "$PATCHES_DIR"
      PATCH_FILE="$PATCHES_DIR/patch-${SESSION_ID}.diff"
      # Capture both staged and unstaged changes for session files only
      {
        git -C "$CWD" diff -- $DIFF_FILES 2>/dev/null
        git -C "$CWD" diff --staged -- $DIFF_FILES 2>/dev/null
      } > "$PATCH_FILE"
      # Remove empty patch files
      [ ! -s "$PATCH_FILE" ] && { rm -f "$PATCH_FILE"; PATCH_FILE=""; }
    fi
  fi
fi

# Write YAML frontmatter
TEAM_MODE=$(remembrall_config "team_handoffs" "false")
FILES_YAML=""
while IFS= read -r fp; do
  [ -z "$fp" ] && continue
  FILES_YAML="${FILES_YAML}\n  - ${fp}"
done <<< "$FILE_PATHS"

cat > "$HANDOFF_FILE" << REMEMBRALL_FRONTMATTER
---
created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
session_id: $SESSION_ID
project: $CWD
status: interrupted
type: auto-generated
branch: ${BRANCH}
commit: ${COMMIT}
patch: ${PATCH_FILE}
files:${FILES_YAML}
team: ${TEAM_MODE}
---

REMEMBRALL_FRONTMATTER
```

Then append the existing markdown body sections (Files Touched, Errors, Git Ops, etc.).

Also: if team handoffs enabled, copy the handoff to the team directory:

```bash
if remembrall_team_enabled; then
  TEAM_DIR=$(remembrall_team_handoff_dir "$CWD")
  mkdir -p "$TEAM_DIR"
  cp "$HANDOFF_FILE" "$TEAM_DIR/"
fi
```

**Step 2: Verify syntax**

Run: `bash -n ${PLUGIN_ROOT}/hooks/precompact-handoff.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add hooks/precompact-handoff.sh
git commit -m "feat: precompact hook with YAML frontmatter, git patches, team copy"
```

---

### Task 4: Session Journal — 60% Nudge in Context Monitor

**Files:**
- Modify: `hooks/context-monitor.sh`

**Step 1: Add 60% journal update nudge**

Insert a new threshold block between the "do nothing above 30%" check and the <=30% warning. At 60%, nudge Claude once per session to update the handoff (living journal):

```bash
# <=60% — JOURNAL UPDATE (nudge once to update running handoff)
if (( $(echo "$REMAINING <= 60" | bc -l 2>/dev/null || echo 0) )); then
  if [ "$LAST_NUDGE" = "journal" ] || [ "$LAST_NUDGE" = "warning" ] || [ "$LAST_NUDGE" = "urgent" ]; then
    # Already nudged at this level or lower — check if we should escalate
    :
  else
    echo "journal" > "$NUDGE_FILE"
    cat << EOF
{
  "additionalContext": "CONTEXT MONITOR (${REMAINING}% remaining${ESTIMATED}): Context is at 60%. Update your session handoff now — run /handoff to save current progress. This is a checkpoint, not an emergency. Continue working after saving."
}
EOF
    exit 0
  fi
fi
```

The nudge state progression is: (none) → journal (60%) → warning (30%) → urgent (20%). Each level only fires once. The existing reset at >80% clears all states.

**Step 2: Adjust the >30% exit to >60%**

Change the early exit:
```bash
# >60% remaining — do nothing (was >30%)
if (( $(echo "$REMAINING > 60" | bc -l 2>/dev/null || echo 0) )); then
  exit 0
fi
```

And restructure the flow: 60% → journal, 30% → warning, 20% → urgent.

**Step 3: Verify syntax**

Run: `bash -n ${PLUGIN_ROOT}/hooks/context-monitor.sh`
Expected: No output

**Step 4: Commit**

```bash
git add hooks/context-monitor.sh
git commit -m "feat: add 60% journal checkpoint nudge to context monitor"
```

---

### Task 5: Session Resume — Handle YAML Frontmatter, Team Handoffs, Git Patches

**Files:**
- Modify: `hooks/session-resume.sh`

**Step 1: Update session-resume.sh**

Changes:
1. Check team handoff directory (`{project}/.remembrall/handoffs/`) in addition to personal directory
2. When loading a handoff with YAML frontmatter, parse structured fields
3. If handoff has a `patch` field, include patch info in the injected context so `/replay` can offer to apply it
4. If handoff has `branch` and `commit`, include them so `/replay` can verify state

Add team directory search after personal directory search:

```bash
# Also check team handoff directory if enabled
if remembrall_team_enabled && [ -z "$HANDOFF_FILE" ]; then
  TEAM_DIR=$(remembrall_team_handoff_dir "$CWD")
  if [ -d "$TEAM_DIR" ]; then
    for f in "$TEAM_DIR"/handoff-*.md; do
      [ -f "$f" ] || continue
      if [ -z "$HANDOFF_FILE" ] || [ "$f" -nt "$HANDOFF_FILE" ]; then
        HANDOFF_FILE="$f"
      fi
    done
  fi
fi
```

When building the injected context, extract frontmatter fields:

```bash
# Extract frontmatter metadata if present
PATCH_PATH=$(remembrall_frontmatter_get "$CLAIMED_FILE" "patch")
BRANCH=$(remembrall_frontmatter_get "$CLAIMED_FILE" "branch")
COMMIT=$(remembrall_frontmatter_get "$CLAIMED_FILE" "commit")
HANDOFF_STATUS=$(remembrall_frontmatter_get "$CLAIMED_FILE" "status")

GIT_CONTEXT=""
if [ -n "$PATCH_PATH" ] && [ -f "$PATCH_PATH" ]; then
  GIT_CONTEXT="\\n\\nGIT STATE: Branch was '${BRANCH}', commit was '${COMMIT}'. A patch file exists at ${PATCH_PATH} with the session's uncommitted changes. Use /replay to verify and restore."
fi
```

**Step 2: Verify syntax**

Run: `bash -n ${PLUGIN_ROOT}/hooks/session-resume.sh`
Expected: No output

**Step 3: Commit**

```bash
git add hooks/session-resume.sh
git commit -m "feat: session resume with YAML frontmatter, team handoffs, git context"
```

---

### Task 6: `/replay` Skill (Replaces `/resume`)

**Files:**
- Rewrite: `skills/resume/SKILL.md` (rename skill from `resume` to `replay`)

**Step 1: Rename skill directory**

```bash
mv ${PLUGIN_ROOT}/skills/resume ${PLUGIN_ROOT}/skills/replay
```

**Step 2: Write new SKILL.md for /replay**

The `/replay` skill is a smarter version of `/resume`. It:

1. Finds the handoff file (same as before — personal dir, then team dir)
2. Parses YAML frontmatter to extract structured metadata
3. Presents a **structured briefing** (not raw dump):
   - "Previous session was working on: [task]"
   - "Status: [status] on branch [branch] at commit [commit]"
   - "Completed: [list]"
   - "Remaining: [list]"
4. **Verifies state:**
   - Check if current branch matches handoff branch
   - Check if HEAD matches handoff commit (or show what changed since)
   - For each file in the files list: verify it exists, show if it was modified since handoff
   - If a patch file exists: show patch stats, offer to apply
5. **Git patch restore** (if patch exists and git_integration enabled):
   - Check if patch applies cleanly: `git apply --check $PATCH_FILE`
   - If clean: ask user "Apply saved changes from previous session?" then `git apply $PATCH_FILE`
   - If conflict: warn and show which files conflict, suggest manual resolution
   - Delete consumed patch file after apply
6. **Re-creates task list** from remaining items
7. **Asks before proceeding** — "Ready to continue with [next item]?"

```markdown
---
name: replay
description: Resume work from a previous session with state verification and git patch restore. Replaces /resume with smarter briefing and verification.
---

# Replay From Handoff

Pick up work from a previous session with full state verification.

## Lifecycle

The handoff file is a **single-use baton**. Read it, verify state, restore patches, delete it.

## Steps

1. **Find handoff** — Run:
   ```bash
   HANDOFF_DIR=$(bash -c 'source "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/remembrall}/hooks/lib.sh"; remembrall_handoff_dir "$(pwd)"')
   TEAM_DIR="$(pwd)/.remembrall/handoffs"
   echo "Personal: $HANDOFF_DIR"
   echo "Team: $TEAM_DIR"
   ls -lt "$HANDOFF_DIR"/handoff-*.md "$TEAM_DIR"/handoff-*.md 2>/dev/null || echo "No handoffs found"
   ```

   - **0 files:** "No handoff found. Nothing to replay."
   - **1 file:** Use it.
   - **Multiple:** List with timestamps, use most recent, mention others.

2. **Read the handoff** — Read the file contents.

3. **Delete consumed file** — `rm -f "$HANDOFF_FILE"` (single-use baton).

4. **Parse frontmatter** — If the file starts with `---`, extract:
   - `status`, `branch`, `commit`, `patch`, `files`, `tasks`, `team`
   - If no frontmatter (legacy handoff), proceed with markdown-only mode.

5. **Verify git state** (if frontmatter has branch/commit):
   ```bash
   CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
   CURRENT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null)
   echo "Handoff: branch=$BRANCH commit=$COMMIT"
   echo "Current: branch=$CURRENT_BRANCH commit=$CURRENT_COMMIT"
   ```
   - Branch mismatch → warn user, ask if they want to switch
   - Commit mismatch → show `git log --oneline $COMMIT..HEAD` to show what changed

6. **Verify files** — For each file in the files list:
   - Check if it exists
   - If frontmatter has commit, check `git diff $COMMIT -- $FILE` to see if modified since handoff
   - Report: "3 files unchanged, 1 modified since handoff, 1 deleted"

7. **Restore git patches** (if patch field exists and file is present):
   ```bash
   # Check if patch applies cleanly
   git apply --check "$PATCH_PATH" 2>&1
   ```
   - If clean → ask user: "Apply saved changes from previous session? (X files, Y lines)"
   - If yes → `git apply "$PATCH_PATH"` then `rm -f "$PATCH_PATH"`
   - If conflicts → show which files conflict, suggest manual review
   - If no patch file → skip silently

8. **Present structured briefing:**
   ```
   ## Session Replay

   **Task:** [from handoff]
   **Status:** [status] → was on branch [branch] at [commit]
   **Git:** [branch match/mismatch] | [commit match/X new commits since]
   **Files:** [N unchanged, N modified, N deleted since handoff]
   **Patches:** [applied/skipped/none]

   ### Completed
   - [items]

   ### Remaining
   1. [items — these become tasks]

   ### Key Decisions (from previous session)
   - [preserved decisions]

   ### Open Questions
   - [unresolved items]
   ```

9. **Create task list** — For each remaining item, create a task.

10. **Ask to proceed** — "Ready to continue with [next remaining item]?"

## Rules
- Delete only the consumed handoff file — leave others alone
- Delete consumed patch file after successful apply
- NEVER force-apply patches — if `--check` fails, warn and skip
- Verify file state before modifying anything
- Respect decisions from the handoff — don't re-debate
- Legacy handoffs (no frontmatter) work fine — just skip verification steps
- If handoff mentions blockers, address those first
```

**Step 3: Commit**

```bash
git add skills/
git commit -m "feat: /replay skill replaces /resume with state verification and git restore"
```

---

### Task 7: Update Handoff Path Helper for Team Mode

**Files:**
- Modify: `hooks/handoff-path.sh`

**Step 1: Add team handoff path output**

After computing the personal handoff path, also output team path if enabled:

```bash
# If team handoffs enabled, also create team directory
if [ -f "$HOME/.remembrall/config.json" ]; then
  TEAM=$(jq -r '.team_handoffs // "false"' "$HOME/.remembrall/config.json" 2>/dev/null)
  if [ "$TEAM" = "true" ]; then
    TEAM_DIR="$CWD/.remembrall/handoffs"
    mkdir -p "$TEAM_DIR"
    echo "$TEAM_DIR/handoff-${SESSION_ID}.md" >&2
  fi
fi
```

The primary path goes to stdout (personal), team path to stderr (skill reads both).

**Step 2: Commit**

```bash
git add hooks/handoff-path.sh
git commit -m "feat: handoff-path outputs team directory when enabled"
```

---

### Task 8: Update Setup Command with Config Options

**Files:**
- Modify: `commands/setup-remembrall.md`

**Step 1: Extend setup to include config**

Add a new section after the bridge setup that asks the user about optional features:

After bridge is verified, present config options:

```
## Optional Features

After the bridge is set up, ask the user which optional features they want:

1. **Git Integration** — "Would you like remembrall to save git patches of your session's changes before handoff? Patches are stored in ~/.remembrall/patches/, your repo stays untouched."
   - If yes: `remembrall_config_set "git_integration" "true"` via:
     ```bash
     source "${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
     remembrall_config_set "git_integration" "true"
     ```

2. **Team Handoffs** — "Would you like handoffs to also be saved in your project directory so other team members' Claude sessions can pick them up?"
   - If yes: `remembrall_config_set "team_handoffs" "true"`
   - Suggest adding `.remembrall/` to `.gitignore` if they don't want handoffs committed

Show current config after setup:
```bash
cat ~/.remembrall/config.json 2>/dev/null || echo "No config yet"
```
```

**Step 2: Commit**

```bash
git add commands/setup-remembrall.md
git commit -m "feat: setup command with git integration and team handoff config"
```

---

### Task 9: Update Status Script and Command

**Files:**
- Modify: `scripts/remembrall-status.sh`
- Modify: `commands/remembrall-status.md`

**Step 1: Add config, patches, and team status to diagnostic**

Append to `remembrall-status.sh`:

```bash
# Config
CONFIG_FILE="$HOME/.remembrall/config.json"
if [ -f "$CONFIG_FILE" ]; then
  echo "Config:   $CONFIG_FILE"
  GIT_INT=$(jq -r '.git_integration // "false"' "$CONFIG_FILE" 2>/dev/null)
  TEAM=$(jq -r '.team_handoffs // "false"' "$CONFIG_FILE" 2>/dev/null)
  echo "          git_integration: $GIT_INT"
  echo "          team_handoffs: $TEAM"
else
  echo "Config:   Not configured (defaults)"
fi

# Patches
PATCHES_DIR=$(remembrall_patches_dir "$CWD") 2>/dev/null
if [ -n "$PATCHES_DIR" ] && [ -d "$PATCHES_DIR" ]; then
  PATCH_COUNT=0
  for f in "$PATCHES_DIR"/patch-*.diff; do [ -f "$f" ] && PATCH_COUNT=$((PATCH_COUNT + 1)); done
  echo "Patches:  $PATCH_COUNT file(s) in $PATCHES_DIR"
else
  echo "Patches:  None"
fi

# Team handoffs
TEAM_DIR="$CWD/.remembrall/handoffs"
if [ -d "$TEAM_DIR" ]; then
  TEAM_COUNT=0
  for f in "$TEAM_DIR"/handoff-*.md; do [ -f "$f" ] && TEAM_COUNT=$((TEAM_COUNT + 1)); done
  echo "Team:     $TEAM_COUNT handoff(s) in $TEAM_DIR"
else
  echo "Team:     No team handoffs directory"
fi
```

**Step 2: Commit**

```bash
git add scripts/remembrall-status.sh commands/remembrall-status.md
git commit -m "feat: status script shows config, patches, team handoffs"
```

---

### Task 10: Update Plugin Manifests

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

**Step 1: Bump version and update descriptions**

`plugin.json`:
- Version: `"2.0.0"`
- Description: add "session journals, git patch snapshots, team handoffs, smart replay"
- Keywords: add `"git"`, `"team"`, `"journal"`, `"replay"`, `"patches"`

`marketplace.json`:
- Update description and tags to match

**Step 2: Commit**

```bash
git add .claude-plugin/
git commit -m "chore: bump version to 2.0.0, update descriptions"
```

---

### Task 11: Update README

**Files:**
- Modify: `README.md`

**Step 1: Update README with new features**

- Add "What's New in v2" section near the top
- Update architecture diagram to show journal checkpoint at 60%, git patches, team handoffs
- Update Commands/Skills tables (`/resume` → `/replay`)
- Add Config section documenting `~/.remembrall/config.json`
- Add Git Integration section
- Add Team Handoffs section
- Update Storage section with patches directory
- Update Requirements (git is optional, only needed for git_integration)

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README for v2 — journal, git patches, team handoffs, replay"
```

---

## Execution Order

Tasks 1-11 are sequential — each builds on the previous. The dependency chain:

```
Task 1 (lib.sh config) ← everything depends on this
Task 2 (handoff skill) ← needs lib.sh config + git helpers
Task 3 (precompact hook) ← needs lib.sh config + git helpers
Task 4 (context-monitor) ← independent of 2-3 but logically follows
Task 5 (session-resume) ← needs frontmatter parser from lib.sh
Task 6 (/replay skill) ← needs all above working
Task 7 (handoff-path) ← needs config reader
Task 8 (setup command) ← needs config writer
Task 9 (status script) ← needs all new paths
Task 10 (manifests) ← independent, do late
Task 11 (README) ← do last, documents everything
```
