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
  rm -f /tmp/claude-context-pct/test-esc-sess 2>/dev/null
  rm -f /tmp/remembrall-nudges/test-esc-sess 2>/dev/null
  rm -f /tmp/remembrall-autonomous/test-esc-sess 2>/dev/null
  rm -f /tmp/remembrall-handoff-count/test-create-sess 2>/dev/null
  rm -f "/tmp/remembrall-sessions/$(remembrall_md5 "/tmp/test-bridge-project" 2>/dev/null)" 2>/dev/null
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

# Set explicit max_transcript_kb for testing (model detection returns 1600 for non-JSONL files)
remembrall_config_set "max_transcript_kb" "256"

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
rm -f "$HOME/.remembrall/config.json"  # clear max_transcript_kb override so calibration is used
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
assert_match "50% triggers checkpoint nudge" "remaining.*save progress" "$OUTPUT"
assert_match "50% checkpoint suggests /handoff" "/handoff" "$OUTPUT"

# 50% again — should be suppressed (already nudged)
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_eq "50% second time: suppressed" "" "$OUTPUT"

# 25% — warning with plan mode
echo "25" > "$CTX_DIR/test-sess"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "25% triggers warning" "remaining.*BLOCKING REQUIREMENT" "$OUTPUT"
assert_match "25% warning suggests EnterPlanMode" "EnterPlanMode" "$OUTPUT"

# 25% again — persistent (no handoff yet)
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "25% second time: persistent (no handoff yet)" "BLOCKING REQUIREMENT" "$OUTPUT"

# 15% — urgent with plan mode
echo "15" > "$CTX_DIR/test-sess"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "15% triggers urgent" "remaining.*BLOCKING REQUIREMENT" "$OUTPUT"
assert_match "15% urgent requires EnterPlanMode" "EnterPlanMode" "$OUTPUT"
assert_match "15% urgent says MUST invoke" "MUST invoke the /handoff skill NOW" "$OUTPUT"

# 15% again — persistent (repeats until handoff exists)
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "15% second time: persistent (no handoff yet)" "BLOCKING REQUIREMENT" "$OUTPUT"

# Create handoff file — nudge should now be suppressed
HASH=$(source "$PLUGIN_ROOT/hooks/lib.sh" && remembrall_md5 "$TEST_CWD")
mkdir -p "$HOME/.remembrall/handoffs/$HASH"
echo "# handoff" > "$HOME/.remembrall/handoffs/$HASH/handoff-test-sess.md"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_eq "15% after handoff saved: suppressed" "" "$OUTPUT"
rm -f "$HOME/.remembrall/handoffs/$HASH/handoff-test-sess.md"

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

# Handoff file should be consumed (renamed to .consumed.md)
[ ! -f "$HANDOFF_DIR/handoff-test-resume.md" ] && R="consumed" || R="exists"
assert_eq "handoff file consumed after resume" "consumed" "$R"
[ -f "$HANDOFF_DIR/handoff-test-resume.consumed.md" ] && R="renamed" || R="missing"
assert_eq "consumed handoff renamed to .consumed.md" "renamed" "$R"

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

# Low context, no handoff — enforce handoff via additionalContext
echo "30" > "$CTX_DIR/test-stop-sess"
OUTPUT=$(echo '{"session_id":"test-stop-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/stop-check.sh" 2>/dev/null)
assert_match "30% no handoff: enforces handoff" "MUST run /handoff" "$OUTPUT"

# Low context, with handoff — suggest /clear + /replay via stderr
HASH=$(remembrall_md5 "$TEST_CWD")
STOP_HANDOFF_DIR="$HOME/.remembrall/handoffs/$HASH"
mkdir -p "$STOP_HANDOFF_DIR"
echo "test" > "$STOP_HANDOFF_DIR/handoff-test-stop-sess.md"
OUTPUT=$(echo '{"session_id":"test-stop-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/stop-check.sh" 2>&1)
assert_match "30% with handoff: suggests /clear" "/clear" "$OUTPUT"
rm -rf "$STOP_HANDOFF_DIR"

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

# Verify handoff counter was incremented
COUNTER_FILE="/tmp/remembrall-handoff-count/test-create-sess"
[ -f "$COUNTER_FILE" ] && HCOUNT=$(cat "$COUNTER_FILE") || HCOUNT=0
assert_eq "handoff counter incremented to 1" "1" "$HCOUNT"

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
[ -f "$HANDOFF_DIR/handoff-sess-A.consumed.md" ] && R="renamed" || R="missing"
assert_eq "sess-A consumed handoff renamed" "renamed" "$R"
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
echo "v2.3.0 Context Estimation tests"
echo "════════════════════════════════"

# ── remembrall_detect_model ───────────────────────────────────────
echo ""
echo "remembrall_detect_model:"

# Create a test transcript with a known model
MODEL_TRANSCRIPT="$TMPDIR_ROOT/model_transcript.jsonl"
echo '{"type":"assistant","message":{"model":"claude-opus-4-6-20260301","content":[{"type":"text","text":"hello"}]}}' > "$MODEL_TRANSCRIPT"

R=$(remembrall_detect_model "$MODEL_TRANSCRIPT")
MODEL_NAME=$(printf '%s' "$R" | cut -f1)
assert_eq "detects opus model" "claude-opus-4-6-20260301" "$MODEL_NAME"

WINDOW=$(printf '%s' "$R" | cut -f2)
assert_eq "opus window is 200000" "200000" "$WINDOW"

MAX_KB=$(printf '%s' "$R" | cut -f4)
assert_eq "opus max_kb is 1700" "1700" "$MAX_KB"

# Unknown model
UNKNOWN_TRANSCRIPT="$TMPDIR_ROOT/unknown_transcript.jsonl"
echo '{"type":"user","message":{"content":[{"type":"text","text":"hi"}]}}' > "$UNKNOWN_TRANSCRIPT"

R=$(remembrall_detect_model "$UNKNOWN_TRANSCRIPT")
MODEL_NAME=$(printf '%s' "$R" | cut -f1)
assert_eq "unknown model defaults" "unknown" "$MODEL_NAME"

# Missing transcript
R=$(remembrall_detect_model "/nonexistent/path" 2>/dev/null)
MODEL_NAME=$(printf '%s' "$R" | cut -f1)
assert_eq "missing transcript returns unknown" "unknown" "$MODEL_NAME"

# ── remembrall_estimate_tokens ────────────────────────────────────
echo ""
echo "remembrall_estimate_tokens:"

# Create a transcript with real content
TOKEN_TRANSCRIPT="$TMPDIR_ROOT/token_transcript.jsonl"
for i in $(seq 1 50); do
  echo '{"type":"assistant","message":{"model":"claude-opus-4-6","content":[{"type":"text","text":"'"$(printf '%0200d' 0)"'"}]}}' >> "$TOKEN_TRANSCRIPT"
done

R=$(remembrall_estimate_tokens "$TOKEN_TRANSCRIPT" 2>/dev/null)
if [ -n "$R" ] && [ "$R" -gt 0 ] 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} returns >0 for valid JSONL\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} returns >0 for valid JSONL (got: %s)\n" "$R"
  FAIL=$((FAIL + 1))
