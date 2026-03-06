#!/usr/bin/env bash
# Remembrall test runner — zero external dependencies
# Usage: bash tests/run-tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
ERRORS=""

# Colors (if terminal supports them)
RED=""
GREEN=""
RESET=""
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  RESET='\033[0m'
fi

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf "${GREEN}  PASS${RESET} %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "${RED}  FAIL${RESET} %s\n    expected: %s\n    actual:   %s\n" "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  - ${label}"
  fi
}

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  if echo "$actual" | grep -qE "$pattern"; then
    printf "${GREEN}  PASS${RESET} %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "${RED}  FAIL${RESET} %s\n    pattern:  %s\n    actual:   %s\n" "$label" "$pattern" "$actual"
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  - ${label}"
  fi
}

assert_nonzero_exit() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf "${RED}  FAIL${RESET} %s (expected nonzero exit)\n" "$label"
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  - ${label}"
  else
    printf "${GREEN}  PASS${RESET} %s\n" "$label"
    PASS=$((PASS + 1))
  fi
}

# ── Setup temp environment ─────────────────────────────────────────
TMPDIR_ROOT=$(mktemp -d)
export HOME="$TMPDIR_ROOT/home"
mkdir -p "$HOME"

cleanup() {
  rm -rf "$TMPDIR_ROOT"
  # Clean up any bridge files we created in the real /tmp (keyed by session_id)
  rm -f /tmp/claude-context-pct/test-bridge-sess 2>/dev/null
  rm -f /tmp/claude-context-pct/test-sess 2>/dev/null
  rm -f /tmp/claude-context-pct/test-stop-sess 2>/dev/null
  rm -f /tmp/remembrall-nudges/test-sess 2>/dev/null
  rm -f /tmp/remembrall-nudges/test-auto-sess 2>/dev/null
  rm -f /tmp/remembrall-autonomous/test-auto-sess 2>/dev/null
  rm -f /tmp/remembrall-sessions/$(remembrall_md5 "/tmp/test-bridge-project" 2>/dev/null) 2>/dev/null
  true
}
trap cleanup EXIT

# Source lib.sh
source "$PLUGIN_ROOT/hooks/lib.sh"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "lib.sh unit tests"
echo "═════════════════"

# ── remembrall_md5 ────────────────────────────────────────────────
echo ""
echo "remembrall_md5:"
HASH=$(remembrall_md5 "/tmp/test-project")
assert_match "produces 32-char hex hash" '^[0-9a-f]{32}$' "$HASH"

HASH2=$(remembrall_md5 "/tmp/test-project")
assert_eq "deterministic for same input" "$HASH" "$HASH2"

HASH3=$(remembrall_md5 "/tmp/other-project")
if [ "$HASH" != "$HASH3" ]; then
  printf "${GREEN}  PASS${RESET} different input produces different hash\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} different input produces different hash\n"
  FAIL=$((FAIL + 1))
fi

# ── remembrall_validate_number ────────────────────────────────────
echo ""
echo "remembrall_validate_number:"
remembrall_validate_number "42" && assert_eq "integer valid" "0" "0" || assert_eq "integer valid" "0" "1"
remembrall_validate_number "3.14" && assert_eq "decimal valid" "0" "0" || assert_eq "decimal valid" "0" "1"
remembrall_validate_number "abc" && assert_eq "string invalid" "1" "0" || assert_eq "string invalid" "0" "0"
remembrall_validate_number "" && assert_eq "empty invalid" "1" "0" || assert_eq "empty invalid" "0" "0"
remembrall_validate_number "42abc" && assert_eq "mixed invalid" "1" "0" || assert_eq "mixed invalid" "0" "0"

# ── remembrall_escape_json ────────────────────────────────────────
echo ""
echo "remembrall_escape_json:"
ESCAPED=$(remembrall_escape_json 'hello "world"')
# The function strips outer quotes from jq output, so \" becomes the escaped form
assert_match "escapes double quotes" 'hello \\"world\\"' "$ESCAPED"

ESCAPED2=$(remembrall_escape_json $'line1\nline2')
assert_match "escapes newlines" 'line1\\nline2' "$ESCAPED2"

