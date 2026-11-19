-- bloob.events — typed hooks with priorities and protected dispatch.
local events = require("bloob.events")
local bloob = require("bloob")
local M = events

local handlers = {}
local next_id = 1

local Facade = {}
Facade.__index = function(self, key)
  local payload = rawget(self, "_payload")
  if payload and payload[key] ~= nil then return payload[key] end
  return Facade[key]
end

function Facade:notify(msg, opts)
  bloob.notify(msg, opts)
end

function Facade:get(key)
  local payload = rawget(self, "_payload")
  return payload and payload[key] or nil
end

function M.on(name, fn, opts)
  if type(name) ~= "string" then error("events.on: event name must be a string", 2) end
  if type(fn) ~= "function" then error("events.on: handler must be a function", 2) end
  opts = opts or {}
  local id = next_id
  next_id = next_id + 1
  handlers[name] = handlers[name] or {}
  table.insert(handlers[name], {
    id = id,
    fn = fn,
    priority = tonumber(opts.priority) or 50,
    once = opts.once == true,
  })
  table.sort(handlers[name], function(a, b) return a.priority < b.priority end)
  return { name = name, id = id, off = function() M.off({ name = name, id = id }) end }
end

function M.once(name, fn, opts)
  opts = opts or {}
  opts.once = true
  return M.on(name, fn, opts)
end

function M.off(handle)
  if type(handle) ~= "table" then return false end
  local list = handlers[handle.name]
  if not list then return false end
  for i = #list, 1, -1 do
    if list[i].id == handle.id then
      table.remove(list, i)
      return true
    end
  end
  return false
end

function M.reset(name)
  if name then handlers[name] = nil else handlers = {} end
end

function M.count(name)
  return handlers[name] and #handlers[name] or 0
end

function M._dispatch(name, payload)
  local list = handlers[name]
  if not list then return nil end
  local facade = setmetatable({ _payload = payload or {} }, Facade)
  local decision = nil
  for _, h in ipairs(list) do
    local ok, result = xpcall(function() return h.fn(facade) end, debug.traceback)
    if not ok then
      bloob.notify("event " .. name .. " handler failed: " .. tostring(result), { error = true })
    else
      if h.once then M.off({ name = name, id = h.id }) end
      if result ~= nil then
        decision = result
        if result == false or result == "deny" then
          return { action = "deny" }
        elseif result == "ask" then
          decision = { action = "ask" }
        elseif type(result) == "table" and result.action then
          return result
        end
      end
    end
  end
  return decision
end

function M.emit(name, payload)
  return M._dispatch(name, payload)
end

return M
