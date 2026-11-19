#!/usr/bin/env luajit
-- Stub harness for the example configurations.
--
-- It loads the real bundled Lua modules from src/runtime/lua/bloob/*.lua and
-- replaces only the C-backed underscore functions with small Lua stubs. That
-- catches syntax errors, invalid module calls, bad widget names, layout errors
-- and broken on_press callbacks without starting the TUI.
--
-- Run from the repository root:
--   luajit examples/verify.lua
-- or:
--   nix develop -c luajit examples/verify.lua

local script_path = (arg and arg[0]) or "examples/verify.lua"
local script_dir = script_path:match("^(.*)[/\\][^/\\]+$") or "."
local runtime_root = script_dir .. "/../src/runtime/lua"

package.path = runtime_root .. "/?.lua;" .. runtime_root .. "/?/init.lua;" .. package.path

local module_names = {
  "bloob",
  "bloob.ui",
  "bloob.keymap",
  "bloob.events",
  "bloob.tools",
  "bloob.models",
  "bloob.config",
  "bloob.agent",
  "bloob.plugins",
  "bloob.storage",
  "bloob.command",
}

local function unload_modules()
  for _, name in ipairs(module_names) do
    package.loaded[name] = nil
  end
end

local function install_base_modules()
  local state = {
    notifications = {},
    commands = {},
    command_order = {},
    keymaps = {},
    tools = {},
    themes = {},
    layout = nil,
    model = "mock/fixture",
    theme = "default",
    leader = "\\",
    route = nil,
    renders = 0,
    reloads = 0,
    quit = false,
    setup = nil,
    read_file_calls = 0,
  }

  local bloob = {
    version = "0.1.0",
    api_version = 1,
    lua51 = true,
    runtime = "luajit-2.1",
    platform = "harness",
    lua_ffi_available = 1,
  }

  local function notify(msg, is_error)
    state.notifications[#state.notifications + 1] = {
      msg = tostring(msg),
      error = is_error == true,
    }
  end

  function bloob._notify(msg, is_error)
    notify(msg, is_error)
  end

  function bloob._quit()
    state.quit = true
  end

  function bloob._set_model(model)
    state.model = tostring(model)
  end

  function bloob._current_model()
    return state.model
  end

  function bloob._request_render()
    state.renders = state.renders + 1
  end

  function bloob._request_reload()
    state.reloads = state.reloads + 1
  end

  function bloob._run_command(name, args)
    local spec = state.commands[tostring(name)]
    if not spec then return false, "unknown command" end
    local ctx = {
      args = tostring(args or ""),
      notify = function(_, msg, opts)
        notify(msg, opts and opts.error)
      end,
    }
    local ok, err = pcall(spec.run, ctx)
    if not ok then
      notify("command failed: " .. tostring(err), true)
      return false, tostring(err)
    end
    return true
  end

  function bloob._setup(opts)
    state.setup = opts
  end

  function bloob._state()
    return {}
  end

  function bloob._config_sources()
    return { "harness" }
  end

  function bloob._register_command(name, description)
    local key = tostring(name)
    if not state.commands[key] then
      state.command_order[#state.command_order + 1] = key
    end
    state.commands[key] = state.commands[key] or {}
    state.commands[key].description = tostring(description or "")
  end

  function bloob._read_file(path)
    state.read_file_calls = state.read_file_calls + 1
    return nil, "read_file is disabled in the harness for " .. tostring(path)
  end

  function bloob._log(msg)
    state.notifications[#state.notifications + 1] = {
      msg = "[log] " .. tostring(msg),
      error = false,
    }
  end

  local ui = {}

  function ui._set_layout(layout)
    state.layout = layout
  end

  function ui._theme_register(name, palette)
    state.themes[tostring(name)] = palette
  end

  function ui._theme_set(name)
    state.theme = tostring(name)
  end

  function ui._notify(msg, is_error)
    notify(msg, is_error)
  end

  function ui._request_render()
    state.renders = state.renders + 1
  end

  function ui._command(name, args)
    return bloob._run_command(name, args)
  end

  function ui._quit()
    state.quit = true
  end

  local keymap = {}

  function keymap._set_fn(mode, lhs, fn, desc)
    state.keymaps[#state.keymaps + 1] = {
      mode = tostring(mode),
      lhs = tostring(lhs),
      rhs = fn,
      desc = tostring(desc or ""),
    }
  end

  function keymap._set_cmd(mode, lhs, command, desc)
    state.keymaps[#state.keymaps + 1] = {
      mode = tostring(mode),
      lhs = tostring(lhs),
      rhs = tostring(command),
      desc = tostring(desc or ""),
    }
  end

  function keymap._del(mode, lhs)
    for i = #state.keymaps, 1, -1 do
      local m = state.keymaps[i]
      if m.mode == tostring(mode) and m.lhs == tostring(lhs) then
        table.remove(state.keymaps, i)
      end
    end
  end

  function keymap._leader(value)
    if value ~= nil and tostring(value) ~= "" then
      state.leader = tostring(value)
    end
    return state.leader
  end

  local tools = {}

  function tools._register(entry)
    state.tools[tostring(entry.name)] = entry
  end

  function tools._list()
    local out = {}
    for _, entry in pairs(state.tools) do out[#out + 1] = entry end
    return out
  end

  local models = {}

  function models._set_route(fn)
    state.route = fn
  end

  function models._set_model(id)
    state.model = tostring(id)
  end

  function models._current_model()
    return state.model
  end

  local config = {}

  function config._sources()
    return { "harness" }
  end

  function config._reload()
    state.reloads = state.reloads + 1
  end

  package.loaded["bloob"] = bloob
  package.loaded["bloob.ui"] = ui
  package.loaded["bloob.keymap"] = keymap
  package.loaded["bloob.events"] = {}
  package.loaded["bloob.tools"] = tools
  package.loaded["bloob.models"] = models
  package.loaded["bloob.config"] = config
  package.loaded["bloob.agent"] = {}
  package.loaded["bloob.plugins"] = {}
  package.loaded["bloob.storage"] = {}
  package.loaded["bloob.command"] = {}
  _G.bloob = bloob

  return {
    state = state,
    bloob = bloob,
    ui = ui,
    keymap = keymap,
    tools = tools,
    models = models,
    config = config,
  }
end

local bundled = {
  { "bloob.ui", "bloob/ui.lua" },
  { "bloob.keymap", "bloob/keymap.lua" },
  { "bloob.events", "bloob/events.lua" },
  { "bloob.tools", "bloob/tools.lua" },
  { "bloob.models", "bloob/models.lua" },
  { "bloob.config", "bloob/config.lua" },
  { "bloob", "bloob/init.lua" },
}

local function load_runtime()
  unload_modules()
  local base = install_base_modules()
  for _, entry in ipairs(bundled) do
    local chunk = assert(loadfile(runtime_root .. "/" .. entry[2]))
    local result = chunk()
    assert(type(result) == "table", entry[2] .. " did not return a module table")
    package.loaded[entry[1]] = result
  end
  local defaults = assert(loadfile(runtime_root .. "/bloob/defaults.lua"))
  defaults()

  return {
    state = base.state,
    bloob = require("bloob"),
    ui = require("bloob.ui"),
    keymap = require("bloob.keymap"),
    events = require("bloob.events"),
    tools = require("bloob.tools"),
    models = require("bloob.models"),
    config = require("bloob.config"),
  }
end

local function load_example(name)
  local rt = load_runtime()
  local path = script_dir .. "/" .. name .. "/init.lua"
  local chunk = assert(loadfile(path), path)
  local ok, err = pcall(chunk)
  if not ok then
    error("loading " .. path .. " failed: " .. tostring(err), 0)
  end
  return rt, path
end

local known_kinds = {
  column = true,
  row = true,
  panel = true,
  text = true,
  spacer = true,
  button = true,
  list = true,
  scroll = true,
  input = true,
  chat = true,
  statusline = true,
  sidebar = true,
  diff = true,
  tabs = true,
  overlay = true,
  custom = true,
  widget = true,
}

local function example_ctx(rt)
  return {
    width = 120,
    height = 40,
    cwd = "/tmp/bloob-example",
    model = "mock/fixture",
    provider = "mock",
    theme = rt.state.theme or "default",
    mode = "insert",
    state = "idle",
    session_id = "local",
    git_branch = "",
    busy = false,
    message_count = 2,
    prompt_tokens = 10,
    completion_tokens = 20,
    total_tokens = 30,
    bloob_version = "0.1.0",
    api_version = 1,
    agents = {},
  }
end

local function check_layout(rt)
  local layout = rt.state.layout
  assert(layout ~= nil, "no layout was installed")
  local ctx = example_ctx(rt)
  if type(layout) == "function" then
    local ok, result = pcall(layout, ctx)
    assert(ok, "layout function failed: " .. tostring(result))
    layout = result
  end
  assert(type(layout) == "table", "layout must be a table, got " .. type(layout))

  local nodes = 0
  local function expand(node, path, depth)
    assert(depth < 32, path .. " is nested too deeply")
    nodes = nodes + 1
    assert(type(node) == "table", path .. " is not a table")
    local kind = node.__bloob
    assert(known_kinds[kind], path .. " has unknown kind " .. tostring(kind))
    if kind == "widget" then
      assert(node.name and rt.ui.get_widget(node.name),
        path .. " references unregistered widget " .. tostring(node.name))
      local ok, rendered = pcall(rt.ui._render_widget, node.name, ctx)
      assert(ok, path .. " widget render failed: " .. tostring(rendered))
      assert(type(rendered) == "table", path .. " widget returned " .. type(rendered))
      return expand(rendered, path .. "<" .. node.name .. ">", depth + 1)
    end
    local copy = {}
    for key, value in pairs(node) do copy[key] = value end
    local children = {}
    for i, child in ipairs(node.children or {}) do
      children[i] = expand(child, path .. ".children[" .. i .. "]", depth + 1)
    end
    copy.children = children
    return copy
  end
  local expanded = expand(layout, "layout", 0)
  return expanded, nodes
end

local function collect_buttons(node, out)
  if node.__bloob == "button" and type(node.on_press) == "function" then
    out[#out + 1] = node
  end
  for _, child in ipairs(node.children or {}) do
    collect_buttons(child, out)
  end
end

local function find_text(node, value)
  if node.__bloob == "text" and node.content == value then return true end
  for _, child in ipairs(node.children or {}) do
    if find_text(child, value) then return true end
  end
  return false
end

local checks = {
  minimal = function(rt)
    assert(rt.state.theme == "catppuccin", "theme was not applied")
    assert(rt.state.model == "mock/fixture", "model was not applied")
    assert(rt.state.leader == "\\", "leader was not applied")
  end,

  dashboard = function(rt)
    assert(rt.ui.get_widget("dashboard.session"), "dashboard widget not registered")
    local _, nodes = check_layout(rt)
    assert(nodes > 10, "dashboard layout is unexpectedly small")
  end,

  ["custom-widget"] = function(rt)
    local layout = check_layout(rt)
    local buttons = {}
    collect_buttons(layout, buttons)
    assert(#buttons >= 3, "expected three counter buttons")
    local plus
    for _, button in ipairs(buttons) do
      if button.content == "+1" then plus = button end
    end
    assert(plus, "+1 button not found")
    plus.on_press()
    local layout_after = check_layout(rt)
    assert(find_text(layout_after, "count=1"), "signal update did not change the rendered count")
    assert(find_text(layout_after, "clicks=1"), "signal update did not change the click count")
  end,

  ["custom-tool"] = function(rt)
    local tool = rt.tools.get("workspace.snapshot")
    assert(tool, "workspace.snapshot was not registered")
    assert(type(tool.schema) == "table" and tool.schema.type == "object", "invalid tool schema")
    assert(rt.state.tools["workspace.snapshot"], "tool was not passed to the host")
    assert(rt.bloob.command.registry["lua-tools"], "lua-tools command was not registered")
    local result = tool.run({
      cwd = "/tmp/bloob-example",
      model = "mock/fixture",
      provider = "mock",
      mode = "insert",
      state = "idle",
      busy = false,
      message_count = 2,
      prompt_tokens = 10,
      completion_tokens = 20,
      total_tokens = 30,
      api_version = 1,
    }, { label = "harness" })
    assert(result.label == "harness", "tool args were not passed through")
    assert(result.cwd == "/tmp/bloob-example", "tool context was not passed through")
    assert(result.busy == false, "tool boolean conversion is wrong")
  end,

  ["custom-command"] = function(rt)
    assert(rt.bloob.command.registry["greet"], "greet command was not registered")
    local ok = rt.bloob.command.run("greet", "Ada")
    assert(ok == true, "greet command failed")
    local last = rt.state.notifications[#rt.state.notifications]
    assert(last and last.msg == "Hello, Ada", "greet did not receive args")

    local found_string = false
    local found_callback = false
    for _, mapping in ipairs(rt.keymap.list()) do
      if mapping.mode == "normal" and mapping.lhs == "<C-g>" and mapping.rhs == "greet" then
        found_string = true
      end
      if mapping.mode == "normal" and mapping.lhs == "<C-y>" and type(mapping.rhs) == "function" then
        found_callback = true
      end
    end
    assert(found_string, "normal <C-g> command mapping missing")
    assert(found_callback, "normal <C-y> callback mapping missing")
  end,

  ["vim-mode"] = function(rt)
    local found = {}
    for _, mapping in ipairs(rt.keymap.list()) do
      found[mapping.mode .. ":" .. mapping.lhs] = mapping
    end
    assert(found["normal:<C-g>"] and found["normal:<C-g>"].rhs == "help", "normal help mapping missing")
    assert(found["normal:Q"] and found["normal:Q"].rhs == "quit", "normal quit mapping missing")
    assert(found["insert:<C-t>"] and type(found["insert:<C-t>"].rhs) == "function", "insert callback mapping missing")
  end,

  events = function(rt)
    assert(rt.events.count("file.after_write") == 1, "file.after_write handler missing")
    assert(rt.events.count("tool.before_execute") == 1, "tool.before_execute handler missing")

    local before = #rt.state.notifications
    rt.events.emit("file.after_write", { path = "src/example.zig" })
    assert(#rt.state.notifications > before, "file.after_write handler did not notify")

    local decision = rt.events.emit("tool.before_execute", {
      tool = "shell",
      arguments = "{\"command\":\"rm -rf build\"}",
      summary = "Run shell command",
    })
    assert(type(decision) == "table" and decision.action == "deny", "risky shell command was not denied")
  end,
}

local order = {
  "minimal",
  "dashboard",
  "custom-widget",
  "custom-tool",
  "custom-command",
  "vim-mode",
  "events",
}

local failures = 0
for _, name in ipairs(order) do
  local ok, err = pcall(function()
    local rt, path = load_example(name)
    check_layout(rt)
    local check = checks[name]
    if check then check(rt) end
    io.write(string.format("PASS %-15s %s\n", name, path))
  end)
  if not ok then
    failures = failures + 1
    io.write(string.format("FAIL %-15s %s\n", name, tostring(err)))
  end
end

if failures > 0 then
  io.write(string.format("\n%d example(s) failed\n", failures))
  os.exit(1)
end
io.write(string.format("\n%d examples passed (Lua modules exercised with stubbed C bridge)\n", #order))
