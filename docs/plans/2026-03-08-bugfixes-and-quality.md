# Remembrall Bugfixes & Quality Hardening Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all 5 identified bugs, add shellcheck CI, add timeouts to hooks, and standardize error handling across all scripts.

**Architecture:** Each task is independent — fix one bug, add its test, commit. CI setup is the final task. No refactoring beyond what's needed to fix each issue.

**Tech Stack:** Bash, jq, shellcheck, GitHub Actions

---

### Task 1: Fix `local` outside function in precompact-handoff.sh

The `local` keyword on line 51 is outside any function body. Bash prints an error and `existing_type` is never set, which silently disables the skill-generated handoff overwrite protection.

**Files:**
- Modify: `hooks/precompact-handoff.sh:51`
- Modify: `tests/run-tests.sh` (append new test section)

**Step 1: Write the failing test**

Append this test section to `tests/run-tests.sh`, just before the final summary block (the line that starts `echo ""`/`echo "Results"`):

```bash
# ── precompact-handoff.sh (skill-generated handoff protection) ────
echo ""
echo "precompact-handoff.sh (skill-generated handoff protection):"

TEST_CWD_PC="$TMPDIR_ROOT/precompact-protect-test"
mkdir -p "$TEST_CWD_PC"

# Create a minimal JSONL transcript
PC_TRANSCRIPT="$TMPDIR_ROOT/precompact_protect_transcript.jsonl"
echo '{"type":"human","content":"implement auth"}' > "$PC_TRANSCRIPT"
echo '{"type":"assistant","message":{"model":"claude-sonnet-4-6"},"content":[{"type":"text","text":"OK, working on auth implementation now. Let me start by reading the existing code."}]}' >> "$PC_TRANSCRIPT"

# Compute handoff dir and create a skill-generated handoff (no type: auto-generated)
PC_HANDOFF_DIR=$(remembrall_handoff_dir "$TEST_CWD_PC")
mkdir -p "$PC_HANDOFF_DIR"
PC_HANDOFF_FILE="$PC_HANDOFF_DIR/handoff-test-pc-sess.md"

# Write a skill-generated handoff (type is NOT auto-generated — simulates /handoff skill output)
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

# Make it older than 5 minutes so the age check doesn't skip it
touch -t 202603080900 "$PC_HANDOFF_FILE"

# Run precompact — it should NOT overwrite the skill-generated handoff
echo '{"session_id":"test-pc-sess","cwd":"'"$TEST_CWD_PC"'","transcript_path":"'"$PC_TRANSCRIPT"'"}' | \
  bash "$PLUGIN_ROOT/hooks/precompact-handoff.sh" 2>/dev/null

# Verify: file should still contain "Skill Generated" (not overwritten)
if grep -q "Skill Generated" "$PC_HANDOFF_FILE"; then
  printf "${GREEN}  PASS${RESET} skill-generated handoff not overwritten by precompact\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} skill-generated handoff not overwritten by precompact\n"
  FAIL=$((FAIL + 1))
fi

rm -rf "$TEST_CWD_PC"
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | tail -20`

Expected: The test "skill-generated handoff not overwritten by precompact" should FAIL because the `local` bug prevents `existing_type` from being set, so the guard doesn't fire and the file gets overwritten.

**Step 3: Fix the bug — remove `local` keyword**

In `hooks/precompact-handoff.sh`, change line 51 from:

```bash
  local existing_type
  existing_type=$(remembrall_frontmatter_get "$HANDOFF_FILE" "type" 2>/dev/null)
```

to:

```bash
  existing_type=$(remembrall_frontmatter_get "$HANDOFF_FILE" "type" 2>/dev/null)
```

Just remove the `local existing_type` line entirely. The variable assignment on the next line works fine at script scope.

**Step 4: Run test to verify it passes**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | tail -20`

Expected: All tests PASS, including the new "skill-generated handoff not overwritten by precompact" test.

**Step 5: Commit**

```bash
cd /Users/nicolascukas/Web/remembrall
git add hooks/precompact-handoff.sh tests/run-tests.sh
git commit -m "fix: remove local keyword outside function in precompact-handoff.sh

