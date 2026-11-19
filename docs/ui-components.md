# UI components

`bloob.ui` exposes the same declarative primitives used by the bundled default
layout. A layout is a tree of ordinary Lua tables; Zig converts it to native
nodes, lays it out and renders it every dirty frame. Lua does not receive
pointers into the native tree.

```lua
local ui = require("bloob.ui")

ui.set_layout(ui.column({
  ui.row({
    ui.sidebar({ width = 22 }),
    ui.chat({ flex = 1 }),
  }, { flex = 1 }),
  ui.input({ height = 4 }),
  ui.statusline(),
}))
```

## Node constructors

| Constructor | Kind | Notes |
| --- | --- | --- |
| `ui.text(content, opts)` | `text` | `content` is converted to a string; newlines are rendered as multiple lines by the native text renderer |
| `ui.row(children, opts)` | `row` | Horizontal flex container |
| `ui.column(children, opts)` | `column` | Vertical flex container |
| `ui.panel(children, opts)` | `panel` | Container that can draw a border and title |
| `ui.panel(opts)` | `panel` | Empty panel; use the two-argument form when passing children |
| `ui.spacer(size, opts)` | `spacer` | Number sets `height`; a table is used as options, e.g. `{ flex = 1 }` |
| `ui.scroll(children, opts)` | `scroll` | Currently a plain container; no scroll offset/keys |
| `ui.overlay(children, opts)` | `overlay` | Currently laid out and drawn like a container, not composited |
| `ui.tabs(children, opts)` | `tabs` | Currently a plain container; no tab selection |
| `ui.list(items, opts)` | `list` | `items` becomes `lines`; each element is rendered as a row |
| `ui.input(opts)` | `input` | Native prompt editor; default `id = "prompt"` |
| `ui.chat(opts)` | `chat` | Native conversation view; default `id = "conversation"` |
| `ui.sidebar(opts)` | `sidebar` | Native workspace/session sidebar; default `id = "files"` |
| `ui.statusline(opts)` | `statusline` | Native status line; default `id = "status"`, `height = 1` |
| `ui.diff(opts)` | `diff` | Currently rendered by the chat renderer |
| `ui.button(label, opts)` | `button` | Focusable; `on_press = function() ... end` |
| `ui.widget(name, opts)` | `widget` | Expands a widget registered with `ui.register` |

`ui.text` and `ui.button` set `content`; `ui.widget` sets `name`.

**Widget sizing caveat:** the converter replaces the `ui.widget` node with the
node returned by the widget function before reading node options. Put `id`,
`title`, `width`, `height`, `border`, `padding`, style and `visible` on the node
returned from the widget, not on the `ui.widget(...)` wrapper.

## Node options

The converter recognizes these fields on any node where they are meaningful:

| Option | Type | Meaning |
| --- | --- | --- |
| `id` | string | Stable identifier; currently used mostly for built-in nodes |
| `title` | string | Border title for panels and named widgets |
| `content` | string | Text/button label |
| `children` | array of nodes | Child nodes |
| `width`, `height` | number or string | Size; see below |
| `flex` | number | Flex weight within a row/column; defaults to `0` |
| `min_width`, `min_height` | integer | Minimum size in cells |
| `max_width`, `max_height` | integer | Maximum size in cells |
| `padding` | integer | Inner padding in cells |
| `gap` | integer | Gap between children in a row/column |
| `border` | string | `none`, `single`, `line`, `rounded`, `double`, `heavy` |
| `visible` | boolean | `false` skips drawing/layout contribution |
| `focusable` | boolean | Marks a node focusable; buttons/inputs are focusable automatically |
| `style` | string or table | Background/border style for the node |
| `text_style` | string or table | Text style for the node |
| `color` | string | Shorthand for `text_style.fg` |
| `bg` | string | Shorthand for `text_style.bg` |
| `on_press` | function | Button callback |
| `lines` | array of strings | List rows (normally set by `ui.list`) |

Fields such as `align`, `justify`, `on_change`, `on_submit`, `scroll_offset`
or `focus` from the design notes are not converted yet.

### Sizing

`width` and `height` accept:

- a positive integer: fixed cells (`width = 24`);
- a number in `(0, 1)`: percentage of available space (`width = 0.25`);
- `0` or a negative number: `auto`;
- a string ending in `%`: percentage (`width = "25%"`);
- a numeric string: fixed cells (`height = "4"`);
- anything else: `auto`.

Use `flex` for proportional sizing inside a row or column. A typical chat pane
is `{ flex = 1 }`; a fixed sidebar is `{ width = 24 }`.

### Borders

Unknown border names become `none`. Borders consume one cell on each side; use
`padding` and `innerRect`-style layout expectations accordingly. The native
`input`, `chat`, `sidebar`, `panel` and `statusline` renderers have their own
behavior on top of the generic layout.

## Native widgets

Some node kinds are implemented by Zig rather than generic drawing:

- `input` hosts the multiline prompt editor. Its height is the visible editor
  area; borders/padding reduce the inner area. It is always a primary focus
  target.