ESCAPED3=$(remembrall_escape_json "simple")
assert_eq "simple string unchanged" "simple" "$ESCAPED3"

# ── remembrall_handoff_dir ────────────────────────────────────────
echo ""
echo "remembrall_handoff_dir:"
DIR=$(remembrall_handoff_dir "/tmp/my-project")
assert_match "under .remembrall/handoffs/" '\.remembrall/handoffs/[0-9a-f]{32}$' "$DIR"

DIR2=$(remembrall_handoff_dir "/tmp/my-project")
assert_eq "deterministic for same cwd" "$DIR" "$DIR2"

# ── remembrall_patches_dir ────────────────────────────────────────
echo ""
echo "remembrall_patches_dir:"
PDIR=$(remembrall_patches_dir "/tmp/my-project")
assert_match "under .remembrall/patches/" '\.remembrall/patches/[0-9a-f]{32}$' "$PDIR"

# ── remembrall_config / remembrall_config_set ─────────────────────
echo ""
echo "remembrall_config / remembrall_config_set:"

# No config file yet
VAL=$(remembrall_config "nonexistent" "default_val")
assert_eq "missing config returns default" "default_val" "$VAL"

# Set a boolean
remembrall_config_set "git_integration" "true"
VAL=$(remembrall_config "git_integration" "false")
assert_eq "boolean true stored and read" "true" "$VAL"

# Verify it's a real JSON boolean, not a string
RAW=$(jq '.git_integration' "$HOME/.remembrall/config.json")
assert_eq "stored as JSON boolean (not string)" "true" "$RAW"

# Set a string
remembrall_config_set "some_string" "hello"
VAL=$(remembrall_config "some_string" "")
assert_eq "string value stored and read" "hello" "$VAL"

# Set a number
remembrall_config_set "retention_hours" "48"
VAL=$(remembrall_config "retention_hours" "72")
assert_eq "number stored and read" "48" "$VAL"
RAW=$(jq '.retention_hours' "$HOME/.remembrall/config.json")
assert_eq "number stored as JSON number" "48" "$RAW"

# Set false
remembrall_config_set "git_integration" "false"
VAL=$(remembrall_config "git_integration" "true")
assert_eq "boolean false stored and read" "false" "$VAL"

# ── remembrall_retention_hours ────────────────────────────────────
echo ""
echo "remembrall_retention_hours:"

# With custom value set above (48)
remembrall_config_set "retention_hours" "48"
VAL=$(remembrall_retention_hours)
assert_eq "custom retention hours" "48" "$VAL"

# Reset to test default
rm -f "$HOME/.remembrall/config.json"
VAL=$(remembrall_retention_hours)
assert_eq "default retention hours" "72" "$VAL"

# ── remembrall_git_enabled / remembrall_team_enabled ──────────────
echo ""
echo "remembrall_git_enabled / remembrall_team_enabled:"

# No config = disabled
rm -f "$HOME/.remembrall/config.json"
remembrall_git_enabled "/tmp" && R=true || R=false
assert_eq "git disabled by default" "false" "$R"

remembrall_team_enabled && R=true || R=false
assert_eq "team disabled by default" "false" "$R"

# Enable team
remembrall_config_set "team_handoffs" "true"
remembrall_team_enabled && R=true || R=false
assert_eq "team enabled after config set" "true" "$R"

# ── remembrall_gt / remembrall_le / remembrall_ge ────────────────
echo ""
echo "remembrall_gt / remembrall_le / remembrall_ge (integer comparisons):"

remembrall_gt "85" 60 && R=true || R=false
assert_eq "85 > 60 = true" "true" "$R"

remembrall_gt "42" 60 && R=true || R=false
assert_eq "42 > 60 = false" "false" "$R"

remembrall_gt "60" 60 && R=true || R=false
assert_eq "60 > 60 = false" "false" "$R"

remembrall_gt "42.7" 42 && R=true || R=false
assert_eq "42.7 > 42 = false (truncates)" "false" "$R"

remembrall_le "15" 20 && R=true || R=false
assert_eq "15 <= 20 = true" "true" "$R"