fi

# Empty file
EMPTY_TRANSCRIPT="$TMPDIR_ROOT/empty_transcript.jsonl"
touch "$EMPTY_TRANSCRIPT"
R=$(remembrall_estimate_tokens "$EMPTY_TRANSCRIPT" 2>/dev/null) && STATUS=0 || STATUS=1
assert_eq "empty file returns error" "1" "$STATUS"

# ── remembrall_estimate_context_structural ────────────────────────
echo ""
echo "remembrall_estimate_context_structural:"

# Build a transcript large enough (>30% of default content_max ~330KB = ~100KB content)
STRUCTURAL_TRANSCRIPT="$TMPDIR_ROOT/structural_transcript.jsonl"
LONG_TEXT=$(printf '%0500d' 0)
for i in $(seq 1 300); do
  echo '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"'"$LONG_TEXT"'"}]}}' >> "$STRUCTURAL_TRANSCRIPT"
done

R=$(remembrall_estimate_context_structural "$STRUCTURAL_TRANSCRIPT" 2>/dev/null)
if [ -n "$R" ] && [ "$R" -gt 0 ] && [ "$R" -le 100 ] 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} returns valid %% for large content (%s%%)\n" "$R"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} returns valid %% for large content (got: %s)\n" "$R"
  FAIL=$((FAIL + 1))
fi

# Small content — should return error (below 30% threshold)
SMALL_STRUCTURAL="$TMPDIR_ROOT/small_structural.jsonl"
echo '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"tiny"}]}}' > "$SMALL_STRUCTURAL"
R=$(remembrall_estimate_context_structural "$SMALL_STRUCTURAL" 2>/dev/null) && STATUS=0 || STATUS=1
assert_eq "small content returns error" "1" "$STATUS"

# ── remembrall_calibrated_content_max ─────────────────────────────
echo ""
echo "remembrall_calibrated_content_max:"

rm -f "$HOME/.remembrall/calibration.json"

# No data
R=$(remembrall_calibrated_content_max "" 2>/dev/null)
assert_eq "no calibration data returns empty" "" "$R"

# Add content samples via calibrate
CAL_STRUCTURAL="$TMPDIR_ROOT/cal_structural.jsonl"
LONG_TEXT2=$(printf '%0500d' 0)
for i in $(seq 1 400); do
  echo '{"type":"assistant","message":{"model":"claude-opus-4-6","content":[{"type":"text","text":"'"$LONG_TEXT2"'"}]}}' >> "$CAL_STRUCTURAL"
done
remembrall_calibrate "$CAL_STRUCTURAL" 2>/dev/null

R=$(remembrall_calibrated_content_max "$CAL_STRUCTURAL" 2>/dev/null)
if [ -n "$R" ] && [ "$R" -gt 0 ] 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} returns avg after calibration samples (%s)\n" "$R"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} returns avg after calibration samples (got: %s)\n" "$R"
  FAIL=$((FAIL + 1))
fi

rm -f "$HOME/.remembrall/calibration.json"

# ── Bridge-derived content_max ────────────────────────────────────
echo ""
echo "remembrall_store_derived_content_max:"

rm -f "$HOME/.remembrall/calibration.json"

# Should not store when usage < 20%
remembrall_store_derived_content_max 50000 90 "claude-opus-4-6" 2>/dev/null
if [ -f "$HOME/.remembrall/calibration.json" ]; then
  R=$(jq -r '.models["claude-opus-4-6"].derived_content_max // empty' "$HOME/.remembrall/calibration.json" 2>/dev/null) || R=""
else
  R=""
fi
assert_eq "skips when usage < 20% (90% remaining)" "" "$R"

# Should store when usage >= 20% (remaining=80%, used=20%)
remembrall_store_derived_content_max 70000 80 "claude-opus-4-6" 2>/dev/null
R=$(jq -r '.models["claude-opus-4-6"].derived_content_max[0]' "$HOME/.remembrall/calibration.json" 2>/dev/null) || R=""
# 70000 * 100 / 20 = 350000
assert_eq "derives content_max at 20% usage" "350000" "$R"

