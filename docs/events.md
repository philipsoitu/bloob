# Events

`bloob.events` is a small, synchronous hook system. Hooks are useful for
observing tool/file events and for tightening policy decisions. They cannot
grant capabilities the Zig policy denied.

```lua
local bloob = require("bloob")
local events = require("bloob.events")

events.on("file.after_write", function(e)
  e:notify("wrote " .. tostring(e.path))
end)

events.on("tool.before_execute", function(e)
  if e.tool == "shell" then
    e:notify("shell: " .. tostring(e.summary))
  end
  return nil
end)
```

## API

```lua
local events = require("bloob.events")

events.on(name, fn, opts)      -- returns a handle
events.once(name, fn, opts)    -- one successful invocation, then removed
events.off(handle)             -- true if a handler was removed
events.reset(name)             -- remove all handlers for one event
events.reset()                 -- remove all handlers
events.count(name)             -- number of handlers
events.emit(name, payload)     -- manual dispatch
```

`opts` supports:

| Field | Default | Meaning |
| --- | --- | --- |
| `priority` | `50` | Lower numbers run first |
| `once` | `false` | Remove after one successful call |

`on` returns:

```lua
{
  name = "file.after_write",
  id = 1,
  off = function() ... end,
}
```

The app's Lua state is rebuilt on a successful config reload, so all handlers
must be registered again by the config.

## Event facade

Handlers receive a facade `e`:

- payload fields are available directly: `e.path`, `e.tool`, `e.model`, ...;
- `e:get("path")` is an alternative accessor;
- `e:notify(message, opts)` forwards to `ui.notify` and accepts
  `{ error = true }`.

Missing payload fields return `nil`. The facade is read-only in practice; do not
try to mutate engine state through it.

## Events emitted today

| Event | Payload | When |
| --- | --- | --- |
| `tool.before_execute` | `tool` (string), `arguments` (JSON string), `summary` (string) | Before each pending native or Lua tool call, after the Zig permission engine makes its initial decision and before approval/execution |
| `file.after_write` | `path` (string) | After a native `write_file` or `edit_file` changes a file |
| `model.before_request` | `model` (string) | Before an interactive real-provider request; not emitted for `mock/fixture` |
| `model.usage` | `prompt_tokens` (integer), `completion_tokens` (integer), `reported` (boolean) | After a successful interactive provider response that has no tool calls |

Notes:

- `tool.before_execute` is also emitted for Lua-registered tools. Its summary
  comes from the native preview path and may be generic or an error string for
  Lua tools.
- `file.after_write` is **not** emitted for Lua tools; only native tool results
  report a changed path.
- `model.before_request` and `model.usage` are not emitted in `--print` mode,
  which does not create the Lua runtime, nor by the mock/fixture provider.
- Event names are not validated. Registering `tool.after_execute`, `app.start`,
  `agent.before_turn`, etc. is allowed but they never fire in this build unless
  something calls `events.emit` manually.

Not emitted yet (design-note names): `app.start`, `app.quit`,
`config.loaded`, `config.reload`, `theme.changed`, `session.*`,
`agent.*`, `model.after_response`, `tool.after_execute`, `tool.error`,
`file.before_write`, `ui.focus_changed`, `ui.resize`, `ui.notification`.

## Return values and policy

For `tool.before_execute`, the dispatcher interprets handler return values:

| Return | Effect |
| --- | --- |
| `nil` | Pass; keep the existing decision |
| `false` or `"deny"` | Deny immediately |
| `"ask"` | Escalate an `allow` to `ask`; keep scanning |
| `{ action = "deny" }` | Deny immediately |
| `{ action = "ask" }` | Escalate/keep `ask` |
| anything else | Ignored |

The Zig permission engine runs first. A Lua hook can deny or force approval, but
cannot turn a Zig denial into an allow, and cannot bypass the approval modal for
a decision that requires one. A handler returning a value that looks like
`{ action = "allow" }` has no effect.

For observe-only events such as `file.after_write`, return values are ignored.

## Manual dispatch

`events.emit(name, payload)` dispatches the same path and returns a decision
table or `nil`:

```lua
local decision = events.emit("tool.before_execute", {
  tool = "shell",
  arguments = '{"command":"rm -rf build"}',
  summary = "Run shell command",
})

if decision and decision.action == "deny" then
  -- blocked by a handler
end
```

This is also how the stub harness exercises examples without an agent loop.

## Error handling

Each handler is called with a traceback-protected call. If it raises an error:

- the error is reported as an error notification;
- the remaining handlers continue to run;
- the failing `once` handler is not removed (only successful calls trigger
  removal);
- the application does not crash.

Exceptions are still not a control-flow mechanism. Return `nil`, `"deny"` or
`"ask"` explicitly.

## Examples

- [`examples/events`](../examples/events/) observes file writes, reports shell
  requests, and denies a recursive forced removal.
- See [security.md](security.md) for the policy boundary and known gaps.

More event names will be added as the agent and tool loops grow. Payload shapes
may change while `api_version` remains `1`; treat this document as the current
contract.
