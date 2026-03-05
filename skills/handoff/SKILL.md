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
   - Any task list items (check /tasks)

2. **Write the handoff** — Pipe a markdown document to `handoff-create.sh`. The script handles all path computation, git patches, YAML frontmatter, and team copies automatically.

   ```bash
   cat << 'HANDOFF_CONTENT' | bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/remembrall}/scripts/handoff-create.sh" \
     --cwd "$(pwd)" \
     --status "in_progress" \
     --files "file1.ts,file2.ts,file3.ts" \
     --tasks "Remaining task 1" "Remaining task 2" "Remaining task 3"
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
