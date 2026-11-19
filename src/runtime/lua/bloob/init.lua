-- bloob — top-level Lua API.
local bloob = require("bloob")
local ui = require("bloob.ui")
local keymap = require("bloob.keymap")
local events = require("bloob.events")
local tools = require("bloob.tools")
local models = require("bloob.models")
local config = require("bloob.config")

local M = bloob

M.api_version = 1
M.version = "0.1.0"
M.features = {
  lua_ui = true,
  signals = true,
  custom_widgets = true,
  custom_commands = true,
  custom_tools = true,
  keymaps = true,
  events = true,
  hot_reload = true,
  plugins = true,
  mcp = false,
  lsp = false,
}

function M.setup(opts)
  if opts == nil then return end
  if type(opts) ~= "table" then error("bloob.setup expects a table", 2) end
  M._setup(opts)
  if opts.theme then ui.theme_set(opts.theme) end
  if opts.model then M._set_model(opts.model) end
  if opts.leader then keymap._leader(opts.leader) end
end

function M.notify(msg, opts)
  ui.notify(msg, opts)
end

function M.quit()
  M._quit()
end

function M.log(msg)
  M._log(tostring(msg))
end

function M.command_run(name, args)
  return M._run_command(name, args or "")
end

M.command = M.command or {}
M.command.registry = {}

function M.command.register(name, spec)
  if type(name) ~= "string" or name == "" then
    error("command.register(name, spec): name must be a non-empty string", 2)
  end
  if type(spec) ~= "table" or type(spec.run) ~= "function" then
    error("command.register: spec.run must be a function", 2)
  end
  M.command.registry[name] = spec
  M._register_command(name, spec.description or "")
end

function M.command.run(name, args)
  local spec = M.command.registry[name]
  if not spec then return false, "unknown command" end
  local ctx = {
    args = args or "",
    notify = function(_, msg, opts) ui.notify(msg, opts) end,
  }
  local ok, err = xpcall(function() return spec.run(ctx) end, debug.traceback)
  if not ok then
    ui.notify("command " .. name .. " failed: " .. tostring(err), { error = true })
    return false, tostring(err)
  end
  return true
end

function M._run_command(name, args, ctx)
  local ok, err = M.command.run(name, args)
  if not ok then return false, err or "failed" end
  return true
end

M.ui = ui
M.keymap = keymap
M.events = events
M.tools = tools
M.models = models
M.config = config

return M
