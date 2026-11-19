# PROJECT PLAN — A Zig-native, Lua-programmable terminal coding agent

> **Execution instruction:** This document is the implementation brief for an autonomous coding agent. Implement the project, not merely a plan or scaffold. Read this entire document before making architectural changes. Work continuously through the milestones, creating real code, tests, examples, and documentation. Favor a small, reliable implementation of each subsystem over fake implementations or untested breadth. Never claim features exist unless they work. If interrupted or limited by runtime, leave the repository buildable, tests passing, and a precise progress report so another agent can continue.

**Project name (non-negotiable):** `bloob`. Name the executable, CLI, Lua namespace, config directory, examples, and documentation `bloob`. Do not substitute a placeholder.  
**Language:** Zig for the executable, application state, event loop, terminal rendering, tool execution, network transport, and persistence. Lua for configuration, plugins, components, UI composition, event hooks, and agent policies.  
**Product:** Keyboard-first, cross-platform, highly extensible **terminal coding agent**, inspired by the Lua-first customization philosophy of Neovim/WezTerm and the extensible architecture of Pi, but independently implemented and designed around a first-class declarative Lua UI.

---

## 0. Mandatory autonomy protocol

You are the implementation agent. Treat the checklist below as an execution contract.

1. **Inspect the repository first.** Read `README`, `AGENTS.md`, `build.zig`, `build.zig.zon`, existing code, available tests, license, and Git status. Preserve good existing code, naming, conventions, and user changes. If the repository is empty, initialize it. Do not overwrite uncommitted work. Follow any higher-priority instructions and repository-specific constraints.
2. **Verify the local Zig compiler** with `zig version` and inspect its actual standard-library/build APIs. As of the drafting date (2026-11-18), Zig **0.17.1** is the latest published stable version, but Zig changes frequently and libraries may not support it yet. Prefer the newest **stable, compatible, reproducible** Zig version after verifying dependencies; pin the version in documentation and CI. Do not assume examples from 0.13–0.16 compile unchanged.
3. **Investigate dependencies before adopting them.** Evaluate `rockorager/libvaxis` for terminal input/capabilities/rendering, but **embed LuaJIT 2.1 using direct Zig `@cImport` of the LuaJIT C headers**. Do not use ziglua, mlua, or any third-party Lua binding abstraction. Check the supported Zig version, library ABI, architecture, API, license, and build instructions. If libvaxis is incompatible, use a minimal native Zig terminal backend. If LuaJIT is unavailable on a target, document the unsupported target rather than silently swapping the scripting language/runtime. Record decisions in `docs/architecture/decisions.md`. Dependencies must be pinned with reproducible hashes in `build.zig.zon` or an equivalent lock mechanism.
4. **Make a working executable as early as possible.** First build a terminal app with input, a message list, a multiline prompt, and deterministic fake-model streaming. Then implement Lua customization, live providers, and advanced features incrementally. Keep `zig build`, `zig build test`, and a noninteractive smoke test runnable after each milestone. No speculative full rewrite midway through implementation.
5. **Keep a durable progress ledger.** Create/update `IMPLEMENTATION_STATUS.md` after each milestone, recording what actually runs, what is missing, exact commands, known issues, and the next actionable task. Also use the checklist in this plan. Update docs when interfaces change.
6. **Prioritize genuine vertical slices.** A feature is complete only when implemented, integrated, tested, and documented with an example. Do not substitute TODOs, log messages, placeholder buttons, hardcoded model responses, or mock data for production functionality. Mocks are acceptable **only** in clearly labeled tests, demos, and offline development modes.
7. **Do not block on routine decisions.** Choose reasonable defaults, document the tradeoff, and continue. If a service requires keys, implement it against environment variables and fixtures; never wait for credentials. If Internet/dependency access is blocked, implement independent modules, tests, and a documented fallback without fabricating successful validation.
8. **Practice tool-use safety.** Do not execute destructive commands, overwrite user files, change Git remotes, publish packages, exfiltrate data, spend paid API credits unnecessarily, or push commits without authorization. The coding agent **being built** must likewise have explicit permissions, path protections, and approval gates.
9. **Use Git checkpoints prudently** if the workspace permits them and repository instructions allow it. Never force-push. Commits should represent tested vertical slices. If committing is not appropriate, leave clear changes and status documentation.
10. **Do not stop at writing architecture docs.** Build the code. When a milestone is impossible, write an honest blocker, bypass it without compromising safety, and continue with independent tasks. No background promises; do all work possible within your actual execution session.
11. **Track deviations.** The APIs in this document are design targets, not claims of existing Zig library interfaces. If technical reality requires changes, implement the closest coherent interface and update all examples/tests/docs together.
12. **Finish with evidence.** Report implemented modules, compiler/version, test results, smoke-test output, manual checks performed, unresolved limitations, and exact next commands. Never say “all done” unless acceptance criteria are met.

### Priority levels

- **P0 — Working product:** bootable TUI, input/rendering, model streaming, tools with approvals, sessions, Lua config and custom UI, keybindings, error handling, tests.
- **P1 — Strong product:** model adapters, composable widget registry, plugins, hot reload, diff/review workflow, hooks, context management, file search, command palette, robust persistence.
- **P2 — Advanced ecosystem:** multi-agent orchestration, MCP, LSP, Tree-sitter, deeply customizable execution strategies, rich diagnostics, plugin distribution, sophisticated terminal capabilities.

Deliver P0 end-to-end before expanding P2. The goal is large, but an overnight run must not produce a broad, brittle skeleton.

---

## 0.1 Mandatory bloob / Nix / LuaJIT implementation contract

This section overrides any inconsistent historical example or recommendation elsewhere in the plan.

1. **Product identity:** The executable and project are named `bloob`. Expose `require("bloob")`, `require("bloob.ui")`, and other `bloob.*` namespaces. Default user config is `$XDG_CONFIG_HOME/bloob/init.lua` (fallback `~/.config/bloob/init.lua`), with a secure policy for any project-local `.bloob/` configuration. Use `BLOOB_` prefixes for new environment variables.
2. **Required environment:** Honor the existing `flake.nix` and `flake.lock` if present. Include, or verify presence of, Nix packages `zig`, `zls`, `pkg-config`, `luajit`, `lua-language-server`, `git`, `ripgrep`; `clang` and `fd` are useful optional development tools. **Do not need `lua5_4`**. Confirm `pkg-config --modversion luajit`, `pkg-config --cflags --libs luajit`, `luajit -v`, and `zig version` under `nix develop`. If flake is missing, add an appropriate minimal devShell. Never casually update a pinned lockfile.
3. **Native interoperability only:** In a Zig module, import the real LuaJIT headers with `@cImport({ @cInclude("lua.h"); @cInclude("lauxlib.h"); @cInclude("lualib.h"); })`. Configure include paths and linker flags with verified `pkg-config` discovery (`luajit.pc`); use the Zig build APIs of the installed compiler version. Link libc as appropriate. The built `bloob` executable must demonstrably initialize `lua_State`, execute Lua code, expose a Zig function as a Lua callable, load a Lua module, and return errors without crashing. Include automated tests and an offline smoke test. Put bindings under `src/lua/`.
4. **LuaJIT language/version compatibility:** LuaJIT 2.1 principally follows Lua 5.1 semantics with selected extensions. Do not assume Lua 5.4 operators, standard library, or APIs. Ensure all shipped Lua examples run under `luajit`. Avoid relying on Lua 5.2+ features unless verified supported and documented.
5. **Interop correctness:** Lua uses a single owner/thread per state unless a verified design provides safe synchronization; protect all Lua callbacks; validate argument types, string lengths, and stack effects; use `luaL_ref` / `luaL_unref` for registry-held callbacks; avoid dangling Zig pointers; never longjmp across Zig frames in an unsafe manner; do not use `lua_error` casually from Zig C callbacks. Restore stack state and provide actionable traceback diagnostics where possible. Implement lifecycle and hot reload without use-after-free.
6. **Trust model:** User's personal Lua config is trusted. Third-party/project plugins require explicit trust and capability checks; permissions are ultimately enforced in Zig, and LuaJIT FFI must never be marketed as securely sandboxed merely by removing a global. For untrusted code use real isolation or do not execute it. The app must not automatically execute repository Lua configuration on startup.
7. **Shipping:** Start by linking LuaJIT dynamically within `nix develop`; verify runtime loader behavior. A later packaging milestone may support bundling or static linking, but only after checking LuaJIT build and platform limitations. Document the portability tradeoff rather than claiming a single self-contained binary prematurely.
8. **Execution commands:** After each vertical slice run `nix develop -c zig build` and `nix develop -c zig build test`, adapting to existing repository conventions, and keep a noninteractive smoke test that exercises LuaJIT interop and the terminal-free application core. Use `nix develop -c bloob` only if executable resolution is configured; otherwise run `./zig-out/bin/bloob`.

