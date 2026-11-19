#!/usr/bin/env bash
# bloob PTY smoke harness.
#
# Drives the real interactive TUI through a pseudo-terminal, feeds keys with
# bounded waits, captures the ANSI byte stream and asserts on the stripped
# screen text. No API keys, network access or non-fixture providers are used.
#
# Requirements: bash, script (util-linux), stty, timeout, sed, grep, cp, mkdir,
# mktemp, rm, cat. Everything is available in the repository's Nix devShell.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BLOOB_BIN:-$ROOT/zig-out/bin/bloob}"
FIXTURES="$ROOT/tests/fixtures"
EXPECTED_FAILURES="$ROOT/tests/expected_failures.tsv"
ARTIFACTS="${BLOOB_TEST_ARTIFACTS:-$ROOT/tests/.artifacts}"

ROWS="${BLOOB_TEST_ROWS:-30}"
COLS="${BLOOB_TEST_COLS:-100}"
SCALE_MS="${BLOOB_TEST_SCALE_MS:-1000}"
CASE_TIMEOUT_MS="${BLOOB_TEST_TIMEOUT_MS:-30000}"
WAIT_MS="${BLOOB_TEST_WAIT_MS:-10000}"

WORK="$(mktemp -d /tmp/bloob-pty.XXXXXX)" || {
  printf 'pty_smoke: cannot create temp directory\n' >&2
  exit 1
}
KEEP="${BLOOB_TEST_KEEP:-0}"

cleanup() {
  if [[ "$KEEP" == "1" ]]; then
    printf 'pty_smoke: kept work directory: %s\n' "$WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

CASE_NAME=""
CASE_DIR=""
CASE_WS=""
CASE_RAW=""
CASE_TXT=""
CASE_EXIT=""
CASE_ERRORS=()
FEED_VALUE=""

PASS=0
FAIL=0
XFAIL=0
XPASS=0
FAILED_CASES=()

die() {
  printf 'pty_smoke: %s\n' "$*" >&2
  exit 1
}

# Scale every sleep by BLOOB_TEST_SCALE_MS / 1000 so slow CI machines can use
# e.g. BLOOB_TEST_SCALE_MS=2000 without editing the harness.
sleep_ms() {
  local ms=$(( $1 * SCALE_MS / 1000 ))
  (( ms > 0 )) || ms=1
  printf -v _sleep_fmt '%d.%03d' $(( ms / 1000 )) $(( ms % 1000 ))
  sleep "$_sleep_fmt"
}

strip_ansi() {
  # Turn cursor-positioning sequences into newlines first so each rendered
  # terminal row becomes one text line, then remove every remaining escape.
  LC_ALL=C sed -E \
    $'s/\x1b\\[[0-9;?]*H/\\n/g; s/\x1b\\][^\x07]*(\x07|\x1b\\\\)//g; s/\x1b\\[[0-9;?]*[ -\\/]*[@-~]//g; s/\x1b[@-_]//g; s/\r//g' \
    "$1"
}

wait_for_text() {
  local file=$1
  local pattern=$2
  local max_ms=${3:-$WAIT_MS}
  local waited=0
  while (( waited < max_ms )); do
    if [[ -f "$file" ]] && grep -Fq -- "$pattern" "$file" 2>/dev/null; then
      return 0
    fi
    sleep_ms 50
    waited=$(( waited + 50 ))
  done
  return 1
}

note_fail() {
  CASE_ERRORS+=("$*")
}

expect_text() {
  local label=$1 file=$2 pattern=$3
  if ! grep -Fq -- "$pattern" "$file" 2>/dev/null; then
    note_fail "missing $label: '$pattern'"
  fi
}

expect_text_absent() {
  local label=$1 file=$2 pattern=$3
  if grep -Fq -- "$pattern" "$file" 2>/dev/null; then
    note_fail "unexpected $label: '$pattern'"
  fi
}

expect_raw_bytes() {
  local label=$1 file=$2 bytes=$3
  if ! LC_ALL=C grep -Fq -- "$bytes" "$file" 2>/dev/null; then
    note_fail "missing raw $label"
  fi
}

expect_exit() {
  local want=$1
  if [[ "$CASE_EXIT" != "$want" ]]; then
    note_fail "exit status $CASE_EXIT, want $want"
  fi
}

expect_exists() {
  local label=$1 path=$2
  if [[ ! -f "$path" ]]; then
    note_fail "missing $label: $path"
  fi
}

expect_file_text() {
  local label=$1 path=$2 expected=$3
  if [[ ! -f "$path" ]]; then
    note_fail "missing $label: $path"
    return
  fi
  if [[ "$(cat -- "$path")" != "$expected" ]]; then
    note_fail "$label content changed unexpectedly"
  fi
}

expect_file_contains() {
  local label=$1 path=$2 pattern=$3
  if [[ ! -f "$path" ]]; then
    note_fail "missing $label: $path"
    return
  fi
  if ! grep -Fq -- "$pattern" "$path"; then
    note_fail "$label does not contain '$pattern'"
  fi
}

write_runner() {
  local runner="$CASE_DIR/run.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cd %q || exit 1\n' "$CASE_DIR"
    printf 'stty rows %q cols %q -ixon\n' "$ROWS" "$COLS"
    printf 'exec '
    printf '%q ' "$@"
    printf '\n'
  } > "$runner" || die "cannot write runner for $CASE_NAME"
  chmod +x "$runner" || die "cannot chmod runner for $CASE_NAME"
}

