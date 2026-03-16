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
  # Pensieve test cleanup
  rm -f /tmp/remembrall-pensieve/test-pensieve-sess.jsonl 2>/dev/null
  rm -f /tmp/remembrall-pensieve/test-pensieve-sess.pos 2>/dev/null
  rm -f /tmp/remembrall-pensieve/test-distill-sess.jsonl 2>/dev/null
  rm -f /tmp/remembrall-pensieve/test-map-sess.jsonl 2>/dev/null
  # Time-Turner test cleanup
  rm -rf /tmp/remembrall-timeturner/test-tt-sess 2>/dev/null
  # Phoenix test cleanup
  rm -rf /tmp/remembrall-phoenix 2>/dev/null
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
assert_match "under .remembrall/handoffs/<project-name>-<hash>" '\.remembrall/handoffs/my-project-[0-9a-f]{8}$' "$DIR"

DIR2=$(remembrall_handoff_dir "/tmp/my-project")
assert_eq "deterministic for same cwd" "$DIR" "$DIR2"

# Normalization: trailing slashes and symlinks should resolve to the same dir
TEST_NORMALIZE_DIR="/tmp/remembrall-normalize-$$/real-project"
TEST_NORMALIZE_LINK="/tmp/remembrall-normalize-$$/linked-project"
mkdir -p "$TEST_NORMALIZE_DIR"
ln -s "$TEST_NORMALIZE_DIR" "$TEST_NORMALIZE_LINK"
DIR_TRAILING=$(remembrall_handoff_dir "$TEST_NORMALIZE_DIR///")
DIR_REAL=$(remembrall_handoff_dir "$TEST_NORMALIZE_DIR")
DIR_LINK=$(remembrall_handoff_dir "$TEST_NORMALIZE_LINK")
assert_eq "trailing slashes normalize before hashing" "$DIR_REAL" "$DIR_TRAILING"
assert_eq "symlink path resolves to same storage dir" "$DIR_REAL" "$DIR_LINK"

# Compatibility: reuse an existing short-hash dir even if the slug changed
COMPAT_HASH=$(remembrall_project_hash "$TEST_NORMALIZE_DIR" | cut -c1-8)
COMPAT_DIR="$HOME/.remembrall/handoffs/alias-${COMPAT_HASH}"
mkdir -p "$COMPAT_DIR"
rm -rf "$DIR_REAL"
DIR_COMPAT=$(remembrall_handoff_dir "$TEST_NORMALIZE_DIR")
assert_eq "existing compatible short-hash dir is reused" "$COMPAT_DIR" "$DIR_COMPAT"
rm -rf "/tmp/remembrall-normalize-$$" "$COMPAT_DIR"

# Collision safety: same basename, different parent
DIR3=$(remembrall_handoff_dir "/work/clientA/api")
DIR4=$(remembrall_handoff_dir "/work/clientB/api")
if [ "$DIR3" != "$DIR4" ]; then
  printf "${GREEN}  PASS${RESET} collision safe: different parents produce different dirs\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} collision safe: different parents produce different dirs\n"
  FAIL=$((FAIL + 1))
  ERRORS="${ERRORS}\n  - collision safe: different parents produce different dirs"
fi

# Edge case: CWD is "." — resolves to actual path, no traversal
DIR_DOT=$(remembrall_handoff_dir ".")
assert_match "dot CWD handled safely" '\.remembrall/handoffs/' "$DIR_DOT"

# ── remembrall_patches_dir ────────────────────────────────────────
echo ""
echo "remembrall_patches_dir:"
PDIR=$(remembrall_patches_dir "/tmp/my-project")
assert_match "under .remembrall/patches/<project-name>-<hash>" '\.remembrall/patches/my-project-[0-9a-f]{8}$' "$PDIR"

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
EXPECTED_TEAM=$(remembrall_handoff_dir "/tmp/my-project")
assert_eq "team dir is centralized (same as personal)" "$EXPECTED_TEAM" "$TDIR"


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

# Force normal mode for these tests (autonomous is default, but normal uses EnterPlanMode)
remembrall_config_set "autonomous_mode" "false" 2>/dev/null

# High context (85%) — should produce no output
echo "85" > "$CTX_DIR/test-sess"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_eq "85% remaining: silent" "" "$OUTPUT"

# 55% — journal checkpoint (threshold default: 65)
echo "55" > "$CTX_DIR/test-sess"
rm -f "/tmp/remembrall-nudges/test-sess"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "55% triggers checkpoint nudge" "REMEMBRALL:.*save progress" "$OUTPUT"
assert_match "55% checkpoint suggests /handoff" "/handoff" "$OUTPUT"

# 55% again — should be suppressed (already nudged)
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_eq "55% second time: suppressed" "" "$OUTPUT"

# 34% — warning: suggests /handoff (threshold default: 35)
echo "34" > "$CTX_DIR/test-sess"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "34% triggers warning" "REMEMBRALL_WARN" "$OUTPUT"
assert_match "34% warning suggests /handoff" "/handoff" "$OUTPUT"

# 34% again — persistent (no handoff yet)
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "34% second time: persistent (no handoff yet)" "REMEMBRALL_WARN" "$OUTPUT"

# 24% — urgent: AK fires (threshold default: 25)
echo "24" > "$CTX_DIR/test-sess"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "24% triggers urgent" "REMEMBRALL_URGENT.*critical" "$OUTPUT"
assert_match "24% urgent invokes avadakedavra" "avadakedavra" "$OUTPUT"
assert_match "24% urgent is BLOCKING" "BLOCKING" "$OUTPUT"

# 24% again — still urgent
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "24% second time: still urgent AK" "avadakedavra" "$OUTPUT"

# Create handoff file — urgent should STILL fire (AK regardless)
HOFF_DIR=$(source "$PLUGIN_ROOT/hooks/lib.sh" && remembrall_handoff_dir "$TEST_CWD")
mkdir -p "$HOFF_DIR"
echo "# handoff" > "$HOFF_DIR/handoff-test-sess.md"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "24% after handoff saved: still fires AK" "REMEMBRALL_URGENT" "$OUTPUT"
rm -f "$HOFF_DIR/handoff-test-sess.md"

