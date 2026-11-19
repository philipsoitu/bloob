# bloob implementation status

_Last updated: 2026-11-18 (later autonomous checkpoint)._

## Executive summary

bloob is now a runnable terminal coding agent:

- Native Zig TUI with raw mode, alternate screen, resize handling, mouse wheel/click, bracketed paste, restoration on normal/error paths.
- Embedded LuaJIT 2.1 runtime with protected calls, typed marshaling, registry references, user config, modules, hot reload, custom widgets, commands, keymaps, themes, events, tools and signals.
- The default layout is Lua-defined and user layouts can replace it without recompiling Zig.
- Workspace tools with Zig-authoritative permissions, approval modal, diff preview, bounds and tests.
- Deterministic offline fixture provider and real OpenAI-compatible streaming via curl (verified against the IBM ICA DeepSeek endpoint), plus an Anthropic Messages implementation.
- Headless `--print`/`--json` with real streaming and a safe default-deny policy for approval-gated tools.
- Durable append-only JSONL sessions, resume/list/delete, and incremental persistence of user/assistant/tool messages.
- Basic trusted user-plugin loading from `$XDG_CONFIG_HOME/bloob/plugins/*/plugin.lua`, disabled by `--safe-mode`/`--no-config`.
- Context file selection with bounded content injection, Markdown export, and async cancellable TUI shell execution.

## Milestone matrix

| Milestone | Status | Notes |
|---|---|---|
| M0 bootstrap/verified deps | complete | Zig 0.17.1 pinned; LuaJIT 2.1 via pkg-config; `addTranslateC` because 0.17 removed `@cImport`. |
| M1 responsive TUI/offline model | complete | Native backend, cell grid, layout, editor, chat, status, help, palette, fixture streaming, PTY tests. |
| M2 real provider + agent core | mostly complete | Real streaming + tool-call parsing; retries/timeouts partially; headless real provider works. Anthropic parser implemented but not live-tested. |
| M3 tools/safety/diffs/approvals | complete for core tools | read/list/search/write/edit/shell/git; diff preview; deny leaves files unchanged (PTY test). Interactive shell is async/cancellable; headless shell is synchronous. |
| M4 embedded Lua/config/API | complete for core | State lifecycle, protected calls/tracebacks, config discovery, modules, tests, hot reload. |
| M5 composable Lua TUI | complete | Layout replacement, widget registry, signals, buttons/mouse, custom widget errors, examples, PTY layout test. |
| M6 sessions/palette/plugins | partial | Sessions complete; palette/slash commands complete for core; user plugin loading basic; no manifests/teardown/version negotiation yet. |
| M7 provider/UX completeness | partial | OpenAI-compatible + Anthropic code; model switch/usage; routing hook; markdown basic; no streaming retry/backoff or rich diff navigation. |
| M8 workflows/subagents | not implemented | APIs are documented as incomplete. |
| M9 MCP/LSP/Tree-sitter | not implemented | No dependencies added. |
| M10 release validation | in progress | Build/test/smoke/PTY/real-provider checks run; cross-platform/CI not set up. |

## Verified build/test evidence

All commands run in the repository dev shell:

```text
nix develop -c zig build              # success
nix develop -c zig build test         # success (30+ unit/integration tests)
nix develop -c zig build smoke        # success, ANSI-free fixture
nix develop -c zig build smoke-json   # success, JSON events
nix develop -c tests/pty_smoke.sh     # 12/12 passing
nix develop -c luajit examples/verify.lua  # 7/7 examples pass with stubbed bridge
./zig-out/bin/bloob --self-test       # OK (root=column, children=3, 100x30)
./zig-out/bin/bloob --doctor          # reports terminal/config/data/key presence
```

Real provider verification (credentials supplied only through the environment,
never committed/logged):

```text
BLOOB_COMPAT_BASE_URL=https://api.servicesessentials.ibm.com/v1 \
BLOOB_COMPAT_API_KEY=... ./zig-out/bin/bloob --no-config --print \
  --model compat/rits/deepseek-ai/DeepSeek-V4.1-Flash-1017 \
  "Reply with exactly BLOOB_REAL_PROVIDER_OK"
# => BLOOB_REAL_PROVIDER_OK
```

A real headless tool loop (`read_file` → tool result → second model response)
and the same loop in the interactive TUI were also verified against that
endpoint. Provider API keys are passed through a 0600 temporary curl config,
not argv; the file is removed on stream teardown.

PTY verification covers: cold boot, Ctrl-Q restore markers, fixture streaming,
custom Lua layout/widget, broken config fallback, approval deny (file unchanged),
approval allow (file created), Ctrl-C cancellation.