remembrall_le "25" 20 && R=true || R=false
assert_eq "25 <= 20 = false" "false" "$R"

remembrall_ge "40" 40 && R=true || R=false
assert_eq "40 >= 40 = true" "true" "$R"

remembrall_ge "35" 40 && R=true || R=false
assert_eq "35 >= 40 = false" "false" "$R"

remembrall_gt "" 60 && R=true || R=false
assert_eq "empty > 60 = false" "false" "$R"

# ── remembrall_estimate_context ───────────────────────────────────
echo ""
echo "remembrall_estimate_context:"

# No file
R=$(remembrall_estimate_context "" 2>/dev/null) && STATUS=0 || STATUS=1
assert_eq "empty path returns error" "1" "$STATUS"

# Small file (< 40% of 256KB) — should return error (too small)
SMALL_FILE="$TMPDIR_ROOT/small_transcript.jsonl"
dd if=/dev/zero bs=1024 count=50 of="$SMALL_FILE" 2>/dev/null
R=$(remembrall_estimate_context "$SMALL_FILE") && STATUS=0 || STATUS=1
assert_eq "small transcript returns error" "1" "$STATUS"

# Medium file (~60% of 256KB = ~153KB)
MED_FILE="$TMPDIR_ROOT/med_transcript.jsonl"
dd if=/dev/zero bs=1024 count=153 of="$MED_FILE" 2>/dev/null
R=$(remembrall_estimate_context "$MED_FILE")
assert_match "medium transcript returns 30-50%" '^(3[0-9]|4[0-9]|50)$' "$R"

# Large file (~80% of 256KB = ~204KB)
LARGE_FILE="$TMPDIR_ROOT/large_transcript.jsonl"
dd if=/dev/zero bs=1024 count=204 of="$LARGE_FILE" 2>/dev/null
R=$(remembrall_estimate_context "$LARGE_FILE")
assert_match "large transcript returns 10-25%" '^(5|[12][0-9])$' "$R"

# Custom max_transcript_kb
remembrall_config_set "max_transcript_kb" "512"
R=$(remembrall_estimate_context "$LARGE_FILE") && STATUS=0 || STATUS=1
assert_eq "with larger window, 200KB is too small to estimate" "1" "$STATUS"
rm -f "$HOME/.remembrall/config.json"

# ── remembrall_calibrate / remembrall_calibrated_max ──────────────
echo ""
echo "remembrall_calibrate / remembrall_calibrated_max:"

rm -f "$HOME/.remembrall/calibration.json"

# No calibration data
R=$(remembrall_calibrated_max)
assert_eq "no calibration returns empty" "" "$R"

# Calibrate with a 200KB transcript
CAL_FILE="$TMPDIR_ROOT/cal_transcript.jsonl"
dd if=/dev/zero bs=1024 count=200 of="$CAL_FILE" 2>/dev/null
remembrall_calibrate "$CAL_FILE"
R=$(remembrall_calibrated_max)
assert_match "calibrated max is ~200KB" '^20[0-9][0-9][0-9][0-9]$' "$R"

# Second calibration with 250KB — average should shift
CAL_FILE2="$TMPDIR_ROOT/cal_transcript2.jsonl"
dd if=/dev/zero bs=1024 count=250 of="$CAL_FILE2" 2>/dev/null
remembrall_calibrate "$CAL_FILE2"
R=$(remembrall_calibrated_max)
assert_match "calibrated max shifts with 2nd sample" '^2[0-9][0-9][0-9][0-9][0-9]$' "$R"

# Calibration with estimation — calibrated value should be used
R=$(remembrall_estimate_context "$MED_FILE")
# With calibrated max ~225KB, 153KB is ~68% used → ~32% remaining
assert_match "calibrated estimation uses learned max" '^(2[0-9]|3[0-9]|4[0-9])$' "$R"

# Tiny transcript should not calibrate
TINY_FILE="$TMPDIR_ROOT/tiny_transcript.jsonl"
dd if=/dev/zero bs=1024 count=10 of="$TINY_FILE" 2>/dev/null
rm -f "$HOME/.remembrall/calibration.json"
remembrall_calibrate "$TINY_FILE"
R=$(remembrall_calibrated_max)
assert_eq "tiny transcript not calibrated" "" "$R"

