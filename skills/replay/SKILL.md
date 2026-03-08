---
name: replay
description: Resume work from a previous session with state verification and git patch restore. Reads the handoff, verifies files and git state, restores patches, and presents a structured briefing.
---

# Replay From Handoff

Pick up work from a previous session with full state verification and git patch restore.

## Lifecycle

The handoff file is a **single-use baton**. Read it, verify state, restore patches, delete it.

## Steps

1. **Find handoff files** — Search both personal and team directories. Check for own session's handoff first:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/remembrall}/hooks/lib.sh"
   CWD=$(pwd)
   HANDOFF_DIR=$(remembrall_handoff_dir "$CWD")
   TEAM_DIR=$(remembrall_team_handoff_dir "$CWD")
   # Session ID: env var or published by hook
   OWN_SID="${CLAUDE_SESSION_ID:-$(remembrall_read_session_id "$CWD" 2>/dev/null)}"
   echo "Personal: $HANDOFF_DIR"
   echo "Team: $TEAM_DIR"
   echo "Own session: $OWN_SID"
   # Check own session first
   if [ -n "$OWN_SID" ] && [ -f "$HANDOFF_DIR/handoff-${OWN_SID}.md" ]; then
     echo "OWN SESSION HANDOFF: $HANDOFF_DIR/handoff-${OWN_SID}.md"
   fi
   # List all available
   ls -lt "$HANDOFF_DIR"/handoff-*.md "$TEAM_DIR"/handoff-*.md 2>/dev/null || echo "No handoffs found"
   ```

   - **0 files:** Tell the user: "No handoff found. Nothing to replay."
   - **Own session file found:** Use it directly.
   - **Only other sessions' files:** List them with timestamps. **Ask the user** which one to replay before consuming — these belong to other Claude instances.
   - **Multiple including own:** Use own session's handoff, mention others exist.

2. **Read the handoff** — Read the selected file's contents.

3. **Parse frontmatter** — If the file starts with `---`, extract structured fields:
   - `status`, `branch`, `commit`, `patch`, `files`, `tasks`, `team`, `previous_session`
   - If no frontmatter (legacy handoff), skip verification steps and proceed with markdown-only mode.

4. **Mark consumed file** — Rename instead of delete (preserved for safety; auto-cleaned after 1 hour):
   ```bash
   mv "$HANDOFF_FILE" "${HANDOFF_FILE%.md}.consumed.md"
   ```

5. **Check chain history** — If `previous_session` is present, note it for the briefing. Optionally check if the previous session's handoff still exists (it usually won't — consumed on resume). This gives the user awareness of how many sessions deep they are.

6. **Validate freshness** — Check the `created` timestamp. If older than the configured retention period, warn the user it may be stale and ask if they want to continue.

7. **Verify git state** (if frontmatter has branch/commit):
   ```bash
   CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
   CURRENT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null)
   echo "Handoff: branch=$BRANCH commit=$COMMIT"
   echo "Current: branch=$CURRENT_BRANCH commit=$CURRENT_COMMIT"
   if [ "$CURRENT_COMMIT" != "$COMMIT" ]; then
     git log --oneline "$COMMIT..HEAD" 2>/dev/null || echo "Could not compare commits"
   fi
   ```
   - **Branch mismatch:** Warn user, ask if they want to switch.
   - **Commit mismatch:** Show what changed since handoff with `git log --oneline`.
   - **Match:** Confirm state is unchanged.

8. **Verify files** — For each file in the frontmatter `files` list:
   - Check if it exists on disk
   - If commit is available, check `git diff $COMMIT -- $FILE` to see if modified since handoff
   - Summarize: "N files unchanged, N modified since handoff, N missing"

9. **Restore git patches** (if `patch` field exists and the file is present):
   ```bash
   # Check if patch applies cleanly
   git apply --check "$PATCH_PATH" 2>&1
   ```
   - **Clean apply:** Ask user: "Apply saved changes from previous session? (X files, Y lines changed)"
   - **If yes:** Run `git apply "$PATCH_PATH"` then `rm -f "$PATCH_PATH"`
   - **If conflicts:** Show which files conflict, suggest manual review. Do NOT force-apply.
   - **No patch file:** Skip silently.

10. **Present structured briefing** — Show a clear summary to the user:

    ```
    ## Session Replay

    **Task:** [from handoff]
    **Status:** [status] | branch: [match/mismatch] | commit: [match/N new commits]
    **Files:** [N unchanged, N modified, N missing since handoff]
    **Patches:** [applied / skipped / none]
    **Chain:** [session N → this session] or [first session] if no previous_session

    ### Completed
    - [items from handoff]

    ### Remaining (priority-ordered)
    1. [blockers first — anything marked as blocked, erroring, or prerequisite]
    2. [in-progress items — partially done work from previous session]
    3. [not-started items — new tasks that haven't been touched]

    ### Key Decisions (preserved from previous session)
    - [decisions]

    ### Open Questions
    - [unresolved items]
    ```

11. **Create task list with priority ordering** — For each remaining item from the handoff, create a task. Order them by priority:
    1. **Blockers** — items flagged as blocked, failing, or prerequisite for other work
    2. **In-progress** — items partially completed in the previous session
    3. **Not-started** — items that haven't been touched yet

    Infer priority from context clues in the handoff:
    - Words like "blocked", "failing", "error", "prerequisite", "depends on", "must fix first" → blocker
    - Words like "started", "partial", "WIP", "halfway", "begun" → in-progress
    - Everything else → not-started

12. **Ask to proceed** — "Ready to continue with [next remaining item]?" Don't charge ahead — the user may have changed priorities.

## Rules
- Delete only the consumed handoff file — leave other sessions' files alone
- Delete consumed patch file only after successful `git apply`
- NEVER force-apply patches — if `git apply --check` fails, warn and skip
- Verify file state before modifying anything
- Respect decisions documented in the handoff — don't re-debate unless the user asks
- Legacy handoffs (no YAML frontmatter) still work — just skip verification steps 7-9
- If the handoff mentions blockers, address those first
- The handoff may have been written by a different Claude model — don't critique the approach, just continue it
- If this instance later needs to hand off, use `/handoff` — it will write a fresh one
- **Do NOT re-read or re-analyze files** just because they appear in a "Files Modified" list — those are for reference only. Only read files needed for the specific Next Step.
- If a "Do NOT Do" section exists, follow it strictly — it documents dead ends and completed work that must not be revisited
- If a "Next Step" section exists, that is the ONLY thing to propose — not a re-exploration of the entire task