# Should store at 40% usage (remaining=60%)
remembrall_store_derived_content_max 140000 60 "claude-opus-4-6" 2>/dev/null
R=$(jq -r '.models["claude-opus-4-6"].derived_content_max | length' "$HOME/.remembrall/calibration.json" 2>/dev/null) || R=""
assert_eq "accumulates multiple samples" "2" "$R"
R=$(jq -r '.models["claude-opus-4-6"].derived_content_max[1]' "$HOME/.remembrall/calibration.json" 2>/dev/null) || R=""
# 140000 * 100 / 40 = 350000
assert_eq "derives content_max at 40% usage" "350000" "$R"

# Should keep only last 5
for i in 1 2 3 4 5; do
  remembrall_store_derived_content_max 175000 50 "claude-opus-4-6" 2>/dev/null
done
R=$(jq -r '.models["claude-opus-4-6"].derived_content_max | length' "$HOME/.remembrall/calibration.json" 2>/dev/null) || R=""
assert_eq "caps at 5 samples" "5" "$R"

# Should not store for unknown model
remembrall_store_derived_content_max 100000 60 "unknown" 2>/dev/null
R=$(jq -r '.models["unknown"].derived_content_max // empty' "$HOME/.remembrall/calibration.json" 2>/dev/null) || R=""
assert_eq "skips unknown model" "" "$R"

# calibrated_content_max should prefer derived over hardcoded defaults
rm -f "$HOME/.remembrall/calibration.json"
remembrall_store_derived_content_max 100000 60 "claude-opus-4-6" 2>/dev/null
# derived: 100000 * 100 / 40 = 250000
R=$(remembrall_calibrated_content_max "$CAL_STRUCTURAL" 2>/dev/null)
assert_eq "calibrated_content_max uses derived value" "250000" "$R"

rm -f "$HOME/.remembrall/calibration.json"

# ── Bridge auto-inject in session-resume.sh ───────────────────────
echo ""
echo "Bridge auto-inject (session-resume.sh):"

# Create settings.json without bridge but with statusLine (includes session_id extraction)
SETTINGS_FILE="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
printf '%s\n' '{
  "statusLine": {
    "command": "input=$(cat); session_id=$(echo \"$input\" | jq -r '"'"'.session_id // empty'"'"'); remaining=$(echo \"$input\" | jq -r '"'"'.context_remaining // empty'"'"'); status=\"ctx: ${remaining}%\"; echo \"$status\""
  }
}' > "$SETTINGS_FILE"

# Run session-resume — should inject bridge
TEST_CWD_BR="$TMPDIR_ROOT/bridge-test-cwd"
mkdir -p "$TEST_CWD_BR"
echo '{"source":"fresh","session_id":"test-bridge-inject","cwd":"'"$TEST_CWD_BR"'"}' | bash "$PLUGIN_ROOT/hooks/session-resume.sh" 2>/dev/null

if grep -q "claude-context-pct" "$SETTINGS_FILE" 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} bridge injected when missing\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} bridge injected when missing\n"
  FAIL=$((FAIL + 1))
fi

# Run again — should not duplicate
BEFORE=$(grep -c "claude-context-pct" "$SETTINGS_FILE" 2>/dev/null)
echo '{"source":"fresh","session_id":"test-bridge-inject2","cwd":"'"$TEST_CWD_BR"'"}' | bash "$PLUGIN_ROOT/hooks/session-resume.sh" 2>/dev/null
AFTER=$(grep -c "claude-context-pct" "$SETTINGS_FILE" 2>/dev/null)
assert_eq "bridge not duplicated on re-run" "$BEFORE" "$AFTER"

rm -rf "$TEST_CWD_BR"
rm -f "$SETTINGS_FILE"

# Test: create bridge from scratch when no statusLine exists
printf '%s\n' '{"env":{"allowAll":true}}' > "$SETTINGS_FILE"
TEST_CWD_BR2="$TMPDIR_ROOT/bridge-test-cwd2"
mkdir -p "$TEST_CWD_BR2"
echo '{"source":"fresh","session_id":"test-bridge-create","cwd":"'"$TEST_CWD_BR2"'"}' | bash "$PLUGIN_ROOT/hooks/session-resume.sh" 2>/dev/null
if grep -q "claude-context-pct" "$SETTINGS_FILE" 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} bridge created from scratch (no statusLine)\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} bridge created from scratch (no statusLine)\n"
  FAIL=$((FAIL + 1))
fi

# Verify the created command is valid — should contain ctx:
if grep -q 'ctx:' "$SETTINGS_FILE" 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} created status line shows context %%\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} created status line shows context %%\n"
  FAIL=$((FAIL + 1))
fi

rm -rf "$TEST_CWD_BR2"
rm -f "$SETTINGS_FILE"

# ── Bootstrap in context-monitor.sh ───────────────────────────────
echo ""
echo "Bootstrap (context-monitor.sh):"

# No bridge, no settings bridge — first call should bootstrap
TEST_CWD_BS="$TMPDIR_ROOT/bootstrap-test-cwd"
mkdir -p "$TEST_CWD_BS"
rm -f "/tmp/remembrall-bootstrap/test-bootstrap-sess"
rm -f "/tmp/claude-context-pct/test-bootstrap-sess"
# No settings.json with bridge
rm -f "$HOME/.claude/settings.json"