pty_capture() {
  local feed=$1
  shift
  write_runner "$@"

  local timeout_s=$(( CASE_TIMEOUT_MS * SCALE_MS / 1000000 ))
  (( timeout_s >= 5 )) || timeout_s=5

  # The feeder runs on the left side of the pipeline and polls CASE_RAW, so it
  # can react to the UI instead of relying only on fixed sleeps.
  ( "$feed" ) | \
    env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
      HOME="$CASE_DIR/home" \
      XDG_CONFIG_HOME="$CASE_DIR/xdg" \
      TERM="xterm-256color" \
      LANG="C.UTF-8" \
      LC_ALL="C.UTF-8" \
      timeout "${timeout_s}s" script -q -e -c "exec $CASE_DIR/run.sh" /dev/null \
      > "$CASE_RAW"
  CASE_EXIT=${PIPESTATUS[1]}
  strip_ansi "$CASE_RAW" > "$CASE_TXT" 2>/dev/null || : > "$CASE_TXT"
}

begin_case() {
  CASE_NAME=$1
  CASE_DIR="$WORK/$CASE_NAME"
  CASE_WS="$CASE_DIR/ws"
  CASE_RAW="$ARTIFACTS/$CASE_NAME.raw"
  CASE_TXT="$ARTIFACTS/$CASE_NAME.txt"
  mkdir -p "$CASE_DIR" "$CASE_WS" "$CASE_DIR/home" "$CASE_DIR/xdg" "$ARTIFACTS"
  CASE_ERRORS=()
  CASE_EXIT=""
  FEED_VALUE=""
}

