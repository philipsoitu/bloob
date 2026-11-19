-- PTY harness fixture: a custom declarative layout with a registered widget.
--
-- The screenshot assertions look for HARNESS-WIDGET-OK, Harness Chat and
-- Harness Input. The widget also receives the terminal size from the Zig host,
-- which lets the harness prove that the PTY was configured to 100x30.
local ui = require("bloob.ui")

ui.register("harness.badge", function(ctx)
  return ui.row({
    ui.text("HARNESS-WIDGET-OK", { color = "primary" }),
    ui.text(tostring(ctx.width) .. "x" .. tostring(ctx.height), { color = "muted" }),
  }, { height = 1, gap = 1 })
end)

ui.set_layout(function(_ctx)
  return ui.column({
    ui.widget("harness.badge", { height = 1 }),
    ui.chat({
      id = "conversation",
      flex = 1,
      border = "rounded",
      title = "Harness Chat",
      padding = 1,
    }),
    ui.input({
      id = "prompt",
      height = 5,
      border = "rounded",
      title = "Harness Input",
      padding = 1,
    }),
    ui.statusline({ id = "status" }),
  })
end)
