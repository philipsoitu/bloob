-- Custom Lua tool.
--
-- The schema is sent to real providers. A model can request this tool by name;
-- ctx:read_file is a permission-checked, bounded workspace read implemented by
-- Zig (sensitive paths/symlinks are denied by the host).
local bloob = require("bloob")
local tools = require("bloob.tools")

local function list_lua_tools()
  local names = {}
  for _, tool in ipairs(tools.list()) do
    names[#names + 1] = tool.name
  end
  return table.concat(names, ", ")
end

tools.register("workspace.count_lines", {
  description = "Count lines in a workspace file after a permission-checked read.",
  schema = {
    type = "object",
    properties = {
      path = { type = "string", description = "Workspace-relative file path" },
    },
    required = { "path" },
  },
  permissions = { "workspace.read" },
  run = function(ctx, args)
    local path = tostring((args and args.path) or "")
    if path == "" then
      return { error = "path is required" }
    end
    local content, err = ctx:read_file(path)
    if not content then
      return { error = tostring(err or "read failed"), path = path }
    end
    local _, newlines = content:gsub("\n", "\n")
    local count = newlines
    if #content > 0 and content:sub(-1) ~= "\n" then count = count + 1 end
    return {
      path = path,
      lines = count,
      bytes = #content,
      cwd = ctx.cwd,
      model = ctx.model,
      api_version = ctx.api_version,
    }
  end,
})

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
