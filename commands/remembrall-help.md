---
name: remembrall-help
description: List all Remembrall commands, skills, and config options
---

# Remembrall Help

Show the user this reference:

## Commands

| Command | Description |
|---------|-------------|
| `/remembrall-status` | Diagnostic — check context %, bridge, handoffs, Pensieve, Time-Turner |
| `/remembrall-help` | This help — list all commands, skills, and config |
| `/setup-remembrall` | One-time setup — status-line bridge and config |
| `/autonomous` | Toggle autonomous mode on/off |
| `/phoenix` | Toggle Phoenix mode on/off — recurring context recycling |
| `/map` | The Marauder's Map — visual session overview |
| `/lineage` | Session ancestry DAG — see how sessions branch and chain |
| `/insights` | Ambient learning — file hotspots, patterns, recurring errors |
| `/obliviate` | Memory pruning — analyze and archive stale memories |
| `/budget` | Context budget — code vs conversation vs memory breakdown |

## Skills

| Skill | Description |
|-------|-------------|
| `/handoff` | Save structured handoff with state, files, git patches |
| `/replay` | Resume from handoff — verify git state, restore patches |
| `/pensieve` | Browse and search Pensieve session memories |
| `/timeturner` | Manage Time-Turner parallel agents — status, diff, merge, cancel |
| `/obliviate` | Guided memory pruning with user confirmation |

## Config (`~/.remembrall/config.json`)

| Setting | Default | Description |
|---------|---------|-------------|
| `git_integration` | `false` | Save git patches before handoff |
| `team_handoffs` | `false` | Copy handoffs to project `.remembrall/` |
| `autonomous_mode` | `true` | Skip plan mode for overnight/unattended runs |
| `retention_hours` | `72` | Hours to keep handoffs before cleanup |
| `max_transcript_kb` | *(auto)* | Override max transcript size (rarely needed — bridge calibration handles this) |
| `pensieve` | `true` | Track session intelligence (files, commands, errors) |
| `pensieve_max_sessions` | `3` | Past sessions to inject on resume |
| `pensieve_inject_budget` | `2000` | Max chars for Pensieve context injection |
| `time_turner` | `false` | Spawn parallel agent at low context (opt-in) |
| `time_turner_model` | `sonnet` | Model for Time-Turner agent |
| `time_turner_max_budget_usd` | `1.00` | Budget cap for Time-Turner agent |
| `threshold_timeturner` | `30` | Context % to trigger Time-Turner |
| `lineage` | `true` | Record session ancestry (parent/child chains) |
| `lineage_max_entries` | `50` | Max sessions to keep in lineage index |
| `insights` | `true` | Aggregate Pensieve data into project insights |
| `insights_inject` | `false` | Inject insights into session context |
| `insights_min_sessions` | `3` | Min sessions before generating insights |
| `obliviate` | `true` | Analyze memories for staleness |
| `obliviate_stale_sessions` | `5` | Sessions without update before memory is stale |
| `budget_enabled` | `false` | Track context budget allocation (opt-in) |
| `budget_code` | `50` | Target % for code (tool use) content |
| `budget_conversation` | `30` | Target % for conversation content |
| `budget_memory` | `20` | Target % for memory/system content |
| `patrol_integration` | `true` | Listen for Patrol signal files |
| `patrol_signal_ttl` | `300` | Signal expiry in seconds |
| `phoenix_mode` | `false` | Recurring context recycling at urgent threshold |
| `phoenix_max_cycles` | `10` | Max Phoenix cycles per chain (safety cap) |

## How Context Management Works

```
100% ████████████████████  — working normally (Pensieve tracks everything)
 60% ████████████░░░░░░░░  — nudge: suggests /handoff (Obliviate + Budget warnings)
 35% ███████░░░░░░░░░░░░░  — warning: /handoff then EnterPlanMode
 30% ██████░░░░░░░░░░░░░░  — Time-Turner spawns parallel agent (if enabled)
 25% ─────░░░░░░░░░░░░░░░░░  — Phoenix: auto-capture + recycle (if enabled, repeating)
 15% ███░░░░░░░░░░░░░░░░░  — urgent: two-stage escalation
  0% ░░░░░░░░░░░░░░░░░░░░  — auto-compaction safety net fires
```

**Pensieve** (on by default): Tracks files, commands, errors throughout the session. Distills into structured summaries on compaction. Injects session memory on resume — Claude never forgets.

**Time-Turner** (opt-in: `time_turner: true`): At 30%, spawns a `claude -p` agent in a git worktree with remaining tasks. Review with `/timeturner diff`, apply with `/timeturner merge`. Budget-capped, never auto-merges.

**Map** (`/map`): Visual overview of context level, files explored, commands run, errors, and burn rate.

**Lineage** (`/lineage`): Session ancestry graph showing parent-child chains, Time-Turner branches, and session status. Recorded automatically.

**Insights** (`/insights`): Aggregates Pensieve data across sessions. Shows file hotspots, workflow patterns, recurring errors. Runs in background on session start.

**Obliviate** (`/obliviate`): Analyzes memory files for staleness. Cross-references with Pensieve data. Archives stale memories to `.archive/` with user confirmation.

**Budget** (`/budget`, opt-in): Categorizes transcript into code/conversation/memory. Warns when any category exceeds its configured allocation.

**Patrol Integration** (auto if Patrol installed): Listens for signal files from Patrol. Supports handoff triggers and context alerts. Owl Post theme.

**Phoenix Rebirth** (opt-in: `phoenix_mode: true`): At the urgent threshold, automatically captures state and triggers context recycling. The cycle rearms after compaction — zero clicks, indefinite continuation. Safety-capped at `phoenix_max_cycles` (default 10). Falls through to normal AK when cap is reached.
