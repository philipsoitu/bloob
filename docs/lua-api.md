# Lua API

`bloob` embeds LuaJIT 2.1. The API version is `1` (`bloob.api_version`). It is
still an early interface: private names beginning with `_` are implementation
details and may change without notice.

All example snippets in this document use only APIs present in the current
checkpoint. Unsupported design-note APIs are marked **not implemented**.

## Loading modules

Bundled modules are installed before the user config runs:

```lua
local bloob   = require("bloob")
local ui      = require("bloob.ui")
local keymap  = require("bloob.keymap")
local events  = require("bloob.events")
local tools   = require("bloob.tools")
local models  = require("bloob.models")
local config  = require("bloob.config")
```

`require("bloob.agent")`, `require("bloob.plugins")`,
`require("bloob.storage")` and `require("bloob.command")` return empty
placeholder tables. In particular, the command API is on `require("bloob")`
(`bloob.command.register`), not on the separate `bloob.command` module table.

The runtime also sets a global `bloob` table, but the `require` form is the
supported style.

## `bloob`

Fields:

| Field | Value |
| --- | --- |
| `version` | `"0.1.0"` |
| `api_version` | `1` |
| `lua51` | `true` |
| `runtime` | `"luajit-2.1"` |
| `platform` | Zig target OS tag, e.g. `"linux"` |
| `lua_ffi_available` | `1`; LuaJIT's `ffi` module is available |
| `features` | Table of booleans (see below) |

`features` currently reports:

```lua
{
  lua_ui = true,
  signals = true,
  custom_widgets = true,
  custom_commands = true,
  custom_tools = true,
  keymaps = true,
  events = true,
  hot_reload = true,
  plugins = false,
  mcp = false,
  lsp = false,
}
```

`features` describes the Lua-facing layer; it does not guarantee that every
core agent feature is complete.

### `bloob.setup(opts)`

```lua
bloob.setup({
  theme = "catppuccin",
  model = "mock/fixture",
  leader = "\\",
})
```

- `opts` may be `nil` (no-op) or a table.
- `theme` calls the host theme setter if present.
- `model` calls the host model setter.
- `leader` stores the leader codepoint for later key-spec parsing.
- Any other key is accepted and ignored. There is no general settings store.

### `bloob.notify(message, opts)`

Shows a status notification.

```lua
bloob.notify("saved")
bloob.notify("could not save", { error = true })
bloob.notify("could not save", { level = "error" })
```

Forwards to `ui.notify`. Non-string messages are converted with `tostring`.

### `bloob.quit()`

Requests application shutdown.

### `bloob.log(message)`

Writes an informational log line through Zig's logger. Intended for debugging;
it is not a UI notification.

### `bloob.command_run(name, args)`

Dispatches a command through the application, exactly like a slash command or
keymap command action. This reaches both native commands (`help`, `theme`, ...)
and Lua-registered commands. It returns no meaningful value (`nil`); use the
local `bloob.command.run` below if you need a success boolean for the Lua
registry.

```lua
bloob.command_run("theme", "catppuccin")
bloob.command_run("greet", "Ada")
```

Native commands take precedence over a Lua command with the same name.

### `bloob.command.register(name, spec)`

```lua
bloob.command.register("greet", {
  description = "Show a greeting",
  run = function(ctx)
    local who = ctx.args ~= "" and ctx.args or "world"
    ctx:notify("Hello, " .. who)
  end,
})
```

- `name` must be a non-empty string. It may contain dots or dashes.
- `spec.run(ctx)` is required.
- `spec.description` is used by the command palette.
- Registrations are also exposed in `bloob.command.registry[name]`.
- Registering the same Lua name again replaces the registry entry and updates
  the host description.
- A command name that collides with a native command is reachable through
  `bloob.command.run`, but the application dispatcher will run the native
  command instead.

Command `ctx` fields in this build:

| Field | Type | Meaning |
| --- | --- | --- |
| `args` | string | Raw argument text after the command name; may be empty |
| `notify` | function | `ctx:notify(message, opts)` or `ctx.notify(ctx, ...)` |

No parsed arguments, session data, async result or permission fields exist yet.

### `bloob.command.run(name, args)`

Runs a **Lua-registered** command directly, bypassing native command dispatch.
Returns `true` on success, or `false, error_message` if the name is unknown or
the handler raised an error. Errors are also shown as notifications.

### `bloob.command.registry`

A normal Lua table keyed by command name containing the registered specs. It is
readable, but prefer `bloob.command.register`.

### Internal helpers

`bloob._notify`, `_quit`, `_set_model`, `_current_model`, `_request_render`,
`_request_reload`, `_run_command`, `_setup`, `_state`, `_config_sources`,
`_register_command`, `_read_file` and `_log` are the Lua/C bridge. Do not rely
on them. `_read_file` in particular is not the workspace-checked tool API.

## `bloob.ui`

`bloob.ui` builds declarative node tables, registers widgets, owns themes and
provides signals and notifications. See [ui-components.md](ui-components.md)
for the full node reference.

### Node constructors

