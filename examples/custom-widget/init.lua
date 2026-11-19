-- Stateful custom widget: signals plus buttons with on_press callbacks.
--
-- Signals are in-memory Lua values owned by the current Lua state. They are
-- reset when the configuration is reloaded (Ctrl-R).

local bloob = require("bloob")
local ui = require("bloob.ui")

bloob.setup({ theme = "catppuccin" })

local count = ui.signal(0)
local clicks = ui.signal(0)
local last = ui.signal("none")

local function bump(delta)
  count:update(function(value)
    return value + delta
  end)
  clicks:set(clicks:get() + 1)
  last:set(delta > 0 and "increment" or (delta < 0 and "decrement" or "reset"))
end

local function reset()
  count:set(0)
  clicks:set(clicks:get() + 1)
  last:set("reset")
end

ui.register("demo.counter", function(ctx)
  return ui.panel({
    ui.row({
      ui.text("count=" .. tostring(count:get())),
      ui.text("clicks=" .. tostring(clicks:get())),
      ui.text("last=" .. tostring(last:get()), { color = "muted" }),
    }, { gap = 2 }),
    ui.row({
      ui.button("-1", { width = 6, on_press = function() bump(-1) end }),
      ui.button("+1", { width = 6, on_press = function() bump(1) end }),
      ui.button("reset", { width = 8, on_press = reset }),
    }, { gap = 1 }),
    ui.text("Tab to focus a button, Enter to press. Mouse clicks work too.", {
      color = "muted",
    }),
    ui.text("mode=" .. tostring(ctx.mode) .. " state=" .. tostring(ctx.state), {
      color = "muted",
    }),
  }, {
    id = "demo.counter",
    title = "Signal counter",
    border = "rounded",
    padding = 1,
    height = 8,
  })
end)

ui.set_layout(function()
  return ui.column({
    ui.widget("demo.counter"),
    ui.chat({
      id = "conversation",
      flex = 1,
      border = "rounded",
      title = "Conversation",
      padding = 1,
    }),
    ui.input({
      id = "prompt",
      height = 4,
      border = "rounded",
      title = "Prompt",
      padding = 1,
    }),
    ui.statusline({ id = "status" }),
  })
end)