### Suggested minimal `flake.nix` devShell package list

```nix
packages = with pkgs; [
  zig
  zls
  pkg-config
  clang
  luajit
  lua-language-server
  git
  ripgrep
  fd
];
```

Add dependencies only when the implementation truly requires them. Explicitly verify library discovery and header inclusion within the Nix devShell. The exact Zig linking API is version-dependent; compile a minimal real `@cImport` proof before designing the complete bridge.

---

## 1. Product definition and non-goals

### 1.1 Vision

A coding agent where **the core is Zig and the user-facing environment is programmable in Lua**. Users can run an excellent default TUI with zero configuration, use simple Lua settings to tailor it, or build entirely new layouts and workflows from low-level components. The UI is not a fixed chat pane with a couple of extension points. It is a composable, state-driven system with replaceable built-in widgets.

A user should be able to:

- launch the agent in a project with `bloob`, open a session, ask questions, inspect/edit code, review diffs, approve commands, and follow streaming output;
- configure the model, theme, keymaps, status line, prompt editor, sidebar, notifications, tool policy, context selection, and layout using `~/.config/bloob/init.lua`;
- write a custom widget (e.g. agents monitor, Git status, token/cost meter), insert it into any panel, and react to keyboard/mouse events;
- install a Lua plugin that registers commands, tools, event handlers, prompt templates, themes, and view components;
- program model routing, pre-/post-tool hooks, retry/verification policies, and workflow strategies;
- use the agent without Lua customization, with safe defaults and an ergonomic terminal experience;
- run the same agent headlessly for scripting, automation, and testing.

### 1.2 Non-goals / constraints

- Do **not** build a desktop GUI, Electron application, or web application as the primary interface.
- Do **not** embed Node/TypeScript for the extension system. Lua is the first-class embedded language; Zig is the implementation language.
- Do **not** require Neovim or another editor to function. Integrate with external `$EDITOR` optionally.
- Do **not** attempt full terminal emulation in v1. Tool output is captured and rendered as text; a PTY/terminal pane can be added after the core works.
- Do **not** implement your own HTTP/TLS/Unicode/Markdown/JSON parser if a dependable, licensed, compatible library or Zig stdlib functionality suffices. However, minimize native dependency surface.
- Do **not** represent arbitrary configuration Lua as a security sandbox. Local user configuration is trusted by default; remotely installed or project-local plugins are **untrusted until approved**. Define strict capabilities and isolate or disable unsafe operations, as detailed later.
- Do **not** guarantee identical terminal features everywhere. Baseline ANSI TTY behavior should degrade gracefully and preserve functional keyboard-only operation.

### 1.3 Supported environments

Primary: Linux/macOS, terminal emulators with UTF-8 and ANSI/VT support. Secondary: Windows Terminal / ConPTY with explicit support or documented limitations. CI should build and smoke-test at least Linux and macOS if available, with Windows compile checks where feasible. No root privileges required. Support truecolor where available, 256-color fallback, and mono/no-color mode; handle SSH and multiplexers.

---

## 2. Architectural principles

1. **Zig controls execution and resources.** Terminal lifecycle, ANSI rendering, screen buffers, event loop, network calls, file I/O, subprocesses, tool policy enforcement, session storage, and concurrency remain owned by Zig.
2. **Lua declares appearance and policy.** Configuration, keymaps, themes, layout trees, widget functions, hooks, custom tools, routing policies, and workflows are Lua APIs over the Zig engine.
3. **Events instead of tight coupling.** Core emits typed events; components and plugins subscribe. No blocking provider calls or filesystem reads in UI render callbacks.
4. **One-way UI data flow.** Immutable-ish snapshots of relevant state feed component functions; UI actions dispatch commands; the engine updates state, marks affected components dirty, and redraws. Do not give arbitrary pointers to internal Zig memory to Lua.
5. **Stable public API and compatibility policy.** The Lua API uses named functions, versioned interfaces, helpful errors, and examples. Private Zig modules may evolve more freely.
6. **Safe defaults.** Reading inside the workspace is allowed after workspace trust is established; file edits and shell execution require configurable approvals; dangerous shell and outside-workspace writes are denied without explicit consent.
7. **Testable without a real model.** A fixture/fake transport should drive the actual agent loop and UI events so unit/integration tests never need paid APIs.
8. **No terminal corruption.** Always restore terminal modes, cursor, mouse/paste state, and alternate screen on controlled shutdown and error paths. Handle signals appropriately; fatal crashes cannot always be recovered, so document recovery (`reset`/`stty sane`).
9. **Bounded resources.** Token output, subprocess capture, render frames, request retry behavior, plugin execution, and session growth must have limits and cancellation.
10. **Composable over monolithic.** Core widgets are registered via the same public interfaces that custom widgets use, except for explicit performance-critical internals.

### 2.1 Module dependency direction

```text
                           User Lua config / plugins
                                      |
                              Zig–Lua bridge
                                      |
       +------------------------------+------------------------------+
       |                              |                              |
  UI registry + state          Agent orchestration             Config + commands
       |                              |                              |
  Layout + event dispatch       Provider abstraction         Hooks + permissions
       |                              |                              |
  Terminal backend         Context / tools / sessions        Plugin loader
       |                              |                              |
       +----------------------+-------+------------------------------+
                              |
                  Zig OS + I/O + standard library
```

The application message/event bus carries high-level events, not terminal escape strings. Network workers enqueue events; a single UI owner thread/event loop updates UI state and Lua widget state. Cross-thread communication must use owned data and well-defined lifetimes.

---

## 3. Dependency, Zig version, and build strategy

### 3.1 Research and lock choices

Verify current versions and compatibility. Starting candidates:

- Zig downloads/releases: https://ziglang.org/download/ and https://ziglang.org/news/0.17.1-released/
- Terminal I/O/reference: https://github.com/rockorager/libvaxis
- LuaJIT 2.1 source/reference: https://github.com/LuaJIT/LuaJIT
- Lua 5.1 reference manual (baseline syntax/API semantics): https://www.lua.org/manual/5.1/
- Inspiration/competitive study (do not copy code uncritically): https://github.com/badlogic/pi-mono

Use Zig stable with a verified working dependency graph. As of 2026-11-18 Zig 0.17.1 is released; do not commit to this version if required dependencies currently target a different Zig release. Prefer a reproducible, known-good stable toolchain over an unverified newer compiler. Document exact choices and tradeoffs.

**Lua runtime mandate:** Embed **LuaJIT 2.1** with direct Zig **`@cImport`** from `lua.h`, `lauxlib.h`, and `lualib.h`, using the C ABI and version-appropriate Lua 5.1-compatible APIs. No Ziglua, mlua, or alternative Lua binding layer. Link Nix-provided LuaJIT via `pkg-config` (`luajit.pc`) after verifying the installed include/library paths and the Zig build API. Manage state ownership, stack discipline, registry references, protected calls, traceback/error propagation, callback lifetime, safe hot-reload state swaps, threading constraints, memory limits, and cancellation. LuaJIT `ffi`, `package.loadlib`, `io`, `os`, and `debug` are powerful: do not claim a Lua-state sandbox is a security boundary. Expose `bloob.version`, `bloob.api_version`, and `bloob.features`.

**TUI recommendation:** Try libvaxis for terminal capabilities, key/mouse/paste input, and low-level screen handling; place it behind `src/tui/backend.zig`. Build all layout, component state, and public Lua UI APIs in project-owned modules to avoid leaking third-party types into the plugin API. If libvaxis is incompatible, own a minimal backend that can enter raw mode, parse ANSI input, render a cell buffer, and restore state; test it thoroughly before building complex widgets.

