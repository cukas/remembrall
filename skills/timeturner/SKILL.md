---
name: timeturner
description: Manage Time-Turner parallel agents — check status, diff changes, merge results, or cancel. Time-Turner spawns a headless Claude agent to continue work when context runs low.
---

# Time-Turner — Parallel Agent Manager

Manage Time-Turner agents that were spawned to continue work in parallel.

## Sub-commands

Parse the user's argument to determine which sub-command to run.

### `/timeturner status` (default if no argument)

Show the current Time-Turner state:

```bash
REMEMBRALL_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cat /tmp/remembrall-meta/plugin-root 2>/dev/null)}"
bash "$REMEMBRALL_ROOT/hooks/time-turner-check.sh" "$(pwd)"
```

If the script exits 1 (no active Time-Turner), tell the user: "No active Time-Turner found."

### `/timeturner diff`

Show what the Time-Turner agent changed:

```bash
# Find completed Time-Turner
for d in /tmp/remembrall-timeturner/*/; do
  [ -f "$d/status" ] || continue
  STATUS=$(cat "$d/status")
  [ "$STATUS" = "completed" ] || continue
  WORKTREE="$d/worktree"
  cd "$WORKTREE" && git diff HEAD
  break
done
```

If no completed Time-Turner is found, run `/timeturner status` instead and tell the user to wait.

### `/timeturner merge`

1. Show the diff for user review (run the diff sub-command above)
2. Ask the user to confirm before merging: "Apply these changes to your working branch?"
3. Find the main repo CWD and session ID:
   ```bash
   for d in /tmp/remembrall-timeturner/*/; do
     [ -f "$d/status" ] || continue
     STATUS=$(cat "$d/status")
     [ "$STATUS" = "completed" ] || continue
     SESSION_ID=$(basename "$d")
     WORKTREE="$d/worktree"
     break
   done
   ```
4. In the main repo, attempt merge:
   ```bash
   git -C "$(pwd)" merge --no-commit "timeturner/${SESSION_ID}"
   ```
5. If clean merge (exit 0) → commit with `[Time-Turner]` prefix:
   ```bash
   git -C "$(pwd)" commit -m "[Time-Turner] Apply parallel agent changes from session ${SESSION_ID}"
   ```
6. If conflicts (exit non-zero) → warn the user, abort merge, suggest manual resolution:
   ```bash
   git -C "$(pwd)" merge --abort 2>/dev/null || true
   ```
   Tell the user which files have conflicts and how to resolve manually.
7. Clean up regardless of outcome on success:
   ```bash
   git -C "$(pwd)" worktree remove "$WORKTREE" 2>/dev/null || true
   git -C "$(pwd)" branch -d "timeturner/${SESSION_ID}" 2>/dev/null || true
   rm -rf "/tmp/remembrall-timeturner/${SESSION_ID}"
   ```

### `/timeturner cancel`

1. Find the active Time-Turner:
   ```bash
   for d in /tmp/remembrall-timeturner/*/; do
     [ -f "$d/status" ] || continue
     SESSION_ID=$(basename "$d")
     PID=$(cat "$d/pid" 2>/dev/null) || PID=""
     WORKTREE="$d/worktree"
     break
   done
   ```
2. Kill the running process if PID is still alive:
   ```bash
   if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
     kill "$PID" 2>/dev/null || true
   fi
   ```
3. Remove git worktree:
   ```bash
   git -C "$(pwd)" worktree remove --force "$WORKTREE" 2>/dev/null || true
   ```
4. Delete branch:
   ```bash
   git -C "$(pwd)" branch -D "timeturner/${SESSION_ID}" 2>/dev/null || true
   ```
5. Remove state directory:
   ```bash
   rm -rf "/tmp/remembrall-timeturner/${SESSION_ID}"
   ```
6. Confirm to the user: "Time-Turner cancelled and cleaned up."

## Rules

- NEVER auto-merge — always show diff and ask user first
- After merge, confirm success and show what was applied
- On conflict, explain which files conflict and suggest resolution
