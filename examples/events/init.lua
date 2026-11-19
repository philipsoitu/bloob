-- Observe and veto/approve-escalate events.
--
-- The app emits only a small set of events today:
--   file.after_write, tool.before_execute, model.before_request, model.usage
-- The mock/fixture provider never emits model.before_request or model.usage.

local bloob = require("bloob")
local events = require("bloob.events")

bloob.setup({ theme = "catppuccin" })

local writes = 0

events.on("file.after_write", function(e)
  writes = writes + 1
  e:notify("wrote " .. tostring(e.path) .. " (observed " .. writes .. ")")
end, { priority = 10 })

events.on("tool.before_execute", function(e)
  local tool = tostring(e.tool or "")
  local arguments = tostring(e.arguments or "")

  if tool == "shell" then
    e:notify("shell request: " .. tostring(e.summary or arguments))
  end

  -- Returning "deny" (or false, or { action = "deny" }) blocks the tool.
  -- Hooks can tighten a decision or escalate "allow" to "ask"; they cannot
  -- turn a Zig policy denial into an allow.
  if tool == "shell" and arguments:find("rm%s+%-rf") then
    e:notify("blocked a recursive forced removal")
    return "deny"
  end

  return nil
end, { priority = 10 })