### 3.2 Build targets and commands

Required:

```sh
zig build                  # build the executable
zig build run              # interactive TUI
zig build test             # unit + offline integration tests
zig build smoke            # noninteractive fixture smoke tests
zig build -Doptimize=ReleaseSafe
zig fmt --check src build.zig
```

Document and implement CLI usage:

```sh
bloob                       # interactive TUI in cwd
bloob --cwd /path/to/project
bloob --config /path/to/init.lua
bloob --no-config           # disable user and project Lua config
bloob --safe-mode           # disable nonbundled plugins; approvals stay enforced
bloob --model provider/model
bloob --resume [session-id]
bloob --session <id>
bloob --print "Explain this module"  # headless output
bloob --json "Explain this module"   # machine-readable events
bloob --list-models
bloob --list-sessions
bloob --doctor              # detect terminal, config, providers, plugins
bloob --version
bloob --help
```

`--print` and `--json` must support non-TTY execution with exit codes and no ANSI control output. Implement actual parsing/behavior or omit the flag until implemented; do not advertise inert flags.

---

## 4. Suggested repository structure

Adapt if a repository already exists. Do not create empty directories/files for features not yet implemented.

```text
.
├── build.zig
├── build.zig.zon
├── README.md
├── LICENSE
├── AGENTS.md                      # local contributor/agent instructions
├── plan.md
├── IMPLEMENTATION_STATUS.md
├── src/
│   ├── main.zig
│   ├── cli.zig
│   ├── app.zig
│   ├── event_bus.zig
│   ├── config.zig
│   ├── logging.zig
│   ├── core/
│   │   ├── types.zig
│   │   ├── errors.zig
│   │   ├── cancellation.zig
│   │   ├── secrets.zig
│   │   └── workspace.zig
│   ├── tui/
│   │   ├── backend.zig            # abstraction over libvaxis or native backend
│   │   ├── terminal.zig
│   │   ├── events.zig
│   │   ├── buffer.zig
│   │   ├── renderer.zig
│   │   ├── layout.zig
│   │   ├── style.zig
│   │   ├── text.zig
│   │   ├── theme.zig
│   │   ├── focus.zig
│   │   ├── keymap.zig
│   │   ├── widget.zig
│   │   └── widgets/
│   │       ├── chat.zig
│   │       ├── editor.zig
│   │       ├── statusline.zig
│   │       ├── sidebar.zig
│   │       ├── diff.zig
│   │       ├── popup.zig
│   │       ├── list.zig
│   │       ├── markdown.zig
│   │       └── command_palette.zig
│   ├── agent/
│   │   ├── runner.zig
│   │   ├── messages.zig
│   │   ├── context.zig
│   │   ├── prompts.zig
│   │   ├── compaction.zig
│   │   ├── routing.zig
│   │   ├── cost.zig
│   │   └── subagents.zig
│   ├── providers/
│   │   ├── interface.zig
│   │   ├── http_client.zig
│   │   ├── sse.zig
│   │   ├── openai.zig
│   │   ├── anthropic.zig
│   │   ├── openai_compatible.zig
│   │   └── mock.zig
│   ├── tools/
│   │   ├── registry.zig
│   │   ├── permissions.zig
│   │   ├── read_file.zig
│   │   ├── write_file.zig
│   │   ├── edit_file.zig
│   │   ├── list_files.zig
│   │   ├── search.zig
│   │   ├── shell.zig
│   │   ├── git.zig
│   │   └── diff.zig
│   ├── lua/
│   │   ├── runtime.zig
│   │   ├── bindings.zig
│   │   ├── marshal.zig
│   │   ├── events.zig
│   │   ├── permissions.zig
│   │   ├── plugins.zig
│   │   ├── reload.zig
│   │   └── ui.zig
│   ├── sessions/
│   │   ├── store.zig
│   │   ├── schema.zig
│   │   └── migration.zig
│   └── integrations/
│       ├── mcp.zig                # P2
│       ├── lsp.zig                # P2
│       └── treesitter.zig         # P2
├── runtime/
│   └── lua/
│       ├── bloob/
│       │   ├── init.lua
│       │   ├── ui.lua
│       │   ├── api.lua
│       │   └── defaults.lua
│       └── themes/
│           ├── default.lua
│           ├── catppuccin.lua
│           └── monochrome.lua
├── examples/
│   ├── minimal/init.lua
│   ├── dashboard/init.lua
│   ├── vim-mode/init.lua
│   ├── custom-widget/init.lua
│   ├── custom-tool/init.lua
│   ├── agent-workflow/init.lua
│   └── plugins/
├── tests/
│   ├── fixtures/
│   │   ├── provider/
│   │   ├── sessions/
│   │   └── projects/
│   ├── integration/
│   └── golden/
├── docs/
│   ├── getting-started.md
│   ├── configuration.md
│   ├── lua-api.md
│   ├── ui-components.md
│   ├── plugins.md
│   ├── security.md
│   ├── architecture/
│   │   ├── overview.md
│   │   └── decisions.md
│   └── troubleshooting.md
└── .github/workflows/ci.yml
```

Keep boundaries and naming consistent but allow consolidation where it improves maintainability.

---

## 5. Terminal and TUI engine — first-class and deeply customizable

### 5.1 Terminal lifecycle

Implement:

- Capability detection and fallback: color depth, terminal dimensions, ANSI support, Unicode, synchronized updates if supported.
- Enter/exit alternate screen where supported; raw mode; hide/show cursor; optional bracketed paste/mouse/focus modes.
- Robust input: ASCII, Unicode text, Ctrl/Alt/Shift combinations where distinguishable, arrows, Home/End, PageUp/Down, Delete, function keys, resize, paste, scroll, and mouse wheel if available.
- SIGINT/cancellation behavior: first Ctrl-C cancels current request or clears selection, second/dedicated quit exits according to configured policy. Ensure signal handler work is signal-safe; handle restoration in the normal event loop where possible.
- Dirty-region rendering, cursor placement, frame throttling, resize invalidation, terminal cleanup on controlled exit.
- Safe escape-sequence handling: never render untrusted model/tool ANSI escapes directly. Strip or parse content into safe styling; prevent OSC/terminal control injection and terminal title/clipboard changes from model output.
- Scrollback retained in application state, not dependent on terminal emulator scrollback. Virtualize massive chat histories.

### 5.2 Cell grid and layout

Create a terminal cell abstraction with Unicode grapheme width (including combining marks and wide glyphs) and foreground/background/style metadata; avoid splitting wide glyphs. Handle narrow and zero-size terminals gracefully.

The UI engine uses a tree of nodes:

```text
Node = Column | Row | Stack | Panel | Text | Scroll | List | Input
     | Tabs | Split | Spacer | CustomWidget | Chat | Statusline | ...
```

Core properties: `id`, `width`, `height`, `min_width`, `min_height`, `max_width`, `max_height`, `flex`, `padding`, `gap`, `border`, `background`, `foreground`, `align`, `justify`, `visible`, `focusable`, `scroll`, `z_index` where meaningful. Support percentage/fixed/flex sizing, clipping, nested splits, and overlays. Define deterministic layout resolution under over-constrained dimensions. Layout is owned by Zig; Lua contributes typed data, not raw pointers.

Prefer a stable retained component tree/diffing design: widget identity is based on explicit IDs or position/type; only changed props/state trigger subtree invalidation. Avoid rerunning expensive Lua functions for every terminal cell. Provide high-level text rendering, plus a **carefully permissioned advanced surface** for custom drawing to clipped buffers if needed later.

### 5.3 Default UX

A useful default UI must include:

- streaming chat with user, assistant, tool-call and tool-result blocks;
- multi-line prompt editor with undo/redo, history, paste, selections and sensible keyboard editing;
- markdown and fenced code rendering with wrapping, source-friendly indentation and selectable/copyable content where feasible;
- syntax-highlighted diffs and a readable tool approval dialog;
- scrollable tool output with truncation/expand controls;
- status line: mode/model/provider, Git branch, tokens/cost when known, busy/idle, session;
- command palette and searchable commands;
- keyboard navigation across chat, editor, sidebar, tool results, popups;
- help overlay and obvious status/error notifications;
- accessible monochrome fallback and keyboard-only operation.

A minimal default layout:

