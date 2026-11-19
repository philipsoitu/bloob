-- Dashboard layout: conversation + file sidebar + a custom status widget.
--
-- The widget receives the same read-only snapshot passed to a layout function.
-- All fields used here exist in the current runtime. `git_branch` and `agents`
-- are placeholders today: the branch is always empty and agents is always an
-- empty list.

local bloob = require("bloob")
local ui = require("bloob.ui")

bloob.setup({
  theme = "catppuccin",
  model = "mock/fixture",
})

local function row(label, value)
  return ui.row({
    ui.text(label, { color = "muted" }),
    ui.spacer({ flex = 1 }),
    ui.text(tostring(value)),
  })
end

ui.register("dashboard.session", function(ctx)
  local compact = (ctx.width or 100) < 110
  return ui.panel({
    row("model", ctx.model),
    row("provider", ctx.provider),
    row("state", ctx.busy and "working" or ctx.state),
    row("messages", ctx.message_count),
    row("tokens", ctx.total_tokens),
    row("mode", ctx.mode),
    row("cwd", ctx.cwd),
    row("branch", ctx.git_branch ~= "" and ctx.git_branch or "-"),
    row("terminal", tostring(ctx.width) .. "x" .. tostring(ctx.height)),
  }, {
    id = "dashboard.session",
    title = "Session",
    border = "rounded",
    padding = 1,
    width = compact and 24 or 30,
  })
end)

ui.set_layout(function(ctx)
  local compact = (ctx.width or 100) < 110
  return ui.column({
    ui.row({
      ui.sidebar({
        id = "files",
        width = compact and 20 or 24,
        border = "rounded",
        title = "Context",
        padding = 1,
      }),
      ui.chat({
        id = "conversation",
        flex = 1,
        border = "rounded",
        title = "Conversation",
        padding = 1,
      }),
      ui.widget("dashboard.session"),
    }, { flex = 1, gap = 1 }),
    ui.input({
      id = "prompt",
      height = 6,
      border = "rounded",
      title = "Prompt  (Enter send / Alt-Enter newline / /help)",
      padding = 1,
    }),
    ui.statusline({ id = "status" }),
  })
end)
