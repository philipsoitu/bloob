-- Default layout, expressed with the same primitives available to users.
local ui = require("bloob.ui")

local function default_layout(ctx)
  local narrow = (ctx.width or 100) < 70
  if narrow then
    return ui.column({
      ui.chat({
        id = "conversation",
        flex = 1,
        border = "rounded",
        title = "Conversation",
        padding = 1,
      }),
      ui.input({
        id = "prompt",
        height = 8,
        border = "rounded",
        title = "Prompt",
        padding = 1,
      }),
      ui.statusline({ id = "status" }),
    })
  end
  return ui.column({
    ui.row({
      ui.sidebar({
        id = "files",
        width = 24,
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
    }, { flex = 1 }),
    ui.input({
      id = "prompt",
      height = 8,
      border = "rounded",
      title = "Prompt  (Enter send · Alt-Enter newline · /help)",
      padding = 1,
    }),
    ui.statusline({ id = "status" }),
  })
end

ui.set_layout(default_layout)

-- A small built-in widget proves the same registry path used by user widgets.
ui.register("bloob.help_hint", function(ctx)
  return ui.row({
    ui.text("?" .. (ctx.model or ""), { color = "muted" }),
    ui.spacer({ flex = 1 }),
    ui.text(ctx.busy and "working" or "ready", { color = ctx.busy and "warning" or "muted" }),
  }, { gap = 1 })
end)