Manual checks:

- Hot reload: config changed from marker A to B, Ctrl-R showed B and
  `Configuration reloaded`.
- Session create/list/resume: JSONL + `.meta.json` created, `--list-sessions`
  shows rows, `--resume` restored the user message.
- Plugin loading: a user plugin registered a command; `/plugin-hello` notified;
  `--safe-mode` skipped it.
- Local OpenAI-compatible SSE server: text, usage and final idle state.

## Implemented subsystems

### Terminal/UI

- `src/term.zig`, `src/c/sys.h`: raw mode, alternate screen, mouse/paste/focus,
  SIGINT/TERM/HUP/QUIT/WINCH flags, winsize, write helpers, `errdefer` cleanup.
- `src/frame.zig`: Unicode/wide/combining cells, ANSI-safe text entry, borders,
  truecolor/256/16/mono output, injected-control stripping at the render choke
  point.
- `src/ui/node.zig`: declarative nodes, flex/fixed/percent layout, min/max,
  padding, gap, deterministic clamping, intrinsic measurement.
- `src/ui/chat.zig`, `src/editor.zig`: bounded conversation rendering, wrapping,
  multiline UTF-8 editing, undo/redo, history, visual cursor.
- `src/app.zig`: event loop, focus, palette, help, approval modal, chat/input/
  status/sidebar rendering, provider pump, tool loop, session persistence.
- `src/style.zig`, `src/theme.zig`: semantic palettes, custom themes, fallbacks.

### LuaJIT

- `src/lua/runtime.zig`, `src/lua/util.zig`, `src/lua/c.zig`: LuaJIT C ABI via
  translated official headers; lifecycle; protected calls with traceback;
  registry refs; config load; local `require`; layout conversion; widget
  registry; signals; keymaps; events; commands; tools; model routing; themes.
- `src/runtime/lua/bloob/*.lua`: bundled modules and Lua-defined default layout.
- Hot reload builds a candidate state, loads config/plugins/layout, and swaps
  only on success. Candidate config side effects (theme/model) are restored on
  failure; custom theme registrations may persist (known limitation).

### Agent/providers

- `src/messages.zig`: typed roles, text, tool calls/results, usage.
- `src/providers/stream.zig`: curl transport, OpenAI/Anthropic SSE parsing,
  bounded event sizes, usage, tool-call accumulation.
- `src/providers/request.zig`: JSON request serialization, tool schemas,
  Anthropic role merging.
- `src/providers/registry.zig`: `mock`, `openai`, `anthropic`, `compat`
  resolution from environment; no hardcoded model IDs.
- `src/agent/prompts.zig`, `src/headless.zig`: system prompt, `--print`/`--json`,
  bounded tool loop, approval-gated tools denied by default headless.

### Tools/security

- `src/core/workspace.zig`: canonical workspace root, lexical + realpath
  containment, sibling-prefix safety, symlink-sensitive denial, `.git` write
  refusal, sensitive credential names.
- `src/tools/permissions.zig`: authoritative allow/ask/deny, ground denials,
  session allow scope, policy tests.
- `src/tools/tools.zig`: bounded read/list/search/write/edit/shell/git tools,
  atomic writes, mode preservation, diff generation, stderr capture,
  cancellation/time limits, output truncation, path tests.
- Approval modal shows tool, command/paths, diff, Deny/Allow once/Allow session;
  default Deny. Lua `tool.before_execute` can tighten to deny/ask, never loosen.

### Sessions/plugins

- `src/sessions/store.zig`, `codec.zig`, `types.zig`, `compat.zig`: JSONL,
  versioning, crash-tail recovery, 0600/0700 permissions, atomic meta, list,
  load, delete, bounds; tests.
- App integration persists messages incrementally and resumes without replaying
  side-effecting tools.
- `--list-sessions`, `--delete-session`, `--resume`, `--session`,
  `/session list|new|resume ID|delete ID`.
- Trusted user plugins load from the config directory; `--safe-mode` and
  `--no-config` skip them. Project-local plugins are never auto-loaded.

## Known limitations / open bugs

1. **Synchronous search/git (TUI)**: the interactive shell tool is async and
   cancellable, but search/git still block the UI thread (bounded by caps).
   Headless shell execution remains synchronous.
2. **Hot reload is not fully transactional**: candidate config can register
   themes/run commands before swap. Theme/model are restored on failure, but
   custom theme registrations may remain. Plugin teardown is not implemented.
3. **Anthropic live path untested** against a real key; parser/request tests
   and a fake Anthropic SSE integration exist. OpenAI-compatible live path is
   verified.
4. **No retry/backoff** for transient provider errors; no explicit overall
   stream deadline beyond curl `--max-time 300`.
