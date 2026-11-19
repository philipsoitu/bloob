-- bloob.config — validated configuration and sources.
local config = require("bloob.config")
local M = config

function M.sources()
  return M._sources()
end

function M.reload()
  M._reload()
end

return M