OUTPUT=$(echo '{"session_id":"test-bootstrap-sess","cwd":"'"$TEST_CWD_BS"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "bootstrap fires: requests bridge write" "claude-context-pct" "$OUTPUT"

# Second call — should NOT bootstrap again
OUTPUT=$(echo '{"session_id":"test-bootstrap-sess","cwd":"'"$TEST_CWD_BS"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
# Should be empty or estimation-based — not bootstrap
if echo "$OUTPUT" | grep -q "Write your context"; then
  printf "${RED}  FAIL${RESET} bootstrap does not repeat\n"
  FAIL=$((FAIL + 1))
else
  printf "${GREEN}  PASS${RESET} bootstrap does not repeat\n"
  PASS=$((PASS + 1))
fi

rm -f "/tmp/remembrall-bootstrap/test-bootstrap-sess"
rm -rf "$TEST_CWD_BS"

# ── Calibration pairs ────────────────────────────────────────────
echo ""
echo "Calibration pairs (Phase 3):"

rm -f "$HOME/.remembrall/calibration.json"

# Create a transcript for pair logging
PAIR_TRANSCRIPT="$TMPDIR_ROOT/pair_transcript.jsonl"
PAIR_TEXT=$(printf '%0500d' 0)
for i in $(seq 1 200); do
  echo '{"type":"assistant","message":{"model":"claude-opus-4-6","content":[{"type":"text","text":"'"$PAIR_TEXT"'"}]}}' >> "$PAIR_TRANSCRIPT"
done

# Log 6 pairs (need >=5 for correction offset)
for i in $(seq 1 6); do
  bridge=$((40 + i))
  structural=$((35 + i))
  remembrall_log_calibration_pair "$PAIR_TRANSCRIPT" "$bridge" "$structural" 2>/dev/null
done

# Check pairs were stored
PAIR_COUNT=$(jq '.pairs["claude-opus-4-6"] | length' "$HOME/.remembrall/calibration.json" 2>/dev/null)
assert_eq "6 pairs stored" "6" "$PAIR_COUNT"

# Check correction offset (bridge is ~5% higher than structural)
OFFSET=$(remembrall_correction_offset "claude-opus-4-6" 2>/dev/null)
if [ -n "$OFFSET" ] && [ "$OFFSET" -ge 3 ] && [ "$OFFSET" -le 7 ] 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} correction offset is ~5 (got: %s)\n" "$OFFSET"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} correction offset is ~5 (got: %s)\n" "$OFFSET"
  FAIL=$((FAIL + 1))
fi

# No pairs for unknown model — should return empty
OFFSET_UNKNOWN=$(remembrall_correction_offset "unknown-model" 2>/dev/null)
assert_eq "no offset for unknown model" "" "$OFFSET_UNKNOWN"

# <5 pairs — should return empty
rm -f "$HOME/.remembrall/calibration.json"
for i in $(seq 1 3); do
  remembrall_log_calibration_pair "$PAIR_TRANSCRIPT" "50" "45" 2>/dev/null
done
OFFSET_FEW=$(remembrall_correction_offset "claude-opus-4-6" 2>/dev/null)
assert_eq "no offset with <5 pairs" "" "$OFFSET_FEW"

rm -f "$HOME/.remembrall/calibration.json"

# ── Self-correcting feedback loop (Phase 5) ──────────────────────
echo ""
echo "Self-correcting feedback (Phase 5):"

# No correction available — should return original value
R=$(remembrall_apply_correction "42" "unknown-model" 2>/dev/null)
assert_eq "no correction returns original" "42" "$R"

# With correction data
echo '{"samples":[],"models":{},"pairs":{}}' > "$HOME/.remembrall/calibration.json"
CORR_TRANSCRIPT="$TMPDIR_ROOT/corr_transcript.jsonl"
CORR_TEXT=$(printf '%0500d' 0)
for i in $(seq 1 200); do
  echo '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"'"$CORR_TEXT"'"}]}}' >> "$CORR_TRANSCRIPT"
done
# Bridge always 8% higher → offset ~8
for i in $(seq 1 6); do
  remembrall_log_calibration_pair "$CORR_TRANSCRIPT" "50" "42" 2>/dev/null
done
R=$(remembrall_apply_correction "35" "claude-sonnet-4-6" 2>/dev/null)
if [ -n "$R" ] && [ "$R" -ge 40 ] && [ "$R" -le 50 ] 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} correction applied: 35 → %s (offset ~8)\n" "$R"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} correction applied: 35 → %s (expected 40-50)\n" "$R"
  FAIL=$((FAIL + 1))
fi

# Cap at ±15% — log extreme offsets
rm -f "$HOME/.remembrall/calibration.json"
echo '{"samples":[],"models":{},"pairs":{}}' > "$HOME/.remembrall/calibration.json"
for i in $(seq 1 6); do
  remembrall_log_calibration_pair "$CORR_TRANSCRIPT" "70" "40" 2>/dev/null  # offset ~30
done
R=$(remembrall_apply_correction "20" "claude-sonnet-4-6" 2>/dev/null)
# Should cap at +15: 20 + 15 = 35
if [ -n "$R" ] && [ "$R" -eq 35 ] 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} correction capped at ±15%% (20 → %s)\n" "$R"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} correction capped at ±15%% (20 → %s, expected 35)\n" "$R"
  FAIL=$((FAIL + 1))
fi

rm -f "$HOME/.remembrall/calibration.json"

# ── Growth tracking (Phase 4) ────────────────────────────────────
echo ""
echo "Growth tracking (Phase 4):"

rm -rf "/tmp/remembrall-growth"

# Create growing transcript
GROWTH_TRANSCRIPT_1="$TMPDIR_ROOT/growth_transcript_1.jsonl"
GROWTH_TEXT=$(printf '%0500d' 0)
for i in $(seq 1 100); do
  echo '{"type":"assistant","message":{"model":"claude-opus-4-6","content":[{"type":"text","text":"'"$GROWTH_TEXT"'"}]}}' >> "$GROWTH_TRANSCRIPT_1"
done

# First measurement — no deltas yet
R=$(remembrall_track_growth "test-growth-sess" "$GROWTH_TRANSCRIPT_1" 2>/dev/null)
AVG=$(printf '%s' "$R" | cut -f1)
assert_eq "first measurement: avg growth is 0" "0" "$AVG"

