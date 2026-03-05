---
name: resume
description: Resume work from a handoff document left by a previous Claude instance (or this one before /clear). Reads the handoff file and picks up where the other session left off.
---

# Resume From Handoff

Pick up work from a previous Claude session's handoff document.

## Lifecycle

The handoff file is a **single-use baton**. Read it, absorb it, delete it immediately. This frees the slot so any Claude instance can write a new handoff when needed.

## Handoff Directory

Handoffs are stored per-project using a hash of the working directory:

```
~/.remembrall/handoffs/{md5_of_cwd}/handoff-*.md
```

## Steps

1. **Compute handoff directory** — Run this to find your project's handoff storage:
   ```bash
   CWD=$(pwd)
   if command -v md5 >/dev/null 2>&1; then
     CWD_HASH=$(md5 -qs "$CWD")
   elif command -v md5sum >/dev/null 2>&1; then
     CWD_HASH=$(printf '%s' "$CWD" | md5sum | cut -d' ' -f1)
   fi
   HANDOFF_DIR="$HOME/.remembrall/handoffs/$CWD_HASH"
   ```

2. **Find handoff files** — Search for files matching `handoff-*.md` in `$HANDOFF_DIR`.

   - **If 0 files found:** Tell the user: "No handoff document found. There's nothing to resume."
   - **If 1 file found:** Read it and proceed.
   - **If multiple files found:** List them with timestamps (use `ls -lt`), pick the most recent one, and tell the user about the others (e.g., "Found 3 handoff files. Using the most recent one from [timestamp]. There are 2 older handoffs from other sessions — let me know if you want to use one of those instead.").

3. **Read the handoff** — Read the selected file's contents.

4. **Clean up** — Delete only the consumed handoff file. Do NOT delete other sessions' handoff files:
   ```bash
   rm -f "$HANDOFF_DIR/handoff-{the_one_you_read}.md"
   ```

   Your own context monitor counter starts at 0 automatically (new session = new session ID). Do NOT touch other sessions' nudge files in `/tmp/remembrall-nudges/`.

5. **Validate freshness** — Check the timestamp in the handoff. If older than 24 hours, warn the user it may be stale and ask if they still want to resume. (Note: the auto-resume hook deletes handoffs older than 24h, so this mainly applies to manually invoked `/resume`.)

6. **Orient yourself** — Read the key files mentioned in the handoff to verify the current state matches what was described. Things may have changed since the handoff was written (e.g., the user made manual edits).

7. **Summarize to the user** — Give a brief status report:
   - What was being worked on
   - What was completed
   - What remains
   - Any blockers or open questions from the previous session

8. **Re-create task list** — If the handoff has remaining items, create tasks for them so progress is tracked.

9. **Ask to proceed** — Ask the user: "Ready to continue with [next remaining item]?" Don't just charge ahead — the user may have changed priorities.

## Rules
- Delete only the consumed handoff file immediately after reading — leave other sessions' files alone
- Never assume the handoff is perfectly accurate — always verify file state before modifying
- Respect decisions documented in the handoff — don't re-debate unless the user asks
- If the handoff mentions blockers, address them first before continuing with remaining work
- The handoff may have been written by a different Claude model — don't critique the approach, just continue it
- If this instance later needs to hand off, use `/handoff` — it will write a fresh one
