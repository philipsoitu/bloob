# custom-tool

Registers `workspace.snapshot` with `tools.register` and shows its schema in the
provider tool list for real providers.

```sh
bloob --config examples/custom-tool/init.lua
```

Try `/lua-tools` to inspect the Lua registry. To actually invoke the tool, use a
real provider (`--model openai/<model>` or `anthropic/<model>`) and ask the model
to call `workspace.snapshot`. The mock/fixture provider never invokes arbitrary
Lua tools.

What is real today:

- `tools.register(name, spec)` stores `description`, `schema`, `permissions` and
  `run`.
- The schema is serialized to JSON and included in provider requests.
- `run(ctx, args)` is called with a context snapshot and the JSON arguments
  decoded into a Lua table.
- The return value is serialized to JSON and shown as the tool result.
- `tools.get(name)` and `tools.list()` are available to Lua.
- Custom tools go through the approval flow as the `custom` capability.

What is not implemented yet:

- There is no `ctx:read_file` and no `ctx:write_file`. The private
  `bloob._read_file` helper is not a stable, workspace-checked tool API.
- `permissions` metadata is not enforced by the Zig engine yet.
- There is no direct "run tool" slash command, and mock/fixture does not emit
  tool calls for Lua tools.
- If `run` raises an error, the UI reports `Lua tool failed` without a detailed
  traceback.

Return values follow the JSON conversion rules: tables with contiguous numeric
keys become arrays; other tables become objects; `nil`, functions and userdata
are not meaningful. Prefer strings, numbers, booleans and plain tables.

See [../../docs/lua-api.md](../../docs/lua-api.md) and
[../../docs/security.md](../../docs/security.md).