expected_failure_reason() {
  local name=$1
  [[ -f "$EXPECTED_FAILURES" ]] || return 1
  local case_name reason
  while IFS=$'\t' read -r case_name reason; do
    [[ -z "$case_name" || "$case_name" == \#* ]] && continue
    if [[ "$case_name" == "$name" ]]; then
      printf '%s' "${reason:-no reason recorded}"
      return 0
    fi
  done < "$EXPECTED_FAILURES"
  return 1
}

tail_log() {
  local file=$1
  [[ -f "$file" ]] || return 0
  printf '  --- last 25 stripped lines of %s ---\n' "$file"
  tail -n 25 -- "$file" | sed 's/^/  | /'
}

end_case() {
  local txt="$CASE_TXT"

  local reason
  reason="$(expected_failure_reason "$CASE_NAME" || true)"

  if (( ${#CASE_ERRORS[@]} == 0 )); then
    if [[ -n "$reason" ]]; then
      XPASS=$(( XPASS + 1 ))
      printf '[XPASS] %s (listed as expected failure: %s)\n' "$CASE_NAME" "$reason"
    else
      PASS=$(( PASS + 1 ))
      printf '[PASS]  %s\n' "$CASE_NAME"
    fi
    return
  fi

  if [[ -n "$reason" ]]; then
    XFAIL=$(( XFAIL + 1 ))
    printf '[XFAIL] %s (documented product failure: %s)\n' "$CASE_NAME" "$reason"
    printf '        raw: %s\n' "$CASE_RAW"
    printf '        txt: %s\n' "$txt"
    local err
    for err in "${CASE_ERRORS[@]}"; do printf '        %s\n' "$err"; done
    tail_log "$txt"
    return
  fi

  FAIL=$(( FAIL + 1 ))
  FAILED_CASES+=("$CASE_NAME")
  printf '[FAIL]  %s\n' "$CASE_NAME"
  printf '        raw: %s\n' "$CASE_RAW"
  printf '        txt: %s\n' "$txt"
  local err
  for err in "${CASE_ERRORS[@]}"; do printf '        %s\n' "$err"; done
  tail_log "$txt"
}

# ---------------------------------------------------------------------------
# Input feeders. Each one runs in the pipeline subshell and may poll CASE_RAW.
# ---------------------------------------------------------------------------

feed_quit_after_boot() {
  wait_for_text "$CASE_RAW" "INSERT" || true
  sleep_ms 250
  printf '\021' # Ctrl-Q
  sleep_ms 400
}

feed_stream() {
  wait_for_text "$CASE_RAW" "Welcome to" || true
  sleep_ms 150
  printf 'hello harness'
  sleep_ms 150
  printf '\023' # Ctrl-S submits
  wait_for_text "$CASE_RAW" "You said:" 6000 || true
  wait_for_text "$CASE_RAW" '`/tools`.' "$WAIT_MS" || true
  sleep_ms 400
  printf '\021'
  sleep_ms 400
}

feed_custom_layout() {
  wait_for_text "$CASE_RAW" "HARNESS-WIDGET-OK" || true
  sleep_ms 200
  printf 'custom layout works'
  sleep_ms 150
  printf '\023'
  wait_for_text "$CASE_RAW" "You said:" 6000 || true
  wait_for_text "$CASE_RAW" '`/tools`.' "$WAIT_MS" || true
  sleep_ms 400
  printf '\021'
  sleep_ms 400
}

feed_broken_config() {
  wait_for_text "$CASE_RAW" "HARNESS-BROKEN-CONFIG" || true
  sleep_ms 200
  printf 'recovered'
  sleep_ms 150
  printf '\023'
  wait_for_text "$CASE_RAW" "You said:" 6000 || true
  wait_for_text "$CASE_RAW" '`/tools`.' "$WAIT_MS" || true
  sleep_ms 400
  printf '\021'
  sleep_ms 400
}

feed_cancel() {
  wait_for_text "$CASE_RAW" "Welcome to" || true
  sleep_ms 150
  printf 'cancel this stream'
  sleep_ms 150
  printf '\023'
  wait_for_text "$CASE_RAW" "streaming" 6000 || true
  sleep_ms 350
  printf '\003' # Ctrl-C cancels the fixture stream
  wait_for_text "$CASE_RAW" "cancelled" 6000 || true
  sleep_ms 250
  printf '\021'
  sleep_ms 400
}

feed_approval() {
  local decision=$1
  wait_for_text "$CASE_RAW" "Welcome to" || true
  sleep_ms 150
  printf 'create %s' "$FEED_VALUE"
  sleep_ms 150
  printf '\023'
  wait_for_text "$CASE_RAW" "Approval required" "$WAIT_MS" || true
  sleep_ms 250
  printf '%s' "$decision"
  if [[ "$decision" == "a" ]]; then
    wait_for_text "$CASE_RAW" "File written successfully." "$WAIT_MS" || true
  else
    wait_for_text "$CASE_RAW" "Denied by the user." "$WAIT_MS" || true
  fi
  sleep_ms 300
  printf '\021'
  sleep_ms 400
}

feed_shell_cancel() {
  wait_for_text "$CASE_RAW" "Welcome to" || true
  sleep_ms 150
  printf "run sleep 5; printf 'SHELL''_DONE_OUTPUT'"
  sleep_ms 150
  printf '\023'
  wait_for_text "$CASE_RAW" "Approval required" "$WAIT_MS" || true
  sleep_ms 250
  printf 'a'
  wait_for_text "$CASE_RAW" "shell" "$WAIT_MS" || true
  sleep_ms 700
  printf '\003' # Ctrl-C cancels the async shell
  wait_for_text "$CASE_RAW" "command cancelled" "$WAIT_MS" || true
  sleep_ms 400
  printf '\021'
  sleep_ms 400
}

feed_reload() {
  wait_for_text "$CASE_RAW" "RELOAD_A" "$WAIT_MS" || true
  cp "$CASE_DIR/reload_b.lua" "$CASE_DIR/reload.lua"
  sleep_ms 200
  printf '\022' # Ctrl-R
  wait_for_text "$CASE_RAW" "RELOAD_B" "$WAIT_MS" || true
  sleep_ms 300
  printf '\021'
  sleep_ms 400
}

feed_session_first() {
  wait_for_text "$CASE_RAW" "Welcome to" || true
  sleep_ms 150
  printf 'SESSION_PERSIST_TOKEN'
  sleep_ms 150
  printf '\023'
  wait_for_text "$CASE_RAW" "SESSION_PERSIST_TOKEN" 6000 || true
  wait_for_text "$CASE_RAW" "fixture provider" 6000 || true
  sleep_ms 500
  printf '\021'
  sleep_ms 400
}

feed_plugin() {
  wait_for_text "$CASE_RAW" "Welcome to" || true
  sleep_ms 150
  printf '/harness.plugin'
  sleep_ms 150
  printf '\023'
  wait_for_text "$CASE_RAW" "PLUGIN_HARNESS_OK" "$WAIT_MS" || true
  sleep_ms 300
  printf '\021'
  sleep_ms 400
}

feed_deny() {
  feed_approval d
}

feed_allow() {
  feed_approval a
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

case_cold_boot_no_config() {
  begin_case cold_boot_no_config
  # A decoy user config proves --no-config never reads XDG_CONFIG_HOME.
  mkdir -p "$CASE_DIR/xdg/bloob"
  cat > "$CASE_DIR/xdg/bloob/init.lua" <<'LUA'
local ui = require("bloob.ui")
ui.set_layout(function()
  return ui.column({ ui.text("DECOY-CONFIG-LOADED", { color = "error" }) })
end)
LUA

  pty_capture feed_quit_after_boot "$BIN" --no-config --cwd ws
  expect_exit 0
  expect_text "splash" "$CASE_TXT" "Welcome to **bloob**"
  expect_text "ready banner" "$CASE_TXT" "bloob is ready. Model: mock/fixture"
  expect_text "default layout" "$CASE_TXT" "Conversation"
  expect_text "default prompt" "$CASE_TXT" "Prompt  (Enter send"
  expect_text "insert status" "$CASE_TXT" "INSERT  mock/fixture  idle"
  expect_text_absent "decoy user config" "$CASE_TXT" "DECOY-CONFIG-LOADED"
  end_case
}

case_ctrl_q_restore() {
  begin_case ctrl_q_restore
  pty_capture feed_quit_after_boot "$BIN" --no-config --cwd ws
  expect_exit 0
  expect_text "insert status" "$CASE_TXT" "INSERT  mock/fixture  idle"
  expect_raw_bytes "alternate-screen enter" "$CASE_RAW" $'\x1b[?1049h'
  expect_raw_bytes "alternate-screen leave" "$CASE_RAW" $'\x1b[?1049l'
  expect_raw_bytes "mouse disable" "$CASE_RAW" $'\x1b[?1000l'
  expect_raw_bytes "SGR mouse disable" "$CASE_RAW" $'\x1b[?1006l'
  expect_raw_bytes "bracketed-paste disable" "$CASE_RAW" $'\x1b[?2004l'
  expect_raw_bytes "focus-events disable" "$CASE_RAW" $'\x1b[?1004l'
  expect_raw_bytes "cursor show" "$CASE_RAW" $'\x1b[?25h'
  end_case
}

case_mock_streaming_ctrl_s() {
  begin_case mock_streaming_ctrl_s
  pty_capture feed_stream "$BIN" --no-config --cwd ws
  expect_exit 0
  expect_text "user message" "$CASE_TXT" "hello harness"
  expect_text "assistant heading" "$CASE_TXT" "You said:"
  expect_text "stream state observed" "$CASE_TXT" "streaming"
  expect_text "stream completed" "$CASE_TXT" "composable UI"
  expect_text "fixture marker" "$CASE_TXT" "fixture provider"
  end_case
}

case_custom_lua_layout_widget() {
  begin_case custom_lua_layout_widget
  cp "$FIXTURES/custom_layout.lua" "$CASE_DIR/custom.lua"

  pty_capture feed_custom_layout "$BIN" --config custom.lua --cwd ws
  expect_exit 0
  expect_text "registered widget" "$CASE_TXT" "HARNESS-WIDGET-OK"
  expect_text "widget terminal size" "$CASE_TXT" "100x30"
  expect_text "custom chat title" "$CASE_TXT" "Harness Chat"
  expect_text "custom input title" "$CASE_TXT" "Harness Input"
  expect_text "loaded config notice" "$CASE_TXT" "Loaded conf"
  expect_text "custom layout still converses" "$CASE_TXT" "You said:"
  expect_text_absent "layout fallback" "$CASE_TXT" "UI layout error"
  end_case
}

case_broken_init_fallback() {
  begin_case broken_init_fallback
  cp "$FIXTURES/broken_init.lua" "$CASE_DIR/b.lua"

  pty_capture feed_broken_config "$BIN" --config b.lua --cwd ws
  expect_exit 0
  expect_text "config error reported" "$CASE_TXT" "HARNESS-BROKEN-CONFIG"
  expect_text "default splash after fallback" "$CASE_TXT" "Welcome to **bloob**"
  expect_text "default layout after fallback" "$CASE_TXT" "Conversation"
  expect_text "default prompt after fallback" "$CASE_TXT" "Prompt  (Enter send"
  expect_text "fallback remains usable" "$CASE_TXT" "You said:"
  expect_text "recovered prompt" "$CASE_TXT" "recovered"
  end_case
}

case_approval_deny_unchanged() {
  begin_case approval_deny_unchanged
  local target="$CASE_WS/keep.txt"
  printf 'ORIGINAL\n' > "$target"
  FEED_VALUE="keep.txt"

  pty_capture feed_deny "$BIN" --no-config --cwd ws
  expect_exit 0
  expect_text "approval modal" "$CASE_TXT" "Approval required"
  expect_text "approval tool" "$CASE_TXT" "Tool: write_file"
  expect_text "denial result" "$CASE_TXT" "Denied by the user."
  expect_file_text "denied target" "$target" "ORIGINAL"
  end_case
}

case_approval_allow_creates() {
  begin_case approval_allow_creates
  local target="$CASE_WS/made.txt"
  FEED_VALUE="made.txt"

  pty_capture feed_allow "$BIN" --no-config --cwd ws
  expect_exit 0
  expect_text "approval modal" "$CASE_TXT" "Approval required"
  expect_text "approval tool" "$CASE_TXT" "Tool: write_file"
  expect_text "write result" "$CASE_TXT" "File written successfully."
  expect_exists "allowed target" "$target"
  expect_file_contains "allowed target" "$target" "Created by the bloob offline fixture."
  end_case
}

case_ctrl_c_cancels_stream() {
  begin_case ctrl_c_cancels_stream
  pty_capture feed_cancel "$BIN" --no-config --cwd ws
  expect_exit 0
  expect_text "cancel marker" "$CASE_TXT" "[cancelled]"
  expect_text "cancel notice" "$CASE_TXT" "Request cancelled"
  expect_text "cancelled state" "$CASE_TXT" "cancelled"
  end_case
}

case_async_shell_cancel() {
  begin_case async_shell_cancel
  pty_capture feed_shell_cancel "$BIN" --no-config --cwd ws
  expect_exit 0
  expect_text "approval modal" "$CASE_TXT" "Approval required"
  expect_text "shell approval command" "$CASE_TXT" "sleep 5"
  expect_text "shell cancelled result" "$CASE_TXT" "[command cancelled]"
  expect_text "shell cancel notice" "$CASE_TXT" "Shell command cancelled"
  expect_text_absent "shell was not allowed to finish" "$CASE_TXT" "SHELL_DONE_OUTPUT"
  end_case
}

case_reload_swaps_layout() {
  begin_case reload_swaps_layout
  cat > "$CASE_DIR/reload.lua" <<'LUA'
local ui = require("bloob.ui")
ui.register("reload.marker", function() return ui.text("RELOAD_A") end)
ui.set_layout(function()
  return ui.column({ ui.row({ ui.chat({ flex = 1 }), ui.widget("reload.marker", { width = 20 }) }, { flex = 1 }), ui.input({ height = 6 }), ui.statusline() })
end)
LUA
  cat > "$CASE_DIR/reload_b.lua" <<'LUA'
local ui = require("bloob.ui")
ui.register("reload.marker", function() return ui.text("RELOAD_B") end)
ui.set_layout(function()
  return ui.column({ ui.row({ ui.chat({ flex = 1 }), ui.widget("reload.marker", { width = 20 }) }, { flex = 1 }), ui.input({ height = 6 }), ui.statusline() })
end)
LUA
  pty_capture feed_reload "$BIN" --config reload.lua --cwd ws
  expect_exit 0
  expect_text "initial layout" "$CASE_TXT" "RELOAD_A"
  expect_text "reloaded layout" "$CASE_TXT" "RELOAD_B"
  expect_text "reload notice" "$CASE_TXT" "Configuration reloaded"
  end_case
}

case_session_resume() {
  begin_case session_resume
  pty_capture feed_session_first "$BIN" --no-config --cwd ws
  expect_exit 0
  expect_text "first user message" "$CASE_TXT" "SESSION_PERSIST_TOKEN"
  pty_capture feed_quit_after_boot "$BIN" --no-config --cwd ws --resume
  expect_exit 0
  expect_text "resumed user message" "$CASE_TXT" "SESSION_PERSIST_TOKEN"
  expect_text "resume notice" "$CASE_TXT" "Session resumed"
  end_case
}

case_user_plugin_loads() {
  begin_case user_plugin_loads
  mkdir -p "$CASE_DIR/xdg/bloob/plugins/harness"
  cat > "$CASE_DIR/xdg/bloob/plugins/harness/plugin.lua" <<'LUA'
local bloob = require("bloob")
bloob.command.register("harness.plugin", {
  description = "Harness plugin command",
  run = function(ctx) ctx:notify("PLUGIN_HARNESS_OK") end,
})
LUA
  pty_capture feed_plugin "$BIN" --cwd ws
  expect_exit 0
  expect_text "plugin loaded notice" "$CASE_TXT" "Loaded 1 plugin"
  expect_text "plugin command result" "$CASE_TXT" "PLUGIN_HARNESS_OK"
  end_case
}

all_cases() {
  case_cold_boot_no_config
  case_ctrl_q_restore
  case_mock_streaming_ctrl_s
  case_custom_lua_layout_widget
  case_broken_init_fallback
  case_approval_deny_unchanged
  case_approval_allow_creates
  case_ctrl_c_cancels_stream
  case_async_shell_cancel
  case_reload_swaps_layout
  case_session_resume
  case_user_plugin_loads
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "${BLOOB_PTY_SKIP_BUILD:-0}" != "1" ]]; then
  printf 'pty_smoke: building with nix develop\n'
  ( cd "$ROOT" && nix develop -c zig build ) || die "nix develop -c zig build failed"
fi

[[ -x "$BIN" ]] || die "bloob binary not found or not executable: $BIN"
mkdir -p "$ARTIFACTS"
: > "$ARTIFACTS/.gitkeep"

printf 'bloob PTY smoke harness\n'
printf '  binary: %s\n' "$BIN"
printf '  pty:    %s rows x %s cols\n' "$ROWS" "$COLS"
printf '  scale:  %s ms per nominal 1000 ms\n' "$SCALE_MS"
printf '  logs:   %s\n\n' "$ARTIFACTS"

all_cases

TOTAL=$(( PASS + FAIL + XFAIL + XPASS ))
printf '\nSummary: %d passed, %d failed, %d expected-fail, %d unexpected-pass (of %d)\n' \
  "$PASS" "$FAIL" "$XFAIL" "$XPASS" "$TOTAL"

if (( FAIL > 0 )); then
  printf 'Failed cases: %s\n' "${FAILED_CASES[*]}"
  exit 1
fi
exit 0
