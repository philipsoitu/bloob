# custom-widget

A stateful widget using `ui.signal` and `ui.button`:

- `count`, `clicks` and `last` are signals.
- Each button's `on_press` mutates the signals.
- `Signal:set`/`Signal:update` schedules a redraw through the host.
- Buttons are focusable. Use Tab/Shift-Tab to move focus; in normal mode Enter
  activates the focused button. The mouse also works.

```sh
bloob --config examples/custom-widget/init.lua
```

Limits worth knowing:

- Signal state is not persisted and is recreated on config reload.
- Signals are plain Lua values with callback lists; there is no cross-thread
  synchronization. Configuration runs on the UI thread.
- Sizing is set on the panel returned by the widget; options on the
  `ui.widget(...)` wrapper are ignored by the current converter.
- `on_press` callbacks are recreated from the widget render each frame; nothing
  in the callback is retained except through the Lua closure itself.
- The bundled `bloob.help_hint` widget is still registered but unused by this
  layout.

See [../../docs/ui-components.md](../../docs/ui-components.md).