# 90% — reset (post-compaction)
echo "90" > "$CTX_DIR/test-sess"
OUTPUT=$(echo '{"session_id":"test-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_eq "90% post-compaction: silent + reset" "" "$OUTPUT"
[ ! -f "/tmp/remembrall-nudges/test-sess" ] && R="cleaned" || R="exists"
assert_eq "nudge file cleaned after reset" "cleaned" "$R"

# Cleanup + restore autonomous default
rm -f "$CTX_DIR/test-sess"
rm -rf "$TEST_CWD"
rm -f "/tmp/remembrall-nudges/test-sess"
remembrall_config_set "autonomous_mode" "true" 2>/dev/null

# ── context-monitor.sh (autonomous vs normal mode) ───────────────
echo ""
echo "context-monitor.sh (autonomous vs normal mode):"

CTX_DIR="/tmp/claude-context-pct"
mkdir -p "$CTX_DIR"
TEST_CWD="/tmp/remembrall-test-auto-$$"
mkdir -p "$TEST_CWD"

# Autonomous mode helpers still work
remembrall_set_autonomous "test-auto-sess" "test-skill"
R=$(remembrall_is_autonomous "test-auto-sess") && STATUS=0 || STATUS=1
assert_eq "autonomous mode set" "0" "$STATUS"
assert_eq "autonomous skill name" "test-skill" "$R"
remembrall_clear_autonomous "test-auto-sess"
R=$(remembrall_is_autonomous "test-auto-sess") && STATUS=0 || STATUS=1
assert_eq "autonomous mode cleared" "1" "$STATUS"

# Autonomous mode (config): warning at 34% — no EnterPlanMode, keep working
remembrall_config_set "autonomous_mode" "true" 2>/dev/null
echo "34" > "$CTX_DIR/test-auto-sess"
rm -f "/tmp/remembrall-nudges/test-auto-sess"
OUTPUT=$(echo '{"session_id":"test-auto-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "34% autonomous: mentions AUTONOMOUS MODE" "AUTONOMOUS MODE" "$OUTPUT"
assert_match "34% autonomous: mentions /handoff" "/handoff" "$OUTPUT"
if echo "$OUTPUT" | grep -q "EnterPlanMode"; then
  printf "${RED}  FAIL${RESET} 34%% autonomous: must NOT mention EnterPlanMode\n"
  FAIL=$((FAIL + 1))
else
  printf "${GREEN}  PASS${RESET} 34%% autonomous: no EnterPlanMode (auto-compaction)\n"
  PASS=$((PASS + 1))
fi

# Autonomous mode: urgent at 24% — same, no EnterPlanMode
echo "24" > "$CTX_DIR/test-auto-sess"
rm -f "/tmp/remembrall-nudges/test-auto-sess"
OUTPUT=$(echo '{"session_id":"test-auto-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "24% autonomous urgent: mentions /handoff NOW" "/handoff NOW" "$OUTPUT"
if echo "$OUTPUT" | grep -q "EnterPlanMode"; then
  printf "${RED}  FAIL${RESET} 24%% autonomous urgent: must NOT mention EnterPlanMode\n"
  FAIL=$((FAIL + 1))
else
  printf "${GREEN}  PASS${RESET} 24%% autonomous urgent: no EnterPlanMode (auto-compaction)\n"
  PASS=$((PASS + 1))
fi

# Normal mode: warning at 34% — suggests /handoff (AK fires at urgent)
remembrall_config_set "autonomous_mode" "false" 2>/dev/null
echo "34" > "$CTX_DIR/test-auto-sess"
rm -f "/tmp/remembrall-nudges/test-auto-sess"
OUTPUT=$(echo '{"session_id":"test-auto-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)
assert_match "34% normal: suggests /handoff" "/handoff" "$OUTPUT"
assert_match "34% normal: mentions AK at urgent" "Avada Kedavra" "$OUTPUT"
assert_match "34% normal: is WARN not URGENT" "REMEMBRALL_WARN" "$OUTPUT"

# Restore default
remembrall_config_set "autonomous_mode" "true" 2>/dev/null

# Cleanup
rm -f "$CTX_DIR/test-auto-sess"
rm -rf "$TEST_CWD"
rm -f "/tmp/remembrall-nudges/test-auto-sess"

# ── session-resume.sh ─────────────────────────────────────────────
echo ""
echo "session-resume.sh:"

# Fresh start — should emit standing instruction
TEST_CWD="/tmp/remembrall-test-resume-$$"
mkdir -p "$TEST_CWD"
OUTPUT=$(echo '{"source":"fresh","session_id":"test-resume","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/session-resume.sh" 2>/dev/null)
assert_match "fresh start: emits standing instruction" "REMEMBRALL ACTIVE" "$OUTPUT"
assert_match "fresh start: uses hookSpecificOutput format" "hookSpecificOutput" "$OUTPUT"

# Compact/clear resume WITHOUT handoff — should still emit standing instruction
COMPACT_CWD="/tmp/remembrall-test-compact-nohoff-$$"
mkdir -p "$COMPACT_CWD"
OUTPUT=$(echo '{"source":"compact","session_id":"test-compact-nohoff","cwd":"'"$COMPACT_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/session-resume.sh" 2>/dev/null)
assert_match "compact without handoff: emits standing instruction" "REMEMBRALL ACTIVE" "$OUTPUT"
rm -rf "$COMPACT_CWD"

# Compact resume with handoff file
HANDOFF_DIR=$(remembrall_handoff_dir "$TEST_CWD")
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

# ── Autopilot resume (autonomous mode) ────────────────────────────
echo ""
echo "Session Autopilot resume:"

TEST_CWD="/tmp/remembrall-test-autopilot-$$"
mkdir -p "$TEST_CWD"
HANDOFF_DIR=$(remembrall_handoff_dir "$TEST_CWD")
mkdir -p "$HANDOFF_DIR"

# Create handoff
cat > "$HANDOFF_DIR/handoff-test-autopilot.md" << 'HEOF'
---
{
  "session_id": "test-autopilot",
  "status": "in_progress"
}
---

# Session Handoff
**Task:** Refactor the parser
HEOF

# Set autonomous mode marker for this session
mkdir -p /tmp/remembrall-autonomous
echo "autopilot-test" > /tmp/remembrall-autonomous/test-autopilot

# Resume in compact mode — should detect autopilot
OUTPUT=$(echo '{"source":"compact","session_id":"test-autopilot","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/session-resume.sh" 2>/dev/null)
assert_match "autopilot resume: tagged AUTOPILOT" "AUTOPILOT" "$OUTPUT"
assert_match "autopilot resume: no ask-to-continue" "START WORKING immediately" "$OUTPUT"
assert_match "autopilot resume: contains task" "Refactor the parser" "$OUTPUT"

# Attended mode — should say "Ask the user"
rm -f /tmp/remembrall-autonomous/test-autopilot
remembrall_config_set "autonomous_mode" "false" 2>/dev/null
HANDOFF_DIR2=$(remembrall_handoff_dir "$TEST_CWD")
cat > "$HANDOFF_DIR2/handoff-test-attended.md" << 'HEOF'
---
{
  "session_id": "test-attended",
  "status": "in_progress"
}
---

# Session Handoff
**Task:** Fix the tests
HEOF

OUTPUT2=$(echo '{"source":"compact","session_id":"test-attended","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/session-resume.sh" 2>/dev/null)
assert_match "attended resume: tagged ATTENDED" "ATTENDED" "$OUTPUT2"
assert_match "attended resume: asks user to continue" "Ask the user" "$OUTPUT2"

# Cleanup — restore autonomous default
remembrall_config_set "autonomous_mode" "true" 2>/dev/null
rm -rf "$TEST_CWD" "$HANDOFF_DIR" "$HANDOFF_DIR2"

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

# Low context, with handoff — confirm auto-resume message via stderr
STOP_HANDOFF_DIR=$(remembrall_handoff_dir "$TEST_CWD")
mkdir -p "$STOP_HANDOFF_DIR"
echo "test" > "$STOP_HANDOFF_DIR/handoff-test-stop-sess.md"
OUTPUT=$(echo '{"session_id":"test-stop-sess","cwd":"'"$TEST_CWD"'"}' | bash "$PLUGIN_ROOT/hooks/stop-check.sh" 2>&1)
assert_match "30% with handoff: confirms auto-resume" "auto-resume" "$OUTPUT"
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
assert_match "path under .remembrall/handoffs/<project>-<hash>" '\.remembrall/handoffs/.*-[0-9a-f]{8}/' "$OUTPUT"

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
rm -rf "$(remembrall_handoff_dir "$TEST_CWD")"
unset CLAUDE_SESSION_ID


# ═══════════════════════════════════════════════════════════════════
echo ""
echo "Edge case tests"
echo "════════════════"

echo ""
echo "Handoff chains (remembrall_previous_session):"
TEST_CWD="/tmp/remembrall-test-chain-$$"
mkdir -p "$TEST_CWD"
CHAIN_DIR=$(remembrall_handoff_dir "$TEST_CWD")
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
HANDOFF_DIR=$(remembrall_handoff_dir "$TEST_CWD")
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
echo "Replay fallback directory scan:"
REPLAY_PARENT="/tmp/remembrall-test-replay-parent-$$"
REPLAY_PROJECT="$REPLAY_PARENT/app"
mkdir -p "$REPLAY_PROJECT"

MATCH_DIR_OLD="$HOME/.remembrall/handoffs/replay-old-11111111"
MATCH_DIR_NEW="$HOME/.remembrall/handoffs/replay-new-22222222"
UNRELATED_DIR="$HOME/.remembrall/handoffs/replay-unrelated-33333333"
mkdir -p "$MATCH_DIR_OLD" "$MATCH_DIR_NEW" "$UNRELATED_DIR"

cat > "$MATCH_DIR_OLD/handoff-old.md" << EOF
---
{
  "project": "$REPLAY_PROJECT"
}
---
# Older matching handoff
EOF
touch -t 202601010101 "$MATCH_DIR_OLD/handoff-old.md"

cat > "$MATCH_DIR_NEW/handoff-new.md" << EOF
---
{
  "project": "$REPLAY_PROJECT/"
}
---
# Newer matching handoff
EOF
touch -t 202601020202 "$MATCH_DIR_NEW/handoff-new.md"

cat > "$UNRELATED_DIR/handoff-other.md" << 'EOF'
---
{
  "project": "/tmp/somewhere-else"
}
---
# Unrelated handoff
EOF

MATCHES=$(remembrall_replay_fallback_dirs "$REPLAY_PARENT")
FIRST_MATCH=$(printf '%s\n' "$MATCHES" | head -1)
MATCH_COUNT=$(printf '%s\n' "$MATCHES" | grep -c . || true)
assert_eq "replay fallback finds newest matching dir first" "$MATCH_DIR_NEW" "$FIRST_MATCH"
assert_eq "replay fallback returns only matching dirs" "2" "$MATCH_COUNT"

rm -rf "$REPLAY_PARENT" "$MATCH_DIR_OLD" "$MATCH_DIR_NEW" "$UNRELATED_DIR"

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
assert_eq "opus max_kb is 1640 (formula-derived)" "1640" "$MAX_KB"

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
    "command": "input=$(cat); session_id=$(echo \"$input\" | jq -r '"'"'.session_id // empty'"'"'); remaining=$(echo \"$input\" | jq -r '"'"'.context_window.remaining_percentage // empty'"'"'); status=\"ctx: ${remaining}%\"; echo \"$status\""
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
    "command": "input=$(cat); remaining=$(echo \"$input\" | jq -r '.context_window.remaining_percentage // empty'); status=\"ctx: ${remaining:-?}%\"; echo \"$status\""
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

R=$(remembrall_threshold "warning" 35)
assert_eq "default warning threshold" "35" "$R"

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
echo "Pensieve & Time-Turner tests"
echo "════════════════════════════"

# ── Pensieve lib.sh functions ─────────────────────────────────────
echo ""
echo "Pensieve: remembrall_pensieve_dir"
echo "──────────────────────────────────"

# remembrall_pensieve_dir produces correct path
PDIR=$(remembrall_pensieve_dir "/tmp/my-project")
assert_match "pensieve dir under .remembrall/pensieve/<name>-<hash>" '\.remembrall/pensieve/my-project-[0-9a-f]{8}$' "$PDIR"

# deterministic
PDIR2=$(remembrall_pensieve_dir "/tmp/my-project")
assert_eq "pensieve dir deterministic" "$PDIR" "$PDIR2"

# collision safe
PDIR3=$(remembrall_pensieve_dir "/work/a/api")
PDIR4=$(remembrall_pensieve_dir "/work/b/api")
if [ "$PDIR3" != "$PDIR4" ]; then
  printf "${GREEN}  PASS${RESET} pensieve dir collision safe\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} pensieve dir collision safe\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve dir collision safe"
fi

# remembrall_pensieve_tmp returns correct path
PTMP=$(remembrall_pensieve_tmp)
assert_eq "pensieve tmp dir" "/tmp/remembrall-pensieve" "$PTMP"

# pensieve dir differs from handoff dir for same CWD
PENSIEVE_D=$(remembrall_pensieve_dir "/tmp/my-project")
HANDOFF_D=$(remembrall_handoff_dir "/tmp/my-project")
if [ "$PENSIEVE_D" != "$HANDOFF_D" ]; then
  printf "${GREEN}  PASS${RESET} pensieve dir differs from handoff dir\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} pensieve dir differs from handoff dir\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve dir differs from handoff dir"
fi

# ── Pensieve config validation ────────────────────────────────────
echo ""
echo "Pensieve: config validation"
echo "───────────────────────────"

# pensieve boolean validation
remembrall_config_validate "pensieve" "true" 2>/dev/null && assert_eq "pensieve=true valid" "0" "0" || assert_eq "pensieve=true valid" "0" "1"
remembrall_config_validate "pensieve" "false" 2>/dev/null && assert_eq "pensieve=false valid" "0" "0" || assert_eq "pensieve=false valid" "0" "1"
remembrall_config_validate "pensieve" "maybe" 2>/dev/null && assert_eq "pensieve=maybe invalid" "1" "0" || assert_eq "pensieve=maybe invalid" "0" "0"

# pensieve_max_sessions positive integer validation
remembrall_config_validate "pensieve_max_sessions" "3" 2>/dev/null && assert_eq "pensieve_max_sessions=3 valid" "0" "0" || assert_eq "pensieve_max_sessions=3 valid" "0" "1"
remembrall_config_validate "pensieve_max_sessions" "0" 2>/dev/null && assert_eq "pensieve_max_sessions=0 invalid" "1" "0" || assert_eq "pensieve_max_sessions=0 invalid" "0" "0"

# pensieve_inject_budget
remembrall_config_validate "pensieve_inject_budget" "2000" 2>/dev/null && assert_eq "inject_budget=2000 valid" "0" "0" || assert_eq "inject_budget=2000 valid" "0" "1"

# ── Time-Turner config validation ─────────────────────────────────
echo ""
echo "Time-Turner: config validation"
echo "──────────────────────────────"

# time_turner boolean
remembrall_config_validate "time_turner" "true" 2>/dev/null && assert_eq "time_turner=true valid" "0" "0" || assert_eq "time_turner=true valid" "0" "1"
remembrall_config_validate "time_turner" "false" 2>/dev/null && assert_eq "time_turner=false valid" "0" "0" || assert_eq "time_turner=false valid" "0" "1"
remembrall_config_validate "time_turner" "yes" 2>/dev/null && assert_eq "time_turner=yes invalid" "1" "0" || assert_eq "time_turner=yes invalid" "0" "0"

# time_turner_model
remembrall_config_validate "time_turner_model" "sonnet" 2>/dev/null && assert_eq "model=sonnet valid" "0" "0" || assert_eq "model=sonnet valid" "0" "1"
remembrall_config_validate "time_turner_model" "opus" 2>/dev/null && assert_eq "model=opus valid" "0" "0" || assert_eq "model=opus valid" "0" "1"
remembrall_config_validate "time_turner_model" "haiku" 2>/dev/null && assert_eq "model=haiku valid" "0" "0" || assert_eq "model=haiku valid" "0" "1"
remembrall_config_validate "time_turner_model" "gpt4" 2>/dev/null && assert_eq "model=gpt4 invalid" "1" "0" || assert_eq "model=gpt4 invalid" "0" "0"

# time_turner_max_budget_usd
remembrall_config_validate "time_turner_max_budget_usd" "1.00" 2>/dev/null && assert_eq "budget=1.00 valid" "0" "0" || assert_eq "budget=1.00 valid" "0" "1"
remembrall_config_validate "time_turner_max_budget_usd" "0.50" 2>/dev/null && assert_eq "budget=0.50 valid" "0" "0" || assert_eq "budget=0.50 valid" "0" "1"
remembrall_config_validate "time_turner_max_budget_usd" "abc" 2>/dev/null && assert_eq "budget=abc invalid" "1" "0" || assert_eq "budget=abc invalid" "0" "0"

# threshold_timeturner
remembrall_config_validate "threshold_timeturner" "30" 2>/dev/null && assert_eq "threshold_tt=30 valid" "0" "0" || assert_eq "threshold_tt=30 valid" "0" "1"
remembrall_config_validate "threshold_timeturner" "0" 2>/dev/null && assert_eq "threshold_tt=0 invalid" "1" "0" || assert_eq "threshold_tt=0 invalid" "0" "0"
remembrall_config_validate "threshold_timeturner" "100" 2>/dev/null && assert_eq "threshold_tt=100 invalid" "1" "0" || assert_eq "threshold_tt=100 invalid" "0" "0"

# ── Pensieve track script ─────────────────────────────────────────
echo ""
echo "Pensieve: pensieve-track.sh"
echo "───────────────────────────"

PENSIEVE_TRACK_CWD="/tmp/remembrall-pensieve-track-test-$$"
mkdir -p "$PENSIEVE_TRACK_CWD"

# Create a mock transcript in the real Claude Code JSONL format
PENSIEVE_TRANSCRIPT="$TMPDIR_ROOT/pensieve-track-transcript.jsonl"
cat > "$PENSIEVE_TRANSCRIPT" << 'PTEOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"Read","input":{"file_path":"/tmp/test/foo.ts"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"file contents here"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu2","name":"Edit","input":{"file_path":"/tmp/test/bar.ts","old_string":"a","new_string":"b"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu2","content":"edited"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu3","name":"Bash","input":{"command":"npm test"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu3","content":"Exit code: 0\nAll tests passed"}]}}
PTEOF

# Run pensieve-track.sh
echo '{"session_id":"test-pensieve-sess","cwd":"'"$PENSIEVE_TRACK_CWD"'","transcript_path":"'"$PENSIEVE_TRANSCRIPT"'"}' \
  | bash "$PLUGIN_ROOT/hooks/pensieve-track.sh" 2>/dev/null || true

# Check that JSONL output file was created
PENSIEVE_OUT="/tmp/remembrall-pensieve/test-pensieve-sess.jsonl"
if [ -f "$PENSIEVE_OUT" ]; then
  printf "${GREEN}  PASS${RESET} pensieve-track: JSONL output file created\n"; PASS=$((PASS+1))
else
  TRACK_ERR_MSG=$(cat "$PENSIEVE_TRACK_ERR" 2>/dev/null | head -3 | tr '\n' '|') || TRACK_ERR_MSG=""
  printf "${RED}  FAIL${RESET} pensieve-track: JSONL output file not created\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve-track: JSONL output file created"
fi

# Verify file paths present in output
if [ -f "$PENSIEVE_OUT" ]; then
  if jq -e '.files | has("/tmp/test/foo.ts")' "$PENSIEVE_OUT" >/dev/null 2>&1; then
    printf "${GREEN}  PASS${RESET} pensieve-track: Read file path recorded\n"; PASS=$((PASS+1))
  else
    printf "${RED}  FAIL${RESET} pensieve-track: Read file path not found\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve-track: Read file path recorded"
  fi

  if jq -e '.files["/tmp/test/bar.ts"] == "E"' "$PENSIEVE_OUT" >/dev/null 2>&1; then
    printf "${GREEN}  PASS${RESET} pensieve-track: Edit file tagged E\n"; PASS=$((PASS+1))
  else
    printf "${RED}  FAIL${RESET} pensieve-track: Edit file not tagged E\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve-track: Edit file tagged E"
  fi

  # Verify command present
  if jq -e '.cmds | index("npm test")' "$PENSIEVE_OUT" >/dev/null 2>&1; then
    printf "${GREEN}  PASS${RESET} pensieve-track: Bash command recorded\n"; PASS=$((PASS+1))
  else
    printf "${RED}  FAIL${RESET} pensieve-track: Bash command not found\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve-track: Bash command recorded"
  fi
else
  FAIL=$((FAIL+3)); ERRORS="${ERRORS}\n  - pensieve-track: Read file path recorded\n  - pensieve-track: Edit file tagged E\n  - pensieve-track: Bash command recorded"
fi

# Idempotency: run again with same transcript — no new content → no new entry
ENTRY_COUNT_BEFORE=$([ -f "$PENSIEVE_OUT" ] && wc -l "$PENSIEVE_OUT" | tr -d '[:alpha:] ' | tr -d '/' || echo "0") || ENTRY_COUNT_BEFORE=0
# Trim to just the number
ENTRY_COUNT_BEFORE=$(printf '%s' "$ENTRY_COUNT_BEFORE" | tr -d ' ' | grep -oE '^[0-9]+' || echo "0")
echo '{"session_id":"test-pensieve-sess","cwd":"'"$PENSIEVE_TRACK_CWD"'","transcript_path":"'"$PENSIEVE_TRANSCRIPT"'"}' \
  | bash "$PLUGIN_ROOT/hooks/pensieve-track.sh" 2>/dev/null || true
ENTRY_COUNT_AFTER=$([ -f "$PENSIEVE_OUT" ] && wc -l "$PENSIEVE_OUT" | tr -d '[:alpha:] ' | tr -d '/' || echo "0") || ENTRY_COUNT_AFTER=0
ENTRY_COUNT_AFTER=$(printf '%s' "$ENTRY_COUNT_AFTER" | tr -d ' ' | grep -oE '^[0-9]+' || echo "0")
assert_eq "pensieve-track: idempotent (no new entry for same content)" "$ENTRY_COUNT_BEFORE" "$ENTRY_COUNT_AFTER"

# Add new content to transcript and run again — entry count should increase
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu4","name":"Bash","input":{"command":"npm run build"}}]}}' >> "$PENSIEVE_TRANSCRIPT"
echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu4","content":"Exit code: 0\nbuild complete"}]}}' >> "$PENSIEVE_TRANSCRIPT"
echo '{"session_id":"test-pensieve-sess","cwd":"'"$PENSIEVE_TRACK_CWD"'","transcript_path":"'"$PENSIEVE_TRANSCRIPT"'"}' \
  | bash "$PLUGIN_ROOT/hooks/pensieve-track.sh" 2>/dev/null || true
ENTRY_COUNT_NEW=$([ -f "$PENSIEVE_OUT" ] && wc -l "$PENSIEVE_OUT" | tr -d '[:alpha:] ' | tr -d '/' || echo "0") || ENTRY_COUNT_NEW=0
ENTRY_COUNT_NEW=$(printf '%s' "$ENTRY_COUNT_NEW" | tr -d ' ' | grep -oE '^[0-9]+' || echo "0")
if [ "${ENTRY_COUNT_NEW:-0}" -gt "${ENTRY_COUNT_BEFORE:-0}" ]; then
  printf "${GREEN}  PASS${RESET} pensieve-track: new content appends new entry\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} pensieve-track: new content should append entry (before=%s after=%s)\n" "$ENTRY_COUNT_BEFORE" "$ENTRY_COUNT_NEW"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve-track: new content appends new entry"
fi

rm -rf "$PENSIEVE_TRACK_CWD"

# ── Pensieve distill script ───────────────────────────────────────
echo ""
echo "Pensieve: pensieve-distill.sh"
echo "─────────────────────────────"

PENSIEVE_DISTILL_CWD="/tmp/remembrall-pensieve-distill-test-$$"
mkdir -p "$PENSIEVE_DISTILL_CWD"

# Create a JSONL file for distillation
mkdir -p /tmp/remembrall-pensieve
DISTILL_JSONL="/tmp/remembrall-pensieve/test-distill-sess.jsonl"
cat > "$DISTILL_JSONL" << 'DJEOF'
{"ts":1700000000,"files":{"/tmp/test/src.ts":"R","/tmp/test/lib.ts":"E"},"cmds":["npm test","npm run build"],"errors":["Error: cannot find module","Exit code: 1\nfailure"],"exits":{"npm test":0,"npm run build":0}}
{"ts":1700000100,"files":{"/tmp/test/src.ts":"E"},"cmds":["npm test"],"errors":[],"exits":{"npm test":0}}
DJEOF

DISTILL_OUT=$(bash "$PLUGIN_ROOT/hooks/pensieve-distill.sh" "test-distill-sess" "$PENSIEVE_DISTILL_CWD" 2>/dev/null) || DISTILL_OUT=""

# Verify JSON has required top-level fields
if echo "$DISTILL_OUT" | jq -e '.version' >/dev/null 2>&1; then
  printf "${GREEN}  PASS${RESET} pensieve-distill: output has version\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} pensieve-distill: output missing version\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve-distill: output has version"
fi

if echo "$DISTILL_OUT" | jq -e '.session_id == "test-distill-sess"' >/dev/null 2>&1; then
  printf "${GREEN}  PASS${RESET} pensieve-distill: session_id correct\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} pensieve-distill: session_id incorrect\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve-distill: session_id correct"
fi

if echo "$DISTILL_OUT" | jq -e '.files and .commands and .errors and .patterns' >/dev/null 2>&1; then
  printf "${GREEN}  PASS${RESET} pensieve-distill: has files, commands, errors, patterns\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} pensieve-distill: missing required output fields\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve-distill: has files, commands, errors, patterns"
fi

# Verify read/edit counts for /tmp/test/src.ts (1 R + 1 E = reads:1, edits:1)
if echo "$DISTILL_OUT" | jq -e '.files["/tmp/test/src.ts"].reads == 1 and .files["/tmp/test/src.ts"].edits == 1' >/dev/null 2>&1; then
  printf "${GREEN}  PASS${RESET} pensieve-distill: file read/edit counts correct\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} pensieve-distill: file read/edit counts wrong\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve-distill: file read/edit counts correct"
fi

# Verify error resolution heuristic: second row has no errors → first error should be resolved
if echo "$DISTILL_OUT" | jq -e '[.errors[] | select(.resolved == true)] | length > 0' >/dev/null 2>&1; then
  printf "${GREEN}  PASS${RESET} pensieve-distill: error resolved heuristic works\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} pensieve-distill: error resolved heuristic failed\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve-distill: error resolved heuristic works"
fi

# Verify persistence file was created in ~/.remembrall/pensieve/
PERSIST_DIR=$(remembrall_pensieve_dir "$PENSIEVE_DISTILL_CWD")
PERSIST_FILE="$PERSIST_DIR/session-test-distill-sess.json"
if [ -f "$PERSIST_FILE" ]; then
  printf "${GREEN}  PASS${RESET} pensieve-distill: persistence file created\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} pensieve-distill: persistence file not found at %s\n" "$PERSIST_FILE"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve-distill: persistence file created"
fi

# Verify empty JSONL returns exit 1
EMPTY_JSONL="$TMPDIR_ROOT/empty-distill.jsonl"
touch "$EMPTY_JSONL"
# pensieve-distill reads from fixed path /tmp/remembrall-pensieve/<session_id>.jsonl
# so test with a session that has no JSONL file
bash "$PLUGIN_ROOT/hooks/pensieve-distill.sh" "no-such-sess-$$" "$PENSIEVE_DISTILL_CWD" 2>/dev/null && EMPTY_STATUS=0 || EMPTY_STATUS=1
assert_eq "pensieve-distill: missing JSONL returns exit 1" "1" "$EMPTY_STATUS"

rm -rf "$PENSIEVE_DISTILL_CWD"

# ── Pensieve inject script ────────────────────────────────────────
echo ""
echo "Pensieve: pensieve-inject.sh"
echo "─────────────────────────────"

PENSIEVE_INJECT_CWD="/tmp/remembrall-pensieve-inject-test-$$"
mkdir -p "$PENSIEVE_INJECT_CWD"

# Create mock session JSON files in the pensieve dir for the test CWD
INJECT_PENSIEVE_DIR=$(remembrall_pensieve_dir "$PENSIEVE_INJECT_CWD")
mkdir -p "$INJECT_PENSIEVE_DIR"

cat > "$INJECT_PENSIEVE_DIR/session-inject-sess1.json" << 'IJEOF'
{
  "version": 1,
  "session_id": "inject-sess1",
  "project": "/tmp/inject-test",
  "distilled_at": "2026-03-10T12:00:00Z",
  "files": {
    "/tmp/inject-test/app.ts": {"reads": 2, "edits": 1},
    "/tmp/inject-test/lib.ts": {"reads": 1, "edits": 0}
  },
  "commands": [
    {"cmd": "npm test", "exit": 0, "ts": 1700000000},
    {"cmd": "npm run build", "exit": 0, "ts": 1700000100}
  ],
  "errors": [{"text": "Error: module not found", "resolved": true}],
  "patterns": {
    "test_fix_cycles": 1,
    "dominant_activity": "editing",
    "unique_files": 2,
    "total_commands": 2,
    "total_errors": 1,
    "resolved_errors": 1
  }
}
IJEOF

INJECT_OUT=$(bash "$PLUGIN_ROOT/hooks/pensieve-inject.sh" "$PENSIEVE_INJECT_CWD" 2>/dev/null) || INJECT_OUT=""

# Verify output starts with PENSIEVE MEMORY
assert_match "pensieve-inject: output starts with PENSIEVE MEMORY" "^PENSIEVE MEMORY:" "$INJECT_OUT"

# Verify file names appear
assert_match "pensieve-inject: includes file names" "app\.ts" "$INJECT_OUT"

# Verify command names appear
assert_match "pensieve-inject: includes command names" "npm" "$INJECT_OUT"

# Verify budget truncation: pass tiny budget
INJECT_TINY=$(bash "$PLUGIN_ROOT/hooks/pensieve-inject.sh" "$PENSIEVE_INJECT_CWD" 100 2>/dev/null) || INJECT_TINY=""
if [ "${#INJECT_TINY}" -le 103 ]; then
  printf "${GREEN}  PASS${RESET} pensieve-inject: budget truncation works (len=%d)\n" "${#INJECT_TINY}"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} pensieve-inject: budget truncation failed (len=%d, expected ≤103)\n" "${#INJECT_TINY}"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve-inject: budget truncation works"
fi

# Verify exit 1 when no data exists
MISSING_CWD="/tmp/remembrall-inject-missing-$$"
bash "$PLUGIN_ROOT/hooks/pensieve-inject.sh" "$MISSING_CWD" 2>/dev/null && INJECT_MISSING_STATUS=0 || INJECT_MISSING_STATUS=1
assert_eq "pensieve-inject: exit 1 when no data" "1" "$INJECT_MISSING_STATUS"

# Verify sessions count in header
assert_match "pensieve-inject: sessions count in header" "sessions=1" "$INJECT_OUT"

rm -rf "$PENSIEVE_INJECT_CWD"

# ── Time-Turner check script ──────────────────────────────────────
echo ""
echo "Time-Turner: time-turner-check.sh"
echo "──────────────────────────────────"

TT_BASE="/tmp/remembrall-timeturner"

# Verify exit 1 when no Time-Turner dir exists
rm -rf "$TT_BASE/test-tt-sess" 2>/dev/null
if [ ! -d "$TT_BASE" ]; then
  bash "$PLUGIN_ROOT/hooks/time-turner-check.sh" "/tmp" 2>/dev/null && TT_NO_DIR_STATUS=0 || TT_NO_DIR_STATUS=1
  assert_eq "time-turner-check: exit 1 when no base dir" "1" "$TT_NO_DIR_STATUS"
fi

# Create mock state dir with completed status
mkdir -p "$TT_BASE/test-tt-sess"
echo "completed" > "$TT_BASE/test-tt-sess/status"
echo "3" > "$TT_BASE/test-tt-sess/files_changed"
STARTED_TS=$(date +%s)
echo "$STARTED_TS" > "$TT_BASE/test-tt-sess/started"
FINISHED_TS=$(( STARTED_TS + 120 ))
echo "$FINISHED_TS" > "$TT_BASE/test-tt-sess/finished"

TT_OUT=$(bash "$PLUGIN_ROOT/hooks/time-turner-check.sh" "/tmp" 2>/dev/null) || TT_OUT=""
assert_match "time-turner-check: completed status" "Time-Turner finished" "$TT_OUT"
assert_match "time-turner-check: files changed count" "3 files" "$TT_OUT"

# Test running status
echo "running" > "$TT_BASE/test-tt-sess/status"
# Use a PID that definitely exists (current shell)
echo "$$" > "$TT_BASE/test-tt-sess/pid"

TT_OUT2=$(bash "$PLUGIN_ROOT/hooks/time-turner-check.sh" "/tmp" 2>/dev/null) || TT_OUT2=""
assert_match "time-turner-check: running status" "still working" "$TT_OUT2"

# Test failed status
echo "failed" > "$TT_BASE/test-tt-sess/status"
echo "compilation error" > "$TT_BASE/test-tt-sess/error.log"
TT_OUT3=$(bash "$PLUGIN_ROOT/hooks/time-turner-check.sh" "/tmp" 2>/dev/null) || TT_OUT3=""
assert_match "time-turner-check: failed status" "Time-Turner failed" "$TT_OUT3"

# Verify auto-cleanup of >24h entries
OLD_STARTED=$(( $(date +%s) - 90000 ))  # 25h ago
echo "completed" > "$TT_BASE/test-tt-sess/status"
echo "$OLD_STARTED" > "$TT_BASE/test-tt-sess/started"

bash "$PLUGIN_ROOT/hooks/time-turner-check.sh" "/tmp" 2>/dev/null && TT_STALE_STATUS=0 || TT_STALE_STATUS=1
# Entry should be cleaned up → exit 1 (no active entries)
assert_eq "time-turner-check: stale entry auto-cleaned (exit 1)" "1" "$TT_STALE_STATUS"

if [ ! -d "$TT_BASE/test-tt-sess" ]; then
  printf "${GREEN}  PASS${RESET} time-turner-check: stale dir removed\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} time-turner-check: stale dir should be removed\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - time-turner-check: stale dir removed"
  rm -rf "$TT_BASE/test-tt-sess"
fi

# ── Map script ────────────────────────────────────────────────────
echo ""
echo "Map: remembrall-map.sh"
echo "──────────────────────"

MAP_CWD="/tmp/remembrall-map-test-$$"
mkdir -p "$MAP_CWD"

# Set up session JSONL so the map has data to display
mkdir -p /tmp/remembrall-pensieve
MAP_JSONL="/tmp/remembrall-pensieve/test-map-sess.jsonl"
echo '{"ts":1700000000,"files":{"/tmp/map-test/main.ts":"E","/tmp/map-test/util.ts":"R"},"cmds":["npm test"],"errors":[],"exits":{"npm test":0}}' > "$MAP_JSONL"

# Publish a session_id for the MAP_CWD so the map can find the JSONL
remembrall_publish_session_id "$MAP_CWD" "test-map-sess"

# Disable easter eggs to get clean output (avoid ANSI noise in matching)
remembrall_config_set "easter_eggs" "false" 2>/dev/null

MAP_OUT=$(bash "$PLUGIN_ROOT/scripts/remembrall-map.sh" "$MAP_CWD" 2>/dev/null) || MAP_OUT=""

# Verify output contains Marauder's Map header
assert_match "map: contains Marauder's Map header" "Marauder" "$MAP_OUT"

# Verify it shows files section
assert_match "map: shows Files Explored section" "Files Explored" "$MAP_OUT"

# Verify it shows commands section
assert_match "map: shows Commands Run section" "Commands Run" "$MAP_OUT"

# Clean up
rm -rf "$MAP_CWD"
rm -f /tmp/remembrall-pensieve/test-map-sess.jsonl
BRIDGE_MAP_HASH=$(remembrall_md5 "$MAP_CWD" 2>/dev/null) || true
rm -f "/tmp/remembrall-sessions/$BRIDGE_MAP_HASH" 2>/dev/null || true
rm -f "$HOME/.remembrall/config.json" 2>/dev/null || true

# ── Integration: context-monitor Pensieve spawn ───────────────────
echo ""
echo "Integration: context-monitor Pensieve spawn"
echo "────────────────────────────────────────────"

CTX_DIR="/tmp/claude-context-pct"
mkdir -p "$CTX_DIR"
PENSIEVE_SPAWN_CWD="/tmp/remembrall-pensieve-spawn-$$"
mkdir -p "$PENSIEVE_SPAWN_CWD"

# Create a small transcript for track to process
SPAWN_TRANSCRIPT="$TMPDIR_ROOT/pensieve-spawn-transcript.jsonl"
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"ts1","name":"Read","input":{"file_path":"/tmp/spawn/file.ts"}}]}}' > "$SPAWN_TRANSCRIPT"
echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"ts1","content":"ok"}]}}' >> "$SPAWN_TRANSCRIPT"

