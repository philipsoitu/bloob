-- Install by copying this directory to:
--   $XDG_CONFIG_HOME/bloob/plugins/hello/
local bloob = require("bloob")
local ui = require("bloob.ui")
local keymap = require("bloob.keymap")

ui.register("hello.badge", function(ctx)
  return ui.text("plugin hello · " .. (ctx.model or ""), { color = "accent" })
end)

bloob.command.register("hello.plugin", {
  description = "Say hello from the example plugin",
  run = function(ctx)
    ctx:notify("Hello from the bloob plugin system")
  end,
})

keymap.set("normal", "<C-h>", "hello.plugin", { desc = "hello plugin" })