# Add more content and track again
GROWTH_TRANSCRIPT_2="$TMPDIR_ROOT/growth_transcript_2.jsonl"
cp "$GROWTH_TRANSCRIPT_1" "$GROWTH_TRANSCRIPT_2"
for i in $(seq 1 50); do
  echo '{"type":"assistant","message":{"model":"claude-opus-4-6","content":[{"type":"text","text":"'"$GROWTH_TEXT"'"}]}}' >> "$GROWTH_TRANSCRIPT_2"
done

R=$(remembrall_track_growth "test-growth-sess" "$GROWTH_TRANSCRIPT_2" 2>/dev/null)
AVG=$(printf '%s' "$R" | cut -f1)
if [ -n "$AVG" ] && [ "$AVG" -gt 0 ] 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} second measurement: growth rate >0 (%s)\n" "$AVG"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} second measurement: growth rate >0 (got: %s)\n" "$AVG"
  FAIL=$((FAIL + 1))
fi

# Prompts until threshold
R=$(remembrall_prompts_until_threshold "100000" "10000" "358400" "20" 2>/dev/null)
# threshold_bytes = 358400 * 80/100 = 286720; remaining = 286720 - 100000 = 186720; prompts = 186720/10000 = 18
if [ -n "$R" ] && [ "$R" -gt 0 ] 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} prompts_until_threshold returns >0 (%s)\n" "$R"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} prompts_until_threshold returns >0 (got: %s)\n" "$R"
  FAIL=$((FAIL + 1))
fi

# Zero growth — should return error
R=$(remembrall_prompts_until_threshold "100000" "0" "358400" "20" 2>/dev/null) && STATUS=0 || STATUS=1
assert_eq "zero growth returns error" "1" "$STATUS"

# Already past threshold
R=$(remembrall_prompts_until_threshold "350000" "10000" "358400" "20" 2>/dev/null)
assert_eq "past threshold returns 0" "0" "$R"

rm -rf "/tmp/remembrall-growth"

# ── precompact-handoff.sh (skill-generated handoff protection) ────
echo ""
echo "precompact-handoff.sh (skill-generated handoff protection):"

TEST_CWD_PC="$TMPDIR_ROOT/precompact-protect-test"
mkdir -p "$TEST_CWD_PC"

PC_TRANSCRIPT="$TMPDIR_ROOT/precompact_protect_transcript.jsonl"
echo '{"type":"human","content":"implement auth"}' > "$PC_TRANSCRIPT"
echo '{"type":"assistant","message":{"model":"claude-sonnet-4-6"},"content":[{"type":"text","text":"OK working on auth now."}]}' >> "$PC_TRANSCRIPT"

PC_HANDOFF_DIR=$(remembrall_handoff_dir "$TEST_CWD_PC")
mkdir -p "$PC_HANDOFF_DIR"
PC_HANDOFF_FILE="$PC_HANDOFF_DIR/handoff-test-pc-sess.md"

cat > "$PC_HANDOFF_FILE" << 'SKILL_HANDOFF'
---
{
  "created": "2026-03-08T10:00:00Z",
  "session_id": "test-pc-sess",
  "project": "/tmp/test",
  "status": "in_progress"
}
---

# Session Handoff — Skill Generated

This handoff was created by the /handoff skill with rich context.
SKILL_HANDOFF

touch -t 202603080900 "$PC_HANDOFF_FILE"

echo '{"session_id":"test-pc-sess","cwd":"'"$TEST_CWD_PC"'","transcript_path":"'"$PC_TRANSCRIPT"'"}' | \
  bash "$PLUGIN_ROOT/hooks/precompact-handoff.sh" 2>/dev/null

if grep -q "Skill Generated" "$PC_HANDOFF_FILE"; then
  printf "${GREEN}  PASS${RESET} skill-generated handoff not overwritten by precompact\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} skill-generated handoff not overwritten by precompact\n"
  FAIL=$((FAIL + 1))
fi

rm -rf "$TEST_CWD_PC"

# ── hooks.json timeout validation ─────────────────────────────────
echo ""
echo "hooks.json timeout validation:"

HOOKS_FILE="$PLUGIN_ROOT/hooks/hooks.json"
for hook_event in UserPromptSubmit PreCompact SessionStart Stop; do
  HAS_TIMEOUT=$(jq -r --arg h "$hook_event" '.hooks[$h][0].hooks[0].timeout // empty' "$HOOKS_FILE")
  if [ -n "$HAS_TIMEOUT" ] && [ "$HAS_TIMEOUT" -gt 0 ] 2>/dev/null; then
    printf "${GREEN}  PASS${RESET} %s hook has timeout (%ss)\n" "$hook_event" "$HAS_TIMEOUT"
    PASS=$((PASS + 1))
  else
    printf "${RED}  FAIL${RESET} %s hook missing timeout\n" "$hook_event"
    FAIL=$((FAIL + 1))
  fi
done

# ── context-monitor.sh (autonomous skill with special chars) ──────
echo ""
echo "context-monitor.sh (autonomous skill with special chars):"

CTX_DIR="/tmp/claude-context-pct"
mkdir -p "$CTX_DIR"
TEST_CWD_ESC="$TMPDIR_ROOT/escape-test-cwd"
mkdir -p "$TEST_CWD_ESC"

remembrall_set_autonomous "test-esc-sess" 'ralph"loop'
echo "25" > "$CTX_DIR/test-esc-sess"
rm -f "/tmp/remembrall-nudges/test-esc-sess"

OUTPUT=$(echo '{"session_id":"test-esc-sess","cwd":"'"$TEST_CWD_ESC"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)

if echo "$OUTPUT" | jq . >/dev/null 2>&1; then
  printf "${GREEN}  PASS${RESET} autonomous skill with quotes produces valid JSON\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} autonomous skill with quotes produces valid JSON\n"
  FAIL=$((FAIL + 1))
fi

