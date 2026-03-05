# Remembrall

A Claude Code plugin that automatically preserves your work when context runs low.

Remembrall monitors your context window in real-time, warns you at 30% remaining, creates structured handoff documents, and auto-resumes after compaction or `/clear`.

## How It Works

> **Note:** For best accuracy, run `/setup-remembrall` to set up the status-line bridge. Without it, the context monitor falls back to transcript-size estimation (less accurate but still functional). The safety net and auto-resume layers work without any setup.

```
┌─────────────────────────────────────────────────────────────────┐
│                        Claude Code Session                       │
│                                                                  │
│  Status Line ──writes──> /tmp/claude-context-pct/{hash}          │
│       │                          │                               │
│       │                   context-monitor.sh                     │
│       │                   (UserPromptSubmit)                     │
│       │                          │                               │
│       │              bridge found? ──┐── no?                     │
│       │                  │           │    │                      │
│       │              use bridge   estimate from                  │
│       │                  │        transcript size                │
│       │                  ▼           ▼                           │
│       │                 <=30%? ──┤── <=20%?                      │
│       │                  │       │      │                        │
│       │              "warning"   │   "urgent"                    │
│       │              nudge       │   nudge                       │
│       │                  │       │      │                        │
│       │                  ▼       │      ▼                        │
│       │            Auto /handoff │  STOP + /handoff              │
│       │                          │                               │
│  ─── task complete ──────────────┤                               │
│       │                          │                               │
│  stop-check.sh (Stop hook)       │                               │
│  (suggests /clear if <40%)       │                               │
│       │                          │                               │
│  ─── compaction ─────────────────┤                               │
│       │                          │                               │
│  precompact-handoff.sh           │                               │
│  (safety net — auto-generates    │                               │
│   handoff with errors, git ops,  │                               │
│   tasks, files, conversation)    │                               │
│       │                          │                               │
│       ▼                          │                               │
│  ~/.remembrall/handoffs/{hash}/handoff-{session}.md              │
│       │                          │                               │
│  ─── /clear or compact resume ───┤                               │
│       │                          │                               │
│  session-resume.sh               │                               │
│  (SessionStart — injects         │                               │
│   handoff as additionalContext)   │                               │
│       │                          │                               │
│       ▼                          │                               │
│  Claude resumes with full context                                │
└─────────────────────────────────────────────────────────────────┘
```

## Four Layers of Protection

1. **Early Warning** (`context-monitor.sh`) — Reads context % from a bridge file, or estimates it from transcript size as a fallback. Nudges Claude at 30% remaining ("run /handoff") and 20% remaining ("STOP everything, /handoff NOW").

2. **Safety net** (`precompact-handoff.sh`) — If the early warning is missed and Claude auto-compacts, this hook extracts files touched, errors encountered, git operations, task state, and recent conversation from the transcript into a handoff document. Will not overwrite a higher-quality skill-generated handoff.

3. **Auto-Resume** (`session-resume.sh`) — On session start after compaction or `/clear`, injects the handoff content directly into Claude's context so it picks up where it left off. On fresh session starts, checks if the bridge is configured and nudges setup if missing.

4. **Stop Check** (`stop-check.sh`) — When Claude finishes a task, checks if context is below 40% and suggests `/clear` + `/resume` before starting new work.

## Installation

### 1. Enable the plugin

Add to `~/.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "remembrall@cukas": true
  }
}
```

Or install from the plugin marketplace if available.

### 2. Set up the bridge (optional but recommended)

Run `/setup-remembrall` in Claude Code. This adds a small snippet to your status line that writes context % to a temp file that the hooks can read. Without the bridge, the context monitor falls back to transcript-size estimation (less accurate but still functional). On each fresh session start, Remembrall will remind you once if the bridge is not configured.

The bridge snippet (added inside your existing `if [ -n "$remaining" ]; then ... fi` block):