# pensieve=true: verify track is spawned (bridge at 85% → silent, but track should run)
remembrall_config_set "pensieve" "true" 2>/dev/null
echo "85" > "$CTX_DIR/test-pensieve-spawn-sess"

# Give pensieve-track.sh a moment since it's spawned in background
echo '{"session_id":"test-pensieve-spawn-sess","cwd":"'"$PENSIEVE_SPAWN_CWD"'","transcript_path":"'"$SPAWN_TRANSCRIPT"'"}' \
  | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null || true
sleep 1

if [ -f "/tmp/remembrall-pensieve/test-pensieve-spawn-sess.jsonl" ]; then
  printf "${GREEN}  PASS${RESET} pensieve=true: track spawned and created JSONL\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} pensieve=true: track JSONL not created\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve=true: track spawned and created JSONL"
fi

# pensieve=false: verify track is NOT spawned
remembrall_config_set "pensieve" "false" 2>/dev/null
rm -f "/tmp/remembrall-pensieve/test-pensieve-skip-sess.jsonl"

SKIP_TRANSCRIPT="$TMPDIR_ROOT/pensieve-skip-transcript.jsonl"
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"sk1","name":"Read","input":{"file_path":"/tmp/skip/file.ts"}}]}}' > "$SKIP_TRANSCRIPT"
echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"sk1","content":"ok"}]}}' >> "$SKIP_TRANSCRIPT"

