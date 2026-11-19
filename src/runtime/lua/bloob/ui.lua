-- bloob.ui — declarative UI primitives, widget registry, signals and themes.
local ui = require("bloob.ui")

local M = ui

local function clone(t)
  local out = {}
  if type(t) == "table" then
    for k, v in pairs(t) do out[k] = v end
  end
  return out
end

local function node(kind, opts)
  local n = clone(opts)
  n.__bloob = kind
  return n
end

local function is_children_table(t)
  if type(t) ~= "table" then return false end
  if t.__bloob or t.children or t.title or t.border or t.id or t.flex or t.width or t.height then
    return false
  end
  return #t > 0
end

function M.text(content, opts)
  local n = node("text", opts)
  n.content = tostring(content or "")
  return n
end

function M.column(children, opts)
  local n = node("column", opts)
  if children == nil then
    n.children = {}
  elseif is_children_table(children) then
    n.children = children
  else
    n = node("column", children)
    n.children = {}
  end
  return n
end

function M.row(children, opts)
  local n = node("row", opts)
  if children == nil then
    n.children = {}
  elseif is_children_table(children) then
    n.children = children
  else
    n = node("row", children)
    n.children = {}
  end
  return n
end

function M.panel(a, b)
  local children, opts
  if b ~= nil then
    children, opts = a, b
  elseif is_children_table(a) then
    children, opts = a, nil
  else
    children, opts = nil, a
  end
  local n = node("panel", opts)
  n.children = children or n.children or {}
  return n
end

function M.spacer(size, opts)
  local n = node("spacer", opts)
  if type(size) == "table" then
    n = node("spacer", size)
  elseif type(size) == "number" then
    n.height = size
  end
  return n
end

function M.scroll(children, opts)
  local n = node("scroll", opts)
  n.children = children or {}
  return n
end

function M.overlay(children, opts)
  local n = node("overlay", opts)
  n.children = children or {}
  return n
end

function M.tabs(children, opts)
  local n = node("tabs", opts)
  n.children = children or {}
  return n
end

function M.list(items, opts)
  local n = node("list", opts)
  n.lines = items or {}
  return n
end

function M.input(opts)
  local n = node("input", opts)
  n.id = n.id or "prompt"
  return n
end

function M.chat(opts)
  local n = node("chat", opts)
  n.id = n.id or "conversation"
  return n
end

function M.sidebar(opts)
  local n = node("sidebar", opts)
  n.id = n.id or "files"
  return n
end

function M.statusline(opts)
  local n = node("statusline", opts)
  n.id = n.id or "status"
  n.height = n.height or 1
  return n
end

function M.diff(opts)
  return node("diff", opts)
end

function M.button(label, opts)
  local n = node("button", opts)
  n.content = tostring(label or "")
  n.focusable = true
  return n
end

function M.widget(name, opts)
  local n = node("widget", opts)
  n.name = name
  return n
end

local widgets = {}
local signals_enabled = true
local signal_depth = 0

function M.register(name, fn)
  if type(name) ~= "string" or type(fn) ~= "function" then
    error("ui.register(name, function) requires a string and a function", 2)
  end
  widgets[name] = fn
end

function M.get_widget(name)
  return widgets[name]
end

function M._render_widget(name, ctx)
  local fn = widgets[name]
  if not fn then
    return M.panel({
      border = "rounded",
      title = tostring(name),
      children = { M.text("Unknown widget: " .. tostring(name), { color = "error" }) },
    })
  end
  local ok, result = xpcall(function() return fn(ctx) end, debug.traceback)
  if not ok then
    return M.panel({
      border = "rounded",
      title = tostring(name) .. " (error)",
      children = {
        M.text(tostring(result), { color = "error" }),
      },
    })
  end
  if type(result) ~= "table" then
    return M.panel({
      border = "rounded",
      title = tostring(name) .. " (invalid)",
      children = { M.text("widget must return a UI node table, got " .. type(result), { color = "error" }) },
    })
  end
  return result
end

function M.set_layout(layout)
  M._set_layout(layout)
end

function M.theme_register(name, palette)
  M._theme_register(name, palette)
end

function M.theme_set(name)
  M._theme_set(name)
end

M.theme = {
  register = M.theme_register,
  set = M.theme_set,
}

function M.notify(msg, opts)
  opts = opts or {}
  M._notify(tostring(msg), opts.error == true or opts.level == "error")
end

function M.request_render()
  M._request_render()
end

function M.command(name, args)
  M._command(name, args or "")
end

function M.quit()
  M._quit()
end

-- Reactive values. Signal updates schedule a redraw; render callbacks are never
-- invoked synchronously from inside a set, preventing render/set feedback loops.
local Signal = {}
Signal.__index = Signal

function Signal:get()
  return rawget(self, "_value")
end

function Signal:set(value)
  if rawget(self, "_value") == value then return value end
  rawset(self, "_value", value)
  local subs = rawget(self, "_subs")
  for fn in pairs(subs) do
    local ok, err = pcall(fn, value)
    if not ok then
      M.notify("signal callback failed: " .. tostring(err), { error = true })
    end
  end
  M._request_render()
  return value
end

function Signal:update(fn)
  return self:set(fn(self:get()))
end

function Signal:connect(fn)
  rawget(self, "_subs")[fn] = true
  return fn
end

function Signal:disconnect(fn)
  rawget(self, "_subs")[fn] = nil
end

function M.signal(initial)
  return setmetatable({ _value = initial, _subs = {} }, Signal)
end

function M.signal_depth()
  return signal_depth
end

return M