The 'local' keyword on line 51 was at script scope (inside an if block,
not inside a function). Bash silently errored, leaving existing_type unset,
which disabled the skill-generated handoff overwrite protection."
```

---

### Task 2: Add timeout to UserPromptSubmit and SessionStart hooks

`context-monitor.sh` runs multiple jq passes and can call `precompact-handoff.sh` inline. Without a timeout, a large transcript could block the user's prompt indefinitely. Same issue for `session-resume.sh`.

**Files:**
- Modify: `hooks/hooks.json:3-14` (UserPromptSubmit entry)
- Modify: `hooks/hooks.json:28-38` (SessionStart entry)

**Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
# ── hooks.json timeout validation ─────────────────────────────────
echo ""
echo "hooks.json timeout validation:"

# Every hook should have a timeout
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
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | grep -E "(PASS|FAIL).*timeout"`

Expected: FAIL for UserPromptSubmit and SessionStart (they have no timeout). PASS for PreCompact and Stop.

**Step 3: Add timeouts to hooks.json**

In `hooks/hooks.json`, add `"timeout": 15` to the UserPromptSubmit hook and `"timeout": 15` to the SessionStart hook:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/context-monitor.sh",
            "timeout": 15,
            "async": false
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/precompact-handoff.sh",
            "timeout": 30,
            "async": false
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-resume.sh",
            "timeout": 15,
            "async": false
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop-check.sh",
            "timeout": 5,
            "async": false
          }
        ]
      }
    ]
  }
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | grep -E "(PASS|FAIL).*timeout"`

Expected: All 4 hooks show PASS.

**Step 5: Commit**

```bash
cd /Users/nicolascukas/Web/remembrall
git add hooks/hooks.json tests/run-tests.sh
git commit -m "fix: add timeout to UserPromptSubmit and SessionStart hooks

Without timeouts, large transcripts could block prompt submission or
session start indefinitely. Added 15s timeout to both hooks."
```

---

### Task 3: JSON-escape AUTONOMOUS_SKILL in context-monitor.sh

The `AUTONOMOUS_SKILL` variable is read from a file and interpolated raw into JSON. If it contains quotes or backslashes, the JSON output is malformed.

**Files:**
- Modify: `hooks/context-monitor.sh:198,221`
- Modify: `tests/run-tests.sh` (append test)

**Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
# ── context-monitor.sh (autonomous skill with special chars) ──────
echo ""
echo "context-monitor.sh (autonomous skill with special chars):"

CTX_DIR="/tmp/claude-context-pct"
mkdir -p "$CTX_DIR"
TEST_CWD_ESC="$TMPDIR_ROOT/escape-test-cwd"
mkdir -p "$TEST_CWD_ESC"

# Set autonomous mode with a skill name containing a double quote
remembrall_set_autonomous "test-esc-sess" 'ralph"loop'
echo "25" > "$CTX_DIR/test-esc-sess"
rm -f "/tmp/remembrall-nudges/test-esc-sess"

OUTPUT=$(echo '{"session_id":"test-esc-sess","cwd":"'"$TEST_CWD_ESC"'"}' | bash "$PLUGIN_ROOT/hooks/context-monitor.sh" 2>/dev/null)

# Output should be valid JSON despite the quote in the skill name
if echo "$OUTPUT" | jq . >/dev/null 2>&1; then
  printf "${GREEN}  PASS${RESET} autonomous skill with quotes produces valid JSON\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} autonomous skill with quotes produces valid JSON\n"
  FAIL=$((FAIL + 1))
fi

# Cleanup
remembrall_clear_autonomous "test-esc-sess"
rm -f "$CTX_DIR/test-esc-sess" "/tmp/remembrall-nudges/test-esc-sess"
rm -rf "$TEST_CWD_ESC"
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | grep "quotes produces valid JSON"`

Expected: FAIL — the raw `"` in the skill name breaks the JSON.

**Step 3: Escape AUTONOMOUS_SKILL before JSON interpolation**

In `hooks/context-monitor.sh`, after line 185 (where `AUTONOMOUS_SKILL` is set from `remembrall_is_autonomous`), add an escape step. Insert after line 186:

```bash
# Escape for safe JSON interpolation
AUTONOMOUS_SKILL=$(remembrall_escape_json "$AUTONOMOUS_SKILL")
```

The full block (lines 178-186) becomes:

```bash
# ── Detect autonomous mode (ralph loop, swarms, etc.) ──
IS_AUTONOMOUS=false
AUTONOMOUS_SKILL=""
if [ "$(remembrall_config "autonomous_mode" "false")" = "true" ]; then
  IS_AUTONOMOUS=true
  AUTONOMOUS_SKILL="config"
fi
if [ "$IS_AUTONOMOUS" = false ]; then
  AUTONOMOUS_SKILL=$(remembrall_is_autonomous "$SESSION_ID" 2>/dev/null) && IS_AUTONOMOUS=true || true
fi
# Escape for safe JSON interpolation
AUTONOMOUS_SKILL=$(remembrall_escape_json "$AUTONOMOUS_SKILL")
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | grep "quotes produces valid JSON"`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/nicolascukas/Web/remembrall
git add hooks/context-monitor.sh tests/run-tests.sh
git commit -m "fix: JSON-escape AUTONOMOUS_SKILL before interpolation

The autonomous skill name from the marker file was interpolated raw into
JSON heredocs. If it contained quotes or backslashes, the output was
malformed. Now escaped via remembrall_escape_json."
```

---

### Task 4: Replace sed-based bridge injection with jq in session-resume.sh

The sed-based string replacement at line 77 uses `|` as delimiter, but `bridge_snippet` contains `|` characters. This breaks silently when the user's existing `statusLine.command` has pipes in certain positions.

**Files:**
- Modify: `hooks/session-resume.sh:59-81` (the bridge injection section)
- Modify: `tests/run-tests.sh` (append test)

**Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
# ── session-resume.sh (bridge injection with pipes in existing command) ──
echo ""
echo "session-resume.sh (bridge injection with pipes in existing command):"

SETTINGS_FILE="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"

# Create settings with a status line that has pipes before the echo "$status" pattern
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

# Verify bridge was injected and settings is still valid JSON
if jq . "$SETTINGS_FILE" >/dev/null 2>&1; then
  printf "${GREEN}  PASS${RESET} settings.json still valid JSON after bridge injection with pipes\n"
  PASS=$((PASS + 1))
else
  printf "${RED}  FAIL${RESET} settings.json still valid JSON after bridge injection with pipes\n"
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
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | grep "bridge.*injection with pipes"`

Expected: At least one FAIL — the sed approach may corrupt the JSON or fail to inject.

**Step 3: Replace sed with jq-based string concatenation**

In `hooks/session-resume.sh`, replace lines 59-81 (the bridge_snippet + sed section) with a jq-based approach:

```bash
  # Build the bridge snippet
  local bridge_snippet
  if [ "$has_session_id" = true ]; then
    bridge_snippet='CTX_DIR="/tmp/claude-context-pct"; mkdir -p "$CTX_DIR" 2>/dev/null; printf "%s" "$remaining" > "$CTX_DIR/${session_id}" 2>/dev/null;'
  else
    bridge_snippet='session_id=$(echo "$input" | jq -r '"'"'.session_id // empty'"'"'); CTX_DIR="/tmp/claude-context-pct"; mkdir -p "$CTX_DIR" 2>/dev/null; printf "%s" "$remaining" > "$CTX_DIR/${session_id}" 2>/dev/null;'
  fi

  # Append bridge snippet to existing command using jq (safe string concatenation)
  local new_command
  new_command=$(jq -r '.statusLine.command' "$settings_file" 2>/dev/null)
  new_command="${new_command}; ${bridge_snippet}"

  # Write back to settings.json atomically
  local tmp
  tmp=$(mktemp "${settings_file}.XXXXXX")
  jq --arg cmd "$new_command" '.statusLine.command = $cmd' "$settings_file" > "$tmp" 2>/dev/null
  if [ $? -eq 0 ] && [ -s "$tmp" ]; then
    mv "$tmp" "$settings_file"
    echo "Remembrall: bridge auto-configured in settings.json" >&2
  else
    rm -f "$tmp"
  fi
```

This replaces the fragile sed substitution with simple string concatenation. Instead of trying to insert the bridge at a specific position in the command, it appends the bridge snippet at the end. This is safe regardless of what characters exist in the original command.

**Step 4: Run test to verify it passes**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | grep "bridge.*injection with pipes"`

Expected: Both PASS.

**Step 5: Run all tests to check for regressions**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | tail -5`

Expected: 0 failures.

**Step 6: Commit**

```bash
cd /Users/nicolascukas/Web/remembrall
git add hooks/session-resume.sh tests/run-tests.sh
git commit -m "fix: replace sed-based bridge injection with jq string concatenation

The sed approach used | as delimiter, but bridge_snippet contains |
characters. This broke silently when the existing statusLine command
had pipes in certain positions. Now uses simple string append via jq."
```