echo "85" > "$CTX_DIR/test-pensieve-skip-sess"
echo '{"session_id":"test-pensieve-skip-sess","cwd":"'"$PENSIEVE_SPAWN_CWD"'","transcript_path":"'"$SKIP_TRANSCRIPT"'"}' \
  | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null || true
sleep 1

if [ ! -f "/tmp/remembrall-pensieve/test-pensieve-skip-sess.jsonl" ]; then
  printf "${GREEN}  PASS${RESET} pensieve=false: track skipped (no JSONL created)\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} pensieve=false: track should be skipped\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - pensieve=false: track skipped (no JSONL created)"
fi

# Restore defaults
rm -f "$CTX_DIR/test-pensieve-spawn-sess" "$CTX_DIR/test-pensieve-skip-sess"
rm -f "/tmp/remembrall-pensieve/test-pensieve-spawn-sess.jsonl" 2>/dev/null || true
rm -f "/tmp/remembrall-pensieve/test-pensieve-skip-sess.jsonl" 2>/dev/null || true
rm -rf "$PENSIEVE_SPAWN_CWD"
remembrall_config_set "pensieve" "true" 2>/dev/null
rm -f "$HOME/.remembrall/config.json" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════

echo ""
echo "v3.0.0 New Feature tests"
echo "════════════════════════"

# ── Phase 1: Session Lineage ──────────────────────────────────────
echo ""
echo "Session Lineage: lib.sh functions"
echo "──────────────────────────────────"

# remembrall_lineage_dir
LDIR=$(remembrall_lineage_dir "/tmp/my-project")
assert_match "lineage dir under .remembrall/lineage/<name>-<hash>" '\.remembrall/lineage/my-project-[0-9a-f]{8}$' "$LDIR"

LDIR2=$(remembrall_lineage_dir "/tmp/my-project")
assert_eq "lineage dir deterministic" "$LDIR" "$LDIR2"

LDIR3=$(remembrall_lineage_dir "/tmp/other-project")
if [ "$LDIR" != "$LDIR3" ]; then
  printf "${GREEN}  PASS${RESET} lineage dir collision safe\n"; PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} lineage dir collision safe\n"; FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  - lineage dir collision safe"
fi

# remembrall_lineage_record + lineage_depth + lineage_branches
LINEAGE_CWD="$TMPDIR_ROOT/lineage-test-project"
mkdir -p "$LINEAGE_CWD"

remembrall_lineage_record "sess-root" "" "$LINEAGE_CWD" "normal" "completed" "Initial work" 5
LINEAGE_INDEX=$(remembrall_lineage_dir "$LINEAGE_CWD")/index.json
if [ -f "$LINEAGE_INDEX" ]; then
  printf "${GREEN}  PASS${RESET} lineage record creates index.json\n"; PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} lineage record creates index.json\n"; FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  - lineage record creates index.json"
fi

L_COUNT=$(jq '.sessions | length' "$LINEAGE_INDEX" 2>/dev/null) || L_COUNT=0
assert_eq "lineage index has 1 session" "1" "$L_COUNT"

L_SID=$(jq -r '.sessions[0].session_id' "$LINEAGE_INDEX" 2>/dev/null)
assert_eq "lineage session_id correct" "sess-root" "$L_SID"

L_TYPE=$(jq -r '.sessions[0].type' "$LINEAGE_INDEX" 2>/dev/null)
assert_eq "lineage type correct" "normal" "$L_TYPE"

# Add child session
remembrall_lineage_record "sess-child" "sess-root" "$LINEAGE_CWD" "normal" "active" "Continue work" 3
L_COUNT=$(jq '.sessions | length' "$LINEAGE_INDEX" 2>/dev/null) || L_COUNT=0
assert_eq "lineage index has 2 sessions" "2" "$L_COUNT"

# Depth
DEPTH=$(remembrall_lineage_depth "$LINEAGE_CWD" "sess-child")
assert_eq "lineage depth for child is 1" "1" "$DEPTH"

DEPTH_ROOT=$(remembrall_lineage_depth "$LINEAGE_CWD" "sess-root")
assert_eq "lineage depth for root is 0" "0" "$DEPTH_ROOT"

# Add TT branch
remembrall_lineage_record "sess-tt" "sess-root" "$LINEAGE_CWD" "time-turner" "merged" "TT branch" 2

# Branches
BRANCHES=$(remembrall_lineage_branches "$LINEAGE_CWD")
assert_eq "lineage branches detects 1 branching parent" "1" "$BRANCHES"

# Update existing session (should update, not duplicate)
remembrall_lineage_record "sess-root" "" "$LINEAGE_CWD" "normal" "completed" "Updated goal" 10
L_COUNT=$(jq '.sessions | length' "$LINEAGE_INDEX" 2>/dev/null) || L_COUNT=0
assert_eq "lineage update doesn't duplicate" "3" "$L_COUNT"

L_GOAL=$(jq -r '.sessions[] | select(.session_id == "sess-root") | .goal' "$LINEAGE_INDEX" 2>/dev/null)
assert_eq "lineage update changes goal" "Updated goal" "$L_GOAL"

# Lineage disabled
remembrall_config_set "lineage" "false" 2>/dev/null
remembrall_lineage_record "sess-disabled" "" "$LINEAGE_CWD" "normal" "active" "Should not record" 1
L_COUNT=$(jq '.sessions | length' "$LINEAGE_INDEX" 2>/dev/null) || L_COUNT=0
assert_eq "lineage disabled: no new record" "3" "$L_COUNT"
remembrall_config_set "lineage" "true" 2>/dev/null

# remembrall-lineage.sh script
echo ""
echo "Session Lineage: lineage script"
echo "────────────────────────────────"
LINEAGE_OUTPUT=$(bash "$PLUGIN_ROOT/scripts/remembrall-lineage.sh" "$LINEAGE_CWD" 2>/dev/null)
assert_match "lineage script has header" "Session Ancestry|Session Lineage" "$LINEAGE_OUTPUT"
assert_match "lineage script shows session count" "Sessions: 3" "$LINEAGE_OUTPUT"
assert_match "lineage script shows root session" "sess-root" "$LINEAGE_OUTPUT"
assert_match "lineage script shows TT branch" "TT" "$LINEAGE_OUTPUT"

# lineage-record.sh hook
echo ""
echo "Session Lineage: lineage-record.sh hook"
echo "─────────────────────────────────────────"
LINEAGE_HOOK_CWD="$TMPDIR_ROOT/lineage-hook-test"
mkdir -p "$LINEAGE_HOOK_CWD"
jq -n --arg sid "hook-sess" --arg cwd "$LINEAGE_HOOK_CWD" --arg type "normal" --arg status "active" \
  '{session_id: $sid, cwd: $cwd, type: $type, status: $status, goal: "hook test", files_count: 1}' | \
  bash "$PLUGIN_ROOT/hooks/lineage-record.sh" 2>/dev/null
HOOK_INDEX=$(remembrall_lineage_dir "$LINEAGE_HOOK_CWD")/index.json
if [ -f "$HOOK_INDEX" ]; then
  HOOK_SID=$(jq -r '.sessions[0].session_id' "$HOOK_INDEX" 2>/dev/null)
  assert_eq "lineage hook records session" "hook-sess" "$HOOK_SID"
