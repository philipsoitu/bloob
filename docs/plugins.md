# Lua plugins

bloob loads trusted user plugins from:

```text
$XDG_CONFIG_HOME/bloob/plugins/<plugin-name>/plugin.lua
# fallback: ~/.config/bloob/plugins/<plugin-name>/plugin.lua
```

Each `plugin.lua` runs in the same LuaJIT state as `init.lua`, after the user
config. It can use every public module (`bloob`, `bloob.ui`, `bloob.keymap`,
`bloob.events`, `bloob.tools`, `bloob.models`, `bloob.command`, …). A plugin can
register widgets, commands, keymaps, themes, events, tools and models exactly
like `init.lua`.

Example `plugin.lua`:

```lua
local bloob = require("bloob")
local ui = require("bloob.ui")
local keymap = require("bloob.keymap")

ui.register("demo.badge", function(ctx)
  return ui.text("plugin: " .. (ctx.model or ""), { color = "accent" })
end)

bloob.command.register("demo.greet", {
  description = "Greet from the demo plugin",
  run = function(ctx) ctx:notify("Hello from demo plugin") end,
})

keymap.set("normal", "<C-g>", "demo.greet", { desc = "demo greeting" })
```

See `examples/plugins/hello/plugin.lua` for a runnable example.

## Trust and safety

- Plugins in the user config directory are **trusted user code**. They have the
  full power of LuaJIT (including `ffi`, `io`, `os`), so only install plugins
  you trust.
- Project-local plugins are never loaded automatically. A future milestone may
  add explicit, capability-scoped project trust.
- `--safe-mode` skips plugin loading. `--no-config` also skips plugins.
- Plugin errors are reported with the file name and traceback; other plugins and
  the default UI continue to work.
- Plugins cannot bypass the Zig permission engine. A Lua tool still goes through
  allow/ask/deny and approval; hooks may only tighten a decision.

## Current lifecycle limitations

- There is no manifest or capability negotiation yet. `plugin.lua` is the
  entrypoint; a plugin executes at the top level.
- `setup(ctx)`/`teardown(ctx)` and plugin state migration are not implemented.
- Hot reload creates a new plugin runtime; plugin state does not survive reload.
- Remote installation, dependency resolution and version pinning are future
  work.
