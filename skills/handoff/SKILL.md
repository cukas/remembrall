---
name: handoff
description: Save a structured handoff document so another Claude instance (or this one after /clear) can resume the work. Use when context is getting long, switching tasks, or before /clear.
---

# Session Handoff

Create a structured handoff document that any Claude instance can read to resume this work.

## Steps

1. **Gather state** — Review the current conversation to understand:
   - What task was requested
   - What has been completed so far
   - What remains to be done
   - Key decisions made and why
   - Files created or modified (collect the full list)
   - Current blockers or open questions
   - Test status (passing/failing)
   - Approaches tried that failed (with error messages)
   - Any task list items (check /tasks)

2. **Write the handoff** — Pipe a markdown document to `handoff-create.sh`. The script handles all path computation, git patches, YAML frontmatter, and team copies automatically. Always pass `--session-id` with `$CLAUDE_SESSION_ID` so the handoff can be found by auto-resume after `/clear`.

   ```bash
   cat << 'HANDOFF_CONTENT' | bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/remembrall}/scripts/handoff-create.sh" \
     --cwd "$(pwd)" \
     --session-id "$CLAUDE_SESSION_ID" \
     --status "in_progress" \
     --files "file1.ts,file2.ts,file3.ts" \
     --tasks "Remaining task 1" "Remaining task 2" "Remaining task 3"
   # Session Handoff

   **Task:** [One-line description of what was requested]

   ## Completed
   - [Bullet list of what's done, with file paths]

   ## Next Step — Do This First
   [The EXACT next action. Not a list of everything remaining — just the single next thing to do. Be specific: "Run the test suite for auth module" not "continue testing". Include the file path and line number if applicable.]

   ## Remaining (after next step)
   - [Numbered list of what still needs to happen, in priority order]

   ## Failed Approaches
   - [Approaches tried and ruled out. For each: what was attempted, the exact error message or why it failed, and why it won't work. This prevents the next session from repeating the same dead ends.]

   ## Do NOT Do
   - [Things the next session must NOT do — files to leave alone, features that are done and should not be re-analyzed, rabbit holes to avoid]

   ## Key Decisions
   - [Important choices made and why — so the next instance doesn't re-debate them]

   ## Files Modified
   - [List of files changed in this session, with brief note of what changed]

   ## Context
   [Any important context the next instance needs — error messages, gotchas discovered, user preferences expressed during the session]

   ## Open Questions
   - [Anything unresolved that needs user input]
   HANDOFF_CONTENT
   ```

   **Replace the placeholder content** with actual information from this session. Replace the `--files` and `--tasks` arguments with real values.

3. **Confirm to the user** — Tell them the handoff is saved and they can `/clear` or switch to another Claude instance. Show:
   - Brief summary of what was captured
   - The output path from the script
   - Whether team copy was created (check stderr for `team:` prefix)

## Rules
- Be concise but complete — the next instance has zero context
- Include file paths, not vague descriptions
- If there's an active task list, pass all pending tasks via `--tasks`
- Do NOT include raw code dumps — reference files and line numbers instead
- The handoff must be self-contained: another Claude reading only this file should be able to continue
- Only include files YOU modified this session in `--files` — not the user's other work
- Set `--status` to `blocked` if work is stuck, `paused` if intentionally stopping
