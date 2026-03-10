# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
