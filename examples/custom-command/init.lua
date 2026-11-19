-- Register a command and expose it from normal and insert modes.
--
-- Command strings mapped with keymap.set receive no arguments. Call
-- bloob.command_run(name, args) from a callback when arguments are needed.

local bloob = require("bloob")
local keymap = require("bloob.keymap")

bloob.setup({ leader = "\\" })

bloob.command.register("greet", {
  description = "Show a greeting (accepts an optional name argument)",
  run = function(ctx)
    local who = ctx.args ~= "" and ctx.args or "world"
    ctx:notify("Hello, " .. who)
  end,
})

bloob.command.register("status-line", {
  description = "Report the current model and mode from the keymap callback",
  run = function(ctx)
    ctx:notify("args=" .. tostring(ctx.args))
  end,
})

-- A string dispatches an actual bloob command with empty args.
keymap.set("normal", "<C-g>", "greet", { desc = "Run /greet" })
keymap.set("insert", "<C-g>", "greet", { desc = "Run /greet" })

-- A callback can pass arguments or do conditional work.
keymap.set("normal", "<C-y>", function()
  bloob.command_run("greet", "from <C-y>")
end, { desc = "Greet with a custom argument" })

keymap.set("normal", "<C-o>", function()
  bloob.command_run("status-line", "normal mode")
end, { desc = "Show command arguments" })
