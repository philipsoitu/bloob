# vim-mode

Adds Vim-flavoured command bindings without replacing the editor's built-in
mode handling.

```sh
bloob --config examples/vim-mode/init.lua
```

Built-in Vim-ish keys in the current app:

| Mode | Key | Action |
| --- | --- | --- |
| insert | `Esc` | switch to normal mode |
| normal | `i` | switch to insert mode |
| normal | `:` or `/` | open the command palette |
| normal | `j` / `k` | scroll the conversation |
| normal | `g` / `G` | jump to oldest / newest |
| normal | `n` | new conversation |
| normal | `q` | quit |
| normal | `Tab` / `Enter` | cycle focus / activate focused button |

This example adds:

| Mode | Key | Action |
| --- | --- | --- |
| normal | `Ctrl-G` | `help` command |
| normal | `Q` | `quit` command |
| normal | `Ctrl-F` | `files` command |
| normal | `Ctrl-Y` | `clear` command |
| normal | `Ctrl-T` | callback: `theme catppuccin` |
| insert | `Ctrl-G` | `help` command |
| insert | `Ctrl-Y` | `clear` command |
| insert | `Ctrl-T` | callback: `theme light` |

Important limits:

- Lua cannot change insert/normal mode, so `i` and `Esc` remain built-ins.
- Key chords are not implemented. `<leader>x` currently parses to the bare
  leader key, not a two-key sequence.
- Global keys (`Ctrl-C`, `Ctrl-P`, `Ctrl-Q`, `Ctrl-R`, `Ctrl-S`, `Ctrl-U`, ...)
  are processed before Lua keymaps and cannot be overridden.
- String command actions receive no arguments; use a callback with
  `bloob.command_run(name, args)` when arguments are needed.

See [../../docs/keymaps.md](../../docs/keymaps.md).