```text
┌─ bloob ─ project ──────────────────────────────────────────────────────────┐
│ Files / context       │ Conversation                                      │
│                       │ > Fix failing tests                               │
│ src/                  │ • inspecting files ...                            │
│   main.zig            │ • proposed patch: src/main.zig                   │
│   agent/              │ ...                                               │
│                       │                                                   │
├───────────────────────┴───────────────────────────────────────────────────┤
│ > Ask, edit or use /help                                                   │
│   (multi-line editor)                                                      │
├───────────────────────────────────────────────────────────────────────────┤
│ NORMAL   anthropic/sonnet   main   15.2k tokens   $0.12   session: abc123 │
└───────────────────────────────────────────────────────────────────────────┘
```

Sidebar hidden by default on narrow terminals; input/editor and conversation remain functional.

### 5.4 Focus/event ownership

Input dispatch order: modal/approval UI -> focused widget -> active keymap mode -> global keymap -> fallback editor. Modal dialogs consume relevant keys to prevent dangerous background actions. Handlers can return `handled`, `pass`, or a typed command. Never allow a plugin to intercept system emergency quit/permission confirmation in a way that circumvents explicit approvals.

### 5.5 TUI tests

- Snapshot/golden test rendered cells at 40×12, 80×24, 120×35, unusual widths, and resize sequences.
- Unicode, CJK, emoji, combining marks, RTL limitations documented, long file paths, long unbroken code strings, huge tool results.
- ANSI escape injection attempt in provider messages and tool output.
- Event handling for paste, key chords, focus, modal overlays, scroll, prompt editing, cancellation.
- Continuous redraw only on actual state changes; a deterministic fake clock/frame scheduler for tests.

---

## 6. Lua system — configurable at every layer

### 6.1 Configuration discovery and precedence

Load (subject to trust rules): embedded defaults, system config if supported, user config (`$XDG_CONFIG_HOME/bloob/init.lua`, or OS-appropriate config dir), optional explicitly enabled project config (`.bloob/init.lua`), then CLI overrides. Project config must not execute before user consent/trust. `--no-config` loads only safe embedded defaults. Show active config sources in `bloob --doctor`.

Provide `require("bloob")`, `require("bloob.ui")`, `require("bloob.agent")`, `require("bloob.tools")` through a module registry. LuaJIT is supplied by Nix for development; package/runtime linking must be explicit and documented. Support modular Lua files in a scoped configuration path; avoid ambient module lookup in untrusted directories.

Simple configuration target:

```lua
local bloob = require("bloob")
local ui = require("bloob.ui")

bloob.setup({
  model = "anthropic/claude-sonnet",
  theme = "catppuccin",
  editor = { mode = "vim", history = true },
  permissions = { read = "allow", edit = "ask", shell = "ask" },
  ui = { mouse = true, border = "rounded", sidebar = true },
})

ui.set_layout(ui.column({
  ui.row({
    ui.sidebar({ width = 24 }),
    ui.chat({ flex = 1 }),
  }, { flex = 1 }),
  ui.input({ height = 4 }),
  ui.statusline(),
}))
```

Treat examples as **API contracts to implement**, with ergonomic error messages and complete Lua API tests. Implement exact names or document one consistent replacement; never leave examples unexecutable.

### 6.2 Core Lua API design

Proposed stable modules:

| Module | Responsibilities |
|---|---|
| `bloob` | setup, version, capabilities, workspace metadata, logging, commands |
| `bloob.ui` | layout nodes, component registry, signals, theme, focus, notifications, dialogs, render invalidation |
| `bloob.keymap` | modes, mappings, scopes, descriptions, conflict diagnostics |
| `bloob.events` | typed hooks, subscriptions, unsubscribe handles, priorities |
| `bloob.agent` | sessions, task runs, context, messages, strategies, subagents (advanced) |
| `bloob.models` | available providers, model selection, routing policies, per-task configuration |
| `bloob.tools` | custom tools, schemas, results, permission requests, execution APIs |
| `bloob.plugins` | manifest, registration, dependencies, lifecycle, reload |
| `bloob.config` | validated config, sources, reset, reload |
| `bloob.storage` | namespaced, bounded per-plugin persistence (not arbitrary path writes) |

All returned objects must have explicit lifetimes and no stale Zig pointers. Distinguish synchronous queries/actions from async operations. For async tasks, expose callbacks/promises/task handles in a controlled event-loop-friendly fashion, never stall the UI to await a model call.

### 6.3 Declarative UI API

Implement these primitives at minimum: `ui.text`, `ui.row`, `ui.column`, `ui.panel`, `ui.spacer`, `ui.scroll`, `ui.list`, `ui.input`, `ui.button`, `ui.tabs`, `ui.overlay`, `ui.chat`, `ui.sidebar`, `ui.statusline`, `ui.diff` (last few may wrap native core widgets). Support nested children, stable IDs, optional props, dynamic content, and clearly validated bad configurations.

Example complete custom widget:

```lua
local ui = require("bloob.ui")
local events = require("bloob.events")

local function agent_monitor(ctx)
  local rows = {}
  for _, a in ipairs(ctx.agents or {}) do
    table.insert(rows, ui.row({
      ui.text(a.name, { style = "bold" }),
      ui.text(a.status, { color = "muted" }),
    }, { gap = 1 }))
  end
  return ui.panel({
    id = "my.agents",
    title = "Agents",
    border = "rounded",
    children = { ui.column(rows) },
  })
end

ui.register("my.agent_monitor", agent_monitor)
ui.set_layout(ui.column({
  ui.row({
    ui.chat({ flex = 3 }),
    ui.widget("my.agent_monitor", { flex = 1, min_width = 18 }),
  }, { flex = 1 }),
  ui.input({ height = 4 }),
  ui.statusline(),
}))
```

`ctx` must be a read-only snapshot/proxy of permitted data, not mutable engine internals. Exceptions in component functions are caught; the offending widget is replaced by an error panel, not a full application crash. Provide plugin/line traceback and component ID.

Reactive state design example:

```lua
local ui = require("bloob.ui")
local count = ui.signal(0)

ui.register("my.counter", function()
  return ui.row({
    ui.text("Count: " .. count:get()),
    ui.button("+", { on_press = function() count:set(count:get() + 1) end }),
  })
end)
```

Implement a basic signal/subscription abstraction and dirty-marking with anti-reentrancy safeguards. No infinite redraw loops caused by state writes during render: either reject them with a useful error or schedule them safely with a bounded cycle limit.

### 6.4 Themes

Semantic palette: foreground/background, primary/secondary/muted, success/warning/error, border, selection, focus, tool-call, diff-added/removed, code, headings, syntax tokens. Expose `ui.theme.register(name, palette)`, `ui.theme.set(name)`, and runtime theme change. Themes must be cached/validated and support truecolor/256/mono fallbacks. Built-in dark, light, monochrome, and optional Catppuccin-like theme with proper licensing/attribution.

### 6.5 Keybindings

Example:

```lua
local keymap = require("bloob.keymap")
keymap.set("normal", "<leader>a", "agent.prompt", { desc = "Focus prompt" })
keymap.set("normal", "<leader>r", "agent.review", { desc = "Review changes" })
keymap.set("insert", "<C-Enter>", "agent.submit", { desc = "Send prompt" })
keymap.set("global", "<C-p>", "ui.command_palette")
```

Modes: `insert`, `normal`, `visual` where implemented, and `global`; key chords with timeout; clear precedence; editor modes; conflict reporting (`bloob --doctor`). Ship sensible defaults, keep built-in help aligned, and avoid stealing terminal-reserved keys without fallback.

### 6.6 Events, hooks and policies

Typed event names (minimum):

- `app.start`, `app.quit`, `config.loaded`, `config.reload`, `theme.changed`;
- `session.created`, `session.loaded`, `session.saved`;
- `agent.before_turn`, `agent.after_turn`, `agent.error`, `agent.cancelled`;
- `model.before_request`, `model.after_response`, `model.usage`;
- `tool.before_execute`, `tool.after_execute`, `tool.error`;
- `file.before_write`, `file.after_write`;
- `ui.focus_changed`, `ui.resize`, `ui.notification`.