remembrall_clear_autonomous "test-esc-sess"
rm -f "$CTX_DIR/test-esc-sess" "/tmp/remembrall-nudges/test-esc-sess"
rm -rf "$TEST_CWD_ESC"

# ── session-resume.sh (growth file cleanup) ───────────────────────
echo ""
echo "session-resume.sh (growth file cleanup):"

GROWTH_DIR="/tmp/remembrall-growth"
mkdir -p "$GROWTH_DIR"
echo "100000" > "$GROWTH_DIR/test-growth-cleanup-sess"

TEST_CWD_GC="$TMPDIR_ROOT/growth-cleanup-test"
mkdir -p "$TEST_CWD_GC"

GC_HANDOFF_DIR=$(remembrall_handoff_dir "$TEST_CWD_GC")
mkdir -p "$GC_HANDOFF_DIR"
cat > "$GC_HANDOFF_DIR/handoff-test-growth-cleanup-sess.md" << 'GC_HANDOFF'
---
{
  "created": "2026-03-08T10:00:00Z",
  "session_id": "test-growth-cleanup-sess",
  "project": "/tmp/test",
  "status": "in_progress"
}
---

# Test handoff for growth cleanup
GC_HANDOFF

echo '{"source":"compact","session_id":"test-growth-cleanup-sess","cwd":"'"$TEST_CWD_GC"'"}' | \
  bash "$PLUGIN_ROOT/hooks/session-resume.sh" 2>/dev/null

if [ -f "$GROWTH_DIR/test-growth-cleanup-sess" ]; then
  printf "${RED}  FAIL${RESET} growth file cleaned up on session resume\n"
  FAIL=$((FAIL + 1))
else
  printf "${GREEN}  PASS${RESET} growth file cleaned up on session resume\n"
  PASS=$((PASS + 1))
fi

rm -rf "$TEST_CWD_GC"

# ── session-resume.sh (bridge injection with pipes in existing command) ──
echo ""
echo "session-resume.sh (bridge injection with pipes in existing command):"

SETTINGS_FILE="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"

cat > "$SETTINGS_FILE" << 'PIPE_SETTINGS'
{
  "statusLine": {
    "command": "input=$(cat); remaining=$(echo \"$input\" | jq -r '.context_remaining // empty'); status=\"ctx: ${remaining:-?}%\"; echo \"$status\""
  }
}
PIPE_SETTINGS

TEST_CWD_PIPE="$TMPDIR_ROOT/pipe-bridge-test"
mkdir -p "$TEST_CWD_PIPE"

echo '{"source":"fresh","session_id":"test-pipe-bridge","cwd":"'"$TEST_CWD_PIPE"'"}' | \
  bash "$PLUGIN_ROOT/hooks/session-resume.sh" 2>/dev/null

if jq . "$SETTINGS_FILE" >/dev/null 2>&1; then
  printf "${GREEN}  PASS${RESET} settings.json valid JSON after bridge injection with pipes\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} settings.json valid JSON after bridge injection with pipes\n"
  FAIL=$((FAIL + 1))
fi

if grep -q "claude-context-pct" "$SETTINGS_FILE" 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} bridge snippet present after injection with pipes\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} bridge snippet present after injection with pipes\n"
  FAIL=$((FAIL + 1))
fi

rm -rf "$TEST_CWD_PIPE"

# ── Config validation ─────────────────────────────────────────────
echo ""
echo "Config validation:"

# Valid values should succeed
remembrall_config_set "retention_hours" "48" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "valid retention_hours accepted" "0" "$STATUS"
VAL=$(remembrall_config "retention_hours" "72")
assert_eq "retention_hours stored correctly" "48" "$VAL"

remembrall_config_set "max_transcript_kb" "2000" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "valid max_transcript_kb accepted" "0" "$STATUS"

# Invalid values should be rejected
remembrall_config_set "retention_hours" "-5" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "negative retention_hours rejected" "1" "$STATUS"

remembrall_config_set "retention_hours" "banana" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "non-numeric retention_hours rejected" "1" "$STATUS"

remembrall_config_set "retention_hours" "0" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "zero retention_hours rejected" "1" "$STATUS"

remembrall_config_set "max_transcript_kb" "abc" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "non-numeric max_transcript_kb rejected" "1" "$STATUS"

remembrall_config_set "autonomous_mode" "maybe" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "non-boolean autonomous_mode rejected" "1" "$STATUS"

remembrall_config_set "autonomous_mode" "true" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "valid boolean autonomous_mode accepted" "0" "$STATUS"

# Clean up
remembrall_config_set "retention_hours" "72" 2>/dev/null
remembrall_config_set "autonomous_mode" "false" 2>/dev/null

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "v2.5.0 Improvements tests"
echo "════════════════════════════════"

# ── remembrall_default_content_max ────────────────────────────────
echo ""
echo "remembrall_default_content_max:"

R=$(remembrall_default_content_max "claude-opus-4-6-20260301")
assert_eq "opus content_max" "358400" "$R"

R=$(remembrall_default_content_max "claude-sonnet-4-6-20260301")
assert_eq "sonnet content_max" "337920" "$R"

R=$(remembrall_default_content_max "claude-haiku-4-5-20251001")
assert_eq "haiku content_max" "317440" "$R"

R=$(remembrall_default_content_max "unknown-model")
assert_eq "unknown model falls back to sonnet default" "337920" "$R"

R=$(remembrall_default_content_max "")
assert_eq "empty model falls back to sonnet default" "337920" "$R"

# ── Configurable thresholds ───────────────────────────────────────
echo ""
echo "Configurable thresholds:"

rm -f "$HOME/.remembrall/config.json"

# Default thresholds
R=$(remembrall_threshold "journal" 60)
assert_eq "default journal threshold" "60" "$R"

