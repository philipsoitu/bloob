-- Custom Lua tool.
--
-- The tool schema is sent to real providers. A model can only request this
-- tool by name; the offline mock/fixture provider does not call arbitrary Lua
-- tools. The current runtime does not expose a permission-checked
-- `ctx:read_file`, so this example uses only real context fields and arguments.

local bloob = require("bloob")
local tools = require("bloob.tools")

local function list_lua_tools()
  local names = {}
  for _, tool in ipairs(tools.list()) do
    names[#names + 1] = tool.name
  end
  return table.concat(names, ", ")
end

tools.register("workspace.snapshot", {
  description = "Return a small snapshot of the current bloob session context.",
  schema = {
    type = "object",
    properties = {
      label = {
        type = "string",
        description = "Optional label to include in the result",
      },
    },
  },
  -- Stored as tool metadata today. The Zig permission engine treats custom
  -- Lua tools as the `custom` capability (ask by default); this list is not
  -- used for enforcement yet.
  permissions = { "workspace.read" },
  run = function(ctx, args)
    local label = tostring((args and args.label) or "snapshot")
    return {
      tool = "workspace.snapshot",
      label = label,
      cwd = ctx.cwd,
      model = ctx.model,
      provider = ctx.provider,
      mode = ctx.mode,
      state = ctx.state,
      busy = ctx.busy and true or false,
      messages = ctx.message_count,
      prompt_tokens = ctx.prompt_tokens,
      completion_tokens = ctx.completion_tokens,
      total_tokens = ctx.total_tokens,
      api_version = ctx.api_version,
      note = "Lua tools have no workspace file API in this build",
    }
  end,
})

-- A convenience command so the registration can be inspected without asking a
-- model to call the tool.
bloob.command.register("lua-tools", {
  description = "List Lua tools registered by the custom-tool example",
  run = function(ctx)
    local names = list_lua_tools()
    if names == "" then
      ctx:notify("No Lua tools registered")
    else
      ctx:notify("Lua tools: " .. names)
    end
  end,
})