Hook handlers have documented payloads and semantics (observe-only vs cancellable vs transformable). Provide priorities, unsubscribe handles, structured logging, bounded execution, and cancellation. A hook **cannot** grant itself capabilities or override an explicit denial. Avoid reentrant recursive tool dispatch; track nesting depth.

Example deterministic post-edit hook:

```lua
local events = require("bloob.events")
events.on("file.after_write", function(e)
  if e.path:match("%.zig$") then
    e:notify("Edited Zig file: " .. e.path)
  end
end)
```

If the API returns an event facade, ensure the example actually works. Do not let hooks initiate arbitrary writes if plugin permissions disallow them.

### 6.7 Dynamic model routing

```lua
local models = require("bloob.models")
models.route(function(ctx)
  if ctx.task == "search" then return "openai/gpt-small" end
  if ctx.task == "architecture" then return "anthropic/claude-opus" end
  return "anthropic/claude-sonnet"
end)
```

Model identifiers here are illustrative. Real available model IDs must be configured/discovered from supported providers, validated before requests, and never silently substituted. Built-in static model selection must be fully functional before automatic routing. Track per-request source/model/usage when provider reports it, and show costs only if a verified price table is configured; otherwise say “unknown.”

### 6.8 Plugins, trust and hot reload

Plugin layout:

```text
~/.config/bloob/plugins/my-plugin/
├── plugin.lua
├── manifest.json (or manifest.lua with constrained parsing)
├── lua/...
└── README.md
```

Plugin contract: ID, name, API version, version, entrypoint, requested capabilities, dependencies, optional config schema. Support `setup(ctx)`, `teardown(ctx)`, and optionally `on_reload(old_state)` with explicit restoration semantics. Load local installed plugins first; remote plugin installation is P2 and **must** show source, revisions, capabilities, and ask for approval. Avoid arbitrary `curl | sh` behavior.

Hot reload must:

1. detect changes to loaded config/plugins using a debounced watcher or an explicit `:reload` command (explicit command is minimum P0/P1);
2. parse/validate into a **new candidate Lua state**; do not destroy the running state first;
3. construct candidate UI tree and plugin registries; verify required built-in controls remain accessible;
4. atomically swap registries/layout on success; preserve conversation, current edit buffer, running requests, scroll position where IDs persist;
5. roll back and show detailed errors on failure;
6. unload/release handlers, timers/tasks, component state, subscriptions, and plugin resources without leaks;
7. never reload untrusted code without capability approval.

Document which plugin state survives reload and which resets. For long-running tasks, choose a safe handoff or cancellation model; do not invoke callbacks into destroyed Lua states.

---

## 7. Agent runtime and model providers

### 7.1 Typed conversation model

Define roles `system`, `developer` (where supported/needed), `user`, `assistant`, `tool`. Store content as typed blocks: text, tool request, tool result, optional image/other multimodal metadata later. Each message has stable ID, timestamp, source model/provider, usage where known, tool call IDs, and immutable content; allow streaming deltas before final commit. Session must preserve order and causal relationships.

### 7.2 Agent turn state machine

Use explicit states:

```text
Idle -> PreparingContext -> SendingRequest -> Streaming
     -> (ToolCallsPending -> AwaitingApproval -> ExecutingTools -> SendingRequest)*
     -> Completed | Cancelled | Failed
```

Define transitions for malformed output, timeout, network errors, rate limits, context overflow, tool failure, user cancel, max tool iterations, and process shutdown. Include max turn iterations and per-tool limits to prevent runaway loops. Never call tools from half-formed streaming JSON before validation and policy checks. Expose state events to Lua and UI.

### 7.3 Provider interface

A provider adapter should implement roughly:

```text
Provider {
  id, capabilities, listModels/getModelMetadata,
  stream(request, cancellation, eventSink) -> result,
}

Request {
  model, messages, tools(schema), temperature?, max_output_tokens?,
  system_prompt?, metadata?, provider_options?
}

StreamEvent = TextDelta | ReasoningSummaryDelta? | ToolCallStart
            | ToolCallArgumentDelta | ToolCallComplete | Usage | Done | Error
```

Normalize provider APIs while preserving provider-specific details as opt-in options. Never pretend unsupported features are available. `OpenAI-compatible` doesn't imply all servers implement tool calling, streaming, usage, or identical finish reasons; capability check and graceful errors are required.

### 7.4 Providers to implement

P0: at least **one real streaming provider** plus a complete offline mock adapter. Prefer OpenAI Responses or Chat Completions through current documented API, or Anthropic Messages, depending on implementation ease and compatibility; do not hardcode model names. P1: both OpenAI and Anthropic plus configurable OpenAI-compatible endpoints (e.g. local gateway). Keep provider-specific auth isolated and secret-safe.

Environment/config examples:

```text
OPENAI_API_KEY
ANTHROPIC_API_KEY
BLOOB_OPENAI_BASE_URL (optional)
```

Keys must never be written to session files, shell history, debug logs, Lua UI snapshots, or crash reports. Strip Authorization headers and redact credentials from error messages. Prefer environment references to plaintext config. If key missing, show an actionable configuration error without crashing. Support a developer/offline fixture provider for demos and CI.

### 7.5 Streaming and HTTP reliability

- Incremental SSE parser tolerant of chunk boundaries, CRLF variations, multi-line data, partial UTF-8, `[DONE]` where applicable; maximum event size.
- Timeouts for connect/read/total requests; bounded exponential backoff with jitter for retryable errors before body consumption, honoring `Retry-After` where feasible.
- No accidental duplicate tool execution when retrying requests.
- Proper cancellation propagation to network tasks and spawned tools.
- TLS verification enabled by default; never globally disable certificate checks.
- HTTP status and JSON parsing errors surfaced with redacted bounded snippets, not raw secret-bearing payloads.
- Handle provider usage accounting when supplied; distinguish estimates from reported values.

### 7.6 Context and compaction

Initial implementation: workspace root, explicit referenced files, capped file contents, selected Git diff, bounded recent conversation, model-specific token budget estimate. Implement deterministic file inclusion/exclusion, `.gitignore` awareness, binary detection, size limits, path normalization, and context preview. Model should not silently read the entire repository.

P1: summarizing/compacting older turns when near context limit (using a model if configured), explicit visibility and persisted summary, ability to inspect included files, searchable file selection, prompt templates. Do not silently discard tool approvals or user constraints during compaction. User should be able to disable compaction.

### 7.7 Costs and usage

Record prompt/output/cache tokens if supplied. Provide per-turn/session usage and optionally estimated cost using a user-visible, dated model price table. If pricing is unknown or unverified, display token counts and “cost unavailable,” not invented prices. Set budget guardrails by tokens, tool calls, and optional cost estimates with clear limitations.

---

## 8. Coding tools and execution permissions

### 8.1 Built-in tools

Implement schemas, validation, outputs, and permission metadata for:

1. `read_file(path, start_line?, end_line?)` — bounded UTF-8 read, binary rejection or metadata, line numbers, workspace rules.
2. `list_files(path?, recursive?, max_entries?)` — efficient, ignores configured excluded dirs and `.gitignore` where supported.
3. `search(pattern, path?, glob?, max_results?)` — safe bounded plain-text or regex search; avoid catastrophic regex behavior; external ripgrep optional with fallback.
4. `write_file(path, content)` — guarded workspace write, optional atomic temp-file + rename, approval, no silent overwrite of concurrent edits.
5. `edit_file(path, old_text, new_text)` — exact unique match or explicit fail, compare-before-write, diff preview, approvals.
6. `shell(command, cwd?, timeout_ms?)` — explicit consent and output/time limits, cancellation/kill behavior, no shell injection from interpolation; commands are requested strings and executed only after policy check.
7. `git_status`, `git_diff`, optionally `git_log` — read-only; shell out safely with argument vectors, no uncontrolled shell concatenation.
8. P1: `apply_patch`, `find_symbol`/symbol search where possible, test runner presets.

Prefer `edit_file` or `apply_patch` over unreviewed whole-file replacement. Surface a diff before applying if configured. Include redaction of secrets from logs and UI where practical (do not claim perfect secret detection).

### 8.2 Permission model

Three decisions: `allow`, `ask`, `deny`, with scopes `once`, `session`, `workspace` (persistent only after explicit opt-in). Policy inputs: tool ID, capability class, canonical target paths, command metadata, workspace trust, plugin provenance, user setting. Policy engine in Zig is authoritative; Lua policy functions may **tighten** safety and request additional prompts, but cannot turn a core denial into allow.