R=$(remembrall_threshold "warning" 30)
assert_eq "default warning threshold" "30" "$R"

R=$(remembrall_threshold "urgent" 20)
assert_eq "default urgent threshold" "20" "$R"

# Custom thresholds
remembrall_config_set "threshold_journal" "50" 2>/dev/null
R=$(remembrall_threshold "journal" 60)
assert_eq "custom journal threshold" "50" "$R"

# Invalid thresholds rejected
remembrall_config_set "threshold_warning" "0" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "zero threshold rejected" "1" "$STATUS"

remembrall_config_set "threshold_warning" "100" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "100 threshold rejected" "1" "$STATUS"

remembrall_config_set "threshold_warning" "abc" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "non-numeric threshold rejected" "1" "$STATUS"

# Invalid value in config falls back to default
echo '{"threshold_urgent": "banana"}' > "$HOME/.remembrall/config.json"
R=$(remembrall_threshold "urgent" 20)
assert_eq "invalid config value falls back to default" "20" "$R"

rm -f "$HOME/.remembrall/config.json"

# ── Configurable thresholds in context-monitor.sh ─────────────────
echo ""
echo "Configurable thresholds in context-monitor.sh:"

CTX_DIR="/tmp/claude-context-pct"
mkdir -p "$CTX_DIR"
TEST_CWD_TH="$TMPDIR_ROOT/threshold-test-cwd"
mkdir -p "$TEST_CWD_TH"

# Set custom journal threshold to 40 (default is 60)
remembrall_config_set "threshold_journal" "40" 2>/dev/null

# At 45% remaining with threshold=40: should be silent (above journal threshold)
echo "45" > "$CTX_DIR/test-th-sess"
rm -f "/tmp/remembrall-nudges/test-th-sess"
OUTPUT=$(echo '{"session_id":"test-th-sess","cwd":"'"$TEST_CWD_TH"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
if [ -z "$OUTPUT" ]; then
  printf "${GREEN}  PASS${RESET} 45%% with threshold=40: silent (above threshold)\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} 45%% with threshold=40: should be silent (got output)\n"
  FAIL=$((FAIL + 1))
fi

# At 35% remaining with threshold=40: should trigger journal
echo "35" > "$CTX_DIR/test-th-sess2"
rm -f "/tmp/remembrall-nudges/test-th-sess2"
OUTPUT=$(echo '{"session_id":"test-th-sess2","cwd":"'"$TEST_CWD_TH"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "35% with threshold=40: triggers journal" "handoff" "$OUTPUT"

rm -f "$CTX_DIR/test-th-sess" "$CTX_DIR/test-th-sess2"
rm -f "/tmp/remembrall-nudges/test-th-sess" "/tmp/remembrall-nudges/test-th-sess2"
rm -rf "$TEST_CWD_TH"
rm -f "$HOME/.remembrall/config.json"

# ── Debug logging ─────────────────────────────────────────────────
echo ""
echo "Debug logging:"

rm -f "$HOME/.remembrall/config.json"
rm -f "$HOME/.remembrall/debug.log"
# Reset debug cache for this test
unset _REMEMBRALL_DEBUG_CACHED 2>/dev/null || true

# Debug off by default — no log file created
remembrall_debug "test message should not appear"
if [ ! -f "$HOME/.remembrall/debug.log" ]; then
  printf "${GREEN}  PASS${RESET} debug off: no log file created\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} debug off: log file should not exist\n"
  FAIL=$((FAIL + 1))
fi

# Reset cache, enable via config
unset _REMEMBRALL_DEBUG_CACHED 2>/dev/null || true
remembrall_config_set "debug" "true" 2>/dev/null
remembrall_debug "test debug message"
if [ -f "$HOME/.remembrall/debug.log" ] && grep -q "test debug message" "$HOME/.remembrall/debug.log" 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} debug on: message logged\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} debug on: message not found in log\n"
  FAIL=$((FAIL + 1))
fi

# Check log format includes timestamp and hook name
if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$HOME/.remembrall/debug.log" 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} debug log has ISO timestamp\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} debug log missing ISO timestamp\n"
  FAIL=$((FAIL + 1))
fi

# Debug caching — second call should not re-read config
# (can't directly test cache, but verify it still works)
remembrall_debug "second message"
LINES=$(grep -c "message" "$HOME/.remembrall/debug.log" 2>/dev/null || echo 0)
assert_eq "debug caching: both messages logged" "2" "$LINES"

# Enable via env var
rm -f "$HOME/.remembrall/debug.log"
rm -f "$HOME/.remembrall/config.json"
unset _REMEMBRALL_DEBUG_CACHED 2>/dev/null || true
REMEMBRALL_DEBUG=1 remembrall_debug "env debug message"
if [ -f "$HOME/.remembrall/debug.log" ] && grep -q "env debug message" "$HOME/.remembrall/debug.log" 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} REMEMBRALL_DEBUG=1 enables logging\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} REMEMBRALL_DEBUG=1 should enable logging\n"
  FAIL=$((FAIL + 1))
fi

rm -f "$HOME/.remembrall/debug.log"
rm -f "$HOME/.remembrall/config.json"
unset _REMEMBRALL_DEBUG_CACHED 2>/dev/null || true

# ── format_version in frontmatter ─────────────────────────────────
echo ""
echo "format_version in frontmatter:"

TEST_CWD_FV="$TMPDIR_ROOT/format-version-test"
mkdir -p "$TEST_CWD_FV"

# Test precompact-handoff.sh includes format_version
FV_TRANSCRIPT="$TMPDIR_ROOT/fv_transcript.jsonl"
echo '{"type":"human","content":"test format version"}' > "$FV_TRANSCRIPT"
echo '{"type":"assistant","message":{"model":"claude-sonnet-4-6"},"content":[{"type":"text","text":"OK working on this now."}]}' >> "$FV_TRANSCRIPT"

