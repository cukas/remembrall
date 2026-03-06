# Remembrall

*"It glows when you've forgotten something" — like your entire context window."*

**Context runs out → work gets lost.** Remembrall fixes that.

```bash
claude plugin marketplace add cukas/remembrall
claude plugin install remembrall@cukas
```

That's it. No setup needed. Remembrall monitors your context, warns you when it's running low, and auto-saves structured handoffs so your next session picks up exactly where you left off.

```
🟠 [████░░░░░░] 40%  →  /handoff  →  /clear  →  /replay  →  back to work
```

---

<details>
<summary><strong>Full documentation</strong></summary>

Remembrall monitors your context window in real-time, keeps a running session journal, warns you at critical thresholds, creates structured handoff documents with git patches, and offers smart replay with state verification. Team handoffs let another developer's Claude session pick up where yours left off.

## What's New in v2

- **Zero-Setup Experience** — Remembrall works out of the box with no manual configuration. The self-calibrating transcript estimator learns your context window size after 1-2 compaction events, improving accuracy automatically. The optional status-line bridge is still supported for maximum precision but is no longer required.

- **No External Dependencies** — Removed the `bc` requirement. All comparisons use integer arithmetic. Only `jq` is required (and hooks exit gracefully without it).

- **Single-Script Handoff** — The `/handoff` skill now pipes content to a single `handoff-create.sh` script that handles path computation, git patches, YAML frontmatter, and team copies. More reliable than multi-step orchestration.

- **Session Journal** — At 60% context remaining, Remembrall starts nudging Claude to maintain a running journal checkpoint. This keeps the handoff document up-to-date incrementally, so nothing is lost if compaction happens suddenly.

- **Git Patch Snapshots** — Before handoff, Remembrall captures uncommitted changes for session-touched files only. Patches are stored in `~/.remembrall/patches/` — your repo stays clean (no WIP commits, no stashes).

- **Team Handoffs** — Share handoffs with your team via a project-local `.remembrall/handoffs/` directory. Another team member's Claude session can pick up where yours left off.

- **Smart Replay** — `/replay` replaces `/resume`. It verifies git state, checks that expected files still exist, warns if HEAD has moved, and offers to restore git patches from the previous session. Remaining tasks are priority-ordered: blockers first, then in-progress, then not-started.

- **Handoff Chains** — Each handoff links to its predecessor via `previous_session`. Across multiple sessions, you get a linked history: session 1 → session 2 → session 3. The replay briefing shows where you are in the chain.

- **Global Config** — One-time setup at `~/.remembrall/config.json` persists settings across all sessions. Configure git integration and team handoffs once, and every Claude session respects them.

- **Visual Context Gauge** — Color-coded progress bar in all nudge messages so you can see context health at a glance:
  ```
  🟢 [████████░░] 80%   — plenty of room
  🟠 [████░░░░░░] 40%   — journal checkpoint / warning
  🔴 [██░░░░░░░░] 15%   — urgent, run /handoff now
  ```

## How It Works

> **Zero-setup by default.** Remembrall works out of the box using self-calibrating transcript estimation. After 1-2 sessions, the estimator learns your typical context window size and triggers accurately. For maximum precision, you can optionally run `/setup-remembrall` to set up the status-line bridge — but it's not required.

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
│       │               >60%? ── do nothing (silent)               │
│       │                  │                                       │
│       │              <=60%? ── "journal" checkpoint nudge         │
│       │                  │                                       │
│       │              <=30%? ── "warning" nudge                   │
│       │                  │                                       │
│       │              <=20%? ── "urgent" nudge + STOP             │
│       │                  │                                       │
│       │                  ▼                                       │
│       │            Auto /handoff                                 │
│       │            + git patch capture (if enabled)              │
│       │            + team copy (if enabled)                      │
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
│   tasks, files, conversation     │                               │
│   + git patch snapshot)          │                               │
│       │                          │                               │
│       ▼                          │                               │
│  ~/.remembrall/handoffs/{hash}/handoff-{session}.md              │
│  ~/.remembrall/patches/{hash}/patch-{session}.diff               │
│  .remembrall/handoffs/ (team copy, if enabled)                   │
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

