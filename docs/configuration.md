# Configuration

bloob is configured with Lua. The bundled defaults always load first, so an
empty or missing user config is valid.

## Discovery and precedence

At interactive startup the current implementation does the following:

1. The Lua runtime installs its bundled modules and the default layout from
   `src/runtime/lua/bloob/`.
2. If `--no-config` was passed, no user config is loaded. This wins even if
   `--config` was also passed.
3. Otherwise, if `--config PATH` was passed, that exact path is loaded.
4. Otherwise, `$XDG_CONFIG_HOME/bloob/init.lua` is loaded if it exists; if
   `XDG_CONFIG_HOME` is unset, `$HOME/.config/bloob/init.lua` is used.
5. CLI model selection (`--model`) is applied before the Lua config, so
   `bloob.setup({ model = ... })` can override it.

Not implemented yet:

- system-wide configuration files;
- automatic project-local `.bloob/init.lua` execution (project files are never
  loaded implicitly);
- automatic project-local plugin execution (only the trusted user plugin
  directory is loaded);
- a full settings schema: `bloob.setup` applies `theme`, `model` and `leader`;
  other design-note keys are accepted but ignored.

Local modules can be `require`d from the config directory: the runtime prepends
`<config-dir>/lua/?.lua`, `<config-dir>/lua/?/init.lua` and equivalent paths to
`package.path` **before** executing `init.lua`.

`--no-config` disables user config and plugins; `--safe-mode` keeps user config
but skips plugin loading. Project-local code is never auto-executed. User
plugins live in `<config-dir>/plugins/<name>/plugin.lua`; see
[plugins.md](plugins.md).

`bloob.config.sources()` returns the paths that were successfully loaded.
`bloob.config.reload()` requests the same atomic reload used by `Ctrl-R` and
`/reload`.

## `bloob.setup`

```lua
local bloob = require("bloob")

bloob.setup({
  theme = "catppuccin",
  model = "mock/fixture",
  leader = "\\",
})
```

Only these keys have an effect:

| Key | Effect |
| --- | --- |
| `theme` | Calls `ui.theme.set(name)`; unknown names are ignored by the host |
| `model` | Calls the host model setter; the id should be `provider/model` |
| `leader` | Sets the leader codepoint used when parsing later key specs |

The setup table itself is not a general validated settings database. Design
keys such as `editor`, `permissions`, `ui`, `plugins` or `storage` are accepted
but ignored. There is no public API to read the full effective configuration;
`bloob._state()` is an internal placeholder that returns an empty table.

## Themes

Built-in themes:

- `default` (also `dark`)
- `light`
- `monochrome` (also `mono`)
- `catppuccin`

Select one with `bloob.setup({ theme = ... })`, `ui.theme.set(name)`, or
`/theme NAME`. Unknown names are ignored by the host without an error at the Lua
level; `/theme NAME` shows an "Unknown theme" notification.

Register a custom palette before selecting it:

```lua
local ui = require("bloob.ui")

ui.theme.register("my-theme", {
  default = "#d8dee9",
  fg = "#d8dee9",
  bg = "#1e1e2e",
  primary = "#89b4fa",
  secondary = "#cba6f7",
  muted = "#7f849c",
  success = "#a6e3a1",
  warning = "#f9e2af",
  error = "#f38ba8",
  info = "#94e2d5",
  border = "#585b70",
  selection = "#45475a",
  focus = "#89dceb",
  tool = "#cba6f7",
  tool_error = "#f38ba8",
  diff_added = "#a6e3a1",
  diff_removed = "#f38ba8",
  diff_hunk = "#94e2d5",
  code = "#f9e2af",
  heading = "#cba6f7",
  user = "#89dceb",
  assistant = "#a6e3a1",
  accent = "#cba6f7",
  cursor = "#89b4fa",
})

ui.theme.set("my-theme")
```

Color values support semantic names, `#rrggbb` hex, ANSI names such as `red`,
and numeric 256-color indexes. Unknown strings fall back to the `fg` semantic
color. See [ui-components.md](ui-components.md) for the palette and style
details.

## Models and providers

`mock/fixture` is always available and requires no network. Real providers are
resolved by prefix:

| Model prefix | Environment |
| --- | --- |
| `openai/MODEL` | `OPENAI_API_KEY`; optional `OPENAI_BASE_URL` or `BLOOB_OPENAI_BASE_URL` |
| `anthropic/MODEL` | `ANTHROPIC_API_KEY`; optional `BLOOB_ANTHROPIC_BASE_URL` |
| `compat/MODEL` or `openai-compatible/MODEL` | required `BLOOB_COMPAT_BASE_URL`; optional `BLOOB_COMPAT_API_KEY` (falls back to `OPENAI_API_KEY`) |

Examples:

```sh
OPENAI_API_KEY=... ./zig-out/bin/bloob --model openai/gpt-4.1
ANTHROPIC_API_KEY=... ./zig-out/bin/bloob --model anthropic/claude-sonnet-4
./zig-out/bin/bloob --model mock/fixture
```

The current API is small and partly placeholder:

```lua
local models = require("bloob.models")

models.set("mock/fixture") -- also calls the host model setter
print(models.current())    -- returns the Lua-side selection
models.list()              -- always returns only mock/fixture
models.route(function(ctx)
  -- ctx = { task = ..., model = ... }
  -- NOTE: the host currently never calls this route function.
  return ctx.model
end)
```

`models.current()` reflects the Lua `models.set` selection, not a model chosen
with `/model`, `--model` or `bloob.setup({ model = ... })`. `models.list()` does
not inspect provider availability. Dynamic routing is registered but not wired
into the agent loop.

Headless `--print` supports only `mock/fixture` and does not load Lua config.
Real provider streaming is available in the interactive TUI.

## Reloading

`Ctrl-R`, `/reload` and `bloob.config.reload()` all request a reload. The app:

1. creates a fresh Lua state and loads the bundled modules;
2. loads the same config path (if any);
3. builds the candidate layout once to catch layout errors;
4. swaps the state only if all steps succeed.

A failed reload keeps the previous state and shows an error. A successful reload
discards Lua globals, signals, widget state, custom registrations and callbacks;
the config must register everything again. Host state such as the current model
and theme is restored from the app's previous values if the reload fails.

## Load and layout errors

A syntax error or runtime error while executing `init.lua` causes bloob to start
with a fresh bundled-default runtime and report the error. At render time, an
invalid layout falls back to the native layout and reports `UI layout error`.
On reload, the candidate layout is validated before the swap.

## Environment variables

| Variable | Purpose |
| --- | --- |
| `XDG_CONFIG_HOME` | Config root; bloob looks for `bloob/init.lua` |
| `HOME` | Fallback config root and `$HOME/.config/bloob/init.lua` |
| `OPENAI_API_KEY` | OpenAI provider credentials |
| `OPENAI_BASE_URL` / `BLOOB_OPENAI_BASE_URL` | OpenAI-compatible base URL override |
| `ANTHROPIC_API_KEY` | Anthropic provider credentials |
| `BLOOB_ANTHROPIC_BASE_URL` | Anthropic base URL override |
| `BLOOB_COMPAT_BASE_URL` | Required for `compat/...` |
| `BLOOB_COMPAT_API_KEY` | Optional key for `compat/...` |
| `PWD` | Default working directory when `--cwd` is not given |
| `TERM`, `COLORTERM` | Terminal capability/color detection |

The Nix dev shell also provides LuaJIT; it is not selected by an environment
variable.

## Full example

```lua
local bloob = require("bloob")
local ui = require("bloob.ui")

bloob.setup({
  theme = "catppuccin",
  model = "mock/fixture",
  leader = "\\",
})

ui.register("my.status", function(ctx)
  return ui.panel({
    ui.text("model: " .. tostring(ctx.model)),
    ui.text("state: " .. tostring(ctx.state)),
    ui.text("messages: " .. tostring(ctx.message_count)),
  }, {
    title = "Status",
    border = "rounded",
    padding = 1,
    width = 28,
  })
end)

ui.set_layout(function(ctx)
  return ui.column({
    ui.row({
      ui.chat({ id = "conversation", flex = 1, border = "rounded", title = "Chat" }),
      ui.widget("my.status"),
    }, { flex = 1 }),
    ui.input({ id = "prompt", height = 4 }),
    ui.statusline({ id = "status" }),
  })
end)
```

More complete, runnable files live in [`examples/`](../examples/).