else
  printf "${RED}  FAIL${RESET} lineage hook records session\n"; FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  - lineage hook records session"
fi

# lineage config validation
echo ""
echo "Session Lineage: config validation"
echo "────────────────────────────────────"
remembrall_config_set "lineage" "true" 2>/dev/null && { printf "${GREEN}  PASS${RESET} lineage=true valid\n"; PASS=$((PASS+1)); } || { printf "${RED}  FAIL${RESET} lineage=true valid\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - lineage=true valid"; }
remembrall_config_set "lineage" "false" 2>/dev/null && { printf "${GREEN}  PASS${RESET} lineage=false valid\n"; PASS=$((PASS+1)); } || { printf "${RED}  FAIL${RESET} lineage=false valid\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - lineage=false valid"; }
remembrall_config_set "lineage_max_entries" "50" 2>/dev/null && { printf "${GREEN}  PASS${RESET} lineage_max_entries=50 valid\n"; PASS=$((PASS+1)); } || { printf "${RED}  FAIL${RESET} lineage_max_entries=50 valid\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - lineage_max_entries=50 valid"; }
# Cleanup
rm -f "$HOME/.remembrall/config.json" 2>/dev/null || true

# ── Phase 2: Ambient Learning / Insights ─────────────────────────
echo ""
echo "Insights: lib.sh functions"
echo "──────────────────────────"

# remembrall_insights_dir
IDIR=$(remembrall_insights_dir "/tmp/my-project")
assert_match "insights dir under .remembrall/insights/<name>-<hash>" '\.remembrall/insights/my-project-[0-9a-f]{8}$' "$IDIR"

IDIR2=$(remembrall_insights_dir "/tmp/my-project")
assert_eq "insights dir deterministic" "$IDIR" "$IDIR2"

# remembrall_insights_fresh
INSIGHTS_CWD="$TMPDIR_ROOT/insights-test-project"
mkdir -p "$INSIGHTS_CWD"
INSIGHTS_TEST_DIR=$(remembrall_insights_dir "$INSIGHTS_CWD")
mkdir -p "$INSIGHTS_TEST_DIR"

# No file = not fresh
if remembrall_insights_fresh "$INSIGHTS_CWD" 2>/dev/null; then
  printf "${RED}  FAIL${RESET} insights_fresh returns false when no file\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - insights_fresh returns false when no file"
else
  printf "${GREEN}  PASS${RESET} insights_fresh returns false when no file\n"; PASS=$((PASS+1))
fi

# Fresh file = fresh
echo '{}' > "$INSIGHTS_TEST_DIR/insights.json"
if remembrall_insights_fresh "$INSIGHTS_CWD" 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} insights_fresh returns true for fresh file\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} insights_fresh returns true for fresh file\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - insights_fresh returns true for fresh file"
fi

# insights-aggregate.sh
echo ""
echo "Insights: insights-aggregate.sh"
echo "────────────────────────────────"
INSIGHTS_AGG_CWD="$TMPDIR_ROOT/insights-agg-project"
mkdir -p "$INSIGHTS_AGG_CWD"
PENSIEVE_AGG_DIR=$(remembrall_pensieve_dir "$INSIGHTS_AGG_CWD")
mkdir -p "$PENSIEVE_AGG_DIR"

# Create 3 fake Pensieve sessions
for i in 1 2 3; do
  cat > "$PENSIEVE_AGG_DIR/session-test-${i}.json" << PENS_EOF
{
  "version": 1,
  "session_id": "test-${i}",
  "files": {"src/app.ts": {"reads": $i, "edits": 1}, "src/lib.ts": {"reads": 1, "edits": 0}},
  "commands": ["npm test", "npm build"],
  "errors": ["Error: module not found"],
  "patterns": {"test_fix_cycles": [{"test": "fail", "fix": "pass"}], "dominant_activity": "coding"}
}
PENS_EOF
done

# Remove old insights so aggregator runs fresh
rm -f "$(remembrall_insights_dir "$INSIGHTS_AGG_CWD")/insights.json" 2>/dev/null

bash "$PLUGIN_ROOT/hooks/insights-aggregate.sh" "$INSIGHTS_AGG_CWD" 2>/dev/null
INSIGHTS_AGG_FILE="$(remembrall_insights_dir "$INSIGHTS_AGG_CWD")/insights.json"

if [ -f "$INSIGHTS_AGG_FILE" ]; then
  printf "${GREEN}  PASS${RESET} insights aggregation creates file\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} insights aggregation creates file\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - insights aggregation creates file"
fi

I_AGG_SESSIONS=$(jq -r '.sessions_analyzed // 0' "$INSIGHTS_AGG_FILE" 2>/dev/null) || I_AGG_SESSIONS=0
assert_eq "insights: 3 sessions analyzed" "3" "$I_AGG_SESSIONS"

I_HOTSPOT_COUNT=$(jq '.file_hotspots | length' "$INSIGHTS_AGG_FILE" 2>/dev/null) || I_HOTSPOT_COUNT=0
if [ "$I_HOTSPOT_COUNT" -gt 0 ]; then
  printf "${GREEN}  PASS${RESET} insights: file hotspots detected\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} insights: file hotspots detected\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - insights: file hotspots detected"
fi

I_TOP_HOTSPOT=$(jq -r '.file_hotspots[0].file // ""' "$INSIGHTS_AGG_FILE" 2>/dev/null) || I_TOP_HOTSPOT=""
assert_match "insights: top hotspot is a src file" "src/" "$I_TOP_HOTSPOT"

I_ERROR_COUNT=$(jq '.error_recurrence | length' "$INSIGHTS_AGG_FILE" 2>/dev/null) || I_ERROR_COUNT=0
if [ "$I_ERROR_COUNT" -gt 0 ]; then
  printf "${GREEN}  PASS${RESET} insights: recurring errors detected\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} insights: recurring errors detected\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - insights: recurring errors detected"
fi

# insights: min_sessions guard
echo ""
echo "Insights: min_sessions guard"
echo "─────────────────────────────"
INSIGHTS_MIN_CWD="$TMPDIR_ROOT/insights-min-project"
mkdir -p "$INSIGHTS_MIN_CWD"
PENSIEVE_MIN_DIR=$(remembrall_pensieve_dir "$INSIGHTS_MIN_CWD")
mkdir -p "$PENSIEVE_MIN_DIR"
# Only 1 session (below default min of 3)
cat > "$PENSIEVE_MIN_DIR/session-solo.json" << PMIN_EOF
{"version": 1, "session_id": "solo", "files": {"app.ts": {"reads": 1}}, "commands": [], "errors": [], "patterns": {}}
PMIN_EOF
bash "$PLUGIN_ROOT/hooks/insights-aggregate.sh" "$INSIGHTS_MIN_CWD" 2>/dev/null
if [ ! -f "$(remembrall_insights_dir "$INSIGHTS_MIN_CWD")/insights.json" ]; then
  printf "${GREEN}  PASS${RESET} insights: skipped with < min_sessions\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} insights: skipped with < min_sessions\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - insights: skipped with < min_sessions"
fi

# insights script output
echo ""
echo "Insights: remembrall-insights.sh"
echo "──────────────────────────────────"
INSIGHTS_SCRIPT_OUT=$(bash "$PLUGIN_ROOT/scripts/remembrall-insights.sh" "$INSIGHTS_AGG_CWD" 2>/dev/null)
assert_match "insights script has header" "Pensieve Remembers|Project Insights" "$INSIGHTS_SCRIPT_OUT"
assert_match "insights script shows sessions" "3 sessions" "$INSIGHTS_SCRIPT_OUT"
assert_match "insights script shows hotspots" "Hotspot" "$INSIGHTS_SCRIPT_OUT"

# insights config validation
remembrall_config_set "insights" "true" 2>/dev/null && { printf "${GREEN}  PASS${RESET} insights=true valid\n"; PASS=$((PASS+1)); } || { printf "${RED}  FAIL${RESET} insights=true valid\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - insights=true valid"; }
remembrall_config_set "insights_min_sessions" "5" 2>/dev/null && { printf "${GREEN}  PASS${RESET} insights_min_sessions=5 valid\n"; PASS=$((PASS+1)); } || { printf "${RED}  FAIL${RESET} insights_min_sessions=5 valid\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - insights_min_sessions=5 valid"; }
rm -f "$HOME/.remembrall/config.json" 2>/dev/null || true

# ── Phase 3: Obliviate ────────────────────────────────────────────
echo ""
echo "Obliviate: lib.sh functions"
echo "────────────────────────────"

# remembrall_memory_dirs
# Create a fake memory dir
mkdir -p "$HOME/.claude/projects/test-project/memory"
echo "test" > "$HOME/.claude/projects/test-project/memory/test-mem.md"
MDIRS=$(remembrall_memory_dirs)
assert_match "memory_dirs finds project memory" "test-project/memory" "$MDIRS"

# remembrall_obliviate_dir
ODIR=$(remembrall_obliviate_dir)
assert_eq "obliviate dir is /tmp/remembrall-obliviate" "/tmp/remembrall-obliviate" "$ODIR"

# obliviate-analyze.sh
echo ""
echo "Obliviate: obliviate-analyze.sh"
echo "─────────────────────────────────"
OBLIVIATE_CWD="$TMPDIR_ROOT/obliviate-test-project"
mkdir -p "$OBLIVIATE_CWD"

# Create fake memory files (some stale, some fresh)
OBLIVIATE_PROJECT_HASH=$(printf '%s' "$OBLIVIATE_CWD" | sed 's|/|-|g; s|^-||')
OBLIVIATE_MEM_DIR="$HOME/.claude/projects/${OBLIVIATE_PROJECT_HASH}/memory"
mkdir -p "$OBLIVIATE_MEM_DIR"
echo "---
name: old-memory
type: project
---
Old project memory" > "$OBLIVIATE_MEM_DIR/old-memory.md"
echo "---
name: fresh-memory
type: feedback
---
Fresh feedback" > "$OBLIVIATE_MEM_DIR/fresh-memory.md"
echo "# Memory Index
- [old-memory.md](old-memory.md) — old project memory
- [fresh-memory.md](fresh-memory.md) — fresh feedback" > "$OBLIVIATE_MEM_DIR/MEMORY.md"

# Make old-memory stale (touch with old timestamp)
touch -t 202601010000 "$OBLIVIATE_MEM_DIR/old-memory.md" 2>/dev/null || true

OBLIVIATE_SESS="test-obliviate-sess"
rm -f "/tmp/remembrall-obliviate/${OBLIVIATE_SESS}.json" 2>/dev/null || true

jq -n --arg sid "$OBLIVIATE_SESS" --arg cwd "$OBLIVIATE_CWD" '{session_id: $sid, cwd: $cwd}' | \
  bash "$PLUGIN_ROOT/hooks/obliviate-analyze.sh" 2>/dev/null

OBLIVIATE_REPORT="/tmp/remembrall-obliviate/${OBLIVIATE_SESS}.json"
if [ -f "$OBLIVIATE_REPORT" ]; then
  printf "${GREEN}  PASS${RESET} obliviate analyzer creates report\n"; PASS=$((PASS+1))
  O_STALE=$(jq -r '.stale_count // 0' "$OBLIVIATE_REPORT" 2>/dev/null) || O_STALE=0
  if [ "$O_STALE" -gt 0 ]; then
    printf "${GREEN}  PASS${RESET} obliviate detects stale memories (count: $O_STALE)\n"; PASS=$((PASS+1))
  else
    printf "${RED}  FAIL${RESET} obliviate detects stale memories\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - obliviate detects stale memories"
  fi
else
  printf "${RED}  FAIL${RESET} obliviate analyzer creates report\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - obliviate analyzer creates report"
  printf "${RED}  FAIL${RESET} obliviate detects stale memories\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - obliviate detects stale memories"
fi

# obliviate-archive.sh dry run
echo ""
echo "Obliviate: obliviate-archive.sh"
echo "─────────────────────────────────"
if [ -f "$OBLIVIATE_REPORT" ]; then
  DRY_OUTPUT=$(bash "$PLUGIN_ROOT/scripts/obliviate-archive.sh" --dry-run "$OBLIVIATE_SESS" 2>/dev/null)
  assert_match "obliviate dry-run: shows would archive" "dry-run.*Would archive|dry-run.*No stale" "$DRY_OUTPUT"
fi

# obliviate config validation
remembrall_config_set "obliviate" "true" 2>/dev/null && { printf "${GREEN}  PASS${RESET} obliviate=true valid\n"; PASS=$((PASS+1)); } || { printf "${RED}  FAIL${RESET} obliviate=true valid\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - obliviate=true valid"; }
remembrall_config_set "obliviate_stale_sessions" "5" 2>/dev/null && { printf "${GREEN}  PASS${RESET} obliviate_stale_sessions=5 valid\n"; PASS=$((PASS+1)); } || { printf "${RED}  FAIL${RESET} obliviate_stale_sessions=5 valid\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - obliviate_stale_sessions=5 valid"; }