5. **No context compaction/token budget UI**: `/context` can add bounded files,
   but there is no summarization or model-aware budget enforcement.
6. **Key chords unsupported**: `<leader>x` specs are rejected instead of
   silently colliding. Modes are insert/normal/global only.
7. **Visual selection/copy**, rich diff navigation and expandable tool output
   are not implemented.
8. **Single writer assumption** for sessions; no cross-process lock.
9. **Plugins have no manifest/capability negotiation/teardown**; only trusted
   user plugins load. No market/remote install.
10. **No subagents, strategies, MCP, LSP or Tree-sitter**.
11. **Terminal restoration on panic** is not guaranteed (Zig abort does not
    unwind); normal errors and controlled exits restore.
12. Linux-first: PTY harness uses util-linux `script`; interactive shell uses
    `/bin/sh` and an async job; headless shell uses coreutils `timeout`.
13. Full-frame redraws only; no dirty-region diffing. Large conversations
    re-wrap each frame.
14. Some OOM-only ownership paths still free-before-dupe in places outside the
    hot paths; normal behavior is covered by allocator tests.
15. `--provider` combines into the model when the model lacks a slash; supported
    forms are `--model provider/model` and `--provider P --model M`.
16. Approval diff previews are not pinned to the file bytes executed later
    (TOCTOU). edit_file re-checks unique old_text at execution, but a concurrent
    change that still satisfies the match could be applied.

## Dependencies and versions

- Zig 0.17.1 (nixpkgs unstable in the pinned flake).
- LuaJIT 2.1.1791890110 (`luajit.pc`).
- curl 8.23.0 (provider transport).
- git, ripgrep, fd via the devShell; `/bin/sh` and coreutils `timeout` for shell.
- No third-party Zig packages or Lua binding layers.

## Exact next implementation tasks

1. Make shell/search/git execution asynchronous (worker thread or `std.Io`
   async) and cancellation-aware; add a PTY test that Ctrl-C kills a running
   shell tool.
2. Add provider retry/backoff before body consumption and a hard stream
   deadline; live-test Anthropic.
3. Implement transactional hot reload (buffered host effects) and plugin
   `setup`/`teardown`, manifest API version/capability checks.
4. Add context file selection + bounded file contents and compaction controls.
5. Add session export (Markdown/JSON) and tests for interrupted/corrupt session
   resume in the TUI.
6. Add ANSI-injection, symlink-sensitive, shell-timeout, and approval-TOCTOU
   regression tests to the PTY harness.

## Later-checkpoint evidence

- Fake Anthropic SSE server: `--print --json --model anthropic/test-model`
  produced normalized `text_delta` and reported usage (11 prompt / 4 completion).
- Fake OpenAI-compatible SSE server and the real IBM ICA DeepSeek endpoint both
  streamed normalized text and usage. Real API final check returned
  `BLOOB_FINAL_API_OK`. A real `read_file` tool → result → second-response loop
  completed in both headless and TUI modes.
- Async TUI shell: `run printf ASYNC_SHELL_OK` with approval produced output and
  a clean follow-up; `run sleep 5` + Ctrl-C appended `[command cancelled]` and
  left the prompt usable.
- Sessions: create → list (4 messages) → resume restored user + fixture
  assistant text. Export wrote a Markdown transcript.
- Plugins: user plugin `/plugin-hello` notified `PLUGIN_HELLO_OK`;
  `--safe-mode`/`--no-config` skipped it.
- Hot reload: A→B swap displayed B; invalid config retained A with
  `Reload failed; previous configuration kept`.
- Context: `/context add README.md` listed the file and injected bounded content.
- `zig fmt --check build.zig src`, `zig build test`, `zig build smoke`,
  `tests/pty_smoke.sh` (12/12), `examples/verify.lua` (7/7), and `--self-test`
  all pass.

## Exact next tasks

1. Add PTY cases for async shell cancellation, hot reload rollback, sessions and
   plugin loading (currently manual evidence).
2. Make search/git async or worker-bounded; add provider retry/backoff and a hard
   stream deadline.
3. Make hot reload fully transactional (buffer candidate host effects) and add
   plugin manifests/capabilities/setup/teardown.
4. Add context compaction, token-budget enforcement, visual selection/copy and
   richer diff navigation.
5. Add session export JSON, retention/cleanup and cross-process locking.
6. Run ReleaseSafe/ReleaseFast and a clean-home acceptance scenario.
- Custom Lua tool end-to-end with a real model: `workspace.count_lines` was
  advertised, invoked, executed through `ctx:read_file`, returned
  `{"lines":98,...}`, and the model answered from the tool result.
