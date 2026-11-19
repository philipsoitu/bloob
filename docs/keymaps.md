# Keymaps

`bloob.keymap` registers mode-specific key bindings. The current implementation
is deliberately small: single keys and modifier combinations work, while
multi-key chords do not.

```lua
local bloob = require("bloob")
local keymap = require("bloob.keymap")

bloob.setup({ leader = "\\" })

keymap.set("normal", "<C-g>", "help", { desc = "Open help" })
keymap.set("normal", "<C-y>", function()
  bloob.command_run("greet", "from a keymap")
end, { desc = "Greet with arguments" })
keymap.set("insert", "<C-t>", function()
  bloob.command_run("theme", "catppuccin")
end, { desc = "Switch theme" })
```

## API

```lua
keymap.set(mode, lhs, rhs, opts)
keymap.del(mode, lhs)
keymap.del_all()
keymap.list()
keymap.leader(value)
```

- `mode`: `"insert"`, `"normal"` or `"global"`. The app currently only has
  insert and normal modes; `"global"` is a fallback that matches both. Other
  mode strings are accepted but never match.
- `lhs`: a key spec string. Invalid specs raise `invalid key spec` at config load.
- `rhs`: command-name string or function.
- `opts.desc`: description string. No other options are read.
- Setting the same `mode` + `lhs` again replaces the existing mapping.
- `keymap.list()` returns Lua registrations as `{ mode, lhs, rhs, desc }`
  entries. It does not include built-in app keys.

### Command strings vs callbacks

A string is dispatched as an application command with **empty arguments**:

```lua
keymap.set("normal", "<C-g>", "help", { desc = "Help" })
keymap.set("normal", "Q", "quit", { desc = "Quit" })
```

Use a callback when arguments are needed:

```lua
keymap.set("normal", "<C-t>", function()
  bloob.command_run("theme", "catppuccin")
end, { desc = "Catppuccin theme" })
```

The callback is stored as a Lua registry reference and runs on the UI thread. It
returns nothing and has no access to the key event. Callback errors are reported
as notifications.

Command strings can target native commands (`help`, `model`, `providers`,
`session`, `context`, `files`, `diff`, `tools`, `theme`, `reload`, `keymaps`,
`doctor`, `clear`, `new`, `quit`, `export`) or Lua commands. Native commands win
on name collisions.

## Key-spec syntax

Supported forms:

| Form | Example | Notes |
| --- | --- | --- |
| Single byte character | `a`, `Q`, `:`, `/` | One-byte UTF-8 only as a bare spec |
| Modified character | `<C-x>`, `<A-x>`, `<M-x>`, `<S-x>` | `A`/`M` both mean Alt |
| Combined modifiers | `<C-A-x>`, `<C-S-x>` | Modifier parts are single letters |
| Named key | `<up>`, `<down>`, `<left>`, `<right>` | Case-sensitive enum name |
| Named key + modifier | `<C-up>`, `<A-enter>` | See aliases below |
| Function key | `<f1>` ... `<f12>` | |
| Leader | `<leader>x` | See the limitation below |

Supported named tokens (case-sensitive where noted):

```text
char enter esc tab backspace delete insert up down left right home end
page_up page_down f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
```

Aliases:

```text
cr, return -> enter
bs         -> backspace
del        -> delete
ins        -> insert
pgup       -> page_up
pgdn       -> page_down
space      -> char " "
esc        -> esc
```

Important parser details:

- Enum names are lowercase. `<C-Enter>` is **invalid**; use `<C-cr>` or
  `<C-return>`.
- The shift modifier is set for CSI sequences that report it, but the terminal
  parser does not mark ordinary uppercase letters as shifted. Prefer `Q` over
  `<S-q>` for an uppercase binding.
- Bare specs must be one byte. Use the `<...>` form for non-ASCII keys.
- `<leader>` currently parses to the **bare leader key**, not a two-key
  sequence. `<leader>a` and `<leader>b` therefore collide on the leader key, and
  only the first reachable mapping wins. This is a known limitation.
