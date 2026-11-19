# events

Subscribes to `file.after_write` and `tool.before_execute`, using `e:notify` to
surface messages from inside a hook.

```sh
bloob --config examples/events/init.lua
```

What actually fires in this build:

| Event | Payload | Emitted when |
| --- | --- | --- |
| `tool.before_execute` | `tool`, `arguments` (JSON string), `summary` | before each pending native or Lua tool call, after the Zig permission engine evaluates it |
| `file.after_write` | `path` | after a native `write_file` or `edit_file` changes a file |
| `model.before_request` | `model` | before a real provider request (not mock/fixture) |
| `model.usage` | `prompt_tokens`, `completion_tokens`, `reported` | after a successful real provider response that has no tool calls |

`tool.after_execute`, `file.before_write`, `app.start`, `agent.*` and most other
names in the design notes are not emitted yet. Registering a handler for an
unknown name is allowed; it simply never runs.

Handler semantics:

- Priorities sort ascending (lower runs first). Default is 50.
- `once = true` removes the handler after its first successful call.
- `events.off(handle)`, `events.reset(name)`, `events.reset()`, and
  `events.count(name)` manage subscriptions.
- A handler error is caught and shown as an error notification; it does not
  crash the app.
- Returning `false` or `"deny"` blocks the tool immediately.
- Returning `"ask"` forces the approval modal if the Zig decision was `allow`.
- Returning `{ action = "deny" }` or `{ action = "ask" }` has the same effect.
- Returning anything else is ignored. Hooks cannot grant an allowance.

`e` is a facade: payload fields are read directly (`e.path`, `e.tool`, ...),
`e:get("path")` also works, and `e:notify(message, opts)` forwards to the UI.

See [../../docs/events.md](../../docs/events.md) and
[../../docs/security.md](../../docs/security.md).