## Five Layers of Protection

1. **Early Warning** (`context-monitor.sh`) — Reads context % from a bridge file, or estimates it from transcript size as a fallback. Nudges Claude at 30% remaining ("context getting low, run /handoff") and 20% remaining ("context critically low, run /handoff").

2. **Journal Checkpoint** (`context-monitor.sh` at 60%) — Before things get urgent, Remembrall nudges Claude to update a running journal of progress. This keeps the handoff document incrementally current, so if compaction strikes between 60% and 30%, the handoff already reflects recent work.

3. **Safety Net** (`precompact-handoff.sh`) — If the early warning is missed and Claude auto-compacts, this hook extracts files touched, errors encountered, git operations, task state, and recent conversation from the transcript into a handoff document. Also captures git patches of session-touched files when git integration is enabled. Will not overwrite a higher-quality skill-generated handoff.

4. **Auto-Resume** (`session-resume.sh`) — On session start after compaction or `/clear`, injects the handoff content directly into Claude's context so it picks up where it left off.

5. **Stop Check** (`stop-check.sh`) — When Claude finishes a task, checks if context is below 40% and suggests `/clear` + `/replay` before starting new work.

## Installation

### Install

```bash
claude plugin marketplace add cukas/remembrall
claude plugin install remembrall@cukas
```

Run `/remembrall-status` to verify.

### Optional: Set up the status-line bridge (for maximum precision)

The self-calibrating estimator is accurate after 1-2 sessions. For immediate precision on the first session, you can optionally run `/setup-remembrall` to install a status-line bridge that writes exact context % to a temp file.

The bridge snippet requires `session_id` to be extracted in your status line (add `session_id=$(echo "$input" | jq -r '.session_id // empty');` alongside your other extractions). Then add this inside your existing `if [ -n "$remaining" ]; then ... fi` block:

```bash
CTX_DIR="/tmp/claude-context-pct"; mkdir -p "$CTX_DIR" 2>/dev/null;
if command -v md5 >/dev/null 2>&1; then
  printf "%s" "$remaining" > "$CTX_DIR/$(md5 -qs "$cwd")-${session_id}" 2>/dev/null;
elif command -v md5sum >/dev/null 2>&1; then
  printf "%s" "$remaining" > "$CTX_DIR/$(printf '%s' "$cwd" | md5sum | cut -d' ' -f1)-${session_id}" 2>/dev/null;
fi;
```

## Configuration

Remembrall uses `~/.remembrall/config.json` for persistent settings. Run `/setup-remembrall` to configure, or edit directly:

