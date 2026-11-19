-- Vim-style keymaps that dispatch real bloob commands.
--
-- The editor already has a built-in insert/normal toggle on Esc:
--   insert -> normal: Esc
--   normal -> insert: i
-- Lua cannot switch the editor mode directly yet, so this example does not
-- try to remap `i`. It adds command bindings around the built-in Vim-like keys.

local bloob = require("bloob")
local keymap = require("bloob.keymap")

bloob.setup({ theme = "catppuccin" })

-- Normal mode: dispatch strings through the app command table.
keymap.set("normal", "<C-g>", "help", { desc = "Help" })
keymap.set("normal", "Q", "quit", { desc = "Quit bloob" })
keymap.set("normal", "<C-f>", "files", { desc = "Toggle the file sidebar" })
keymap.set("normal", "<C-y>", "clear", { desc = "Clear the conversation" })

-- Normal mode: callbacks can pass arguments to Lua or built-in commands.
keymap.set("normal", "<C-t>", function()
  bloob.command_run("theme", "catppuccin")
end, { desc = "Use the catppuccin theme" })

-- Insert mode bindings. Avoid global keys such as Ctrl-P, Ctrl-R, Ctrl-S,
-- Ctrl-C, Ctrl-Q and Ctrl-U; those are handled before Lua keymaps.
keymap.set("insert", "<C-g>", "help", { desc = "Help" })
keymap.set("insert", "<C-y>", "clear", { desc = "Clear the conversation" })
keymap.set("insert", "<C-t>", function()
  bloob.command_run("theme", "light")
end, { desc = "Use the light theme" })