```lua
ui.text(content, opts)
ui.row(children, opts)
ui.column(children, opts)
ui.panel(children, opts)      -- or ui.panel(opts) for an empty panel
ui.spacer(size_or_opts)
ui.scroll(children, opts)
ui.overlay(children, opts)
ui.tabs(children, opts)
ui.list(items, opts)
ui.input(opts)
ui.chat(opts)
ui.sidebar(opts)
ui.statusline(opts)
ui.diff(opts)
ui.button(label, opts)
ui.widget(name, opts)
```

`ui.input`, `ui.chat` and `ui.sidebar` assign default IDs (`prompt`,
`conversation`, `files`). `ui.statusline` defaults to `id = "status"` and
`height = 1`. `ui.button` is focusable and accepts `on_press`.

### `ui.register(name, fn)`

Registers a widget function. `fn(ctx)` must return a node table. Rendering a
widget:

- calls the function with the read-only context snapshot;
- converts the returned table to native nodes;
- catches errors and shows an error panel instead of crashing;
- shows an "Unknown widget" panel if the name is not registered;
- shows an "invalid" panel if the function returns a non-table.
- ignores all node options placed on the `ui.widget(...)` wrapper (size,
  border, style, `visible`, ...); put those on the node returned by the widget
  function.

Widgets must be re-registered after a successful config reload.

### `ui.get_widget(name)`

Returns the registered function or `nil`.

### `ui.set_layout(layout)`

`layout` is either a node table or a function `function(ctx) return node end`.
A function is called on every layout build with the context snapshot. The
default layout is installed by bundled Lua before the user config runs, so a
user config can replace it entirely.

### `ui.theme.register(name, palette)` and `ui.theme_set(name)`

`ui.theme.register` stores a palette. `ui.theme_set` asks the host to activate
it. Unknown theme names are ignored by the host. The shorthand `ui.theme.set`
is also provided.

### `ui.notify(message, opts)`

```lua
ui.notify("ok")
ui.notify("failed", { error = true })
ui.notify("failed", { level = "error" })
```

Only `error = true` or `level = "error"` are interpreted.

### `ui.request_render()`

Marks the UI dirty and schedules a redraw. Signals already do this; call it
manually after mutating non-signal state that affects a widget.

### `ui.command(name, args)`

Alias for the host command dispatcher; equivalent to `bloob.command_run`.

### `ui.quit()`

Requests application shutdown.

### Signals

```lua
local count = ui.signal(0)

count:get()                       -- current value
count:set(1)                      -- set; schedules a redraw if changed
count:update(function(v) return v + 1 end)
count:connect(function(value) ... end)
count:disconnect(fn)
```

- `set` uses Lua `==` for equality; setting the same scalar again is a no-op.
- Table values compare by identity.
- Subscribers run synchronously inside `set`; errors are reported as
  notifications and do not abort the remaining subscribers.
- Every effective `set` calls the host render request.
- Signals are in-memory only and reset on reload.
- `ui.signal_depth()` exists but currently always returns `0`; it is not a
  reentrancy guard. Do not mutate a signal from inside a render widget call, or
  you can create avoidable redraw loops.

### Internal UI helpers

`ui._render_widget`, `_set_layout`, `_theme_register`, `_theme_set`, `_notify`,
`_request_render`, `_command` and `_quit` are bridge functions. They are used by
the bundled Lua modules and the stub harness; they are not part of the stable
public API.

## `bloob.keymap`

```lua
local keymap = require("bloob.keymap")

keymap.set(mode, lhs, rhs, opts)
keymap.del(mode, lhs)
keymap.del_all()
keymap.list()
keymap.leader(value)   -- returns the encoder string of the current leader
```

- `mode` is a string. The app matches the current editor mode (`"insert"` or
  `"normal"`) and also falls back to `"global"`.
- `lhs` is a key spec. Chords are **not** supported. See [keymaps.md](keymaps.md).
- `rhs` is either a command-name string or a function.
- `opts.desc` supplies the palette/description string.
- `opts` has no other recognized fields.
- Re-setting the same `mode` + `lhs` replaces the old mapping.
- `keymap.list()` returns the mappings registered through this Lua module as
  `{ mode, lhs, rhs, desc }` tables. It does not include native keys.

Command strings are dispatched with empty arguments:

```lua
keymap.set("normal", "<C-g>", "help", { desc = "Help" })
```

Pass arguments from a callback instead:

```lua
keymap.set("normal", "<C-y>", function()
  bloob.command_run("theme", "catppuccin")
end, { desc = "Catppuccin" })
```

## `bloob.events`

See [events.md](events.md) for payloads and dispatch semantics.

```lua
local events = require("bloob.events")

local handle = events.on(name, fn, { priority = 50, once = false })
events.once(name, fn, opts)
events.off(handle)       -- handle from on/once; returns boolean
events.reset(name)       -- remove one event's handlers
events.reset()           -- remove all handlers
events.count(name)       -- number of handlers
events.emit(name, payload) -- manual dispatch; returns a decision or nil
```

