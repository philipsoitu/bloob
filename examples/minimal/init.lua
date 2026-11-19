-- Minimal bloob configuration.
--
-- Use it directly:
--   bloob --config /path/to/examples/minimal/init.lua
-- or copy it to $XDG_CONFIG_HOME/bloob/init.lua.
--
-- Only `theme`, `model` and `leader` are applied by bloob.setup in the current
-- implementation. Other keys are accepted but have no effect yet.

local bloob = require("bloob")

bloob.setup({
  theme = "catppuccin",
  model = "mock/fixture",
  leader = "\\",
})

bloob.notify("minimal example loaded")
