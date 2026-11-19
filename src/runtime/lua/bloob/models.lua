-- bloob.models — model selection and routing.
local models = require("bloob.models")
local M = models

M.selection = "mock/fixture"

function M.set(id)
  if type(id) ~= "string" then error("models.set expects a model id", 2) end
  M.selection = id
  M._set_model(id)
end

function M.current()
  return M.selection
end

function M.route(fn)
  if type(fn) ~= "function" then error("models.route expects a function", 2) end
  M._set_route(fn)
end

function M.list()
  return {
    { id = "mock/fixture", provider = "mock", available = true },
  }
end

return M