# Cleanup
rm -f "$OBLIVIATE_REPORT" 2>/dev/null || true
rm -f "$HOME/.remembrall/config.json" 2>/dev/null || true

# ── Phase 4: Context Budget Allocation ────────────────────────────
echo ""
echo "Budget: lib.sh functions"
echo "─────────────────────────"

# remembrall_budget_dir
BDIR=$(remembrall_budget_dir)
assert_eq "budget dir is /tmp/remembrall-budget" "/tmp/remembrall-budget" "$BDIR"

# remembrall_budget_validate_total (defaults)
if remembrall_budget_validate_total 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} budget defaults sum to 100\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} budget defaults sum to 100\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - budget defaults sum to 100"
fi

# Custom budget that sums to 100
remembrall_config_set "budget_code" "40" 2>/dev/null
remembrall_config_set "budget_conversation" "40" 2>/dev/null
remembrall_config_set "budget_memory" "20" 2>/dev/null
if remembrall_budget_validate_total 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} custom budget 40/40/20 sums to 100\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} custom budget 40/40/20 sums to 100\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - custom budget 40/40/20 sums to 100"
fi

# Budget that doesn't sum to 100
remembrall_config_set "budget_code" "60" 2>/dev/null
if remembrall_budget_validate_total 2>/dev/null; then
  printf "${RED}  FAIL${RESET} budget 60/40/20 should not sum to 100\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - budget 60/40/20 should not sum to 100"
else
  printf "${GREEN}  PASS${RESET} budget 60/40/20 rejected (sums to 120)\n"; PASS=$((PASS+1))
fi
rm -f "$HOME/.remembrall/config.json" 2>/dev/null || true