Mandatory sensitive cases:

- Paths outside trusted workspace, symlink traversal, `..`, absolute paths, `.git` internals, credentials, SSH keys, environment files, home directory, system files.
- Destructive shell commands, privilege escalation, network/upload commands, package install scripts, Git history rewriting, and running tests with side effects.
- Worktree modified by someone else after an edit was proposed; detect and abort rather than clobber.
- Project-local instructions/plugins and tool output are **untrusted data**; never automatically reinterpret them as authorization to execute commands or expand permissions.
- Apply safety policy to direct UI commands, Lua plugins, hooks, subagents, MCP tools, and agent-invoked tools equally.

No regex-based command blacklist should be advertised as a complete sandbox. Use permissions, process isolation where available, hard limits, and explicit user consent. Shell sandboxing is platform-dependent; document guarantees and limitations precisely. For remote/network plugins, require capability grants and version pinning.

### 8.3 Approval UI

An approval modal shows: requesting agent/tool, exact command or diff summary, working directory and target paths, impact/risk signals, requested permission scope, and clear `Allow once`, `Allow for session` (if appropriate), `Deny`. Default focus should be Deny for high-risk operations. Never automatically approve because an LLM requested it. Headless mode should default to denying operations that require interaction unless the user explicitly supplies a restricted, auditable approval policy.

### 8.4 Testing

Test path traversal, symlink escape, race/concurrent edit, large file, binary file, command timeout, cancellation, subprocess output flood, exit code propagation, permission persistence/revocation, malformed tool args, LLM prompt injection in tool output, and plugin bypass attempts. Tools should return structured errors instead of crashing the TUI.

---

## 9. Sessions, persistence, and recovery

P0: list/create/resume/delete sessions; save conversation and tool results incrementally in a user-data directory with restrictive filesystem permissions. Prefer append-only JSONL with atomic metadata update, or SQLite if compatible/reproducible and worth the dependency. Use schema versioning and migration rules. Store workspace location, model used, message blocks, run state, usage, and timestamps. Make session IDs opaque/non-guessable if externally exposed. Do not persist API secrets.

Support:

- crash-safe append/checkpoint and validation of partial trailing writes;
- session browsing in TUI and CLI;
- session switching without leaking running callbacks into the wrong session;
- resume after interruption with clear markers for interrupted tool/model calls; never replay side-effecting tools automatically;
- bounded retention/cleanup configurable by user;
- export conversation to Markdown/JSON with redaction warning;
- config and plugin state stored separately from conversation state.

Test interrupted writes, invalid JSONL, incompatible schema versions, long sessions, and storage permissions.

---

## 10. Commands and interaction model

Commands should be registered in one place with name, aliases, description, arguments, permission requirements, and async result. The same command should be accessible from palette, slash command, keymap, and Lua API (where authorized).

Core commands target:

```text
/help                help and keybindings
/model               select a configured model
/providers           provider status/configuration
/session new         start a conversation
/session list        browse history
/session resume ID   resume
/context             inspect/add/remove context
/files               toggle file browser
/diff                review pending/working diffs
/tools               inspect registered tools and policy
/theme               switch theme
/reload              reload Lua config/plugins safely
/keymaps             inspect mappings/conflicts
/doctor              diagnostic view
/clear               clear prompt or conversation as specified
/quit                clean shutdown
```

Typed command arguments and validation; errors displayed in TUI and proper noninteractive exit codes. Plugin commands can be namespaced (`myplugin.command`) to avoid collisions; define overwrite rules and conflicts.

---

## 11. Programmable agent strategies and subagents (P1/P2)

The goal is to extend beyond cosmetic plugin support, **without surrendering the safety-critical core**.

### 11.1 Strategy API

Provide an extensible high-level workflow abstraction over safe operations. Proposed Lua syntax (adjust if needed):

```lua
local agent = require("bloob.agent")

agent.strategy.register("test-driven", function(ctx)
  local plan = ctx:plan()
  for _, step in ipairs(plan.steps) do
    ctx:run("write-tests", step)
    ctx:run("implement", step)
    local result = ctx:test()
    if not result.ok then ctx:run("debugger", result.output) end
  end
end)
```

**Implementation requirement:** Do not block the main event loop by running synchronous network calls in Lua. The actual design may use coroutines or task handles with explicit yield/resume semantics. Implement cancellation, max depth/iterations, budgets, tool approval, event logging, and predictable failure propagation. Strategies can propose steps, not bypass permissions. Document API execution semantics and supply working tests.

### 11.2 Subagents

Allow agents with individual name, role/system prompt, selected model, tool allowlist, budget, context visibility, and output type. Parent can spawn/await/cancel them. Limit concurrency and nested spawning. Results feed back into the parent as structured content. Avoid uncontrolled shared concurrent writes: use read-only subagents by default and serialize/approve write plans. UI can display a live agent monitor widget.

### 11.3 MCP, LSP, Tree-sitter

These are P2 integrations, after core quality is established:

- **MCP:** user-configured servers; protocol transport, discovery, typed tool schemas, permissions on each server/tool, error boundaries, clean shutdown, explicit trust.
- **LSP:** connect/spawn configured language servers; diagnostics, symbols, references, definitions, safe tool exposure, workspace lifecycle. No need to reimplement LSP.
- **Tree-sitter:** syntax and structural context support if Zig bindings/dependencies are compatible; fallback to plain text/highlight rules.

No feature should depend on these integrations to make the core TUI usable.

---

## 12. Public Lua documentation and real examples

Build examples as executable integration fixtures wherever possible. Required examples:

### 12.1 Minimal setup

```lua
require("bloob").setup({
  theme = "default",
  model = "openai/YOUR_CONFIGURED_MODEL",
})
```

### 12.2 Fully custom TUI

```lua
local ui = require("bloob.ui")
ui.set_layout(ui.column({
  ui.row({
    ui.sidebar({ id = "files", width = 22 }),
    ui.chat({ id = "conversation", flex = 1 }),
  }, { flex = 1 }),
  ui.input({ id = "prompt", height = 4 }),
  ui.statusline({ id = "status" }),
}))
```

### 12.3 Custom command and tool

```lua
local bloob = require("bloob")
local tools = require("bloob.tools")

bloob.command.register("hello", {
  description = "Show a greeting",
  run = function(ctx)
    ctx:notify("Hello from Lua")
  end,
})

tools.register("count_lines", {
  description = "Count lines in a workspace file",
  schema = {
    type = "object",
    properties = { path = { type = "string" } },
    required = { "path" },
  },
  permissions = { "workspace.read" },
  run = function(ctx, args)
    local content = ctx:read_file(args.path) -- checked by Zig
    local _, newlines = content:gsub("\n", "\n")
    return { count = newlines + (content:sub(-1) == "\n" and 0 or 1) }
  end,
})
```

The snippet is a design target; empty-file line counting should return 0 in the actual implementation. Implement `ctx:read_file` as a permission-checked, bounded operation. If your final API differs, update examples **and tests** consistently.

### 12.4 Vim-style keymaps, themes, hooks, hot reload

Provide separate `examples/` projects and screenshot/golden render fixtures for each. Document API version support, migration guidance, and common errors. Include examples of a plugin that renders a status widget and a plugin that defines an agent workflow.

---

## 13. Security, privacy, stability, and resource budgets

### 13.1 Threat model

Threat actors/data: malicious repository content, model-generated text, tool outputs, project-local Lua config, remote plugins, hostile filenames, crafted ANSI sequences, network responses, compromised MCP servers, symlink races. Boundaries: Zig core vs Lua extension, trusted vs untrusted configuration, workspace vs filesystem, tool execution vs approval policy, provider API vs user secrets.

Implement/document:

