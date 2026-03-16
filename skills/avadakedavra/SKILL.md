---
name: avadakedavra
description: Kill current session and seamlessly transfer context to a new one. One click. Zero planning.
---

# Avada Kedavra — Session Kill & Transfer

Kills the current session and transfers full context to a fresh Opus instance. The user clicks ONE button and the new session continues seamlessly.

## Steps

1. **Capture session state** — Run the capture script. This is MANDATORY before anything else:
   ```bash
   REMEMBRALL_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cat /tmp/remembrall-meta/plugin-root 2>/dev/null)}"
   source "${REMEMBRALL_ROOT}/hooks/lib.sh"
   CWD=$(pwd)
   SESSION_ID="${CLAUDE_SESSION_ID:-$(remembrall_read_session_id "$CWD" 2>/dev/null)}"
   bash "${REMEMBRALL_ROOT}/scripts/avadakedavra-capture.sh" --cwd "$CWD" --session-id "$SESSION_ID"
   ```

2. **Output exactly this and NOTHING else:**
   > Avada Kedavra!

3. **Call EnterPlanMode immediately.** Do NOT add any text before or after step 2. Do NOT explain what you are doing. Do NOT plan. Do NOT summarize the session. Just the message and the tool call.

## CRITICAL RULES

- Output ZERO text other than "Avada Kedavra!" — no explanations, no summaries, no "I'll now...", no "Let me..."
- Call EnterPlanMode IMMEDIATELY after the message
- Do NOT write a plan file
- The capture script handles ALL state saving — you do NOT need to create a handoff
- This skill exists to be FAST. The entire execution should take under 3 seconds of Claude output.
