# custom-command

Registers two Lua commands and binds them in normal and insert modes.

```sh
bloob --config examples/custom-command/init.lua
```

Invocation paths:

- Type `/greet Alice` in the prompt and press Enter. `ctx.args` is `"Alice"`.
- Open the command palette (Ctrl-P), search for `greet`, and run it. The palette
  invokes commands without arguments.
- Press Ctrl-G in normal or insert mode to run the `greet` mapping. String
  keymap actions pass an empty argument string.
- Press Ctrl-Y in normal mode for a callback that calls
  `bloob.command_run("greet", "from <C-y>")`.
- Press Ctrl-O in normal mode to run the `status-line` callback.

Command context in the current runtime has exactly `args` (a string) and
`notify` (callable as `ctx:notify(message, opts)`). Built-in commands win over
Lua commands with the same name: `runCommand` checks the native command table
before asking the Lua registry.

`ctx:notify(message, { error = true })` marks the notification as an error.

See [../../docs/keymaps.md](../../docs/keymaps.md) and
[../../docs/lua-api.md](../../docs/lua-api.md).