```bash
CTX_DIR="/tmp/claude-context-pct"; mkdir -p "$CTX_DIR" 2>/dev/null;
if command -v md5 >/dev/null 2>&1; then
  printf "%s" "$remaining" > "$CTX_DIR/$(md5 -qs "$cwd")" 2>/dev/null;
elif command -v md5sum >/dev/null 2>&1; then
  printf "%s" "$remaining" > "$CTX_DIR/$(printf '%s' "$cwd" | md5sum | cut -d' ' -f1)" 2>/dev/null;
fi;
```

### 3. Verify

Run `/remembrall-status` to check everything is working.

## Requirements

- Claude Code with plugin support
- `jq` — required; hooks exit gracefully if missing but will not function
- `bc` — required for the context monitor; without it, the early warning layer is disabled (safety net and auto-resume still work)
- `md5` (macOS) or `md5sum` (Linux) — required for project hashing

After cloning, ensure hook scripts are executable:

```bash
chmod +x hooks/*.sh scripts/*.sh
```

## Commands

| Command | Description |
|---------|-------------|
| `/setup-remembrall` | One-time bridge setup helper |
| `/remembrall-status` | Diagnostic: check context %, bridge, handoffs |

## Skills

| Skill | Description |
|-------|-------------|
| `/handoff` | Manually create a structured handoff document |
| `/resume` | Find and load a handoff document to resume work |

## Storage

Handoff files are stored per-project:

```
~/.remembrall/handoffs/{md5_of_cwd}/handoff-{session_id}.md
```

- Each session gets its own file — multiple Claude instances can coexist
- Handoffs older than 24 hours are auto-cleaned
- Consumed handoffs are deleted immediately (single-use baton)

## Example Use Cases

### Long refactors that outlast a single context

You're renaming a module across 40 files. Halfway through, context hits 30%. Remembrall nudges Claude to `/handoff` — it captures which files are done, which remain, and the naming convention you agreed on. After `/clear`, the next session picks up at file 21, not file 1.

### Multi-day feature builds

You're building an auth system over several sessions. Each time you stop for the day, `/handoff` saves your progress: completed routes, pending middleware, the JWT-vs-session decision and why. Next morning, `/resume` — Claude knows exactly where you left off.

### Pair-programming handoffs between terminals

You have two Claude instances open — one for frontend, one for backend. The backend session runs low on context. It writes a handoff. You open a fresh terminal, `/resume`, and the new session continues the API work while the frontend session keeps running undisturbed (separate handoff files, no conflicts).

### Unexpected compaction recovery

You're deep in a debugging session and didn't notice context getting low. Claude auto-compacts. Without remembrall, you'd lose all the debugging context — which files you checked, what theories you ruled out, what the error trace showed. With remembrall, the safety net hook fires just before compaction, extracts the key info from the transcript, and injects it into the compacted session automatically.

### Code reviews and large PRs

You're reviewing a 500-line PR file by file. Context fills up with diff content. At 30%, remembrall triggers — Claude saves which files are reviewed, the issues found so far, and which files still need review. Resume in a fresh session without re-reading files you already covered.

### Teaching and onboarding

You're walking Claude through a complex codebase architecture so it can help new team members. The explanation fills context. `/handoff` preserves the architectural understanding — component relationships, data flow patterns, naming conventions — so any future session can build on it instead of re-explaining from scratch.

## How It Differs from Project-Specific Setups

| Aspect | Project-specific | Remembrall (plugin) |
|--------|-----------------|---------------------|
| Storage | Project memory dir | `~/.remembrall/handoffs/{hash}/` |
| Hash | macOS-only `md5` | Cross-platform (md5/md5sum) |
| Hook paths | Absolute paths in settings | `${CLAUDE_PLUGIN_ROOT}/hooks/` |
| CWD | Hardcoded fallback | Dynamic from hook input |
| Nudge dir | `/tmp/claude-context-nudges/` | `/tmp/remembrall-nudges/` |
| SessionStart | Bare `additionalContext` | `hookSpecificOutput` format |

## Privacy

Remembrall is fully local. It does not collect, transmit, or store any data outside your machine.

- Handoff files are stored in `~/.remembrall/handoffs/` on your local filesystem
- Temporary bridge files live in `/tmp/` and are cleared on reboot
- No network requests, no analytics, no telemetry
- No external services or APIs are contacted
- All processing happens in local shell scripts

## License

MIT
