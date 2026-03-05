---
name: handoff
description: Save a structured handoff document so another Claude instance (or this one after /clear) can resume the work. Use when context is getting long, switching tasks, or before /clear.
---

# Session Handoff

Create a structured handoff document that any Claude instance can read to resume this work.

## Multi-Session Design

Each session gets its own handoff file: `handoff-{session_id}.md`. This means multiple Claude sessions can coexist without overwriting each other's handoffs.

## Handoff Directory

Handoffs are stored per-project using a hash of the working directory:

```
~/.remembrall/handoffs/{md5_of_cwd}/handoff-{session_id}.md
```

To compute the hash cross-platform:
- macOS: `md5 -qs "$CWD"`
- Linux: `printf '%s' "$CWD" | md5sum | cut -d' ' -f1`

## Steps

1. **Determine session ID** — Your session ID is available from the context monitor nudge files. Check `/tmp/remembrall-nudges/` for your session's file. If unsure, use a timestamp-based fallback: `handoff-$(date +%s).md`.

2. **Compute handoff directory** — Run this to get the correct path:
   ```bash
   CWD=$(pwd)
   if command -v md5 >/dev/null 2>&1; then
     CWD_HASH=$(md5 -qs "$CWD")
   elif command -v md5sum >/dev/null 2>&1; then
     CWD_HASH=$(printf '%s' "$CWD" | md5sum | cut -d' ' -f1)
   fi
   HANDOFF_DIR="$HOME/.remembrall/handoffs/$CWD_HASH"
   mkdir -p "$HANDOFF_DIR"
   ```

3. **Clean up nudge state** — Reset your context monitor so it doesn't keep firing:
   ```bash
   # Find and remove YOUR nudge file (matches your session ID)
   rm -f /tmp/remembrall-nudges/$SESSION_ID
   ```
   Do NOT wipe all nudge files (`rm *`) — other Claude instances have their own.

4. **Gather state** — Review the current conversation to understand:
   - What task was requested
   - What has been completed so far
   - What remains to be done
   - Key decisions made and why
   - Files created or modified
   - Current blockers or open questions
   - Test status (passing/failing)
   - Any task list items (check /tasks)

5. **Write the handoff** — Save to the per-session file. Use this exact structure:

```markdown
# Session Handoff

**Created:** [ISO timestamp]
**Session ID:** [your session ID]
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

6. **Save location:** Write the handoff to `$HANDOFF_DIR/handoff-{session_id}.md` (the directory computed in step 2).

7. **Confirm to the user** — Tell them the handoff is saved and they can `/clear` or switch to another Claude instance. Show a brief summary of what was captured.

## Rules
- Be concise but complete — the next instance has zero context
- Include file paths, not vague descriptions
- If there's an active task list, capture all pending tasks
- Do NOT include raw code dumps — reference files and line numbers instead
- The handoff must be self-contained: another Claude reading only this file should be able to continue the work
- Do NOT delete other sessions' handoff files — only manage your own
