---
name: handoff
description: Save a structured handoff document so another Claude instance (or this one after /clear) can resume the work. Use when context is getting long, switching tasks, or before /clear.
---

# Session Handoff

Create a structured handoff document with YAML frontmatter that any Claude instance can read to resume this work.

## Multi-Session Design

Each session gets its own handoff file: `handoff-{session_id}.md`. Multiple Claude sessions coexist without overwriting each other's handoffs.

## Steps

1. **Get handoff path** — Run this to compute the correct file path:
   ```bash
   HANDOFF_PATH=$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/remembrall}/hooks/handoff-path.sh")
   echo "$HANDOFF_PATH"
   ```

2. **Clean up nudge state** — Reset your context monitor:
   ```bash
   rm -f "/tmp/remembrall-nudges/$CLAUDE_SESSION_ID"
   ```

3. **Check git state** (if available) — Gather branch and commit info:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/remembrall}/hooks/lib.sh"
   CWD=$(pwd)
   GIT_ENABLED=$(remembrall_git_enabled "$CWD" && echo "true" || echo "false")
   if [ "$GIT_ENABLED" = "true" ]; then
     BRANCH=$(git branch --show-current 2>/dev/null || echo "")
     COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "")
     echo "Git: branch=$BRANCH commit=$COMMIT"
   else
     echo "Git: not enabled or not a repo"
   fi
   ```

4. **Gather state** — Review the current conversation to understand:
   - What task was requested
   - What has been completed so far
   - What remains to be done
   - Key decisions made and why
   - Files created or modified (collect the full list for the frontmatter)
   - Current blockers or open questions
   - Test status (passing/failing)
   - Any task list items (check /tasks)

5. **Capture git patches** (only if git is enabled) — Save diffs for session-touched files only:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/remembrall}/hooks/lib.sh"
   CWD=$(pwd)
   if remembrall_git_enabled "$CWD"; then
     PATCHES_DIR=$(remembrall_patches_dir "$CWD")
     mkdir -p "$PATCHES_DIR"
     PATCH_FILE="$PATCHES_DIR/patch-${CLAUDE_SESSION_ID:-$(date +%s)}.diff"
     # Replace FILE1 FILE2 etc with the actual files you modified this session
     { git diff -- FILE1 FILE2 2>/dev/null; git diff --staged -- FILE1 FILE2 2>/dev/null; } > "$PATCH_FILE"
     if [ -s "$PATCH_FILE" ]; then
       echo "Patch saved: $PATCH_FILE ($(wc -l < "$PATCH_FILE") lines)"
     else
       rm -f "$PATCH_FILE"
       PATCH_FILE=""
       echo "No uncommitted changes to patch"
     fi
   fi
   ```
   **Important:** Only include files YOU modified this session in the git diff command — not the user's other work.

6. **Check team mode** — See if team handoffs are enabled:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/remembrall}/hooks/lib.sh"
   TEAM_ENABLED=$(remembrall_team_enabled && echo "true" || echo "false")
   echo "Team handoffs: $TEAM_ENABLED"
   ```

7. **Write the handoff** — Save to `$HANDOFF_PATH` (from step 1). Use this exact structure:

```markdown
---
created: [ISO timestamp, e.g. 2026-03-05T14:30:00Z]
session_id: [from CLAUDE_SESSION_ID or handoff-path output]
project: [working directory path]
status: [in_progress | blocked | paused]
branch: [git branch or empty]
commit: [short git commit hash or empty]
patch: [path to patch file or empty]
files:
  - [file1]
  - [file2]
tasks:
  - "[remaining task 1]"
  - "[remaining task 2]"
team: [true|false]
---

# Session Handoff

**Task:** [One-line description of what was requested]

## Completed
- [Bullet list of what's done, with file paths]

## Remaining
- [Numbered list of what still needs to happen, in order]

## Key Decisions
- [Important choices made and why — so the next instance doesn't re-debate them]

## Files Modified
- [List of files changed in this session, with brief note of what changed]

## Context
[Any important context the next instance needs — error messages, gotchas discovered, user preferences expressed during the session]

## Open Questions
- [Anything unresolved that needs user input]
```

8. **Copy to team directory** (if team mode enabled):
   ```bash
   source "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/remembrall}/hooks/lib.sh"
   if remembrall_team_enabled; then
     TEAM_DIR=$(remembrall_team_handoff_dir "$(pwd)")
     mkdir -p "$TEAM_DIR"
     cp "$HANDOFF_PATH" "$TEAM_DIR/"
     echo "Team copy saved to $TEAM_DIR/"
   fi
   ```

9. **Confirm to the user** — Tell them the handoff is saved and they can `/clear` or switch to another Claude instance. Show:
   - Brief summary of what was captured
   - Whether git patches were saved
   - Whether team copy was created

## Rules
- Be concise but complete — the next instance has zero context
- Include file paths, not vague descriptions
- If there's an active task list, capture all pending tasks in the `tasks` frontmatter field
- Do NOT include raw code dumps — reference files and line numbers instead
- The handoff must be self-contained: another Claude reading only this file should be able to continue
- Do NOT delete other sessions' handoff files — only manage your own
- Only capture git diffs for files YOU modified this session — not the user's other work
- The YAML frontmatter must be valid — no special characters in values that break YAML parsing
