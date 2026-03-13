---
name: obliviate
description: Guided pruning of stale memories with user confirmation
---

# Obliviate — Guided Memory Pruning

You are running the Obliviate memory pruning skill. Follow these steps:

## Step 1: Analyze

Run the memory staleness analyzer:

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
echo "{\"session_id\":\"$SESSION_ID\",\"cwd\":\"$(pwd)\"}" | bash "$CLAUDE_PLUGIN_ROOT/hooks/obliviate-analyze.sh"
```

## Step 2: Review

Read the analysis report:

```bash
REPORT="/tmp/remembrall-obliviate/${SESSION_ID}.json"
```

If the report exists, present findings to the user:
- Total memories analyzed
- Number flagged as stale
- For each stale memory: filename, age, and reason

## Step 3: Confirm

**NEVER archive without explicit user confirmation.**

Ask: "Would you like to archive these N stale memories? They'll be moved to `.archive/` and can be restored later."

## Step 4: Execute

If the user confirms:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/obliviate-archive.sh" "$SESSION_ID"
```

If the user says no or wants to skip some:
- Respect their choice
- They can run `/obliviate` again later

## Notes

- Archived memories go to `memory/.archive/` — they are NOT deleted
- The MEMORY.md index is updated automatically
- Stale = not updated in more sessions than `obliviate_stale_sessions` (default: 5)
- Pensieve activity is cross-referenced: if a TT agent recently accessed related files, the memory is NOT stale
