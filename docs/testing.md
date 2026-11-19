# Testing bloob

This document covers the automated tests that exist in the repository, with a
focus on the noninteractive PTY smoke harness. It is intentionally practical:
every command below was run against the checkpoint named at the end of this
page.

## 1. Test layers

| Layer | Command | What it proves |
| --- | --- | --- |
| Build | `nix develop -c zig build` | The executable compiles with the pinned Zig 0.17.1 and LuaJIT link flags. |
| Unit / integration | `nix develop -c zig build test` | Text, styles, frames, input parsing, editor, layout, chat wrapping, Lua runtime, workspace safety, permissions, tools, provider request/stream parsing. |
| Headless smoke | `nix develop -c zig build smoke` | The deterministic fixture provider works without a terminal. |
| Headless JSON smoke | `nix develop -c zig build smoke-json` | The fixture JSON event shape stays one-object-per-line and ANSI-free. |
| PTY smoke | `tests/pty_smoke.sh` | The real TUI boots, reads keys, streams, asks for approval, writes/denies files, cancels, exits, and restores the terminal. |
| Everything | `tests/run_all.sh` | Build + unit tests + PTY smoke in one invocation. |

`src/tests.zig` is the Zig test entry point. The PTY harness is deliberately a
separate shell script: it drives the installed executable through a real
pseudo-terminal rather than testing application internals.

## 2. Quick start

From the repository root:

```sh
# Build, run unit tests, then run the PTY harness.
tests/run_all.sh
```

Run only the PTY harness (it builds first unless skipped):

```sh
tests/pty_smoke.sh

# Reuse an existing zig-out/bin/bloob.
BLOOB_PTY_SKIP_BUILD=1 tests/pty_smoke.sh

# Use a specific executable.
BLOOB_BIN=/path/to/bloob BLOOB_PTY_SKIP_BUILD=1 tests/pty_smoke.sh
```

The harness writes an ANSI byte capture and a stripped screen capture for each
case to `tests/.artifacts/` (ignored by Git). Failed cases print the paths and
the last 25 stripped lines. Set `BLOOB_TEST_KEEP=1` to keep the temporary
workspaces and generated runner scripts under `/tmp/bloob-pty.*`.

## 3. What the harness does

`tests/pty_smoke.sh`:

1. Builds bloob with `nix develop -c zig build` unless
   `BLOOB_PTY_SKIP_BUILD=1`.
2. Creates an isolated temporary directory for each case with its own home,
   XDG config directory and workspace.
3. Generates a small `run.sh` that applies `stty rows 30 cols 100 -ixon`, changes
   into the case directory and `exec`s bloob with the case arguments. Using a
   generated script avoids shell-quoting problems in `script -c`.
4. Runs bloob under `script -q -e -c ... /dev/null`, so stdin and stdout are a
   real PTY. The overall run is bounded by `timeout`.
5. Feeds keys from the left side of the pipeline. Feeders poll the live raw
   capture with `grep` for a state marker (for example `Approval required` or
   `HARNESS-WIDGET-OK`) before sending the next key. Fixed sleeps are still used
   between plain typing and control keys, and as bounded fallbacks.
6. Captures the raw ANSI stream. The stripper converts cursor-positioning
   sequences (`ESC[row;colH`) to newlines and removes the remaining CSI, OSC and
   two-byte escape sequences. Assertions run against the resulting text.
7. Asserts on stripped text, raw terminal markers, process exit status and files
   in the temporary workspace.

No API keys are required. The right side of the pipeline explicitly unsets
`OPENAI_API_KEY` and `ANTHROPIC_API_KEY`, and every case uses the deterministic
`mock/fixture` provider. No network calls are made.

## 4. Cases

| Case | Coverage |
| --- | --- |
| `cold_boot_no_config` | `--no-config` ignores a decoy `$XDG_CONFIG_HOME/bloob/init.lua`; default splash, layout, prompt and status render. |
| `ctrl_q_restore` | Ctrl-Q exits 0; raw output contains alternate-screen enter/leave, cursor-show, mouse/bracketed-paste/focus-event disable sequences. |
| `mock_streaming_ctrl_s` | Typing and submitting with Ctrl-S produces a user message and a streamed fixture response; the `streaming` state is observable. |
| `custom_lua_layout_widget` | A `--config` file registers a widget and replaces the layout; the widget sees the PTY size (`100x30`), custom panel titles render, and the layout still converses. |
| `broken_init_fallback` | A config that raises at load time is reported, a clean default Lua runtime is used, and defaults remain usable for a full prompt/stream cycle. |
| `approval_deny_unchanged` | A fixture `write_file` proposal shows the approval modal; denying it (`d`) leaves a pre-existing file byte-for-byte unchanged. |
| `approval_allow_creates` | The same proposal allowed once (`a`) creates the file with the fixture content. |
| `ctrl_c_cancels_stream` | Ctrl-C during a fixture stream appends the cancellation marker, sets the cancelled state, reports `Request cancelled`, and exits cleanly. |

Fixtures:

- `tests/fixtures/custom_layout.lua` — custom layout plus `HARNESS-WIDGET-OK`
  widget.
- `tests/fixtures/broken_init.lua` — raises `HARNESS-BROKEN-CONFIG` on load.

The workspace files used by the approval cases are created by the harness; no
fixture workspace needs to be committed.

## 5. Determinism and configuration

The PTY is fixed at 30 rows x 100 columns. The custom-widget case additionally
asserts the widget receives `100x30`, so a broken `stty` wrapper fails visibly.

Environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `BLOOB_BIN` | `$ROOT/zig-out/bin/bloob` | Executable under test. |
| `BLOOB_PTY_SKIP_BUILD` | unset (builds) | `1` skips `nix develop -c zig build`. |
| `BLOOB_TEST_ROWS` | `30` | PTY rows. |
| `BLOOB_TEST_COLS` | `100` | PTY columns. |
| `BLOOB_TEST_SCALE_MS` | `1000` | Multiplier for every harness sleep; `2000` doubles all waits. |
| `BLOOB_TEST_TIMEOUT_MS` | `30000` | Per-case wall-clock timeout (also scaled, minimum 5 s). |
| `BLOOB_TEST_WAIT_MS` | `10000` | Bounded wait for a UI marker before a feeder continues. |
| `BLOOB_TEST_ARTIFACTS` | `$ROOT/tests/.artifacts` | Raw and stripped capture directory. |
| `BLOOB_TEST_KEEP` | `0` | `1` keeps the temporary work root. |

The fixture stream advances at roughly six characters per 18 ms tick. The
feeders wait for the final response text before sending Ctrl-Q, instead of
guessing a single stream duration.

## 6. Known flakiness and limitations

- **Pseudo-terminal tooling.** The harness assumes util-linux `script` with
  `-q`, `-e` and `-c`. It is exercised on Linux/Nix. On systems whose `script`
  lacks `-e`, the exit status assertion will fail even if the UI output is
  correct. macOS `script` has different arguments.
- **Scheduling under load.** Startup, streaming ticks and Lua loading are
  polling-based, so a very slow or heavily loaded machine can exceed a
  `BLOOB_TEST_WAIT_MS` window. Increase `BLOOB_TEST_SCALE_MS` (for example
  `BLOOB_TEST_SCALE_MS=3000`) and/or `BLOOB_TEST_WAIT_MS`.
- **Full-frame redraws.** bloob currently emits complete ANSI frames. Captured
  text therefore contains the same labels many times, and assertions are
  substring-based rather than exact-frame snapshots. Wording changes in the UI
  require updating the corresponding assertion.
- **Unicode/width assumptions.** Assertions use ASCII markers where possible.
  Some frames contain box-drawing characters; `LC_ALL=C.UTF-8` is set, and the
  case patterns avoid ambiguous wide-character boundaries.
- **Terminal restoration.** The harness asserts the literal disable/show
  sequences written on controlled exit and exit status 0. It cannot inspect the
  child's termios after the PTY is gone, so it does not independently assert
  that every termios flag was restored.
- **No signature/key/network paths.** Provider authentication, real SSE
  transport, sessions, MCP/LSP and multi-agent features are outside this
  harness. They need separate fixture servers or record/replay tests.
- **First Nix run.** `nix develop` may need to fetch flake inputs if they are not
  already in the store. That is a package-manager network access, not a bloob
  API call; after the shell is cached the harness itself is offline.

## 7. Expected failures

Do not skip a blocked product case silently. If a real product bug prevents a
case from passing:

1. Add a tab-separated row to `tests/expected_failures.tsv`:

   ```text
   case_name	short, exact reason with a link/issue reference if available
   ```

2. Keep the case and its assertions in `tests/pty_smoke.sh`.
3. The harness will print `[XFAIL]`, include the assertion errors, and print the
   raw/stripped artifact paths with the last captured lines. It exits 0 when the
   only failures are documented expected failures.
4. If a listed case starts passing, the harness prints `[XPASS]` so the stale
   entry is visible. Remove the row.

At this checkpoint the expected-failure list is empty.

## 8. Current result

Branch: `agent/pty-harness`, based on `main` checkpoint `8bd4e54`.

Commands run from the repository root:

```text
nix develop -c zig build
nix develop -c zig build test
tests/run_all.sh
```

Result: all commands exit 0. `tests/run_all.sh` reports:

```text
== nix develop -c zig build ==
== nix develop -c zig build test ==
== tests/pty_smoke.sh ==
bloob PTY smoke harness
  binary: .../zig-out/bin/bloob
  pty:    30 rows x 100 cols
  scale:  1000 ms per nominal 1000 ms

[PASS]  cold_boot_no_config
[PASS]  ctrl_q_restore
[PASS]  mock_streaming_ctrl_s
[PASS]  custom_lua_layout_widget
[PASS]  broken_init_fallback
[PASS]  approval_deny_unchanged
[PASS]  approval_allow_creates
[PASS]  ctrl_c_cancels_stream

Summary: 8 passed, 0 failed, 0 expected-fail, 0 unexpected-pass (of 8)
```

The harness was also run three additional consecutive times with
`BLOOB_PTY_SKIP_BUILD=1` (8/8 each) and once with
`BLOOB_TEST_SCALE_MS=2000` (8/8). No product bug required an expected-failure
entry.

## 9. Adding a case

1. Pick a unique case name and call `begin_case <name>`.
2. Prepare workspace/config state under `$CASE_DIR` or `$CASE_WS`. The generated
   runner starts in `$CASE_DIR`, so relative `--cwd ws` and `--config file.lua`
   keep status-line paths short and assertions stable.
3. Write a feeder function that uses `wait_for_text "$CASE_RAW" <marker>` before
   sending the next key, with `sleep_ms` for short settle delays.
4. Invoke `pty_capture <feeder> "$BIN" ...args...`.
5. Add `expect_exit`, `expect_text`, `expect_text_absent`, `expect_raw_bytes`,
   `expect_exists`, `expect_file_text` or `expect_file_contains` calls.
6. Call `end_case` and add the case to `all_cases`.