```json
{
  "git_integration": true,
  "team_handoffs": false,
  "retention_hours": 72,
  "max_transcript_kb": 256
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `git_integration` | `false` | Save git patches of session-touched files before handoff |
| `team_handoffs` | `false` | Copy handoffs to project-local `.remembrall/handoffs/` |
| `retention_hours` | `72` | Hours to keep handoff files before auto-cleanup |
| `max_transcript_kb` | `256` | Expected max transcript size in KB (for fallback context estimation) |

Settings apply globally — once configured, all Claude sessions respect them. Values are stored as native JSON types (booleans, numbers).

## Self-Calibrating Context Estimation

Remembrall estimates how much context remains by measuring the transcript file size against a known maximum. On the first session, it uses a conservative default (256KB). After each compaction event, it records the actual transcript size where context ran out. After 1-2 compactions, the estimator uses the average of observed values — becoming accurate for your specific usage patterns.

Calibration data is stored at `~/.remembrall/calibration.json` and persists across sessions. If you want to reset calibration (e.g., after changing models), delete this file.

## Git Integration

When enabled, Remembrall captures git patches of your session's uncommitted changes before handoff. Only files touched by Claude during the session are included — your other work is untouched.

- Patches stored at: `~/.remembrall/patches/{project_hash}/patch-{session}.diff`
- Your repo stays clean — no WIP commits, no stashes
- On `/replay`, patches are verified and offered for restore
- If HEAD moved since handoff, you're warned before applying

## Team Handoffs

When enabled, handoffs are also saved in your project directory at `.remembrall/handoffs/`. Another team member's Claude session can pick up where yours left off.

- Personal handoffs are checked first, then team directory
- Consider adding `.remembrall/` to `.gitignore` unless you want handoffs committed
- Each team member's handoff files coexist (per-session naming)

## Requirements

- Claude Code with plugin support
- `jq` — required; hooks exit gracefully if missing but will not function
- `md5` (macOS) or `md5sum` (Linux/WSL) — required for project hashing
- `git` — optional; only needed when `git_integration` is enabled

### Platform Support

| Platform | Status |
|----------|--------|
| macOS | Fully supported (`md5`, `stat -f`) |
| Linux | Fully supported (`md5sum`, `stat -c`) |
| WSL (Windows Subsystem for Linux) | Fully supported (uses Linux userspace) |
| Windows (native) | Not supported — use WSL |

After cloning, ensure hook scripts are executable:

```bash
chmod +x hooks/*.sh scripts/*.sh
```

## Commands

| Command | Description |
|---------|-------------|
| `/setup-remembrall` | One-time bridge and config setup helper |
| `/remembrall-status` | Diagnostic: check context %, bridge, handoffs |

## Skills

| Skill | Description |
|-------|-------------|
| `/handoff` | Create a structured handoff document with YAML frontmatter, session state, and git patches (when enabled) |
| `/replay` | Smart replay — verifies git state, checks expected files, and offers git patch restore from previous session |

## Storage

Handoff files and patches are stored per-project:

```
~/.remembrall/
  config.json                                          # global settings
  handoffs/{md5_of_cwd}/handoff-{session_id}.md        # personal handoffs
  patches/{md5_of_cwd}/patch-{session_id}.diff         # git patch snapshots

.remembrall/
  handoffs/handoff-{session_id}.md                     # team handoffs (project-local)
```

- Each session gets its own file — multiple Claude instances can coexist
- Handoffs older than the configured retention period (default: 72 hours) are auto-cleaned
- Consumed handoffs are deleted immediately (single-use baton)

## Example Use Cases

### Long refactors that outlast a single context

You're renaming a module across 40 files. Halfway through, context hits 30%. Remembrall nudges Claude to `/handoff` — it captures which files are done, which remain, and the naming convention you agreed on. After `/clear`, the next session picks up at file 21, not file 1.

### Multi-day feature builds

You're building an auth system over several sessions. Each time you stop for the day, `/handoff` saves your progress: completed routes, pending middleware, the JWT-vs-session decision and why. Next morning, `/replay` — Claude knows exactly where you left off.

### Pair-programming handoffs between terminals

You have two Claude instances open — one for frontend, one for backend. The backend session runs low on context. It writes a handoff. With team handoffs enabled, the handoff is also saved in the project directory. You open a fresh terminal, `/replay`, and the new session continues the API work while the frontend session keeps running undisturbed (separate handoff files, no conflicts). Another team member can even pick up the handoff from the shared project directory.

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
| Git patches | Manual stash/commit | `~/.remembrall/patches/{hash}/` (automatic) |
| Team sharing | Not supported | `.remembrall/handoffs/` in project dir |
| Config | Per-project | `~/.remembrall/config.json` (global) |
| Hash | macOS-only `md5` | Cross-platform (md5/md5sum) |
| Hook paths | Absolute paths in settings | `${CLAUDE_PLUGIN_ROOT}/hooks/` |
| CWD | Hardcoded fallback | Dynamic from hook input |
| Nudge dir | `/tmp/claude-context-nudges/` | `/tmp/remembrall-nudges/` |
| SessionStart | Bare `additionalContext` | `hookSpecificOutput` format |

## Privacy

Remembrall is fully local. It does not collect, transmit, or store any data outside your machine.

- Handoff files are stored in `~/.remembrall/handoffs/` on your local filesystem
- Git patches are stored locally in `~/.remembrall/patches/`
- Team handoffs are stored in your project directory at `.remembrall/handoffs/`
- Temporary bridge files live in `/tmp/` and are cleared on reboot
- No network requests, no analytics, no telemetry
- No external services or APIs are contacted
- All processing happens in local shell scripts

## License

MIT

</details>