# remembrall_extract_category_bytes
echo ""
echo "Budget: extract_category_bytes"
echo "───────────────────────────────"
BUDGET_TRANSCRIPT="$TMPDIR_ROOT/budget-transcript.jsonl"
# Create a minimal JSONL with different types of content
cat > "$BUDGET_TRANSCRIPT" << 'BTRANS_EOF'
[
  {"type":"system","content":"System prompt with instructions"},
  {"type":"user","content":[{"type":"text","text":"Hello, please help me"}]},
  {"type":"assistant","content":[{"type":"text","text":"Sure, I can help."},{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/test.ts"}}]},
  {"type":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file content here is some code"}]},
  {"type":"assistant","content":[{"type":"text","text":"Here is my analysis."}]},
  {"type":"user","content":[{"type":"text","text":"REMEMBRALL additionalContext: context injection data here"}]}
]
BTRANS_EOF

BUDGET_CATS=$(remembrall_extract_category_bytes "$BUDGET_TRANSCRIPT" 2>/dev/null)
B_CODE=$(printf '%s' "$BUDGET_CATS" | cut -f1)
B_CONV=$(printf '%s' "$BUDGET_CATS" | cut -f2)
B_MEM=$(printf '%s' "$BUDGET_CATS" | cut -f3)

if [ "${B_CODE:-0}" -gt 0 ]; then
  printf "${GREEN}  PASS${RESET} budget: code bytes > 0 ($B_CODE)\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} budget: code bytes > 0\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - budget: code bytes > 0"
fi

if [ "${B_CONV:-0}" -gt 0 ]; then
  printf "${GREEN}  PASS${RESET} budget: conversation bytes > 0 ($B_CONV)\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} budget: conversation bytes > 0\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - budget: conversation bytes > 0"
fi

if [ "${B_MEM:-0}" -gt 0 ]; then
  printf "${GREEN}  PASS${RESET} budget: memory bytes > 0 ($B_MEM)\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} budget: memory bytes > 0\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - budget: memory bytes > 0"
fi

# budget-analyze.sh
echo ""
echo "Budget: budget-analyze.sh"
echo "──────────────────────────"
BUDGET_SESS="test-budget-sess"
rm -f "/tmp/remembrall-budget/${BUDGET_SESS}.json" 2>/dev/null || true
remembrall_config_set "budget_enabled" "true" 2>/dev/null

jq -n --arg sid "$BUDGET_SESS" --arg tp "$BUDGET_TRANSCRIPT" '{session_id: $sid, transcript_path: $tp}' | \
  bash "$PLUGIN_ROOT/hooks/budget-analyze.sh" 2>/dev/null

BUDGET_REPORT="/tmp/remembrall-budget/${BUDGET_SESS}.json"
if [ -f "$BUDGET_REPORT" ]; then
  printf "${GREEN}  PASS${RESET} budget analyzer creates report\n"; PASS=$((PASS+1))
  B_TOTAL_PCT=$(jq -r '.code_pct + .conversation_pct + .memory_pct' "$BUDGET_REPORT" 2>/dev/null) || B_TOTAL_PCT=0
  # Total should be ~100 (due to rounding it might be 99 or 100)
  if [ "$B_TOTAL_PCT" -ge 95 ] && [ "$B_TOTAL_PCT" -le 100 ]; then
    printf "${GREEN}  PASS${RESET} budget percentages sum to ~100 (got $B_TOTAL_PCT)\n"; PASS=$((PASS+1))
  else
    printf "${RED}  FAIL${RESET} budget percentages sum to ~100 (got $B_TOTAL_PCT)\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - budget percentages sum to ~100"
  fi
  B_HAS_BUDGET=$(jq 'has("budget")' "$BUDGET_REPORT" 2>/dev/null)
  assert_eq "budget report has budget config" "true" "$B_HAS_BUDGET"
else
  printf "${RED}  FAIL${RESET} budget analyzer creates report\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - budget analyzer creates report"
  printf "${RED}  FAIL${RESET} budget percentages sum to ~100\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - budget percentages sum to ~100"
  printf "${RED}  FAIL${RESET} budget report has budget config\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - budget report has budget config"
fi

# Budget disabled
remembrall_config_set "budget_enabled" "false" 2>/dev/null
rm -f "/tmp/remembrall-budget/test-budget-disabled.json" 2>/dev/null || true
jq -n --arg sid "test-budget-disabled" --arg tp "$BUDGET_TRANSCRIPT" '{session_id: $sid, transcript_path: $tp}' | \
  bash "$PLUGIN_ROOT/hooks/budget-analyze.sh" 2>/dev/null
if [ ! -f "/tmp/remembrall-budget/test-budget-disabled.json" ]; then
  printf "${GREEN}  PASS${RESET} budget disabled: no report created\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} budget disabled: no report created\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - budget disabled: no report created"
fi

# Budget config validation
remembrall_config_set "budget_enabled" "true" 2>/dev/null && { printf "${GREEN}  PASS${RESET} budget_enabled=true valid\n"; PASS=$((PASS+1)); } || { printf "${RED}  FAIL${RESET} budget_enabled=true valid\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - budget_enabled=true valid"; }
remembrall_config_set "budget_code" "50" 2>/dev/null && { printf "${GREEN}  PASS${RESET} budget_code=50 valid\n"; PASS=$((PASS+1)); } || { printf "${RED}  FAIL${RESET} budget_code=50 valid\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - budget_code=50 valid"; }

# Cleanup
rm -f "$BUDGET_REPORT" "/tmp/remembrall-budget/test-budget-disabled.json" 2>/dev/null || true
rm -f "$HOME/.remembrall/config.json" 2>/dev/null || true

# ── Phase 5: Patrol Integration ───────────────────────────────────
echo ""
echo "Patrol Integration: lib.sh functions"
echo "──────────────────────────────────────"

# remembrall_signal_dir
SDIR=$(remembrall_signal_dir)
assert_eq "signal dir is /tmp/remembrall-signals" "/tmp/remembrall-signals" "$SDIR"

# remembrall_check_patrol_signal — no signals
SIG=$(remembrall_check_patrol_signal "no-signal-sess" 2>/dev/null) || SIG=""
assert_eq "no signal: returns empty" "" "$SIG"

# Create a signal
PATROL_SESS="test-patrol-sess"
PATROL_SIG_DIR="/tmp/remembrall-signals/${PATROL_SESS}"
mkdir -p "$PATROL_SIG_DIR"
echo '{"type":"handoff_trigger","reason":"test reason"}' > "$PATROL_SIG_DIR/handoff_trigger.json"

SIG=$(remembrall_check_patrol_signal "$PATROL_SESS" 2>/dev/null) || SIG=""
assert_eq "signal detected: handoff_trigger" "handoff_trigger" "$SIG"

# remembrall_consume_signal
PAYLOAD=$(remembrall_consume_signal "$PATROL_SESS" "handoff_trigger" 2>/dev/null) || PAYLOAD=""
assert_match "consume signal: returns payload" "test reason" "$PAYLOAD"

if [ ! -f "$PATROL_SIG_DIR/handoff_trigger.json" ]; then
  printf "${GREEN}  PASS${RESET} consume signal: file deleted\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} consume signal: file deleted\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - consume signal: file deleted"
fi

# TTL expiry — create old signal
mkdir -p "$PATROL_SIG_DIR"
echo '{"type":"context_alert","message":"old alert"}' > "$PATROL_SIG_DIR/context_alert.json"
touch -t 202601010000 "$PATROL_SIG_DIR/context_alert.json" 2>/dev/null || true

SIG_OLD=$(remembrall_check_patrol_signal "$PATROL_SESS" 2>/dev/null) || SIG_OLD=""
assert_eq "expired signal: returns empty" "" "$SIG_OLD"

if [ ! -f "$PATROL_SIG_DIR/context_alert.json" ]; then
  printf "${GREEN}  PASS${RESET} expired signal: file cleaned up\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} expired signal: file cleaned up\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - expired signal: file cleaned up"
fi

# Patrol disabled
remembrall_config_set "patrol_integration" "false" 2>/dev/null
mkdir -p "$PATROL_SIG_DIR"
echo '{"type":"handoff_trigger"}' > "$PATROL_SIG_DIR/handoff_trigger.json"
SIG_DISABLED=$(remembrall_check_patrol_signal "$PATROL_SESS" 2>/dev/null) || SIG_DISABLED=""
assert_eq "patrol disabled: no signal returned" "" "$SIG_DISABLED"
rm -rf "$PATROL_SIG_DIR" 2>/dev/null || true
remembrall_config_set "patrol_integration" "true" 2>/dev/null

# remembrall_patrol_detected
echo ""
echo "Patrol Integration: detection"
echo "──────────────────────────────"
# Create a fake patrol installation
mkdir -p "$HOME/.claude/plugins/cache/cukas/patrol"
if remembrall_patrol_detected 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} patrol_detected: finds cached install\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} patrol_detected: finds cached install\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - patrol_detected: finds cached install"
fi
rm -rf "$HOME/.claude/plugins/cache/cukas/patrol" 2>/dev/null

# Patrol integration in context-monitor (signal handling)
echo ""
echo "Patrol Integration: context-monitor signal handling"
echo "────────────────────────────────────────────────────"
# Create handoff_trigger signal
PATROL_CM_SESS="test-patrol-cm-sess"
mkdir -p "/tmp/remembrall-signals/${PATROL_CM_SESS}"
echo '{"type":"handoff_trigger","reason":"Patrol says handoff now"}' > "/tmp/remembrall-signals/${PATROL_CM_SESS}/handoff_trigger.json"

# Need bridge file for context-monitor to work
CTX_DIR="/tmp/claude-context-pct"
mkdir -p "$CTX_DIR"
echo "50" > "$CTX_DIR/$PATROL_CM_SESS"

PATROL_CM_CWD="$TMPDIR_ROOT/patrol-cm-test"
mkdir -p "$PATROL_CM_CWD"

PATROL_CM_OUTPUT=$(jq -n \
  --arg sid "$PATROL_CM_SESS" \
  --arg cwd "$PATROL_CM_CWD" \
  '{session_id: $sid, cwd: $cwd}' | \
  bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null) || PATROL_CM_OUTPUT=""

assert_match "patrol signal in context-monitor: mentions Owl Post" "Owl Post" "$PATROL_CM_OUTPUT"
assert_match "patrol signal in context-monitor: mentions reason" "Patrol says handoff now" "$PATROL_CM_OUTPUT"

# Signal should be consumed
if [ ! -f "/tmp/remembrall-signals/${PATROL_CM_SESS}/handoff_trigger.json" ]; then
  printf "${GREEN}  PASS${RESET} patrol signal consumed by context-monitor\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} patrol signal consumed by context-monitor\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - patrol signal consumed by context-monitor"
fi

# context_alert with skip_timeturner
echo ""
echo "Patrol Integration: skip_timeturner"
echo "─────────────────────────────────────"
PATROL_TT_SESS="test-patrol-tt-sess"
mkdir -p "/tmp/remembrall-signals/${PATROL_TT_SESS}"
echo '{"type":"context_alert","message":"Skip TT for debug","skip_timeturner":true}' > "/tmp/remembrall-signals/${PATROL_TT_SESS}/context_alert.json"
echo "50" > "$CTX_DIR/$PATROL_TT_SESS"

jq -n --arg sid "$PATROL_TT_SESS" --arg cwd "$PATROL_CM_CWD" '{session_id: $sid, cwd: $cwd}' | \
  bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null || true

TT_SKIP_FILE="/tmp/remembrall-timeturner/${PATROL_TT_SESS}-skip"
if [ -f "$TT_SKIP_FILE" ]; then
  printf "${GREEN}  PASS${RESET} patrol skip_timeturner: skip file created\n"; PASS=$((PASS+1))
else
  printf "${RED}  FAIL${RESET} patrol skip_timeturner: skip file created\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - patrol skip_timeturner: skip file created"
fi

# Patrol config validation
remembrall_config_set "patrol_integration" "true" 2>/dev/null && { printf "${GREEN}  PASS${RESET} patrol_integration=true valid\n"; PASS=$((PASS+1)); } || { printf "${RED}  FAIL${RESET} patrol_integration=true valid\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - patrol_integration=true valid"; }
remembrall_config_set "patrol_signal_ttl" "300" 2>/dev/null && { printf "${GREEN}  PASS${RESET} patrol_signal_ttl=300 valid\n"; PASS=$((PASS+1)); } || { printf "${RED}  FAIL${RESET} patrol_signal_ttl=300 valid\n"; FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  - patrol_signal_ttl=300 valid"; }

# ── Cross-feature: status script includes new sections ────────────
echo ""
echo "Cross-feature: remembrall-status.sh"
echo "─────────────────────────────────────"
STATUS_CWD="$LINEAGE_CWD"  # Re-use lineage CWD which has data
STATUS_OUT=$(bash "$PLUGIN_ROOT/scripts/remembrall-status.sh" "$STATUS_CWD" 2>/dev/null)
assert_match "status shows Lineage" "Lineage:" "$STATUS_OUT"
assert_match "status shows Insights" "Insights:" "$STATUS_OUT"
assert_match "status shows Obliviate" "Obliviate:" "$STATUS_OUT"
assert_match "status shows Budget" "Budget:" "$STATUS_OUT"
assert_match "status shows Patrol" "Patrol:" "$STATUS_OUT"

# ── Cross-feature: help includes new commands ─────────────────────
echo ""
echo "Cross-feature: remembrall-help.md"
echo "───────────────────────────────────"
HELP_CONTENT=$(cat "$PLUGIN_ROOT/commands/remembrall-help.md")
assert_match "help lists /lineage" "/lineage" "$HELP_CONTENT"
assert_match "help lists /insights" "/insights" "$HELP_CONTENT"
assert_match "help lists /obliviate" "/obliviate" "$HELP_CONTENT"
assert_match "help lists /budget" "/budget" "$HELP_CONTENT"
assert_match "help lists patrol_integration config" "patrol_integration" "$HELP_CONTENT"
assert_match "help lists lineage config" "lineage.*true" "$HELP_CONTENT"
assert_match "help lists budget_enabled config" "budget_enabled.*false" "$HELP_CONTENT"

# ── Cross-feature: map includes budget section ────────────────────
echo ""
echo "Cross-feature: remembrall-map.sh with budget"
echo "───────────────────────────────────────────────"
MAP_BUDGET_SESS="test-map-budget-sess"
mkdir -p "/tmp/remembrall-budget"
# Write a budget report
jq -n '{code_pct: 55, conversation_pct: 30, memory_pct: 15, budget: {code: 50, conversation: 30, memory: 20}, warnings: []}' \
  > "/tmp/remembrall-budget/${MAP_BUDGET_SESS}.json"
# Fake the session ID for map
mkdir -p "/tmp/remembrall-sessions"
MAP_BUDGET_CWD="$TMPDIR_ROOT/map-budget-test"
mkdir -p "$MAP_BUDGET_CWD"
_map_hash=$(remembrall_project_hash "$MAP_BUDGET_CWD" 2>/dev/null)
echo "$MAP_BUDGET_SESS" > "/tmp/remembrall-sessions/$_map_hash"
echo "50" > "$CTX_DIR/$MAP_BUDGET_SESS"

MAP_OUTPUT=$(bash "$PLUGIN_ROOT/scripts/remembrall-map.sh" "$MAP_BUDGET_CWD" 2>/dev/null)
assert_match "map shows budget section" "Budget.*code.*55%" "$MAP_OUTPUT"

# Cleanup all patrol/budget test files
rm -f "$CTX_DIR/$PATROL_CM_SESS" "$CTX_DIR/$PATROL_TT_SESS" "$CTX_DIR/$MAP_BUDGET_SESS"
rm -f "/tmp/remembrall-nudges/$PATROL_CM_SESS" "/tmp/remembrall-nudges/$PATROL_TT_SESS"
rm -rf "/tmp/remembrall-signals/$PATROL_CM_SESS" "/tmp/remembrall-signals/$PATROL_TT_SESS"
rm -f "$TT_SKIP_FILE" 2>/dev/null
rm -f "/tmp/remembrall-budget/$BUDGET_SESS" "/tmp/remembrall-budget/test-budget-disabled.json" "/tmp/remembrall-budget/$MAP_BUDGET_SESS.json"
rm -f "/tmp/remembrall-sessions/$_map_hash" 2>/dev/null
rm -f "$HOME/.remembrall/config.json" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "Phoenix Mode"
echo "════════════"

# ── Phoenix helpers ──────────────────────────────────────────────
echo ""
echo "Phoenix helpers:"

# Setup
PHOENIX_DIR_TEST="/tmp/remembrall-phoenix"
rm -rf "$PHOENIX_DIR_TEST" 2>/dev/null

# Test chain ID operations
PHOENIX_TEST_SESS="test-phoenix-sess"
PHOENIX_TEST_CHAIN="phoenix-1234567890-42"

CHAIN_BEFORE=$(remembrall_phoenix_chain_id "$PHOENIX_TEST_SESS")
assert_eq "chain_id empty before set" "" "$CHAIN_BEFORE"

remembrall_phoenix_set_chain "$PHOENIX_TEST_SESS" "$PHOENIX_TEST_CHAIN"
CHAIN_AFTER=$(remembrall_phoenix_chain_id "$PHOENIX_TEST_SESS")
assert_eq "chain_id set and read" "$PHOENIX_TEST_CHAIN" "$CHAIN_AFTER"

# Test cycle count
CYCLE_BEFORE=$(remembrall_phoenix_cycle_count "$PHOENIX_TEST_CHAIN")
assert_eq "cycle count starts at 0" "0" "$CYCLE_BEFORE"

remembrall_phoenix_increment "$PHOENIX_TEST_CHAIN"
CYCLE_AFTER=$(remembrall_phoenix_cycle_count "$PHOENIX_TEST_CHAIN")
assert_eq "cycle count increments to 1" "1" "$CYCLE_AFTER"

remembrall_phoenix_increment "$PHOENIX_TEST_CHAIN"
CYCLE_AFTER2=$(remembrall_phoenix_cycle_count "$PHOENIX_TEST_CHAIN")
assert_eq "cycle count increments to 2" "2" "$CYCLE_AFTER2"

# Test lineage recording
remembrall_phoenix_record "$PHOENIX_TEST_CHAIN" "$PHOENIX_TEST_SESS" "1"
LINEAGE_FILE="$PHOENIX_DIR_TEST/${PHOENIX_TEST_CHAIN}.lineage"
if [ -f "$LINEAGE_FILE" ]; then
  LINEAGE_CONTENT=$(cat "$LINEAGE_FILE")
  assert_match "lineage contains session_id" "$PHOENIX_TEST_SESS" "$LINEAGE_CONTENT"
  assert_match "lineage contains chain_id" "$PHOENIX_TEST_CHAIN" "$LINEAGE_CONTENT"
else
  assert_eq "lineage file exists" "true" "false"
fi

# ── AK capture with Phoenix args ────────────────────────────────
echo ""
echo "AK capture with Phoenix args:"

AK_TEST_CWD="$TMPDIR_ROOT/phoenix-capture-test"
mkdir -p "$AK_TEST_CWD"
# Init a git repo so capture can get branch/commit
git -C "$AK_TEST_CWD" init -q 2>/dev/null
git -C "$AK_TEST_CWD" -c user.name="test" -c user.email="test@test" commit --allow-empty -m "init" -q 2>/dev/null

AK_PHOENIX_SESS="test-phoenix-ak-sess"
AK_FILE=$(bash "$PLUGIN_ROOT/scripts/avadakedavra-capture.sh" \
  --cwd "$AK_TEST_CWD" --session-id "$AK_PHOENIX_SESS" \
  --trigger phoenix --cycle 3 --chain-id "$PHOENIX_TEST_CHAIN")

if [ -f "$AK_FILE" ]; then
  AK_CONTENT=$(cat "$AK_FILE")
  assert_match "AK file has trigger phoenix" '"trigger".*"phoenix"' "$AK_CONTENT"
  assert_match "AK file has cycle 3" '"cycle".*3' "$AK_CONTENT"
  assert_match "AK file has chain_id" '"chain_id".*"phoenix-' "$AK_CONTENT"
else
  assert_eq "AK capture file created" "true" "false"
fi

# ── AK capture backward compat (no phoenix args) ────────────────
echo ""
echo "AK capture backward compat:"

AK_COMPAT_SESS="test-phoenix-compat-sess"
AK_COMPAT_FILE=$(bash "$PLUGIN_ROOT/scripts/avadakedavra-capture.sh" \
  --cwd "$AK_TEST_CWD" --session-id "$AK_COMPAT_SESS")

if [ -f "$AK_COMPAT_FILE" ]; then
  AK_COMPAT_CONTENT=$(cat "$AK_COMPAT_FILE")
  assert_match "compat AK has trigger avadakedavra" '"trigger".*"avadakedavra"' "$AK_COMPAT_CONTENT"
  # Should NOT have cycle or chain_id fields
  if echo "$AK_COMPAT_CONTENT" | grep -q '"cycle"'; then
    assert_eq "compat AK has no cycle field" "false" "true"
  else
    printf "${GREEN}  PASS${RESET} compat AK has no cycle field\n"
    PASS=$((PASS + 1))
  fi
else
  assert_eq "compat AK capture file created" "true" "false"
fi

# ── Phoenix context-monitor integration ──────────────────────────
echo ""
echo "Phoenix context-monitor:"

# Phoenix fires at urgent threshold when enabled
PHOENIX_CM_SESS="test-phoenix-cm-sess"
CTX_DIR="/tmp/claude-context-pct"
mkdir -p "$CTX_DIR"
echo "20" > "$CTX_DIR/$PHOENIX_CM_SESS"

# Enable Phoenix mode
remembrall_config_set "phoenix_mode" "true"
remembrall_config_set "phoenix_max_cycles" "5"

# Clean nudge state
rm -f "/tmp/remembrall-nudges/$PHOENIX_CM_SESS"

CM_INPUT=$(jq -n --arg sid "$PHOENIX_CM_SESS" --arg cwd "$AK_TEST_CWD" '{session_id: $sid, cwd: $cwd, transcript_path: ""}')
CM_OUTPUT=$(echo "$CM_INPUT" | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null) || CM_OUTPUT=""
assert_match "Phoenix fires at urgent threshold" "Phoenix Rebirth cycle" "$CM_OUTPUT"
assert_match "Phoenix shows cycle number" "cycle 1" "$CM_OUTPUT"

# Verify cycle was recorded
PHOENIX_CM_CHAIN=$(remembrall_phoenix_chain_id "$PHOENIX_CM_SESS")
if [ -n "$PHOENIX_CM_CHAIN" ]; then
  PHOENIX_CM_CYCLE=$(remembrall_phoenix_cycle_count "$PHOENIX_CM_CHAIN")
  assert_eq "Phoenix cycle recorded as 1" "1" "$PHOENIX_CM_CYCLE"
else
  assert_eq "Phoenix chain created" "true" "false"
fi

# ── Phoenix disabled: behavior identical to normal AK ────────────
echo ""
echo "Phoenix disabled:"

PHOENIX_OFF_SESS="test-phoenix-off-sess"
echo "20" > "$CTX_DIR/$PHOENIX_OFF_SESS"
rm -f "/tmp/remembrall-nudges/$PHOENIX_OFF_SESS"

# Disable Phoenix mode + autonomous mode to hit AK path
remembrall_config_set "phoenix_mode" "false"
remembrall_config_set "autonomous_mode" "false"

CM_OFF_INPUT=$(jq -n --arg sid "$PHOENIX_OFF_SESS" --arg cwd "$AK_TEST_CWD" '{session_id: $sid, cwd: $cwd, transcript_path: ""}')
CM_OFF_OUTPUT=$(echo "$CM_OFF_INPUT" | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null) || CM_OFF_OUTPUT=""
assert_match "Normal AK fires when Phoenix disabled" "avadakedavra" "$CM_OFF_OUTPUT"

# ── Safety cap: falls through to normal AK at max cycles ─────────
echo ""
echo "Phoenix safety cap:"

PHOENIX_CAP_SESS="test-phoenix-cap-sess"
echo "20" > "$CTX_DIR/$PHOENIX_CAP_SESS"
rm -f "/tmp/remembrall-nudges/$PHOENIX_CAP_SESS"

# Enable Phoenix with max_cycles=1, disable autonomous to hit AK path
remembrall_config_set "phoenix_mode" "true"
remembrall_config_set "phoenix_max_cycles" "1"
remembrall_config_set "autonomous_mode" "false"

# Pre-set cycle count to 1 (already at max)
CAP_CHAIN="phoenix-cap-test-chain"
remembrall_phoenix_set_chain "$PHOENIX_CAP_SESS" "$CAP_CHAIN"
remembrall_phoenix_increment "$CAP_CHAIN"  # cycle=1, which equals max

CM_CAP_INPUT=$(jq -n --arg sid "$PHOENIX_CAP_SESS" --arg cwd "$AK_TEST_CWD" '{session_id: $sid, cwd: $cwd, transcript_path: ""}')
CM_CAP_OUTPUT=$(echo "$CM_CAP_INPUT" | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null) || CM_CAP_OUTPUT=""
# Should fall through to normal AK since cycle (2) > max (1)
assert_match "Falls through to normal AK at max cycles" "avadakedavra" "$CM_CAP_OUTPUT"

# ── Config validation ────────────────────────────────────────────
echo ""
echo "Phoenix config validation:"

assert_nonzero_exit "phoenix_max_cycles rejects 0" remembrall_config_validate "phoenix_max_cycles" "0"
assert_nonzero_exit "phoenix_max_cycles rejects 100" remembrall_config_validate "phoenix_max_cycles" "100"
assert_nonzero_exit "phoenix_mode rejects string" remembrall_config_validate "phoenix_mode" "yes"

# ── Cleanup ──────────────────────────────────────────────────────
rm -rf "$PHOENIX_DIR_TEST" 2>/dev/null
rm -f "$CTX_DIR/$PHOENIX_CM_SESS" "$CTX_DIR/$PHOENIX_OFF_SESS" "$CTX_DIR/$PHOENIX_CAP_SESS"
rm -f "/tmp/remembrall-nudges/$PHOENIX_CM_SESS" "/tmp/remembrall-nudges/$PHOENIX_OFF_SESS" "/tmp/remembrall-nudges/$PHOENIX_CAP_SESS"
rm -f "/tmp/remembrall-avadakedavra/$AK_PHOENIX_SESS" "/tmp/remembrall-avadakedavra/$AK_COMPAT_SESS"
rm -f "$HOME/.remembrall/config.json" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════
# DYNAMIC CONTEXT WINDOW SUPPORT
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Dynamic Context Window Support ==="

# ── remembrall_context_window ────────────────────────────────────
echo ""
echo "remembrall_context_window:"

CTX_WIN_SESS="test-window-sess"
CTX_WIN_DIR="/tmp/claude-context-pct"
mkdir -p "$CTX_WIN_DIR"

# No model file → 200000 default
rm -f "$CTX_WIN_DIR/${CTX_WIN_SESS}.model"
R=$(remembrall_context_window "$CTX_WIN_SESS")
assert_eq "no model file returns 200000" "200000" "$R"

# Empty session_id → 200000
R=$(remembrall_context_window "")
assert_eq "empty session returns 200000" "200000" "$R"

# "1M context" → 1000000
printf "Opus 4.6 (1M context)" > "$CTX_WIN_DIR/${CTX_WIN_SESS}.model"
R=$(remembrall_context_window "$CTX_WIN_SESS")
assert_eq "1M display name → 1000000" "1000000" "$R"

# "200K" → 200000
printf "Opus 4.6 (200K)" > "$CTX_WIN_DIR/${CTX_WIN_SESS}.model"
R=$(remembrall_context_window "$CTX_WIN_SESS")
assert_eq "200K display name → 200000" "200000" "$R"

# Future-proof: "2M context" → 2000000
printf "Opus 5 (2M context)" > "$CTX_WIN_DIR/${CTX_WIN_SESS}.model"
R=$(remembrall_context_window "$CTX_WIN_SESS")
assert_eq "2M display name → 2000000" "2000000" "$R"

# Future-proof: "500K" → 500000
printf "Sonnet 5 (500K context)" > "$CTX_WIN_DIR/${CTX_WIN_SESS}.model"
R=$(remembrall_context_window "$CTX_WIN_SESS")
assert_eq "500K display name → 500000" "500000" "$R"

# No size in display name → 200000 fallback
printf "Opus 4.6" > "$CTX_WIN_DIR/${CTX_WIN_SESS}.model"
R=$(remembrall_context_window "$CTX_WIN_SESS")
assert_eq "no size in name → 200000" "200000" "$R"

# Case insensitive: "1m"
printf "Sonnet 4.6 (1m context)" > "$CTX_WIN_DIR/${CTX_WIN_SESS}.model"
R=$(remembrall_context_window "$CTX_WIN_SESS")
assert_eq "lowercase 1m → 1000000" "1000000" "$R"

# Cleanup
rm -f "$CTX_WIN_DIR/${CTX_WIN_SESS}" "$CTX_WIN_DIR/${CTX_WIN_SESS}.model"

# ── remembrall_scale_threshold ───────────────────────────────────
echo ""
echo "remembrall_scale_threshold (formula-based):"

# 200K window: unchanged
R=$(remembrall_scale_threshold 65 200000)
assert_eq "200K: 65% unchanged" "65" "$R"

R=$(remembrall_scale_threshold 35 200000)
assert_eq "200K: 35% unchanged" "35" "$R"

# 1M window: (200K/1M)^0.25 ≈ 0.669 → 65×0.669 ≈ 42
R=$(remembrall_scale_threshold 65 1000000)
assert_eq "1M: 65% → 42% (4th-root)" "42" "$R"

R=$(remembrall_scale_threshold 35 1000000)
assert_eq "1M: 35% → 23% (4th-root)" "23" "$R"

R=$(remembrall_scale_threshold 25 1000000)
assert_eq "1M: 25% → 16% (4th-root)" "16" "$R"

# 2M window: (200K/2M)^0.25 ≈ 0.562 → 65×0.562 ≈ 35
R=$(remembrall_scale_threshold 65 2000000)
assert_eq "2M: 65% → 35% (4th-root)" "35" "$R"

R=$(remembrall_scale_threshold 25 2000000)
assert_eq "2M: 25% → 13% (4th-root)" "13" "$R"

# 500K window: (200K/500K)^0.25 ≈ 0.795 → 65×0.795 ≈ 51
R=$(remembrall_scale_threshold 65 500000)
assert_eq "500K: 65% → 51% (4th-root)" "51" "$R"

# ── remembrall_default_content_max (formula-based) ────────────────
echo ""
echo "remembrall_default_content_max (formula-based):"

# 200K legacy defaults (exact values preserved)
R=$(remembrall_default_content_max "claude-opus-4-6" 200000)
assert_eq "opus 200K = legacy 358400" "358400" "$R"

R=$(remembrall_default_content_max "claude-opus-4-6")
assert_eq "opus no param = legacy 358400" "358400" "$R"

# 1M: formula = 1000000 * 42 * 42 / 1000 = 1764000
R=$(remembrall_default_content_max "claude-opus-4-6" 1000000)
assert_eq "opus 1M = 1764000" "1764000" "$R"

# 1M Sonnet: 1000000 * 40 * 42 / 1000 = 1680000
R=$(remembrall_default_content_max "claude-sonnet-4-6" 1000000)
assert_eq "sonnet 1M = 1680000" "1680000" "$R"

# 2M Opus: 2000000 * 42 * 42 / 1000 = 3528000
R=$(remembrall_default_content_max "claude-opus-4-6" 2000000)
assert_eq "opus 2M = 3528000" "3528000" "$R"

# 500K Opus: 500000 * 42 * 42 / 1000 = 882000
R=$(remembrall_default_content_max "claude-opus-4-6" 500000)
assert_eq "opus 500K = 882000" "882000" "$R"

# ── remembrall_detect_model (window param) ───────────────────────
echo ""
echo "remembrall_detect_model (window param):"

WIN_MODEL_TRANSCRIPT="$TMPDIR_ROOT/win_model_transcript.jsonl"
echo '{"type":"assistant","message":{"model":"claude-opus-4-6","content":[{"type":"text","text":"hello"}]}}' > "$WIN_MODEL_TRANSCRIPT"

# Default 200K
R=$(remembrall_detect_model "$WIN_MODEL_TRANSCRIPT")
WIN_WINDOW=$(printf '%s' "$R" | cut -f2)
assert_eq "default opus window=200000" "200000" "$WIN_WINDOW"

# Explicit 200K
R=$(remembrall_detect_model "$WIN_MODEL_TRANSCRIPT" 200000)
WIN_WINDOW=$(printf '%s' "$R" | cut -f2)
assert_eq "explicit 200K window" "200000" "$WIN_WINDOW"

# 1M
R=$(remembrall_detect_model "$WIN_MODEL_TRANSCRIPT" 1000000)
WIN_WINDOW=$(printf '%s' "$R" | cut -f2)
WIN_MAXKB=$(printf '%s' "$R" | cut -f4)
assert_eq "1M window passthrough" "1000000" "$WIN_WINDOW"
# max_kb = 1000000 * 42 * 2 / 10240 = 8203
assert_eq "1M max_kb derived" "8203" "$WIN_MAXKB"

# 2M
R=$(remembrall_detect_model "$WIN_MODEL_TRANSCRIPT" 2000000)
WIN_WINDOW=$(printf '%s' "$R" | cut -f2)
assert_eq "2M window passthrough" "2000000" "$WIN_WINDOW"

# ── Standing instruction anti-handoff ────────────────────────────
echo ""
echo "Standing instruction:"

STANDING_FILE="$PLUGIN_ROOT/hooks/session-resume.sh"
if grep -q "Do NOT voluntarily suggest handoffs" "$STANDING_FILE" 2>/dev/null; then
  printf "${GREEN}  PASS${RESET} standing instruction includes anti-handoff language\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} standing instruction missing anti-handoff language\n"
  FAIL=$((FAIL + 1))
  ERRORS="${ERRORS}\n  - standing instruction missing anti-handoff language"
fi

# ── Context monitor dynamic threshold scaling ────────────────────
echo ""
echo "Context monitor dynamic scaling:"

CM_DYN_SESS="test-dyn-cm-sess"
CTX_DIR="/tmp/claude-context-pct"
mkdir -p "$CTX_DIR"

CM_DYN_CWD="$TMPDIR_ROOT/test-dyn-cwd"
mkdir -p "$CM_DYN_CWD"
rm -f "$HOME/.remembrall/config.json" 2>/dev/null || true

# 1M context at 50%: journal scaled to 42% (fourth-root), so 50 > 42 → no nudge
echo "50" > "$CTX_DIR/$CM_DYN_SESS"
printf "Opus 4.6 (1M context)" > "$CTX_DIR/${CM_DYN_SESS}.model"
rm -f "/tmp/remembrall-nudges/$CM_DYN_SESS"
CM_DYN_INPUT=$(jq -n --arg sid "$CM_DYN_SESS" --arg cwd "$CM_DYN_CWD" '{session_id: $sid, cwd: $cwd, transcript_path: ""}')
CM_DYN_OUTPUT=$(echo "$CM_DYN_INPUT" | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null) || CM_DYN_OUTPUT=""
assert_eq "1M at 50%: no nudge (journal scaled to 42%)" "" "$CM_DYN_OUTPUT"

# 1M context at 40%: journal=42%, so 40 < 42 → journal nudge
echo "40" > "$CTX_DIR/$CM_DYN_SESS"
rm -f "/tmp/remembrall-nudges/$CM_DYN_SESS"
CM_DYN_OUTPUT=$(echo "$CM_DYN_INPUT" | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null) || CM_DYN_OUTPUT=""
assert_match "1M at 40%: journal nudge fires (below 42%)" "REMEMBRALL" "$CM_DYN_OUTPUT"

# 200K context at 30%: no model file, journal stays 65%, so 30 < 65 → journal nudge
CM_200K_SESS="test-200k-cm-sess"
echo "30" > "$CTX_DIR/$CM_200K_SESS"
rm -f "$CTX_DIR/${CM_200K_SESS}.model"
rm -f "/tmp/remembrall-nudges/$CM_200K_SESS"
CM_200K_INPUT=$(jq -n --arg sid "$CM_200K_SESS" --arg cwd "$CM_DYN_CWD" '{session_id: $sid, cwd: $cwd, transcript_path: ""}')
CM_200K_OUTPUT=$(echo "$CM_200K_INPUT" | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null) || CM_200K_OUTPUT=""
assert_match "200K at 30%: nudge fires (below 65%)" "REMEMBRALL" "$CM_200K_OUTPUT"

# Cleanup
rm -f "$CTX_DIR/$CM_DYN_SESS" "$CTX_DIR/${CM_DYN_SESS}.model"
rm -f "$CTX_DIR/$CM_200K_SESS"
rm -f "/tmp/remembrall-nudges/$CM_DYN_SESS" "/tmp/remembrall-nudges/$CM_200K_SESS"

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
