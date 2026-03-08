# Remembrall

[![CI](https://github.com/cukas/remembrall/actions/workflows/ci.yml/badge.svg)](https://github.com/cukas/remembrall/actions)

*"It glows when you've forgotten something" — like your entire context window.*

<p align="center">
  <img src="docs/remembrall-hero.png" alt="Remembrall — context: 15%" width="400" />
</p>

**Context runs out → work gets lost.** Remembrall fixes that.

```bash
claude plugin marketplace add cukas/remembrall
claude plugin install remembrall@cukas
```

That's it. No setup needed. Remembrall monitors your context, warns you when it's running low, and seamlessly refreshes it using Claude Code's native plan mode.

```
🔮 [████░░░░░░] 30% ⚡  →  /handoff  →  plan mode  →  "Yes, clear context"  →  back to work
```

The gauge auto-configures on first session. Run `/setup-remembrall` to customize it:

```
🔮 [████████░░] 80%              green, calm
🔮 [█████░░░░░] 50% ✦            orange, sparkle
🔮 [███░░░░░░░] 28% ⚡            lightning, danger
💀 [██░░░░░░░░] 15% Obliviate!   memory wipe incoming — pulsing 🔮↔💀
```

<p align="center">
  <img src="docs/remembrall-demo.gif" alt="Remembrall in action — context drains, handoff fires, fresh start" width="780" />
</p>

---

## How It Works

> **Zero-setup by default.** Remembrall auto-configures the status-line bridge on first session start and derives per-user context limits from bridge data. No compaction events needed — the estimator calibrates once the session has used 20% of context.

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Claude Code Session                          │
│                                                                      │
│  Status Line ──writes──> /tmp/claude-context-pct/{session_id}        │
│       │                          │                                   │
│       │                   context-monitor.sh                         │
│       │                   (UserPromptSubmit)                         │
│       │                          │                                   │
│       │              bridge found? ──┐── no?                         │
│       │                  │           │    │                          │
│       │              use bridge   estimate from                      │
│       │                  │        transcript size                    │
│       │                  ▼           ▼                               │
│       │            >journal%? ── do nothing (silent)                  │
│       │                  │                                           │
│       │           <=journal%? ── early handoff nudge (default 60%)    │
│       │                  │                                           │
│       │           <=warning%? ── autonomous mode?   (default 30%)    │
│       │                  │         │                                 │
│       │                  │    ┌────┴────┐                            │
│       │                  │    no        yes                          │
│       │                  │    │         │                            │
│       │                  │    │    /handoff + continue               │
│       │                  │    │    (auto-compaction recycles)        │
│       │                  │    │                                      │
│       │                  │    Claude runs /handoff                    │
│       │                  │    (captures task, files, decisions,       │
│       │                  │     "Resume With" methodology,            │
│       │                  │     active tools/agents/skills)           │
│       │                  │    then calls EnterPlanMode               │
│       │                  │         │                                 │
│       │            <=urgent%? ── same, but IMMEDIATELY (default 20%) │
│       │                  │                                           │
│       │                  ▼                                           │
│       │            Plan mode UI appears:                             │
│       │            "Yes, clear context"                              │
│       │            User clicks → fresh context                       │
│       │            with plan preserved                               │
│       │                          │                                   │
│  ─── task complete ──────────────┤                                   │
│       │                          │                                   │
│  stop-check.sh (Stop hook)       │                                   │
│  (suggests /clear if <40%)       │                                   │
│       │                          │                                   │
│  ─── compaction ─────────────────┤                                   │
│       │                          │                                   │
│  precompact-handoff.sh           │                                   │
│  (safety net — auto-generates    │                                   │
│   handoff from transcript        │                                   │
│   + git patch snapshot)          │                                   │
│       │                          │                                   │
│       ▼                          │                                   │
│  ~/.remembrall/handoffs/{hash}/handoff-{session}.md                  │
│  ~/.remembrall/patches/{hash}/patch-{session}.diff                   │
│       │                          │                                   │
│  session-resume.sh               │                                   │
│  (SessionStart — injects         │                                   │
│   handoff as additionalContext)   │                                   │
│       │                          │                                   │
│       ▼                          │                                   │
│  Claude resumes with full context                                    │
└──────────────────────────────────────────────────────────────────────┘
```

## Five Layers of Protection

1. **Plan Mode Trigger** (`context-monitor.sh`) — Reads context % from a bridge file, or estimates it from transcript size as a fallback. At the warning threshold (default: 30%) remaining, tells Claude to run `/handoff` and then call `EnterPlanMode`. The `/handoff` skill captures task state, files, decisions, **and a prescriptive "Resume With" section** (which skill/methodology to invoke, active agents, MCP servers). The user sees the native "Yes, clear context" option — one click for a fresh start. At the urgent threshold (default: 20%), the same but with urgent priority. All thresholds are configurable via `threshold_journal`, `threshold_warning`, and `threshold_urgent` in config.

2. **Journal Checkpoint** (`context-monitor.sh` at configurable threshold, default 60%) — Before things get urgent, Remembrall nudges Claude to run `/handoff` to save progress. This early nudge ensures a handoff document exists before context gets critical, so if compaction strikes between the journal and warning thresholds, the handoff already reflects recent work.

3. **Safety Net** (`precompact-handoff.sh`) — If the early warning is missed and Claude auto-compacts, this hook extracts files touched, errors encountered, git operations, task state, and recent conversation from the transcript into a handoff document. Also captures git patches of session-touched files when git integration is enabled. Will not overwrite a higher-quality skill-generated handoff.

4. **Auto-Resume** (`session-resume.sh`) — On session start after compaction or `/clear`, injects the handoff content directly into Claude's context so it picks up where it left off.

5. **Stop Check** (`stop-check.sh`) — When Claude finishes a task, checks if context is below 40%. If a handoff already exists, suggests `/clear` + `/replay` before starting new work. If no handoff exists, tells Claude to run `/handoff` first.

---

<details>
<summary><strong>Full documentation</strong></summary>

## Installation

### Install

```bash
claude plugin marketplace add cukas/remembrall
claude plugin install remembrall@cukas
```

Run `/remembrall-status` to verify.

### Status-line bridge (auto-configured)

The bridge is auto-configured on first session — no manual setup needed. If you already have a custom `statusLine` in `~/.claude/settings.json`, Remembrall injects the bridge snippet into it. If you have no status line, Remembrall creates one that shows context % with the Remembrall gauge.

Run `/setup-remembrall` to customize the gauge appearance or reconfigure if needed.

## Configuration

Remembrall uses `~/.remembrall/config.json` for persistent settings. Run `/setup-remembrall` to configure, or edit directly:

```json
{
  "git_integration": false,
  "team_handoffs": false,
  "autonomous_mode": false,
  "retention_hours": 72,
  "easter_eggs": true,
  "threshold_journal": 60,
  "threshold_warning": 30,
  "threshold_urgent": 20,
  "debug": false
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `git_integration` | `false` | Save git patches of session-touched files before handoff |
| `team_handoffs` | `false` | Copy handoffs to project-local `.remembrall/handoffs/` |
| `autonomous_mode` | `false` | Skip plan mode (no human click needed) — use `/handoff` + auto-compaction instead. Enable for overnight/unattended runs. |
| `retention_hours` | `72` | Hours to keep handoff files before auto-cleanup |
| `max_transcript_kb` | *(auto)* | Override max transcript size in KB. Rarely needed — bridge-derived calibration handles this automatically. |
| `easter_eggs` | `true` | Show Harry Potter spell mappings in context nudges |
| `disabled_hooks` | `[]` | Array of hook names to disable (e.g., `["stop-check"]`) |
| `threshold_journal` | `60` | Context % that triggers the first "run /handoff" nudge |
| `threshold_warning` | `30` | Context % that triggers the "run /handoff + plan mode" nudge |
| `threshold_urgent` | `20` | Context % that triggers the "IMMEDIATELY" nudge |
| `recency_window` | `60` | Seconds to look back when matching handoffs to sessions |
| `debug` | `false` | Enable debug logging to `~/.remembrall/debug.log` |

Settings apply globally — once configured, all Claude sessions respect them. Values are stored as native JSON types (booleans, numbers).

## Self-Calibrating Context Estimation

Remembrall uses a two-branch estimation strategy:

**When the bridge is active** (most accurate):

The status-line bridge writes Claude's actual context remaining % to `/tmp/claude-context-pct/{session_id}`. Auto-configured on first session. As a side effect, Remembrall derives `content_max` (how many content bytes fit before context runs out) from the equation: `content_max = content_bytes / (used_pct / 100)`. This auto-calibrates per user, per model — accounting for your specific overhead (plugins, skills, system prompt size). Calibration samples are stored once context usage reaches 20%.

**When the bridge is unavailable** (fallback):

1. **Structural JSONL parser** — Parses transcript content bytes and compares against the bridge-derived `content_max` (if calibrated) or model-specific defaults. Accurate when calibration data exists from prior bridge sessions.

2. **File-size fallback** — Last resort when structural parsing fails. Uses raw transcript size against calibrated or model-specific maximums.

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
| `/setup-remembrall` | Manual fallback for bridge setup and config customization |
| `/remembrall-status` | Diagnostic: check context %, bridge, handoffs |
| `/remembrall-help` | List all commands, skills, and config options |
| `/autonomous` | Toggle autonomous mode on/off for overnight runs |
| `/remembrall-uninstall` | Clean removal: removes bridge, data, and temp files (supports `--dry-run`) |

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
  calibration.json                                     # auto-calibration data
  handoffs/{md5_of_cwd}/handoff-{session_id}.md        # personal handoffs
  patches/{md5_of_cwd}/patch-{session_id}.diff         # git patch snapshots

.remembrall/
  handoffs/handoff-{session_id}.md                     # team handoffs (project-local)
```

- Each session gets its own file — multiple Claude instances can coexist
- Handoffs older than the configured retention period (default: 72 hours) are auto-cleaned
- Consumed handoffs are renamed to `.consumed.md` and auto-cleaned after 1 hour
- Handoffs include `format_version: 2` in frontmatter for forward compatibility

## Debug Logging

Enable debug logging to troubleshoot hook behavior:

```bash
# Via config (persistent)
remembrall_config_set "debug" "true"

# Via environment (one-off)
REMEMBRALL_DEBUG=1 claude
```

Logs are written to `~/.remembrall/debug.log` with ISO timestamps and hook names. The log is auto-rotated at 1MB. Each hook identifies itself in log entries (e.g., `[context-monitor]`, `[session-resume]`).

## Example Use Cases

### Long refactors that outlast a single context

You're renaming a module across 40 files. Halfway through, context hits 30%. Remembrall tells Claude to run `/handoff` and enter plan mode. You see "Yes, clear context" — one click, and Claude continues at file 21 with a fresh context and the handoff preserved. No manual steps.

### Multi-day feature builds

You're building an auth system over several sessions. Each time you stop for the day, `/handoff` saves your progress: completed routes, pending middleware, the JWT-vs-session decision and why. Next morning, `/replay` — Claude knows exactly where you left off.

### Pair-programming handoffs between terminals

You have two Claude instances open — one for frontend, one for backend. The backend session runs low on context. It writes a handoff. With team handoffs enabled, the handoff is also saved in the project directory. You open a fresh terminal, `/replay`, and the new session continues the API work while the frontend session keeps running undisturbed (separate handoff files, no conflicts). Another team member can even pick up the handoff from the shared project directory.

### Unexpected compaction recovery

You're deep in a debugging session and didn't notice context getting low. Claude auto-compacts. Without remembrall, you'd lose all the debugging context — which files you checked, what theories you ruled out, what the error trace showed. With remembrall, the safety net hook fires just before compaction, extracts the key info from the transcript, and injects it into the compacted session automatically.

### Code reviews and large PRs

You're reviewing a 500-line PR file by file. Context fills up with diff content. At 30%, Remembrall triggers — Claude runs `/handoff` to capture reviewed files, issues found, and what's left, then enters plan mode. Pick "clear context" and continue reviewing from where you left off.

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

## Troubleshooting

**`jq` not installed** — Hooks exit silently without `jq`. Run `jq --version` to check. Install via `brew install jq` (macOS) or `sudo apt-get install jq` (Linux).

**`md5`/`md5sum` not found** — Handoff directory computation fails silently. Install `coreutils` (`brew install coreutils` on macOS, pre-installed on Linux).

**Bridge not injecting** — Check if the bridge snippet is present: `grep -q "claude-context-pct" ~/.claude/settings.json && echo OK || echo MISSING`. If missing, restart your session or run `/setup-remembrall`.

**Handoff not consumed on resume** — Run `/remembrall-status` and look for `.claimed-*` or `.consumed` files. Claimed files older than 5 minutes are cleaned up automatically.

**Stale calibration after model switch** — Delete `~/.remembrall/calibration.json` and let Remembrall recalibrate from the new model's bridge data.

**Hooks don't seem to be running** — Ensure scripts are executable: `chmod +x hooks/*.sh scripts/*.sh`. Verify `jq --version` returns a version. Check that the plugin is installed: `claude plugin list`. Enable debug logging (`remembrall_config_set "debug" "true"`) and check `~/.remembrall/debug.log` for hook activity.

**Bridge file is empty/missing** — The bridge file is written on each Claude response cycle. After `/clear` or compaction, it's intentionally deleted and recreated on the next response. If persistently missing, restart your session.

**Another plugin owns the status line** — If Remembrall detects an existing `statusLine.command` that doesn't reference context variables, it appends the bridge cautiously and logs a warning. Check the debug log for details.

## FAQ

**Does Remembrall bloat my context?** No. It injects one handoff document on session resume (then deletes it). During a session, nudges are short one-line messages injected via `additionalContext` — each fires at most once per threshold (configurable, defaults: 60%, 30%, 20%), so the total overhead is minimal. There is no accumulated memory that grows over time.

**Hooks don't seem to be running** — Check `jq --version` and `chmod +x hooks/*.sh`. See Troubleshooting section above.

**Bridge file is empty/missing** — Restart the session. The bridge is written on each response cycle. Check `grep -q "claude-context-pct" ~/.claude/settings.json`.

**Handoff not loading after /clear** — Run `/remembrall-status` to check handoff state. Verify the session ID matches between the handoff file and current session.

**Calibration seems wrong** — Delete `~/.remembrall/calibration.json` and let it recalibrate from fresh bridge data.

**Are there any easter eggs?** Maybe. Try speaking to Claude in the language of wizards when the Remembrall starts glowing. 🔮

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