- Handlers receive an event facade `e`. Payload fields are available directly
  (`e.path`, `e.tool`, ...), via `e:get(key)`, and `e:notify(message, opts)` is
  available.
- Lower `priority` runs first. Default is `50`.
- `once = true` removes the handler after a successful invocation.
- Handler errors are caught and notified.
- Return `false` or `"deny"` to deny a tool; return `"ask"` to escalate to the
  approval modal; returning `{ action = "deny" }` or `{ action = "ask" }` has
  the same effect. Other return values are ignored.
- Event names are not restricted, but only events the app actually emits will
  fire unless you call `events.emit` yourself.

`events._dispatch` is the C bridge and is not public.

## `bloob.tools`

```lua
local tools = require("bloob.tools")

tools.register(name, spec)
tools.get(name)
tools.list()
```

`spec`:

| Field | Required | Meaning |
| --- | --- | --- |
| `run` | yes | `function(ctx, args)` |
| `description` | no | Sent to providers |
| `schema` | no | JSON-like Lua table sent to providers; defaults to `{ type = "object", properties = {} }` |
| `permissions` | no | Stored metadata; not enforced yet |

`tools.list()` returns a sorted array of `{ name, description, schema,
permissions }` for Lua-registered tools only. `tools.get` returns the original
registry entry.

Tool execution:

```lua
run = function(ctx, args)
  local value = args.some_field
  return { ok = true, value = value }
end
```

- `ctx` is the same snapshot shape as a widget context (see below).
- `args` is the tool arguments decoded from JSON into a Lua table.
- The returned value is serialized to JSON for the conversation/tool result.
- Tables with contiguous integer keys `1..n` become arrays; other tables become
  objects. Functions, threads and userdata are not meaningful.
- If `run` raises an error, the app reports `Lua tool failed`; there is no
  detailed Lua traceback in the tool message.

`tools._register`, `tools._list` and `tools._invoke` are bridge functions.

## `bloob.models`

```lua
models.selection          -- Lua-side selection string, initially "mock/fixture"
models.set(id)            -- update selection and call the host setter
models.current()          -- read models.selection
models.route(fn)          -- register a router function
models.list()             -- fixed list containing only mock/fixture
```

`models.route` stores the function, but the current app never calls it, so
routing has no effect yet. `models.list` does not reflect the real provider
registry. See [configuration.md](configuration.md) for environment variables and
provider prefixes.

## `bloob.config`

```lua
config.sources()   -- array of successfully loaded config paths
config.reload()    -- request an atomic reload (same as Ctrl-R)
```

There is no public validated settings table, save operation or per-plugin
storage.

## Widget and tool context

Layout functions, widgets and Lua tools receive a new read-only snapshot table:

| Field | Type | Notes |
| --- | --- | --- |
| `width`, `height` | integer | Terminal size in cells |
| `cwd` | string | Working directory |
| `model` | string | Active model id |
| `provider` | string | Provider prefix |
| `theme` | string | Active theme name |
| `mode` | string | `"insert"` or `"normal"` |
| `state` | string | `"idle"`, `"streaming"`, `"awaiting_approval"`, `"executing_tools"`, `"failed"` or `"cancelled"` |
| `session_id` | string | Currently `"local"` |
| `git_branch` | string | Placeholder; currently always `""` |
| `busy` | boolean | Streaming or executing tools |
| `message_count` | integer | Conversation message count |
| `prompt_tokens`, `completion_tokens`, `total_tokens` | integer | Accumulated usage |
| `bloob_version`, `api_version` | string/integer | Runtime version information |
| `agents` | table | Placeholder; currently always empty |

There is **no** `ctx:read_file`, `ctx:write_file`, async task API, session
history or mutable engine handle in this build.

## Data conversion and limits

- Lua-to-JSON serialization is intended for plain tables, strings, numbers,
  booleans and nil. Do not return functions or cyclic tables.
- An empty Lua table serializes as `{}` (an object), not `[]`. This matters for
  JSON Schema fields such as `required = {}`; omit them or use a non-empty
  array.
- Layout conversion has a recursion-depth limit of 64 and a node limit of 4096.
- Unknown node kinds and missing widget names produce layout/widget errors.
- Layout and widget errors are caught; a bad widget becomes an error panel and a
  bad layout falls back to the native layout.
- Command dispatch through the host has a recursion guard of 8. The local
  `bloob.command.run` registry has no separate async/recursion machinery.
- Rendering is on the UI thread. Do not block in widgets or event handlers.

## Status / not implemented

The following namespaces or features do not exist yet:

- sessions, persistence, `bloob.storage`;
- plugins, manifests, trust and lifecycle (`bloob.plugins` is empty);
- agents, subagents, strategies and workflows (`bloob.agent` is empty);
- MCP, LSP, Tree-sitter;
- async Lua tasks or promises;
- model routing use;
- workspace file access from Lua tools;
- visual mode, key chords and user-defined modes;
- rich dialogs, focus APIs and scrollable custom widgets.

See [security.md](security.md) before running configuration from an untrusted
source.