---

### Task 5: Clean up growth tracking files on session resume

Growth tracking files in `/tmp/remembrall-growth/` accumulate across sessions and are never cleaned up. Add cleanup in `session-resume.sh` alongside existing nudge file cleanup.

**Files:**
- Modify: `hooks/session-resume.sh:212-215`
- Modify: `tests/run-tests.sh` (append test)

**Step 1: Write the failing test**

Append to `tests/run-tests.sh`:

```bash
# ── session-resume.sh (growth file cleanup) ───────────────────────
echo ""
echo "session-resume.sh (growth file cleanup):"

GROWTH_DIR="/tmp/remembrall-growth"
mkdir -p "$GROWTH_DIR"
echo "100000" > "$GROWTH_DIR/test-growth-cleanup-sess"

TEST_CWD_GC="$TMPDIR_ROOT/growth-cleanup-test"
mkdir -p "$TEST_CWD_GC"

# Create a handoff so session-resume has something to process
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

# Growth file should be cleaned up after resume
if [ -f "$GROWTH_DIR/test-growth-cleanup-sess" ]; then
  printf "${RED}  FAIL${RESET} growth file cleaned up on session resume\n"
  FAIL=$((FAIL + 1))
else
  printf "${GREEN}  PASS${RESET} growth file cleaned up on session resume\n"
  PASS=$((PASS + 1))
fi

rm -rf "$TEST_CWD_GC"
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | grep "growth file cleaned"`

Expected: FAIL — no cleanup code exists yet.

**Step 3: Add growth file cleanup to session-resume.sh**

In `hooks/session-resume.sh`, after line 214 (the nudge cleanup block), add:

```bash
  rm -f "/tmp/remembrall-growth/$SESSION_ID"
```

The full cleanup block (lines 212-216) becomes:

```bash
# Clean up nudge temp files for this session
if [ -n "$SESSION_ID" ]; then
  rm -f "/tmp/remembrall-nudges/$SESSION_ID"
  rm -f "/tmp/remembrall-growth/$SESSION_ID"
fi
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | grep "growth file cleaned"`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/nicolascukas/Web/remembrall
git add hooks/session-resume.sh tests/run-tests.sh
git commit -m "fix: clean up growth tracking files on session resume

