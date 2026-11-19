# bloob

`bloob` is a high-performance, deeply customizable terminal coding agent written in **Zig**, with **LuaJIT 2.1** as its configuration, plugin, UI and automation language.

The default application works with zero configuration. The UI is built from the same declarative primitives exposed to Lua, so users can replace layouts, register widgets, add keybindings, tools, commands, themes and hooks without recompiling Zig.

> Status: active implementation. See [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) for an honest feature matrix and known gaps.

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
      [--doctor] [--version] [--help]
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
