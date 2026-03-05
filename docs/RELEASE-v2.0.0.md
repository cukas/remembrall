# Remembrall v2.0.0

Context handoff plugin for Claude Code — saves your work when context runs out.

## Install

```bash
claude plugin install remembrall@cukas
```

## What's New

### Zero-Setup Experience
Remembrall works out of the box. The self-calibrating transcript estimator learns your context window size after 1–2 compaction events, improving accuracy automatically. The optional status-line bridge is still supported for maximum precision but is no longer required.

### Session Journals
At 60% context remaining, Remembrall nudges Claude to maintain a running journal checkpoint. This keeps the handoff document incrementally current, so nothing is lost if compaction happens suddenly.

### Git Patch Snapshots
Before handoff, Remembrall captures uncommitted changes for session-touched files only. Patches are stored in `~/.remembrall/patches/` — your repo stays clean (no WIP commits, no stashes).

### Team Handoffs
Share handoffs with your team via a project-local `.remembrall/handoffs/` directory. Another team member's Claude session can pick up where yours left off.

### Smart Replay
`/replay` verifies git state, checks that expected files still exist, warns if HEAD has moved, and offers to restore git patches from the previous session. Remaining tasks are priority-ordered: blockers first, then in-progress, then not-started.

### Handoff Chains
Each handoff links to its predecessor via `previous_session`. Across multiple sessions, you get a linked history: session 1 → session 2 → session 3.

### Session Goal Extraction
Auto-generated handoffs now capture the user's first message as the session goal, so the next instance knows *what you were trying to do*, not just which files were touched.

### JSON Frontmatter
Handoff metadata switched from YAML to JSON (between `---` markers). Parsed with `jq` — no more fragile sed/grep. Legacy YAML handoffs are still supported for backward compatibility.

### Global Config
One-time setup at `~/.remembrall/config.json` persists settings across all sessions. Configure git integration and team handoffs once.

## Five Layers of Protection

1. **Journal Checkpoint** (60%) — nudges Claude to update a running handoff
2. **Warning** (30%) — "context getting low, run /handoff"
3. **Urgent** (20%) — "context critically low, run /handoff now"
4. **Safety Net** (PreCompact) — auto-extracts session state from transcript if warning was missed
5. **Auto-Resume** (SessionStart) — injects handoff into context after compaction or /clear

## Requirements

- Claude Code with plugin support
- `jq` (hooks exit gracefully without it)
- `md5` (macOS) or `md5sum` (Linux/WSL)

## Full Changelog

https://github.com/cukas/remembrall/commits/v2.0.0