- `chat` renders the conversation, scroll state and streaming output.
- `sidebar` renders workspace, session, model and stats information.
- `statusline` renders mode, model, agent state, cwd, token usage and the latest
  notification.
- `button` is drawn as a focusable block and activated by Enter (normal mode)
  or a left mouse click.
- `list` draws its `lines`; it has no selection or scrolling API.
- `diff` is currently drawn through the chat renderer, not a real diff widget.

`scroll`, `overlay`, `tabs` and `panel` recurse into their children when drawn.
`scroll`, `overlay` and `tabs` do not add their named behavior yet.

## Focus and input

- The prompt input is moved to the front of the focus list.
- Buttons are collected as focusable items.
- `Tab` / `Shift-Tab` cycles focus; in normal mode `Enter` activates the
  focused button or returns focus to the input.
- Mouse left-clicks activate buttons that occupy the clicked cell.
- Focus styling is applied by the native button renderer.
- There is no Lua API to set focus, query focus, or attach widget-level key
  handlers.

## Widgets

```lua
local ui = require("bloob.ui")

ui.register("my.status", function(ctx)
  return ui.panel({
    ui.text("model: " .. tostring(ctx.model)),
    ui.text("state: " .. tostring(ctx.state)),
  }, {
    title = "Status",
    border = "rounded",
    padding = 1,
    height = 4,
  })
end)

ui.set_layout(ui.column({
  ui.chat({ flex = 1 }),
  ui.widget("my.status"),
  ui.input({ height = 4 }),
  ui.statusline(),
}))
```

- `fn(ctx)` must return a node table.
- The widget is evaluated during layout conversion, not during input handling.
- Exceptions and invalid return values are caught and rendered as error panels.
- An unregistered name renders an "Unknown widget" panel.
- Widgets are looked up by name in the current Lua state, so reload requires
  re-registration.
- `ctx` is a new snapshot table each render. See the field table in
  [lua-api.md](lua-api.md#widget-and-tool-context).

The bundled default registers `bloob.help_hint`, but the default layout does not
currently use it. The helper is a useful reference for the registration path.

### Stateful widgets

```lua
local ui = require("bloob.ui")
local count = ui.signal(0)

ui.register("my.counter", function()
  return ui.row({
    ui.text("count=" .. tostring(count:get())),
    ui.button("+1", {
      on_press = function()
        count:update(function(value) return value + 1 end)
      end,
    }),
  }, { gap = 1 })
end)
```

Signals:

| Method | Meaning |
| --- | --- |
| `signal:get()` | Current value |
| `signal:set(value)` | Set; notifies subscribers and requests a redraw if changed |
| `signal:update(fn)` | Set `fn(current)` |
| `signal:connect(fn)` | Add a subscriber; returns the function |
| `signal:disconnect(fn)` | Remove a subscriber |

Signals are plain Lua state. They do not persist across reload and are not a
general store. Avoid mutating them from inside widget render functions; prefer
button/event callbacks.

## Styling

Colors can be semantic names, ANSI color names, `#rrggbb` hex strings, or
numeric 256-color indexes. Unknown strings fall back to the `fg` semantic color.

Semantic names:

```text
default fg bg primary secondary muted success warning error info
border selection focus tool tool_error diff_added diff_removed diff_hunk
code heading user assistant accent cursor
```

Style tables:

```lua
ui.text("hello", {
  color = "accent",
  bg = "selection",
  bold = true,
  underline = true,
})
```

Or a compact attribute string:

```lua
ui.text("hello", { style = "bold underline" })
```

Recognized style fields: `fg`, `bg`, `bold`, `dim`, `italic`, `underline`,
`reverse`, `strikethrough`, plus the attribute string `style`. The node-level
`color` and `bg` shorthands override `text_style.fg`/`bg`.

Custom themes are registered with a table whose keys are semantic names and
whose values are color strings:

```lua
ui.theme.register("my-theme", {
  fg = "#d8dee9",
  bg = "#1e1e2e",
  primary = "#89b4fa",
  border = "#585b70",
  focus = "#89dceb",
  error = "#f38ba8",
})

ui.theme.set("my-theme")
```

See [configuration.md](configuration.md#themes) for a full palette.

## Examples

- [`examples/dashboard`](../examples/dashboard/) replaces the layout and puts a
  custom session widget beside the chat and sidebar.
- [`examples/custom-widget`](../examples/custom-widget/) uses signals and
  buttons.

## Current limitations

- `scroll`, `overlay`, `tabs` and `diff` are placeholders or plain containers.
- No alignment/justification controls are converted.
- No widget-level keyboard or focus API.
- No async data loading in widgets; do not block in render.
- No markdown/rich content API beyond the native chat renderer.
- No stable widget identity beyond IDs, and IDs are not yet used for lookup.
- Layout conversion limits: depth 64, 4096 nodes.
- Rendering is full-frame on dirty state (no dirty-region diffing).
