# bloob

`bloob` is a high-performance, deeply customizable terminal coding agent written in **Zig**, with **LuaJIT 2.1** as its configuration, plugin, UI and automation language.

The default application works with zero configuration. The UI is built from the same declarative primitives exposed to Lua, so users can replace layouts, register widgets, add keybindings, tools, commands, themes and hooks without recompiling Zig.

> Status: usable first implementation. Sessions, real streaming providers (OpenAI-compatible and Anthropic Messages), workspace tools with approvals, headless `--print`/`--json`, Lua layouts/widgets/commands/tools/events and trusted user plugins are implemented. See [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) for the feature matrix and known gaps.

## Quick start

```sh
nix develop
zig build
./zig-out/bin/bloob                 # interactive TUI
./zig-out/bin/bloob --print "hello"  # offline deterministic fixture
zig build test
zig build smoke
```

Requirements: Nix flakes, Zig 0.17.1, LuaJIT 2.1 (provided by the dev shell), a UTF-8 terminal.

## CLI

```text
bloob [--cwd PATH] [--config PATH] [--no-config] [--safe-mode]
      [--model provider/model] [--resume [ID]] [--session ID]
      [--print [PROMPT]] [--json] [--list-models] [--list-sessions]
      [--delete-session ID] [--doctor] [--self-test] [--version] [--help]
```

## Configuration

User config lives at `$XDG_CONFIG_HOME/bloob/init.lua` (fallback `~/.config/bloob/init.lua`). Project-local `.bloob/` configuration is not executed automatically.

```lua
local bloob = require("bloob")
local ui = require("bloob.ui")

bloob.setup({ theme = "catppuccin", model = "mock/fixture" })

ui.set_layout(ui.column({
  ui.row({
    ui.sidebar({ id = "files", width = 22 }),
    ui.chat({ id = "conversation", flex = 1 }),
  }, { flex = 1 }),
  ui.input({ id = "prompt", height = 4 }),
  ui.statusline({ id = "status" }),
}))
```

## Technology

- Zig 0.17.1 (installed compiler; `@cImport` was removed in this version, so LuaJIT bindings are generated with `std.Build.addTranslateC` from the official LuaJIT headers — still direct C ABI interop, no binding library).
- LuaJIT 2.1 through the Nix-provided `luajit.pc`.
- Native ANSI terminal backend owned by bloob (no terminal library types leak into the Lua API).
- Build and dependency pinning through `flake.nix` / `flake.lock`.

## License

MIT. See `LICENSE`.

## Features

- Native Zig TUI: chat, multiline editor, streaming, scrolling, mouse wheel,
  focus, command palette, help, status bar, approval modal and terminal restore.
- Declarative Lua UI: default layout is Lua; replace it, register widgets, use
  signals/buttons, customize themes and keymaps without recompiling.
- Agent runtime: OpenAI-compatible and Anthropic streaming, normalized tool
  calls, usage accounting, cancellation, bounded tool loops.
- Workspace tools: read/list/search/edit/write/shell/git with Zig-enforced path
  safety, approvals, diff preview and bounded output.
- Sessions: incremental JSONL persistence, resume, list and delete.
- Headless operation: `--print` / `--json`, fixture or real providers, safe
  default-deny for approval-gated tools.
- Trusted user plugins from `$XDG_CONFIG_HOME/bloob/plugins/`.

## Tests

```sh
nix develop -c zig build test
nix develop -c tests/pty_smoke.sh
nix develop -c luajit examples/verify.lua
./zig-out/bin/bloob --self-test
```
