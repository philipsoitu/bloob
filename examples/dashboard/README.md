# dashboard

A replacement layout with three panes in the top row:

1. the native file/context sidebar,
2. the native conversation view,
3. a custom `dashboard.session` widget that reads the widget context snapshot.

```sh
bloob --config examples/dashboard/init.lua
```

The widget uses only fields implemented in `src/lua/runtime.zig`:
`width`, `height`, `cwd`, `model`, `provider`, `theme`, `mode`, `state`,
`session_id`, `git_branch`, `busy`, `message_count`, `prompt_tokens`,
`completion_tokens`, `total_tokens`, `bloob_version`, `api_version`, `agents`.

Sizing belongs on the panel returned by the widget. Options placed on the
`ui.widget(...)` wrapper are ignored because the wrapper is replaced by the
rendered node before conversion.

`git_branch` is currently always `""` and `agents` is always an empty table, so
the example renders sensible placeholders for them. Widgets are pure functions
of the snapshot; they should not perform I/O.

See [../../docs/ui-components.md](../../docs/ui-components.md) for the node
reference and layout rules.
