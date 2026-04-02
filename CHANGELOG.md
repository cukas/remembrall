# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [3.0.0] - 2026-03-13 — "The Session Never Dies"

### Added
- **Phoenix Rebirth** — Recurring context recycling. When context hits the urgent threshold with Phoenix enabled, state is captured and recycling triggers automatically. After compaction, the cycle rearms — zero clicks, indefinite continuation. Safety-capped at `phoenix_max_cycles` (default 10)
  - `phoenix_mode` config (default `false`) — opt-in toggle, also available via `/phoenix`
  - `phoenix_max_cycles` config (default `10`) — safety cap per chain
  - Phoenix chain tracking in `/tmp/remembrall-phoenix/` — chain ID, cycle count, lineage
  - Extended `avadakedavra-capture.sh` with `--trigger`, `--cycle`, `--chain-id` args
  - Chain ID restoration on session resume — cycles persist across compactions
  - `/phoenix` command — toggle on/off, view chain status
- **The Pensieve** — Compaction-proof session intelligence. Tracks every file read/edit, command, and error throughout a session into structured JSONL. On compaction or handoff, distills into a summary that gets injected into the next session. Claude retains structured knowledge of what it did, even across compactions and session resets. On by default (`pensieve: true`)
  - `hooks/pensieve-track.sh` — Background incremental transcript parser (runs on every prompt)
  - `hooks/pensieve-distill.sh` — Crunches raw JSONL into structured summary JSON
  - `hooks/pensieve-inject.sh` — Generates compact text for additionalContext (budget-capped)
  - Persisted to `~/.remembrall/pensieve/{project-hash}/`
  - Config: `pensieve`, `pensieve_max_sessions` (default 3), `pensieve_inject_budget` (default 2000)

- **Time-Turner** — Parallel agent at low context. At a configurable threshold (default 30%), spawns a headless `claude -p` agent in a git worktree with remaining tasks. The agent works independently while the main session compacts. On next resume, offers to merge changes. Opt-in only (`time_turner: false` by default)
  - `hooks/time-turner-spawn.sh` — Creates worktree, builds prompt, spawns `claude -p`
  - `hooks/time-turner-check.sh` — Checks status, formats report for injection
  - `/timeturner` skill — `status`, `diff`, `merge`, `cancel` sub-commands
  - Safety: opt-in, budget-capped (`--max-budget-usd`), worktree-isolated, never auto-merges
  - Auto-cleanup: stale worktrees >24h removed on SessionStart
  - Config: `time_turner`, `time_turner_model` (default sonnet), `time_turner_max_budget_usd` (default 1.00), `threshold_timeturner` (default 30)

- **The Marauder's Map** — `/map` command for visual session overview. Shows context gauge, files explored with R/E tags, commands with colored exit codes, error counts, burn rate, and Time-Turner status. Built from Pensieve data + bridge + growth tracking
  - `scripts/remembrall-map.sh` — Terminal visualization
  - `commands/map.md` — Command definition

- **`/pensieve` skill** — Browse and search Pensieve session memories. List sessions, view summaries, search across session history

