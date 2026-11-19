-- bloob.keymap — modes, mappings and descriptions.
local km = require("bloob.keymap")
local M = km
local mappings = {}

function M.set(mode, lhs, rhs, opts)
  if type(mode) ~= "string" then error("keymap.set: mode must be a string", 2) end
  if type(lhs) ~= "string" then error("keymap.set: lhs must be a string", 2) end
  opts = opts or {}
  if type(rhs) == "function" then
    M._set_fn(mode, lhs, rhs, opts.desc or "")
  elseif type(rhs) == "string" then
    M._set_cmd(mode, lhs, rhs, opts.desc or "")
  else
    error("keymap.set: rhs must be a command string or function", 2)
  end
  mappings[#mappings + 1] = {
    mode = mode,
    lhs = lhs,
    rhs = rhs,
    desc = opts.desc or "",
  }
end

function M.del(mode, lhs)
  M._del(mode, lhs)
  for i = #mappings, 1, -1 do
    local m = mappings[i]
    if m.mode == mode and m.lhs == lhs then table.remove(mappings, i) end
  end
end

function M.del_all()
  for i = #mappings, 1, -1 do
    local m = mappings[i]
    M._del(m.mode, m.lhs)
    table.remove(mappings, i)
  end
end

function M.list()
  local out = {}
  for i, m in ipairs(mappings) do out[i] = m end
  return out
end

function M.leader(value)
  return M._leader(value)
end

return M