Growth files in /tmp/remembrall-growth/ accumulated across sessions
without cleanup. Now cleaned alongside nudge files in session-resume.sh."
```

---

### Task 6: Add `set -euo pipefail` to precompact-handoff.sh and stop-check.sh

Two hook scripts lack `set -euo pipefail`, which allows errors to go unnoticed (like the `local` bug in Task 1).

**Files:**
- Modify: `hooks/precompact-handoff.sh:1-3`
- Modify: `hooks/stop-check.sh:1-3`

**Step 1: Verify which scripts lack the option**

Run: `cd /Users/nicolascukas/Web/remembrall && head -5 hooks/*.sh scripts/*.sh`

Check which scripts have `set -euo pipefail` and which don't. Expected: `precompact-handoff.sh` and `stop-check.sh` do not.

**Step 2: Add error handling to precompact-handoff.sh**

After line 1 (`#!/usr/bin/env bash`), add:

```bash
set -euo pipefail
```

But note: `precompact-handoff.sh` uses patterns like `command || exit 0` and `command 2>/dev/null` that work with `set -e`. The `jq` extraction on line 64 uses `2>/dev/null` which is fine. The `echo "$EXTRACTED" | grep` on lines 104-107 will fail with `set -e` if no matches — fix by appending `|| true`:

```bash
FILE_PATHS=$(echo "$EXTRACTED" | grep '^FILE:' | sed 's/^FILE://' | sort -u | head -50 || true)
ERRORS_FOUND=$(echo "$EXTRACTED" | grep '^ERROR:' | sed 's/^ERROR://' | tail -10 | sort -u | tail -5 || true)
GIT_OPS=$(echo "$EXTRACTED" | grep '^GIT:' | sed 's/^GIT://' | tail -20 || true)
TASK_STATE=$(echo "$EXTRACTED" | grep '^TASK:' | sed 's/^TASK://' | tail -30 || true)
```

**Step 3: Add error handling to stop-check.sh**

After line 1, add:

```bash
set -euo pipefail
```

Check: `stop-check.sh` uses `|| exit 0` patterns that are `set -e` safe. The `HASH=$(remembrall_md5 "$CWD")` on line 48 could fail — wrap it: `HASH=$(remembrall_md5 "$CWD") || true`.

**Step 4: Run all tests**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | tail -5`

Expected: All tests pass.

**Step 5: Commit**

```bash
cd /Users/nicolascukas/Web/remembrall
git add hooks/precompact-handoff.sh hooks/stop-check.sh
git commit -m "fix: add set -euo pipefail to precompact-handoff.sh and stop-check.sh

Standardize error handling across all hook scripts. Added || true guards
where grep may legitimately return no matches."
```

---

### Task 7: Add GitHub Actions CI with shellcheck + tests

No CI exists. Add shellcheck linting and test execution on push/PR.

**Files:**
- Create: `.github/workflows/ci.yml`

**Step 1: Create CI workflow**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install shellcheck
        run: sudo apt-get install -y shellcheck
      - name: Run shellcheck on all shell scripts
        run: |
          find hooks scripts tests -name '*.sh' -print0 | \
            xargs -0 shellcheck --severity=warning --shell=bash

  test:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    steps:
      - uses: actions/checkout@v4
      - name: Install jq
        run: |
          if [ "$RUNNER_OS" = "Linux" ]; then
            sudo apt-get install -y jq
          fi
      - name: Make scripts executable
        run: chmod +x hooks/*.sh scripts/*.sh
      - name: Run tests
        run: bash tests/run-tests.sh
```

**Step 2: Verify the workflow file is valid YAML**

Run: `cd /Users/nicolascukas/Web/remembrall && cat .github/workflows/ci.yml | python3 -c "import sys,yaml; yaml.safe_load(sys.stdin); print('Valid YAML')" 2>&1`

Expected: "Valid YAML"

**Step 3: Commit**

```bash
cd /Users/nicolascukas/Web/remembrall
git add .github/workflows/ci.yml
git commit -m "ci: add GitHub Actions workflow with shellcheck and cross-platform tests

Runs shellcheck --severity=warning on all .sh files and executes the
test suite on both ubuntu-latest and macos-latest."
```

---

### Task 8: Fix shellcheck warnings

After CI is set up, run shellcheck locally and fix any warnings. This task is open-ended — fix what shellcheck reports.

**Files:**
- Modify: any `.sh` files that shellcheck flags

**Step 1: Run shellcheck locally**

Run: `cd /Users/nicolascukas/Web/remembrall && shellcheck --severity=warning --shell=bash hooks/*.sh scripts/*.sh 2>&1 | head -100`

**Step 2: Fix each warning**

Common expected issues:
- SC2086: Double quote to prevent globbing and word splitting
- SC2155: Declare and assign separately to avoid masking return values
- SC2034: Unused variables

Fix each warning. Do NOT suppress with `# shellcheck disable` unless the warning is a false positive (document why).

**Step 3: Verify clean**

Run: `cd /Users/nicolascukas/Web/remembrall && shellcheck --severity=warning --shell=bash hooks/*.sh scripts/*.sh`

Expected: No output (clean).

**Step 4: Run tests to ensure no regressions**

Run: `cd /Users/nicolascukas/Web/remembrall && bash tests/run-tests.sh 2>&1 | tail -5`

Expected: All tests pass.

**Step 5: Commit**

```bash
cd /Users/nicolascukas/Web/remembrall
git add hooks/*.sh scripts/*.sh
git commit -m "fix: resolve shellcheck warnings across all scripts

Fixed quoting, separate declare/assign, and other shellcheck warnings.
No functional changes."
```

---

### Task 9: Bump version to 2.3.1

**Files:**
- Modify: `.claude-plugin/plugin.json:5`
- Modify: `README.md` (if version is mentioned)

**Step 1: Update plugin.json version**

Change `"version": "2.3.0"` to `"version": "2.3.1"`.

**Step 2: Check README for version references**

Run: `grep -n "2\.3\.0" README.md`

If found, update to `2.3.1`.

**Step 3: Commit**

```bash
cd /Users/nicolascukas/Web/remembrall
git add .claude-plugin/plugin.json README.md
git commit -m "chore: bump version to 2.3.1

Includes bugfixes: local outside function, missing hook timeouts,
JSON injection in autonomous skill name, fragile sed bridge injection,
growth file leak, standardized error handling, and CI setup."
```
