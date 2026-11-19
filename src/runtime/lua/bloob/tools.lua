-- bloob.tools — custom Lua tools.
local tools = require("bloob.tools")
local M = tools
local registry = {}

function M.register(name, spec)
  if type(name) ~= "string" or name == "" then
    error("tools.register(name, spec): invalid name", 2)
  end
  if type(spec) ~= "table" or type(spec.run) ~= "function" then
    error("tools.register: spec.run must be a function", 2)
  end
  local entry = {
    name = name,
    description = spec.description or "",
    schema = spec.schema or { type = "object", properties = {} },
    permissions = spec.permissions or {},
    run = spec.run,
  }
  registry[name] = entry
  M._register(entry)
end

function M.get(name)
  return registry[name]
end

function M.list()
  local out = {}
  for name, entry in pairs(registry) do
    out[#out + 1] = {
      name = name,
      description = entry.description,
      schema = entry.schema,
      permissions = entry.permissions,
    }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function M._invoke(name, args, ctx)
  local entry = registry[name]
  if not entry then return nil, "unknown Lua tool" end
  local ok, result = xpcall(function() return entry.run(ctx, args) end, debug.traceback)
  if not ok then return nil, tostring(result) end
  return result
end

return M
