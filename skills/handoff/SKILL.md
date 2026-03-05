---
name: handoff
description: Save a structured handoff document so another Claude instance (or this one after /clear) can resume the work. Use when context is getting long, switching tasks, or before /clear.
---

# Session Handoff

Create a structured handoff document that any Claude instance can read to resume this work.

## Multi-Session Design

Each session gets its own handoff file: `handoff-{session_id}.md`. This means multiple Claude sessions can coexist without overwriting each other's handoffs.

## Steps

1. **Get handoff path** — Run this single command to compute the correct file path:
   ```bash
   HANDOFF_PATH=$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/remembrall}/hooks/handoff-path.sh")
   echo "$HANDOFF_PATH"
   ```
   This handles session ID detection, directory creation, and cross-platform hashing automatically.

2. **Clean up nudge state** — Reset your context monitor so it doesn't keep firing:
   ```bash
   rm -f "/tmp/remembrall-nudges/$CLAUDE_SESSION_ID"
   ```
   Do NOT wipe all nudge files (`rm *`) — other Claude instances have their own.

3. **Gather state** — Review the current conversation to understand:
   - What task was requested
   - What has been completed so far
   - What remains to be done
   - Key decisions made and why
   - Files created or modified
   - Current blockers or open questions
   - Test status (passing/failing)
   - Any task list items (check /tasks)

4. **Write the handoff** — Save to `$HANDOFF_PATH` (from step 1). Use this exact structure:

```markdown
# Session Handoff

**Created:** [ISO timestamp]
**Session ID:** [from step 1]
**Project:** [working directory path]
**Task:** [One-line description of what was requested]

## Status
[One of: IN PROGRESS | BLOCKED | PAUSED]

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

5. **Confirm to the user** — Tell them the handoff is saved and they can `/clear` or switch to another Claude instance. Show a brief summary of what was captured.

## Rules
- Be concise but complete — the next instance has zero context
- Include file paths, not vague descriptions
- If there's an active task list, capture all pending tasks
- Do NOT include raw code dumps — reference files and line numbers instead
- The handoff must be self-contained: another Claude reading only this file should be able to continue the work
- Do NOT delete other sessions' handoff files — only manage your own