echo '{"session_id":"test-fv-sess","cwd":"'"$TEST_CWD_FV"'","transcript_path":"'"$FV_TRANSCRIPT"'"}' | \
  bash "$PLUGIN_ROOT/hooks/precompact-handoff.sh" 2>/dev/null || true

FV_HANDOFF_DIR=$(remembrall_handoff_dir "$TEST_CWD_FV")
FV_HANDOFF_FILE="$FV_HANDOFF_DIR/handoff-test-fv-sess.md"

if [ -f "$FV_HANDOFF_FILE" ]; then
  FV_VAL=$(remembrall_frontmatter_get "$FV_HANDOFF_FILE" "format_version" 2>/dev/null)
  assert_eq "precompact handoff has format_version 2" "2" "$FV_VAL"
else
  printf "${RED}  FAIL${RESET} precompact handoff file not created\n"
  FAIL=$((FAIL + 1))
fi

# Test handoff-create.sh includes format_version
FV_CREATED_PATH=$(echo "# Test handoff content" | bash "$PLUGIN_ROOT/scripts/handoff-create.sh" \
  --cwd "$TEST_CWD_FV" --session-id "test-fv-sess3" 2>/dev/null) || true

if [ -n "$FV_CREATED_PATH" ] && [ -f "$FV_CREATED_PATH" ]; then
  FV_VAL2=$(remembrall_frontmatter_get "$FV_CREATED_PATH" "format_version" 2>/dev/null)
  assert_eq "skill handoff has format_version 2" "2" "$FV_VAL2"
else
  printf "${RED}  FAIL${RESET} skill handoff file not created (path: %s)\n" "${FV_CREATED_PATH:-empty}"
  FAIL=$((FAIL + 1))
fi

rm -rf "$TEST_CWD_FV"

# ── Recency window config ────────────────────────────────────────
echo ""
echo "Recency window config:"

remembrall_config_set "recency_window" "120" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "valid recency_window accepted" "0" "$STATUS"
VAL=$(remembrall_config "recency_window" "60")
assert_eq "recency_window stored correctly" "120" "$VAL"

remembrall_config_set "recency_window" "0" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "zero recency_window rejected" "1" "$STATUS"

remembrall_config_set "recency_window" "abc" 2>/dev/null && STATUS=0 || STATUS=1
assert_eq "non-numeric recency_window rejected" "1" "$STATUS"

rm -f "$HOME/.remembrall/config.json"

# ── Uninstall script ──────────────────────────────────────────────
echo ""
echo "Uninstall script (dry run):"

# Set up state to uninstall
mkdir -p "$HOME/.claude"
echo '{"statusLine":{"command":"CTX_DIR=\"/tmp/claude-context-pct\"; echo ctx"}}' > "$HOME/.claude/settings.json"
mkdir -p "$HOME/.remembrall/handoffs/abc"
echo "test" > "$HOME/.remembrall/handoffs/abc/handoff-test.md"
echo '{}' > "$HOME/.remembrall/config.json"
mkdir -p "/tmp/remembrall-nudges"
echo "test" > "/tmp/remembrall-nudges/uninstall-test"

# Dry run should not remove anything
OUTPUT=$(bash "$PLUGIN_ROOT/scripts/remembrall-uninstall.sh" --dry-run 2>&1)
assert_match "dry run header" "DRY RUN" "$OUTPUT"

if [ -f "$HOME/.remembrall/config.json" ]; then
  printf "${GREEN}  PASS${RESET} dry run: config.json preserved\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} dry run: config.json should not be removed\n"
  FAIL=$((FAIL + 1))
fi

# Real run should clean up
OUTPUT=$(bash "$PLUGIN_ROOT/scripts/remembrall-uninstall.sh" 2>&1)
assert_match "uninstall complete message" "Uninstall complete" "$OUTPUT"

if [ ! -d "$HOME/.remembrall" ]; then
  printf "${GREEN}  PASS${RESET} real run: ~/.remembrall removed\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} real run: ~/.remembrall should be removed\n"
  FAIL=$((FAIL + 1))
fi

if [ ! -f "/tmp/remembrall-nudges/uninstall-test" ]; then
  printf "${GREEN}  PASS${RESET} real run: temp files cleaned\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} real run: temp files should be cleaned\n"
  FAIL=$((FAIL + 1))
fi

# Clean up settings backup
rm -f "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.remembrall-backup"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "Plugin root discovery:"

# remembrall_publish_plugin_root writes to /tmp/remembrall-meta/plugin-root
rm -rf /tmp/remembrall-meta 2>/dev/null
export CLAUDE_PLUGIN_ROOT="/fake/plugin/path"
source "$PLUGIN_ROOT/hooks/lib.sh"
remembrall_publish_plugin_root
PUBLISHED=$(cat /tmp/remembrall-meta/plugin-root 2>/dev/null)
assert_eq "publish_plugin_root writes file" "/fake/plugin/path" "$PUBLISHED"

# remembrall_plugin_root returns env var when set
GOT=$(remembrall_plugin_root)
assert_eq "plugin_root prefers env var" "/fake/plugin/path" "$GOT"

# remembrall_plugin_root falls back to file when env unset
unset CLAUDE_PLUGIN_ROOT
GOT=$(remembrall_plugin_root)
assert_eq "plugin_root falls back to file" "/fake/plugin/path" "$GOT"

# remembrall_plugin_root fails when nothing available
rm -rf /tmp/remembrall-meta 2>/dev/null
GOT=$(remembrall_plugin_root 2>/dev/null) || GOT="FAIL"
assert_eq "plugin_root fails gracefully" "FAIL" "$GOT"

# Clean up
rm -rf /tmp/remembrall-meta 2>/dev/null

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