rm -f "$HOME/.remembrall/calibration.json"

# ── remembrall_file_age ───────────────────────────────────────────
echo ""
echo "remembrall_file_age:"
FRESH_FILE="$TMPDIR_ROOT/fresh_file"
touch "$FRESH_FILE"
AGE=$(remembrall_file_age "$FRESH_FILE")
assert_match "fresh file age is 0-2 seconds" '^[012]$' "$AGE"

# ── remembrall_find_bridge ────────────────────────────────────────
echo ""
echo "remembrall_find_bridge:"

# No bridge file (no session_id)
R=$(remembrall_find_bridge "/tmp/nonexistent-project" "" 2>/dev/null) && STATUS=0 || STATUS=1
assert_eq "no bridge returns error (no session_id)" "1" "$STATUS"

# No bridge file (session_id but no file)
R=$(remembrall_find_bridge "/tmp/nonexistent-project" "no-such-sess" 2>/dev/null) && STATUS=0 || STATUS=1
assert_eq "no bridge returns error (file missing)" "1" "$STATUS"

# Create a bridge file keyed by session_id
CTX_DIR="/tmp/claude-context-pct"
mkdir -p "$CTX_DIR"
echo "42" > "$CTX_DIR/test-bridge-sess"
R=$(remembrall_find_bridge "/tmp/test-bridge-project" "test-bridge-sess")
assert_eq "finds bridge by session_id" "$CTX_DIR/test-bridge-sess" "$R"

# Without session_id but with published session_id for CWD
BRIDGE_CWD="/tmp/test-bridge-project"
remembrall_publish_session_id "$BRIDGE_CWD" "test-bridge-sess"
R=$(remembrall_find_bridge "$BRIDGE_CWD" "")
assert_eq "finds bridge via published session_id" "$CTX_DIR/test-bridge-sess" "$R"

# Cleanup bridge
rm -f "$CTX_DIR/test-bridge-sess"
BRIDGE_HASH=$(remembrall_md5 "$BRIDGE_CWD")
rm -f "/tmp/remembrall-sessions/$BRIDGE_HASH"

# ── remembrall_frontmatter_get ────────────────────────────────────
echo ""
echo "remembrall_frontmatter_get:"

# ── JSON frontmatter (new format) ──
FM_FILE="$TMPDIR_ROOT/test_handoff.md"
cat > "$FM_FILE" << 'FMEOF'
---
{
  "created": "2026-03-05T14:30:00Z",
  "session_id": "abc123",
  "branch": "main",
  "commit": "deadbeef",
  "patch": "/tmp/patch.diff",
  "team": true,
  "files": ["src/app.ts", "src/lib.ts"]
}
---

# Session Handoff
Content here.
FMEOF

assert_eq "JSON: extracts created" "2026-03-05T14:30:00Z" "$(remembrall_frontmatter_get "$FM_FILE" "created")"
assert_eq "JSON: extracts session_id" "abc123" "$(remembrall_frontmatter_get "$FM_FILE" "session_id")"
assert_eq "JSON: extracts branch" "main" "$(remembrall_frontmatter_get "$FM_FILE" "branch")"
assert_eq "JSON: extracts commit" "deadbeef" "$(remembrall_frontmatter_get "$FM_FILE" "commit")"
assert_eq "JSON: extracts patch" "/tmp/patch.diff" "$(remembrall_frontmatter_get "$FM_FILE" "patch")"
assert_eq "JSON: missing key returns empty" "" "$(remembrall_frontmatter_get "$FM_FILE" "nonexistent")"

# ── YAML frontmatter (legacy backward compat) ──
FM_LEGACY="$TMPDIR_ROOT/test_handoff_legacy.md"
cat > "$FM_LEGACY" << 'FMEOF'
---
created: 2026-03-05T14:30:00Z
session_id: legacy123
branch: develop
commit: cafe1234
---

# Legacy Handoff
FMEOF