- Trusted **user-owned** `init.lua` may intentionally be powerful; do not mislabel its execution as sandboxed.
- Untrusted/project plugins do not run automatically. Load only after explicit consent with displayed requested capabilities; ideally create restricted Lua states with dangerous standard libraries removed (`io`, `os`, arbitrary `package.loadlib`, debug/ffi, etc.) and capability-mediated APIs. Lua states alone do **not** isolate native code or preempt arbitrary loops; enforce CPU/time/memory limits as feasible, and consider separate subprocess isolation for genuinely untrusted code. If secure sandboxing cannot be guaranteed, require trust or disable third-party execution by default.
- Lua instruction counters/timeout budgets protect responsiveness, but are not a complete security boundary.
- Secrets are never injected into generic Lua context, model context, logs, or session data by default.
- Provider/tool text is always escaped/sanitized before TUI output.
- Canonical path checks and restricted write operations; prefer safe OS APIs for symlink/race resistance where available.
- Structured logging defaults to redaction; optional verbose logs require explicit opt-in and warn about sensitive information.
- Process limits: timeout, output bytes, exit handling, cancellation and descendants where possible. Document limitations on each OS.
- Define per-turn request/tool/token limits, max message sizes, per-frame render budgets, plugin render depth/nodes, and session storage limits.
- File approvals, shell approvals, third-party plugin trust, and provider connection permissions remain separate and auditable.

### 13.2 Failure recovery

No panics on ordinary malformed input; use Zig error unions and structured diagnostic errors. A broken Lua plugin disables that plugin/widget and logs a traceback; base UI remains functional. A failed network request offers Retry/Cancel. A failed tool shows exit status/stderr bounded safely. A failed config reload rolls back without destroying the session. Detect terminal resize and EOF. Fuzz/fixture-test escape parsing, SSE, Lua marshaling, session data, and tool JSON where feasible.

---

## 14. Engineering quality, diagnostics, and performance

- Use format/lint checks consistent with pinned Zig and Lua syntax tooling (optional Lua formatter, document setup).
- Unit tests for parsers, path policy, state machine, layout, Unicode handling, config validation, Lua marshaling.
- Offline integration tests with fake HTTP/SSE provider and sandbox project fixture.
- Pseudo-terminal integration tests for startup, typing, resize, Ctrl-C and restoration, keybindings, modals, reload.
- Golden snapshots for rendered layouts and diffs; update intentionally, not indiscriminately.
- Instrument event-loop latency, render duration, number of dirty cells, Lua callback duration, memory allocations, tool durations, token streams (no secrets).
- Performance targets (guidelines, not fabricated guarantees): maintain responsive input during model streaming and tool execution; avoid terminal flicker and redraw storms; bounded memory on large output; support a sustained stream of ~100 tokens/second on a normal development machine without losing input events.
- Benchmark 10k chat lines, resize bursts, theme reload, many plugin widgets, large diffs, and rapid streaming. Save reproducible benchmark commands/results.
- Use correct ownership (`std.mem.Allocator`), arenas for short-lived render/request data where appropriate, explicit `deinit`, no dangling Lua userdata, and concurrency-safe event queues.
- Include a `--doctor` mode reporting Zig build version, terminal detected capabilities, config source files, plugin load errors, provider key presence (not values), and writable data directories.

---

## 15. Build sequence — execute in order

Each milestone must leave an executable and new tests. Mark status in `IMPLEMENTATION_STATUS.md`. Do not pursue later features at the cost of breaking earlier ones.

### M0 — Repository bootstrap and verified dependencies [P0]

- [ ] Inspect repo, record Zig version and build constraints, check Git status.
- [ ] Decide/version-lock Zig and third-party libraries after validating compatibility.
- [ ] Create build, test, smoke targets and a minimal CLI with `--help`, `--version`.
- [ ] Add README, LICENSE (choose permissive only if you have authority to license new code), `AGENTS.md`, architecture notes, and status ledger.
- [ ] Confirm `zig build`, `zig build test`, smoke target execute.

**Acceptance:** Reproducible build from checkout, no hidden system dependencies beyond documented toolchain/system libraries.

### M1 — Responsive terminal app, offline model [P0]

- [ ] Raw mode/alternate screen lifecycle and crash/error cleanup.
- [ ] Keyboard input, resize, UTF-8 text, mouse/paste if supported.
- [ ] Cell buffer, layout, dirty redraw, styles, default theme.
- [ ] Chat pane, multi-line editor, status line, help, scroll.
- [ ] Offline deterministic streaming mock adapter integrated into agent loop.
- [ ] Terminal golden tests and smoke run without credentials.

**Acceptance:** A user can launch in a TTY, type a message, receive gradually streamed fixture text, scroll history, resize, and exit with terminal restored. Non-TTY smoke mode works.

### M2 — Real provider and agent core [P0]

- [ ] Typed messages, run state machine, cancellation and limits.
- [ ] One actual provider with streaming text and tool-call parsing.
- [ ] Env-var auth, safe error handling, retries where safe.
- [ ] `--print` headless mode with real/mock provider.
- [ ] Offline SSE/provider fixtures and agent-loop tests.

**Acceptance:** With a valid key, real chat streams to the TUI; without key, errors are actionable; CI tests are credential-free.

### M3 — Workspace tools, safety, diff approvals [P0]

- [ ] Workspace path policy, read/list/search/edit/write/shell with bounds.
- [ ] Tool JSON schema validation, dispatch, typed results, max iterations.
- [ ] Permission system enforced in Zig; modal approval UI.
- [ ] Reviewable diffs and concurrency-safe writes.
- [ ] Security tests for path escape, approvals, injection, cancellation.

**Acceptance:** Agent can inspect a fixture project, propose a file patch, receive explicit user approval, execute safely, and show diff/result; denied tools never run.

### M4 — Embedded Lua, configuration, API contract [P0]

- [ ] Embed Lua; protected runtime, error reporting and lifecycle.
- [ ] Config discovery, schema validation, `--no-config`, safe mode.
- [ ] `bloob.setup`, themes, keymaps, commands, events, tool registration.
- [ ] Keep authoritative permission enforcement in Zig.
- [ ] Lua runtime/binding tests and a working minimal `init.lua`.

**Acceptance:** User Lua config changes theme, keymaps and command behavior; syntax errors report paths/lines while safe defaults still boot.

### M5 — **Composable Lua TUI** (signature feature) [P0]

- [ ] Public declarative UI nodes: row/column/panel/text/scroll/input/chat/status/sidebar.
- [ ] Lua `ui.set_layout`, custom widget registry, stable widget IDs, event dispatch.
- [ ] State signals/re-render invalidation with bounded callback execution.
- [ ] Custom component button/input events; focus and keyboard support.
- [ ] Layout constraints and narrow-terminal graceful fallback.
- [ ] Fully functional `examples/dashboard` and `examples/custom-widget`.
- [ ] Golden UI tests for default and custom layouts.

**Acceptance:** A Lua file can **replace the entire default application layout**, add a custom live widget, and interact with agent state without Zig recompilation. This is the project's distinguishing feature, not optional polish.

### M6 — Sessions, command palette, plugin lifecycle [P1]

- [ ] Durable versioned session storage and resume.
- [ ] Slash commands, command palette, search/help, better editor history.
- [ ] Plugin manifests, registration, capability requests, isolation/trust checks.
- [ ] Safe atomic Lua hot reload with error rollback and preserved session.
- [ ] Plugin install from local path; remote install optional later.
- [ ] Tests for plugin unload/reload, malformed plugins, session corruption.

**Acceptance:** Start chat, save, restart/resume, reload a custom Lua theme/layout/plugin without losing conversation; broken reload leaves previous config running.

### M7 — Provider and UX completeness [P1]

- [ ] OpenAI, Anthropic, configurable OpenAI-compatible endpoints.
- [ ] Model switching, usage reporting, cost where verified, model routing.
- [ ] Markdown and code rendering, rich diff navigation, contextual file browser.
- [ ] Context selection and token-budget controls, compaction.
- [ ] Theme/keymap docs, accessibility and terminal compatibility refinements.

**Acceptance:** Representative coding tasks work with each configured provider and offline fixture suite. UI remains responsive during streaming and large tool output.

### M8 — Programmable workflows and multi-agent [P1/P2]

- [ ] Lua strategy/workflow API with async execution semantics.
- [ ] Subagent registration, parallel read-only work, reporting and budgets.
- [ ] Tool/model routing hooks, before/after edit and test workflows.
- [ ] Agent monitor widget, cancellation, nested-run limits.
- [ ] Integration tests for orchestration and permission inheritance.