- **Session Lineage (Marauder's Map — Session Ancestry)** — Full session DAG tracking. Every session (main, compacted, Time-Turner) is recorded in a lineage index with parent/child relationships. Renders as a text DAG showing session ancestry, branches, and merge status
  - `hooks/lineage-record.sh` — Records session in lineage index (called by precompact + handoff-create)
  - `scripts/remembrall-lineage.sh` — Renders text DAG with depth, branch counts, and HP theming
  - `commands/lineage.md` — `/lineage` command
  - Library: `remembrall_lineage_dir()`, `remembrall_lineage_record()`, `remembrall_lineage_depth()`, `remembrall_lineage_branches()`
  - Storage: `~/.remembrall/lineage/{project-hash}/index.json`
  - Config: `lineage` (default true), `lineage_max_entries` (default 50)
  - HP theme: branches = "Horcrux detected"

- **Ambient Learning / Statistics (The Pensieve Remembers)** — Aggregates Pensieve session data into actionable patterns. Tracks file hotspots, workflow patterns (test-before-commit), error recurrence, and session statistics. Background aggregation on SessionStart
  - `hooks/statistics-aggregate.sh` — Aggregates Pensieve sessions into patterns (background)
  - `scripts/remembrall-statistics.sh` — Renders formatted statistics with HP theming
  - `commands/statistics.md` — `/statistics` command
  - Library: `remembrall_statistics_dir()`, `remembrall_statistics_fresh()`
  - Storage: `~/.remembrall/statistics/{project-hash}/statistics.json`
  - Config: `statistics` (default true), `statistics_inject` (default false), `statistics_min_sessions` (default 3)

- **Semantic Context Pruning / Obliviate** — Memory staleness analyzer that cross-references memory files with Pensieve data. Identifies stale memories not accessed in recent sessions and offers guided pruning with user confirmation. Archives stale memories instead of deleting
  - `hooks/obliviate-analyze.sh` — Memory staleness analyzer (background, at journal threshold)
  - `scripts/obliviate-archive.sh` — Moves stale memories to `.archive/`
  - `commands/obliviate.md` — `/obliviate` command
  - `skills/obliviate/SKILL.md` — Guided pruning skill with user confirmation
  - Library: `remembrall_memory_dirs()`, `remembrall_obliviate_dir()`, `remembrall_analyze_memory_staleness()`
  - Tmp: `/tmp/remembrall-obliviate/{session_id}.json`
  - Config: `obliviate` (default true), `obliviate_stale_sessions` (default 5)
  - HP theme: "Obliviate! N stale memories banished to the archive."

- **Context Budget Allocation (The Sorting Hat)** — Transcript category breakdown that classifies context consumption into code, conversation, and memory. Compares actuals vs configured budgets and warns when categories are imbalanced. Opt-in
  - `hooks/budget-analyze.sh` — Transcript category breakdown (background)
  - `commands/budget.md` — `/budget` command
  - Library: `remembrall_budget_dir()`, `remembrall_extract_category_bytes()`, `remembrall_budget_check()`, `remembrall_budget_validate_total()`
  - Tmp: `/tmp/remembrall-budget/{session_id}.json`
  - Config: `budget_enabled` (default false), `budget_code` (default 50), `budget_conversation` (default 30), `budget_memory` (default 20)
  - HP theme: "The Sorting Hat detects an imbalance!"

- **Patrol Integration (Owl Post)** — File-based signal protocol for Patrol plugin interop. Patrol is fully optional — zero behavior change when not installed. Signal types: `handoff_trigger`, `context_alert`. Patrol writes signal files, Remembrall reads and consumes them
  - `docs/patrol-integration.md` — Signal protocol spec (the contract)
  - Library: `remembrall_signal_dir()`, `remembrall_check_patrol_signal()`, `remembrall_consume_signal()`, `remembrall_patrol_detected()`
  - Tmp: `/tmp/remembrall-signals/{session_id}/`
  - Config: `patrol_integration` (default true), `patrol_signal_ttl` (default 300)
  - HP theme: "Owl Post" / "Ministry of Magic: Patrol (connected)"

- Config validation for all new settings (12 new config keys total)
- `remembrall_pensieve_dir()` and `remembrall_pensieve_tmp()` library functions
- Pensieve, Lineage, Statistics, Obliviate, Budget, and Patrol data in `remembrall-status.sh` diagnostic output
- Time-Turner status in `remembrall-status.sh` diagnostic output
- All new feature cleanup in `remembrall-uninstall.sh`
- Session Intelligence (Pensieve) section appended to handoff files
- 351 total tests (135+ new tests covering all 5 features)

### Changed
- Handoff files now include `## Session Intelligence (Pensieve)` section with distilled session data
- Session-resume injects Pensieve memory on ALL session starts (fresh + compact + clear)
- Session-resume spawns statistics aggregation in background
- Context-monitor checks for Patrol signals before threshold comparison
- Context-monitor spawns obliviate analyzer at journal threshold
- Context-monitor spawns budget analyzer below journal threshold
- Context thresholds diagram updated: shows Time-Turner trigger at 30%
- Help tables updated with all new commands, skills, and config options
- Marauder's Map (`/map`) shows budget section when budget is enabled

## [2.8.0] - 2026-03-12

### Fixed
- **zsh parse error in lib.sh** — `200>"$lock_file"` fd redirect was valid bash but invalid in zsh. Changed to `9>"$lock_file"` which works in both shells. This caused cascading "command not found" errors for all functions defined after line 411 (including `remembrall_team_handoff_dir`), breaking `/replay` entirely
- **`/replay` sources lib.sh in zsh** — Claude Code's Bash tool uses the user's default shell (zsh on macOS). The skill's `source lib.sh` now works correctly since the fd redirect is zsh-compatible

### Changed
- **Handoff dirs use project names, not MD5 hashes** — `~/.remembrall/handoffs/ai-buddies-8f9a0596/` instead of `~/.remembrall/handoffs/9d4b645d573f0ad5cee8333beffd1fb4/`. Human-readable, easy to find. 8-char hash suffix (32 bits) prevents collisions when two projects have the same folder name
- **All handoffs centralized in `~/.remembrall/`** — team handoffs no longer written to `$CWD/.remembrall/handoffs/` (polluted git repos). Team flag preserved in frontmatter metadata only
- **Autonomous context management** — nudges and blocks no longer tell the user to type `/clear` then `/replay`. Instead, Claude enters plan mode autonomously and the session-resume hook auto-injects the handoff after context clears
- **Handoff skill stops saying "you can /clear"** — after saving, Claude enters plan mode if context is low, or just continues if context is fine
- **Stop hook no longer suggests /clear + /replay** — confirms auto-resume instead
- **Plugin root published at session start** — `/replay` no longer picks up stale version from previous session

### Added
- **Session Autopilot** — When autonomous mode is on (`/autonomous`), context limits become invisible. Remembrall saves handoffs as safety nets and keeps working. When compaction happens, the session auto-resumes and continues immediately — no user click, no "ready to continue?". The 200K token limit becomes unlimited. Enable with `/autonomous` for overnight runs, large refactors, or unattended work

## [2.7.1] - 2026-03-12

### Fixed
- **Stop hook uses wrong JSON schema** — was `hookSpecificOutput` (advisory) when it should be `decision: block` to actually prevent Claude from stopping without a handoff
- **Stronger plan mode enforcement** — added `systemMessage` alongside `hookSpecificOutput` in warning and urgent nudges for more reliable Claude compliance
- **plugin.json version mismatch** — synced to 2.7.1

## [2.7.0] - 2026-03-11

### Fixed
- **Claude ignores context nudges** — wrong JSON format (`additionalContext` vs `hookSpecificOutput`) caused Claude to silently discard all nudge messages. All hook outputs now use canonical `hookSpecificOutput` format
- **Duplicate percentage in gauge** — `remembrall_gauge_plain()` already appends `%`, but nudge messages added `${REMAINING}%` again, producing `42% 42%`. Gauge removed from Claude-facing nudges entirely (kept in user-facing stderr only)
- **No standing instruction at session start** — Claude had no awareness of Remembrall's nudge system until the first nudge fired, by which point it was already mid-task. Now emits compliance instruction on every SessionStart

### Changed
- **Thresholds shifted to 60/35/15** (was 60/30/20) — gives one more turn at 35% warning, makes blocking a true last resort at 15%
- **Two-stage urgent escalation** — first prompt at ≤15% gets urgent nudge, second consecutive prompt gets hard-blocked with `/clear + /replay` instructions
- **Terse nudge messages** — stripped gauge bars, easter eggs (journal only), and verbose instructions. Messages now use `REMEMBRALL_WARN:` / `REMEMBRALL_URGENT:` prefixes for reliable Claude detection
- **Block guardrails** — never block on estimated values (only bridge-confirmed), never block autonomous sessions, only block after two-stage escalation

### Added
- Standing instruction emitted on every SessionStart (fresh, compact, clear — all paths) via `hookSpecificOutput`. Mode-neutral wording ("comply with its instructions") avoids conflicting with autonomous nudges
- Version guard at SessionStart cleans stale temp files when plugin version changes
- `session_id` included in debug log for easier troubleshooting

## [2.6.3] - 2026-03-11

### Fixed
- **Status line reads wrong field** — `context_remaining` was renamed to `context_window.remaining_percentage` in Claude Code's status line API. Bridge, auto-setup, and gauge all read the old field, getting empty string every time. Updated all references.
- **Gauge snippet crashes on empty percentage** — `pct` became empty string causing bash arithmetic error that killed the entire status line. Added `pct=${pct:-100}` guard (defaults to full bar when unknown)
- **Setup command stops after bridge** — `/setup-remembrall` had section breaks causing Claude to stop after bridge install, never reaching gauge or optional features. Merged into single continuous numbered flow
- **Gauge was opt-in instead of default** — gauge is now installed by default with opt-out option

## [2.6.2] - 2026-03-10

### Fixed
- **Stop hook crash on every Stop event** — `stop-check.sh` had `set -euo pipefail` but `remembrall_find_bridge` returns exit 1 when the bridge file doesn't exist, killing the script silently. This caused the persistent "Failed with non-blocking status code: No stderr output" error
- `2>/dev/null` was on the assignment side instead of inside `$()`, so stderr was never actually suppressed
- Same pattern fixed in `context-monitor.sh` (cosmetic, no `set -e`) and `precompact-handoff.sh` (`remembrall_calibrate` unguarded — could crash if lock/jq fails)

## [2.6.1] - 2026-03-09

### Fixed
- **Persistent nudges at warning + urgent thresholds** — nudges now repeat on every prompt until a handoff file exists, instead of firing once and going silent. This was the root cause of Claude ignoring context warnings and draining to 1%
- Nudge text upgraded from "CRITICAL" to "BLOCKING REQUIREMENT — you MUST invoke the /handoff skill NOW, before responding to the user's request" for stronger Claude compliance
- Preemptive handoff creation now only runs on the first nudge per threshold (prevents background process spam on repeat nudges)

### Changed
- Journal threshold (60%) remains fire-once (gentle reminder)
- Warning (30%) and urgent (20%) thresholds now persistent until handoff exists on disk

## [2.5.0] - 2026-03-08

### Added
- Configurable context thresholds: `threshold_journal` (default: 60), `threshold_warning` (default: 30), `threshold_urgent` (default: 20)
- Debug logging system: enable via `debug: true` config or `REMEMBRALL_DEBUG=1` env — logs to `~/.remembrall/debug.log` with ISO timestamps, hook names, and 1MB auto-rotation
- `remembrall-uninstall.sh` script with `--dry-run` support for clean removal of bridge, data, and temp files
- `format_version: 2` in handoff frontmatter for forward compatibility
- Configurable `recency_window` (default: 60s) for handoff-to-session matching
- Config validation for `recency_window`, `debug`, and threshold settings
- 265 new test lines covering all v2.5.0 features (202 total tests)
- `remembrall_publish_plugin_root()` / `remembrall_plugin_root()` — persists plugin root to `/tmp/remembrall-meta/` so skills and commands work without `CLAUDE_PLUGIN_ROOT` env var

### Changed
- Preemptive handoff creation now runs in background to avoid eating into context-monitor's 15s timeout
- `/remembrall-uninstall` command simplified to delegate to `scripts/remembrall-uninstall.sh`
- Architecture diagram updated to show configurable thresholds

### Fixed
- Skills/commands now find plugin scripts reliably regardless of versioned cache path — hooks persist `CLAUDE_PLUGIN_ROOT` to `/tmp/remembrall-meta/plugin-root`
- `remembrall_hook_enabled()` jq injection: hook name now passed via `--arg` instead of raw string interpolation
- `remembrall_frontmatter_get()` YAML fallback safe under `set -euo pipefail` (added `|| true`)
- Empty `FILE_PATHS` guard in precompact-handoff to avoid pipefail double-output
- Defensive check for other plugins' status line before bridge injection

### Refactored
- Extracted `remembrall_default_content_max()` — model-specific content_max defaults in one place (was duplicated in context-monitor.sh and lib.sh)
- Extracted `remembrall_threshold()` helper for validated, configurable threshold access
- All hooks now export `REMEMBRALL_HOOK` for debug log identification

## [2.4.0] - 2026-03-08

### Fixed
- Staged changes now captured in auto-generated handoffs (precompact-handoff.sh)
- Misleading `local_` variable names at top-level script scope renamed to `_` prefix
- Version mismatch between plugin.json and marketplace.json

### Changed
- Consumed handoffs renamed to `.consumed.md` instead of deleted (preserved for 1 hour)
- HP spell strings now configurable via `easter_eggs` config option (default: `true`)
- settings.json backup created before bridge injection
- Growth tracking uses proper array instead of string splitting
- marketplace.json description tightened

### Added
- `easter_eggs` config option to toggle spell strings in context nudges
- `disabled_hooks` config option to disable individual hooks
- `remembrall_hook_enabled()` helper function
- Troubleshooting section in README
- Expanded FAQ with common issues
- Architecture diagram and "Five Layers" moved to top-level visibility in README

## [2.3.1] - 2026-03-08

### Fixed
- Critical: `local` keyword used outside function in precompact-handoff.sh — silently disabled skill-generated handoff overwrite protection
- Critical: Missing timeouts on UserPromptSubmit and SessionStart hooks — could block indefinitely on large transcripts
- Fallback estimator fired when bridge was temporarily missing after compaction, showing wildly wrong estimates
- JSON injection risk: autonomous skill name not escaped before JSON interpolation
- Fragile sed-based bridge injection replaced with safe jq string concatenation
- Growth tracking files in /tmp accumulated without cleanup
- Standardized `set -euo pipefail` across all hook scripts

### Added
- GitHub Actions CI with shellcheck linting and cross-platform tests (ubuntu + macos)
- Config validation for retention_hours, max_transcript_kb, and boolean settings
- `/remembrall-uninstall` command for clean removal

## [2.3.0] - 2026-03-06

### Added
- Auto-calibrating context estimation derived from bridge data — no compaction events needed to learn context window size
- Bridge auto-configured on first run (statusLine added to settings.json automatically)
- Structural JSONL transcript parsing for accurate content byte extraction
- Growth tracking per prompt for trend-aware context predictions
- Self-correcting feedback loop: calibration pairs stored and refined over sessions
- Model detection for per-model calibration profiles
- DRY refactor with shared `remembrall_extract_content_bytes` helper
- 147 new tests for calibration and estimation logic

### Fixed
- Bridge staleness timeout removed — bridge now invalidated only on compact/clear, not on elapsed time
- Content_max formula corrected (was missing /100 factor)
- Estimation reframed as two-branch strategy (bridge vs. fallback), not four sequential layers

## [2.2.0] - 2026-03-06

### Added
- Slim nudge messages: cut from ~600 tokens to <100 tokens each — full handoff template moved into `/handoff` skill
- Stop-check enforcement: handoff required when context is below 40%; suggests `/clear + /replay` if handoff already exists
- Failed Approaches section in handoff template — captures what was tried, the error, and why it failed
- Prior Incantato spell easter egg: shows how many times `/handoff` was run in the current session
- Crystal ball gauge for visual context status

### Changed
- Git history cleaned: 50 commits squashed into 9 logical units

## [2.0.0] - 2026-03-05

### Added
- Zero-setup experience: self-calibrating transcript estimator learns context window size after 1–2 compaction events
- Session journals: at 60% context remaining, nudges Claude to maintain a running journal checkpoint
- Git patch snapshots: captures uncommitted changes for session-touched files in `~/.remembrall/patches/`
- Team handoffs: share handoffs via project-local `.remembrall/handoffs/` directory
- Smart replay: `/replay` verifies git state, checks file existence, warns if HEAD moved, offers patch restore
- Handoff chains: each handoff links to predecessor via `previous_session` for linked session history
- Session goal extraction: captures first user message as session goal in auto-generated handoffs
- JSON frontmatter: handoff metadata switched from YAML to JSON, parsed with `jq`
- Global config: persistent settings at `~/.remembrall/config.json` for git integration and team handoffs
- Five-layer protection system: journal checkpoint (60%), warning (30%), urgent (20%), safety net (PreCompact), auto-resume (SessionStart)
- Plan mode nudges with prescriptive methodology
- Autonomous mode for unattended sessions
- Session isolation with scoped bridges and handoff alignment