assert_eq "YAML legacy: extracts session_id" "legacy123" "$(remembrall_frontmatter_get "$FM_LEGACY" "session_id")"
assert_eq "YAML legacy: extracts branch" "develop" "$(remembrall_frontmatter_get "$FM_LEGACY" "branch")"

# ── remembrall_team_handoff_dir ───────────────────────────────────
echo ""
echo "remembrall_team_handoff_dir:"
TDIR=$(remembrall_team_handoff_dir "/tmp/my-project")
assert_eq "team dir is project-local" "/tmp/my-project/.remembrall/handoffs" "$TDIR"


# ═══════════════════════════════════════════════════════════════════
echo ""
echo "Hook integration tests"
echo "══════════════════════"

# ── context-monitor.sh ────────────────────────────────────────────
echo ""
echo "context-monitor.sh:"

# Bridge files are keyed by session_id (not CWD hash)
CTX_DIR="/tmp/claude-context-pct"
mkdir -p "$CTX_DIR"
TEST_CWD="/tmp/remembrall-test-cwd-$$"
mkdir -p "$TEST_CWD"

# High context (85%) — should produce no output
echo "85" > "$CTX_DIR/test-sess"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_eq "85% remaining: silent" "" "$OUTPUT"

# 50% — journal checkpoint
echo "50" > "$CTX_DIR/test-sess"
rm -f "/tmp/remembrall-nudges/test-sess"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "50% triggers checkpoint nudge" "Context checkpoint" "$OUTPUT"
assert_match "50% checkpoint suggests /handoff" "/handoff" "$OUTPUT"

# 50% again — should be suppressed (already nudged)
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_eq "50% second time: suppressed" "" "$OUTPUT"

# 25% — warning with plan mode
echo "25" > "$CTX_DIR/test-sess"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "25% triggers warning" "Context getting low" "$OUTPUT"
assert_match "25% warning suggests EnterPlanMode" "EnterPlanMode" "$OUTPUT"

# 15% — urgent with plan mode
echo "15" > "$CTX_DIR/test-sess"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "15% triggers urgent" "Context critically low" "$OUTPUT"
assert_match "15% urgent requires EnterPlanMode" "EnterPlanMode" "$OUTPUT"
assert_match "15% urgent says IMMEDIATELY" "IMMEDIATELY" "$OUTPUT"

# 15% again — suppressed
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_eq "15% second time: suppressed" "" "$OUTPUT"

# 90% — reset (post-compaction)
echo "90" > "$CTX_DIR/test-sess"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_eq "90% post-compaction: silent + reset" "" "$OUTPUT"
[ ! -f "/tmp/remembrall-nudges/test-sess" ] && R="cleaned" || R="exists"
assert_eq "nudge file cleaned after reset" "cleaned" "$R"

# Cleanup
rm -f "$CTX_DIR/test-sess"
rm -rf "$TEST_CWD"
rm -f "/tmp/remembrall-nudges/test-sess"

# ── context-monitor.sh (autonomous mode) ─────────────────────────
echo ""
echo "context-monitor.sh (autonomous mode):"

CTX_DIR="/tmp/claude-context-pct"
mkdir -p "$CTX_DIR"
TEST_CWD="/tmp/remembrall-test-auto-$$"
mkdir -p "$TEST_CWD"

# Set autonomous mode for this session
remembrall_set_autonomous "test-auto-sess" "ralph-loop"
R=$(remembrall_is_autonomous "test-auto-sess") && STATUS=0 || STATUS=1
assert_eq "autonomous mode set" "0" "$STATUS"
assert_eq "autonomous skill name" "ralph-loop" "$R"