**Acceptance:** Example Lua plugin registers a custom workflow that plans, invokes safe tool steps, checks a result, and reports status in a custom widget, with bounded/cancellable execution.

### M9 — Integrations and polish [P2]

- [ ] MCP tool server client with capability checks and trust prompts.
- [ ] LSP diagnostics/symbols and optional Tree-sitter highlighting.
- [ ] Package/plugin distribution design with pinned versions.
- [ ] Improved mouse, selection, scrolling, accessibility, Windows fallback.
- [ ] Performance profiling, fuzzing, cross-platform CI and release artifacts.

**Acceptance:** Integrations are optional; enabling/disabling them does not destabilize core behavior. Documentation and test fixtures cover every released extension point.

### M10 — Release and final validation

- [ ] Run all build/test/smoke/format commands and document outputs.
- [ ] Run a clean-install scenario from README.
- [ ] Test no-config, broken-config, offline fixture, missing API key, real provider (if credentials explicitly available), and permission-denial flows.
- [ ] Validate terminal recovery on quit, cancel, and known errors.
- [ ] Audit secrets in repo/logs and dependency licenses.
- [ ] Verify every published Lua example loads and at least core UI examples render.
- [ ] Prepare changelog, architecture diagram, troubleshooting guide and honest feature matrix.
- [ ] Update `IMPLEMENTATION_STATUS.md` with full/partial/blocker per milestone.

**Acceptance:** The project is demonstrably usable, reproducible, and documented. No false claims of completed integration or tested platform.

---

## 16. Offline end-to-end acceptance scenarios

Implement a test harness (PTY where available, event injection otherwise) for these scenarios. Target all scenarios eventually; prioritize 1–7.

1. **Cold boot:** In a clean home directory, `bloob --no-config` starts, shows chat/editor/status and exits cleanly.
2. **Mock streaming:** Fixture provider emits 100 text deltas while user can navigate and resize; final message is preserved in history.
3. **Provider error:** Missing key or 429/500 response shows meaningful status, does not crash, never logs secret values.
4. **Tool approval:** Assistant requests `edit_file`, diff modal appears, Deny leaves file byte-for-byte unchanged; Allow performs checked update.
5. **Path traversal:** Attempts to read/write `../`, absolute sensitive paths or symlink escape are denied under default policy.
6. **Lua custom layout:** Example replaces default tree with split chat/sidebar plus custom widget; rendered golden snapshot matches.
7. **Lua failure:** Syntax/runtime error in plugin yields diagnostic; default or last-good UI continues, no corrupt terminal.
8. **Safe reload:** Change theme and widget text; `:reload` swaps UI while preserving messages/input; invalid reload rolls back.
9. **Resume:** Save and restart; previous messages and tool decisions remain visible without repeating side effects.
10. **Headless:** `bloob --print` and JSON mode have stable machine-readable, ANSI-free output and meaningful exit codes.
11. **Cancellation:** Ctrl-C stops pending model/tool run and returns to usable prompt without killing unrelated child processes.
12. **Huge output:** 10 MiB tool output is bounded/truncated with clear marker; UI doesn't freeze or exhaust memory.
13. **Unicode/terminal:** Width tests and 40-column rendering preserve prompt input and status without cell corruption.
14. **Plugins:** Registration, unload, repeated reload, permissions and API version mismatch behave predictably.
15. **Cross-provider:** Recorded OpenAI/Anthropic fixtures produce normalized stream events with tool call IDs and usage when supplied.
16. **Multi-agent:** Read-only subagent cannot write or bypass parent permission requirements; cancellation stops descendants.

---

## 17. Implementation guidance and pitfalls

### Zig-specific

- Build against **the installed, pinned Zig version**, checking its current API rather than relying on old snippets. Use errors explicitly, stable ownership, deterministic destruction, and minimal unsafe pointer casting.
- FFI: keep C ABI boundaries isolated, ensure `lua_State` never outlives dependent callbacks, avoid storing Lua pointers without registry references and cleanup, and guard callback reentrancy.
- Network/terminal concurrency: one thread or controlled queue owns mutable UI state and Lua state; workers send data/events; never call into a single Lua state concurrently.
- Handle allocators and cross-thread allocations consistently. Long streams/session snapshots must not retain pointers into temporary arenas.
- Prefer clear, boring code for core safety systems over clever abstractions.

### Lua-specific

- Public APIs need predictable parameter typing, errors with file/line traceback, and marshaling with depth/size limits.
- Prevent cycles in Lua UI tables and JSON/tool schema payloads; detect them and report useful errors.
- Configuration and render callbacks must not block on I/O; use event-driven tasks/handles.
- Document whether components are pure, when state can be mutated, and how updates are scheduled.
- Validate theme/layout/keybinding configuration before applying, with precise error paths.

### Product-specific

- A coding agent is more than a chat view. Users need trustworthy tools, diffs, approvals, cancellation, and recoverable sessions.
- Keep a tiny, delightful default interface; extensive customization should be optional.
- Preserve an unbreakable escape path from bad user UI layouts (e.g., safe mode or known key sequence) so a configuration cannot permanently hide the prompt or make the app unusable.
- Avoid competing with Pi by copying superficial UX; differentiate via coherent Lua-first programmability and Zig-native performance.

---

## 18. Definition of done

The **minimum compelling deliverable** is a Zig executable that:

- launches as a polished terminal app and restores terminal state;
- accepts text, streams at least one real provider, runs a deterministic offline mock, and supports cancellation;
- supports workspace file inspection/edits with visible diff and user approvals;
- loads Lua config and allows modifying theme/keybindings/commands;
- allows a user-authored Lua file to replace the top-level TUI layout and add a live custom widget;
- has tests, a reproducible build, examples, and usable docs.

A **mature v1** additionally has sessions, reliable multi-provider support, plugin lifecycle and reload, robust Markdown/diff UI, model routing, context management, and rich event APIs.

A **stretch v2** adds composable workflows, multi-agent execution, MCP/LSP/Tree-sitter integration, plugin distribution, extended rendering primitives, and advanced cross-platform terminal support.

Do **not** downgrade the signature Lua UI customization to a simple theme switch. If tradeoffs arise, prioritize a smaller agent with *working programmable layout and custom widgets* over a feature-rich fixed interface.

---

## 19. What to do immediately (first command through first demonstration)

1. Print `pwd`, `ls -la`, `git status --short`, `zig version`; inspect repository instructions and files.
2. Check `zig build` if a project exists; preserve what already works. Research library compatibility; choose and document toolchain/dependencies.
3. Implement a minimal `bloob` app that runs in both TTY and non-TTY fixture mode. Confirm compile/test.
4. Add event loop, terminal buffer and default chat/editor/status. Make mock streaming visible and cancellable.
5. Build real model integration and safe tools, then embed Lua and expose the first UI API.
6. Demonstrate **two different runnable Lua layouts without recompiling Zig**. One must include an actual custom interactive component.
7. Continue milestones in order, running checks and updating status at every checkpoint.

**At the end of your execution:** Print a concise implementation report with commands/results and paths to key files. If unfinished, cite precise blockers and the next tests/code changes. Leave a buildable repo and working vertical slice, not a pile of disconnected stubs.

---

## 20. References to verify while implementing

- Official Zig releases/documentation: https://ziglang.org/download/
- Zig 0.17.1 release (2026-11-03): https://ziglang.org/news/0.17.1-released/
- libvaxis terminal library: https://github.com/rockorager/libvaxis
- LuaJIT 2.1 runtime and C headers: https://github.com/LuaJIT/LuaJIT
- Lua 5.1 reference manual: https://www.lua.org/manual/5.1/
- Pi coding agent architecture/inspiration: https://github.com/badlogic/pi-mono

These are reference points, **not** a license to assume interfaces or compatibility. Confirm current README/API/build instructions, pin revisions, respect licenses, and update architectural decisions based on evidence.

---

# FINAL DIRECTIVE TO IMPLEMENTATION AGENT

**Implement this system. Start with the repository and a working, tested Zig executable; integrate Lua as a real first-class UI and agent customization layer; continue to the highest complete milestone you can reach without misrepresenting progress. Treat all checkboxes as executable work, not prose to paraphrase. Make decisions without stopping for ordinary clarifications. Keep security gates intact. Keep the application buildable and runnable. Document remaining work truthfully.**
