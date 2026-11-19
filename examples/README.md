# bloob examples

Each directory is a standalone `init.lua` that can be passed with `--config`.
None of them require changes to the repository.

| Example | Shows |
| --- | --- |
| [minimal](minimal/) | `bloob.setup` with a theme and model |
| [dashboard](dashboard/) | full replacement layout with sidebar, chat and a custom widget that reads `ctx` |
| [custom-widget](custom-widget/) | `ui.signal` plus buttons with `on_press` callbacks |
| [custom-tool](custom-tool/) | `tools.register` with a JSON-like schema and a `run(ctx, args)` function |
| [custom-command](custom-command/) | `bloob.command.register` and keymap bindings |
| [vim-mode](vim-mode/) | normal/insert keymaps that dispatch real commands |
| [events](events/) | `file.after_write` and `tool.before_execute` hooks with `e:notify` |

```sh
nix develop
zig build
./zig-out/bin/bloob --config examples/dashboard/init.lua
```

## Verification

Every file is valid LuaJIT 2.1 syntax:

```sh
for f in examples/*/init.lua; do luajit -bl "$f" /dev/null || exit 1; done
```

`verify.lua` is a stub harness. It loads the real bundled Lua modules from
`src/runtime/lua/bloob/`, replaces only the C-backed underscore functions with
Lua stubs, loads each example, evaluates its layout, checks widget names and
exercises the important callbacks:

```sh
luajit examples/verify.lua
```

This is not a full application test: it does not render the TUI, validate key
specs with the Zig parser, execute native tools, or test provider streaming.

See [../docs/getting-started.md](../docs/getting-started.md).