# 25% in autonomous mode — should suggest /handoff, NOT EnterPlanMode
echo "25" > "$CTX_DIR/test-auto-sess"
rm -f "/tmp/remembrall-nudges/test-auto-sess"
OUTPUT=$(echo '{"session_id":"test-auto-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "25% autonomous: mentions AUTONOMOUS MODE" "AUTONOMOUS MODE" "$OUTPUT"
assert_match "25% autonomous: mentions /handoff" "/handoff" "$OUTPUT"
assert_match "25% autonomous: mentions ralph-loop" "ralph-loop" "$OUTPUT"
# Must NOT mention EnterPlanMode
if echo "$OUTPUT" | grep -q "EnterPlanMode"; then
  printf "${RED}  FAIL${RESET} 25%% autonomous: must NOT mention EnterPlanMode\n"
  FAIL=$((FAIL + 1))
else
  printf "${GREEN}  PASS${RESET} 25%% autonomous: does not mention EnterPlanMode\n"
  PASS=$((PASS + 1))
fi

# 15% in autonomous mode — urgent, same autonomous path
echo "15" > "$CTX_DIR/test-auto-sess"
OUTPUT=$(echo '{"session_id":"test-auto-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "15% autonomous urgent: mentions AUTONOMOUS MODE" "AUTONOMOUS MODE" "$OUTPUT"
assert_match "15% autonomous urgent: says IMMEDIATELY" "IMMEDIATELY" "$OUTPUT"
if echo "$OUTPUT" | grep -q "EnterPlanMode"; then
  printf "${RED}  FAIL${RESET} 15%% autonomous urgent: must NOT mention EnterPlanMode\n"
  FAIL=$((FAIL + 1))
else
  printf "${GREEN}  PASS${RESET} 15%% autonomous urgent: does not mention EnterPlanMode\n"
  PASS=$((PASS + 1))
fi

# Clear autonomous mode
remembrall_clear_autonomous "test-auto-sess"
R=$(remembrall_is_autonomous "test-auto-sess") && STATUS=0 || STATUS=1
assert_eq "autonomous mode cleared" "1" "$STATUS"

# Config-based autonomous mode (no marker file needed)
remembrall_clear_autonomous "test-auto-cfg"
rm -f "/tmp/remembrall-nudges/test-auto-cfg"
remembrall_config_set "autonomous_mode" "true"
echo "25" > "$CTX_DIR/test-auto-cfg"
OUTPUT=$(echo '{"session_id":"test-auto-cfg","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "25% config autonomous: mentions AUTONOMOUS MODE" "AUTONOMOUS MODE" "$OUTPUT"
assert_match "25% config autonomous: mentions config" "config" "$OUTPUT"
if echo "$OUTPUT" | grep -q "EnterPlanMode"; then
  printf "${RED}  FAIL${RESET} 25%% config autonomous: must NOT mention EnterPlanMode\n"
  FAIL=$((FAIL + 1))
else
  printf "${GREEN}  PASS${RESET} 25%% config autonomous: does not mention EnterPlanMode\n"
  PASS=$((PASS + 1))
fi
remembrall_config_set "autonomous_mode" "false"

# Cleanup
rm -f "$CTX_DIR/test-auto-sess" "$CTX_DIR/test-auto-cfg"
rm -rf "$TEST_CWD"
rm -f "/tmp/remembrall-nudges/test-auto-sess" "/tmp/remembrall-nudges/test-auto-cfg"

# ── session-resume.sh ─────────────────────────────────────────────
echo ""
echo "session-resume.sh:"

# Fresh start — should exit silently (no bridge nudge anymore)
TEST_CWD="/tmp/remembrall-test-resume-$$"
mkdir -p "$TEST_CWD"
OUTPUT=$(echo '{"source":"fresh","session_id":"test-resume","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/session-resume.sh" 2>/dev/null)
assert_eq "fresh start: silent (no bridge nudge)" "" "$OUTPUT"

# Compact resume with handoff file
HASH=$(remembrall_md5 "$TEST_CWD")
HANDOFF_DIR="$HOME/.remembrall/handoffs/$HASH"
mkdir -p "$HANDOFF_DIR"
cat > "$HANDOFF_DIR/handoff-test-resume.md" << 'HEOF'
---
{
  "created": "2026-03-05T14:30:00Z",
  "session_id": "test-resume",
  "project": "/tmp/test",
  "status": "in_progress",
  "branch": "main",
  "commit": "abc1234",
  "patch": ""
}
---

# Session Handoff
**Task:** Fix the widget
HEOF

OUTPUT=$(echo '{"source":"compact","session_id":"test-resume","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/session-resume.sh" 2>/dev/null)
assert_match "compact resume: injects handoff" "SESSION HANDOFF LOADED" "$OUTPUT"
assert_match "compact resume: contains task" "Fix the widget" "$OUTPUT"

# Handoff file should be consumed (deleted)
[ ! -f "$HANDOFF_DIR/handoff-test-resume.md" ] && R="consumed" || R="exists"
assert_eq "handoff file consumed after resume" "consumed" "$R"

# Cleanup
rm -rf "$TEST_CWD" "$HANDOFF_DIR"

# ── stop-check.sh ─────────────────────────────────────────────────
echo ""
echo "stop-check.sh:"

TEST_CWD="/tmp/remembrall-test-stop-$$"
mkdir -p "$TEST_CWD"
CTX_DIR="/tmp/claude-context-pct"

# High context — no suggestion (bridge keyed by session_id)
echo "60" > "$CTX_DIR/test-stop-sess"
OUTPUT=$(echo '{"session_id":"test-stop-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/stop-check.sh" 2>&1)
assert_eq "60% remaining: no suggestion" "" "$OUTPUT"

# Low context — suggest clear
echo "30" > "$CTX_DIR/test-stop-sess"
OUTPUT=$(echo '{"session_id":"test-stop-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/stop-check.sh" 2>&1)
assert_match "30% remaining: suggests /clear" "/clear" "$OUTPUT"

# Cleanup
rm -f "$CTX_DIR/test-stop-sess"
rm -rf "$TEST_CWD"

# ── handoff-path.sh ──────────────────────────────────────────────
echo ""
echo "handoff-path.sh:"

TEST_CWD="/tmp/remembrall-test-path-$$"
mkdir -p "$TEST_CWD"
export CLAUDE_SESSION_ID="test-path-sess"

OUTPUT=$(bash "$PLUGIN_ROOT/hooks/handoff-path.sh" "$TEST_CWD" 2>/dev/null)
assert_match "outputs valid handoff path" 'handoff-test-path-sess\.md$' "$OUTPUT"
assert_match "path under .remembrall/handoffs/" '\.remembrall/handoffs/[0-9a-f]' "$OUTPUT"

# Without session ID — uses timestamp fallback
unset CLAUDE_SESSION_ID
OUTPUT=$(bash "$PLUGIN_ROOT/hooks/handoff-path.sh" "$TEST_CWD" 2>/dev/null)
assert_match "fallback uses timestamp" 'handoff-[0-9]+\.md$' "$OUTPUT"

rm -rf "$TEST_CWD"

# ── handoff-create.sh ────────────────────────────────────────────
echo ""
echo "handoff-create.sh:"

TEST_CWD="/tmp/remembrall-test-create-$$"
mkdir -p "$TEST_CWD"
export CLAUDE_SESSION_ID="test-create-sess"
rm -f "$HOME/.remembrall/config.json"

OUTPUT=$(echo "# Test Handoff

**Task:** Build the widget

## Completed
- Created widget.ts

## Remaining
- Add tests" | bash "$PLUGIN_ROOT/scripts/handoff-create.sh" --cwd "$TEST_CWD" --status "in_progress" --files "widget.ts,test.ts" --tasks "Add tests" "Deploy" 2>/dev/null)

assert_match "outputs handoff path" 'handoff-test-create-sess\.md$' "$OUTPUT"

# Verify file was created and has correct content
if [ -f "$OUTPUT" ]; then
  assert_match "handoff has frontmatter" '^---' "$(head -1 "$OUTPUT")"
  assert_match "handoff has session_id" 'session_id.*test-create-sess' "$(cat "$OUTPUT")"
  assert_match "handoff has status" '"status".*"in_progress"' "$(cat "$OUTPUT")"
  assert_match "handoff has files" 'widget.ts' "$(cat "$OUTPUT")"
  assert_match "handoff has tasks" 'Add tests' "$(cat "$OUTPUT")"
  assert_match "handoff has markdown content" 'Build the widget' "$(cat "$OUTPUT")"
else
  printf "${RED}  FAIL${RESET} handoff file was not created at: %s\n" "$OUTPUT"
  FAIL=$((FAIL + 1))
fi

rm -rf "$TEST_CWD"
HASH=$(remembrall_md5 "$TEST_CWD")
rm -rf "$HOME/.remembrall/handoffs/$HASH"
unset CLAUDE_SESSION_ID


# ═══════════════════════════════════════════════════════════════════
echo ""
echo "Edge case tests"
echo "════════════════"

echo ""
echo "Handoff chains (remembrall_previous_session):"
TEST_CWD="/tmp/remembrall-test-chain-$$"
mkdir -p "$TEST_CWD"
HASH=$(remembrall_md5 "$TEST_CWD")
CHAIN_DIR="$HOME/.remembrall/handoffs/$HASH"
mkdir -p "$CHAIN_DIR"

# No previous handoffs
R=$(remembrall_previous_session "$TEST_CWD" "sess-1" 2>/dev/null) && STATUS=0 || STATUS=1
assert_eq "no previous session when dir empty" "" "$R"

# One previous handoff
cat > "$CHAIN_DIR/handoff-sess-old.md" << 'EOF'
---
session_id: sess-old
---
# Old handoff
EOF

R=$(remembrall_previous_session "$TEST_CWD" "sess-new")
assert_eq "finds previous session" "sess-old" "$R"

# Should not return own session
R=$(remembrall_previous_session "$TEST_CWD" "sess-old")
assert_eq "skips own session" "" "$R"

# Multiple previous — returns most recent (backdate old file to ensure ordering)
touch -t 202501010000 "$CHAIN_DIR/handoff-sess-old.md"
cat > "$CHAIN_DIR/handoff-sess-newer.md" << 'EOF'
---
session_id: sess-newer
---
# Newer handoff
EOF

R=$(remembrall_previous_session "$TEST_CWD" "sess-current")
assert_eq "returns most recent previous" "sess-newer" "$R"

rm -rf "$TEST_CWD" "$CHAIN_DIR"

echo ""
echo "Concurrent sessions:"
TEST_CWD="/tmp/remembrall-test-concurrent-$$"
mkdir -p "$TEST_CWD"
HASH=$(remembrall_md5 "$TEST_CWD")
HANDOFF_DIR="$HOME/.remembrall/handoffs/$HASH"
mkdir -p "$HANDOFF_DIR"

# Create two handoff files
cat > "$HANDOFF_DIR/handoff-sess-A.md" << 'EOF'
---
{"session_id": "sess-A", "status": "in_progress"}
---
# Handoff A
EOF

cat > "$HANDOFF_DIR/handoff-sess-B.md" << 'EOF'
---
{"session_id": "sess-B", "status": "in_progress"}
---
# Handoff B
EOF

# Resume sess-A — should only consume A, leave B
OUTPUT=$(echo '{"source":"compact","session_id":"sess-A","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/session-resume.sh" 2>/dev/null)
assert_match "sess-A resume loads A" "Handoff A" "$OUTPUT"
[ ! -f "$HANDOFF_DIR/handoff-sess-A.md" ] && R="consumed" || R="exists"
assert_eq "sess-A handoff consumed" "consumed" "$R"
[ -f "$HANDOFF_DIR/handoff-sess-B.md" ] && R="preserved" || R="gone"
assert_eq "sess-B handoff preserved" "preserved" "$R"

rm -rf "$TEST_CWD" "$HANDOFF_DIR"

echo ""
echo "Retention guard (find -delete safety):"
# Verify retention_hours returns safe values
rm -f "$HOME/.remembrall/config.json"
VAL=$(remembrall_retention_hours)
assert_eq "default retention is 72" "72" "$VAL"

# Set invalid value — should fall back to 72
echo '{"retention_hours": "abc"}' > "$HOME/.remembrall/config.json"
VAL=$(remembrall_retention_hours)
assert_eq "invalid retention falls back to 72" "72" "$VAL"
rm -f "$HOME/.remembrall/config.json"


# ═══════════════════════════════════════════════════════════════════
echo ""
echo "─────────────────"
printf "Results: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}\n" "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  printf "\nFailed tests:${ERRORS}\n"
  exit 1
fi

echo ""
echo "All tests passed."
exit 0
