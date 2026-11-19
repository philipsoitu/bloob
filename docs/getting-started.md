# Getting started

`bloob` is a terminal coding agent written in Zig with an embedded LuaJIT 2.1
runtime. The default UI works without configuration. A user `init.lua` can
change the theme/model, replace the layout, register widgets, add commands,
tools, keymaps and event hooks.

This guide covers the code as it exists at the current checkpoint. Where an API
from the design notes is not implemented, it is called out explicitly.

## Requirements

- Linux or another POSIX terminal environment
- Nix flakes
- Zig 0.17.1 (provided by the flake)
- LuaJIT 2.1 (provided by the flake)
- A UTF-8 terminal

```sh
nix develop
zig build
```

Artifacts are written to `zig-out/bin/bloob`.

## First run

```sh
# Interactive TUI, deterministic offline provider by default
./zig-out/bin/bloob

# Headless fixture output (does not load Lua config)
./zig-out/bin/bloob --print "hello"

# Diagnostics
./zig-out/bin/bloob --doctor
./zig-out/bin/bloob --list-models
./zig-out/bin/bloob --help
```

The default model is `mock/fixture`, so the TUI works offline. Real provider
streaming is wired for interactive mode through `openai/...`, `anthropic/...`
and `compat/...` model IDs; see [configuration.md](configuration.md).

## Configuration file

bloob reads `$XDG_CONFIG_HOME/bloob/init.lua`, falling back to
`~/.config/bloob/init.lua`. If the file does not exist, only the bundled
defaults run.

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/bloob"
cp examples/minimal/init.lua "${XDG_CONFIG_HOME:-$HOME/.config}/bloob/init.lua"
```

You can also point at a file explicitly:

```sh
./zig-out/bin/bloob --config examples/minimal/init.lua
./zig-out/bin/bloob --no-config
```

Project-local `.bloob/init.lua` is **not** loaded automatically in this build.
There is no system-wide config file. `--safe-mode` is parsed but currently has
no effect.

## A minimal configuration

```lua
local bloob = require("bloob")

bloob.setup({
  theme = "catppuccin",
  model = "mock/fixture",
  leader = "\\",
})

bloob.notify("loaded my config")
```

`bloob.setup` applies only `theme`, `model` and `leader` today. Other keys such
as `editor`, `permissions` or `ui` are accepted and ignored.

## A custom layout

```lua
local bloob = require("bloob")
local ui = require("bloob.ui")

bloob.setup({ theme = "catppuccin" })

ui.set_layout(ui.column({
  ui.row({
    ui.sidebar({ id = "files", width = 22 }),
    ui.chat({ id = "conversation", flex = 1 }),
  }, { flex = 1 }),
  ui.input({ id = "prompt", height = 4 }),
  ui.statusline({ id = "status" }),
}))
```

See [ui-components.md](ui-components.md) for node options and widget state.

## Examples

| Directory | What it demonstrates |
| --- | --- |
| [`examples/minimal`](../examples/minimal/) | theme, model and leader |
| [`examples/dashboard`](../examples/dashboard/) | replacement layout and a custom session widget |
| [`examples/custom-widget`](../examples/custom-widget/) | signals and button callbacks |
| [`examples/custom-tool`](../examples/custom-tool/) | `tools.register` with schema and `run(ctx, args)` |
| [`examples/custom-command`](../examples/custom-command/) | commands and keymap actions |
| [`examples/vim-mode`](../examples/vim-mode/) | normal/insert command bindings |
| [`examples/events`](../examples/events/) | `file.after_write` and `tool.before_execute` hooks |

Run an example directly:

```sh
./zig-out/bin/bloob --config examples/dashboard/init.lua
```

Verify all examples without starting the TUI:

```sh
# LuaJIT syntax check
for f in examples/*/init.lua; do luajit -bl "$f" /dev/null || exit 1; done

# Stub harness: real bundled Lua modules, stubbed C bridge
nix develop -c luajit examples/verify.lua
```

The harness checks module loading, layouts, widget names, tool/command
registration and key callbacks. It is not a renderer or provider integration
test.

## Keys and commands

| Key | Action |
| --- | --- |
| `Enter` / `Ctrl-S` | send the prompt (insert mode) |
| `Alt-Enter` / `Ctrl-J` | insert a newline |
| `Ctrl-P` | command palette |
| `Ctrl-R` | reload Lua configuration |
| `Ctrl-Q` | quit |
| `Ctrl-C` | cancel/clear; press twice quickly to quit |
| `F1` | help overlay |
| `PageUp` / `PageDown` | scroll the conversation |
| `Esc` | toggle insert/normal mode |
| `i` | insert mode from normal mode |
| `:` or `/` | command palette from normal mode |
| `Tab` / `Enter` | cycle focus / activate focused button (Enter activates in normal mode) |

Slash commands: `/help`, `/model`, `/providers`, `/session`, `/context`,
`/files`, `/diff`, `/tools`, `/theme`, `/reload`, `/keymaps`, `/doctor`,
`/clear`, `/new`, `/quit`, `/export`.

Some commands are placeholders: `/context`, `/diff`, `/export` and session
persistence are not fully implemented, and `/tools` reports a fixed legacy
string rather than the live registry. `/files` toggles the native layout's
sidebar flag; a Lua layout that always renders a sidebar is unaffected.
Lua commands are also available through the palette and `/name`.

## Reloading

Press `Ctrl-R`, run `/reload`, or call `bloob.config.reload()`. Reloading builds
a new Lua state, loads the same config path, validates that the layout can be
built, then swaps it in. If anything fails, the previous state is kept and an
error notification is shown. Signals, widget state and Lua module state are not
preserved across a successful reload.

## Troubleshooting

**The TUI is broken after a crash.** Run `reset` or `stty sane` in the shell,
then start bloob again.

**My config has an error.** A syntax/runtime error at startup is reported and
bloob falls back to the bundled defaults. A bad layout can fall back to the
native layout at render time. Check the notification line or run with a minimal
config to isolate the problem.

**`--config` says the file was not found.** The path is resolved relative to the
current directory. Use an absolute path to avoid surprises.

**Headless output ignores my config.** `--print` and `--json` currently use a
headless runner that does not create the Lua runtime. Model selection still
comes from `--model`/`BLOOB_*` environment variables.

**Real providers do not work in `--print`.** Real streaming providers work in
headless mode when their API key (or compatible base URL) is configured; the
fixture provider remains the zero-credential default.

## Current limitations

- `bloob.features` reports what the Lua layer supports, not every core feature.
  Basic trusted user plugin loading is available; MCP and LSP are not.
- Sessions are persisted as append-only JSONL and can be resumed, listed and
  deleted with `--resume`, `--session`, `--list-sessions` and
  `--delete-session`. Headless mode does not create a session yet.
- Project-local config/plugins are never auto-loaded. `--safe-mode` skips user
  plugins; `--no-config` skips both user config and plugins.
- Key chords are not implemented. `<leader>x` specs are rejected rather than
  silently treated as a bare leader key. See [keymaps.md](keymaps.md).
- Lua tools can use `ctx:read_file(path)` (checked by the Zig workspace policy),
  but the custom-tool execution surface is intentionally small. See
  [security.md](security.md).
- Visual mode, rich dialogs, async Lua tasks, context compaction, subagents,
  strategies, MCP, LSP and Tree-sitter remain future work.

For the full API, continue with [configuration.md](configuration.md),
[lua-api.md](lua-api.md), [ui-components.md](ui-components.md),
[keymaps.md](keymaps.md), [events.md](events.md), [plugins.md](plugins.md) and
[security.md](security.md).
