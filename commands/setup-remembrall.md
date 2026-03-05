---
name: setup-remembrall
description: One-time setup — adds the status-line bridge snippet that feeds context % to remembrall's hooks
---

# Setup Remembrall Bridge

Remembrall needs a small bridge in your Claude Code status line to feed context window % to its hooks. This command helps you add it.

## What the Bridge Does

Your status line already has access to `$remaining` (context window % remaining) and `$cwd` (current working directory). The bridge writes `$remaining` to a file in `/tmp/claude-context-pct/` named after the md5 hash of `$cwd`. Remembrall's hooks read this file to know when to trigger handoffs.

## Steps

1. **Check if the bridge already exists** — Run:
   ```bash
   grep -q "claude-context-pct" ~/.claude/settings.json && echo "Bridge already installed" || echo "Bridge not found"
   ```

2. **If already installed:** Tell the user "Remembrall bridge is already set up. You're good to go!" and stop.

3. **If not installed:** Read the user's current `~/.claude/settings.json` and find the `statusLine` section.

4. **Find the insertion point** — Look for the block that checks `if [ -n "$remaining" ]`. The bridge snippet goes inside this block, before the closing `fi`.

5. **Show the user the bridge snippet** they need to add inside their existing `if [ -n "$remaining" ]; then ... fi` block:

```bash
CTX_DIR="/tmp/claude-context-pct"; mkdir -p "$CTX_DIR" 2>/dev/null;
if command -v md5 >/dev/null 2>&1; then
  printf "%s" "$remaining" > "$CTX_DIR/$(md5 -qs "$cwd")" 2>/dev/null;
elif command -v md5sum >/dev/null 2>&1; then
  printf "%s" "$remaining" > "$CTX_DIR/$(printf '%s' "$cwd" | md5sum | cut -d' ' -f1)" 2>/dev/null;
fi;
```

6. **Edit the settings file** — Insert the bridge snippet into the status line command. The exact location depends on the user's existing status line format. Find the `if [ -n "$remaining" ]` block and add the bridge snippet inside it (after the existing context display logic, before the `fi`).

7. **Verify** — After editing, run:
   ```bash
   cat /tmp/claude-context-pct/* 2>/dev/null || echo "No bridge files yet — start a new Claude session to generate them"
   ```

## Important Notes

- The bridge is cross-platform: uses `md5` on macOS, `md5sum` on Linux
- The bridge writes to `/tmp/` so data is ephemeral (cleared on reboot)
- The plugin itself CANNOT modify settings.json — this command guides the user/Claude through the edit
- If the user doesn't have a status line configured at all, they need to set one up first. Point them to the Claude Code docs on status line configuration.
- The bridge snippet is idempotent — running it multiple times is harmless