- Multi-key chords (`gg`, `dd`, `<leader>a` as a sequence, timeouts) are not
  implemented. `parseSpec` rejects a spec with trailing text after a `<...>`
  token.

## Dispatch order

The app processes input in this order:

1. Approval modal, command palette and help overlay consume keys first.
2. Global hard-coded keys are handled next:
   - `Ctrl-Q` quit, `Ctrl-P` palette, `Ctrl-R` reload, `Ctrl-S` submit;
   - `Ctrl-C` cancel/clear/quit behavior;
   - `Ctrl-A`, `Ctrl-E`, `Ctrl-U`, `Ctrl-K`, `Ctrl-W`, `Ctrl-J`, `Ctrl-L`,
     `Ctrl-N` editing/navigation shortcuts;
   - `F1`, `PageUp`, `PageDown`;
   - `Esc` toggles insert/normal mode.
3. In normal mode, Lua keymaps are checked, then built-in normal-mode keys.
4. In insert mode, Lua keymaps are checked, then the editor receives the key.

Consequences:

- Lua keymaps cannot override the hard-coded global keys listed above.
- In normal mode, a Lua mapping can shadow a built-in normal key such as `q`,
  `n`, `i`, `g`, `G`, `j` or `k`. This example does not shadow `i` because Lua
  cannot switch the editor mode directly.
- In insert mode, a plain-character mapping would intercept typing before the
  editor. Bind modified keys such as `<C-t>` unless that is really intended.
- `"global"` mappings are found in both modes, but only after global hard-coded
  keys.

## Built-in keys

| Key | Action |
| --- | --- |
| `Enter` / `Ctrl-S` | send the prompt in insert mode |
| `Alt-Enter` / `Ctrl-J` | insert a newline |
| `Ctrl-P` | command palette |
| `Ctrl-R` | reload Lua configuration |
| `Ctrl-Q` | quit |
| `Ctrl-C` | cancel request / clear prompt; press twice quickly to quit |
| `Ctrl-A` / `Ctrl-E` | line start / end |
| `Ctrl-U` / `Ctrl-K` | delete to line start / end |
| `Ctrl-W` | delete previous word |
| `Ctrl-L` | jump to latest conversation output |
| `Ctrl-N` | new conversation |
| `F1` | help overlay |
| `PageUp` / `PageDown` | scroll conversation |
| `Esc` | toggle insert/normal mode |
| `Tab` / `Enter` | cycle focus / activate focused button in normal mode |

Default Vim-like normal keys: `i`, `:`, `/`, `g`, `G`, `j`, `k`, `n`, `q`.

## Conflicts and removal

```lua
keymap.del("normal", "<C-g>")
keymap.del_all()
```

- `del` removes the Lua mapping with the same literal `mode` and `lhs`.
- Different spellings that parse to the same key (for example `<C-p>` and
  `<c-p>`) are stored independently; the first matching registry entry wins.
  Avoid aliases for the same binding.
- There is no conflict diagnostic yet. `/keymaps` opens the general help overlay;
  it does not list Lua keymaps. Use `keymap.list()` from Lua for inspection.

## Full example

```lua
local bloob = require("bloob")
local keymap = require("bloob.keymap")

bloob.setup({ theme = "catppuccin", leader = "\\" })

keymap.set("normal", "<C-g>", "help", { desc = "Help" })
keymap.set("normal", "Q", "quit", { desc = "Quit" })
keymap.set("normal", "<C-f>", "files", { desc = "Toggle sidebar" })
keymap.set("normal", "<C-y>", "clear", { desc = "Clear conversation" })
keymap.set("normal", "<C-t>", function()
  bloob.command_run("theme", "catppuccin")
end, { desc = "Catppuccin theme" })

keymap.set("insert", "<C-g>", "help", { desc = "Help" })
keymap.set("insert", "<C-y>", "clear", { desc = "Clear conversation" })
```

Runnable copies are in [`examples/custom-command`](../examples/custom-command/)
and [`examples/vim-mode`](../examples/vim-mode/).
