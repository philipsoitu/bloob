//! Interactive application: event loop, state, input routing and rendering.
const std = @import("std");
const term = @import("term.zig");
const key = @import("key.zig");
const frame_mod = @import("frame.zig");
const style = @import("style.zig");
const theme = @import("theme.zig");
const text = @import("text.zig");
const editor_mod = @import("editor.zig");
const messages = @import("messages.zig");
const ui = @import("ui/node.zig");
const chat = @import("ui/chat.zig");

const Frame = frame_mod.Frame;
const Rect = frame_mod.Rect;
const Style = style.Style;

pub const Mode = enum { insert, normal };
pub const AgentPhase = enum { idle, streaming, awaiting_approval, executing_tools, failed, cancelled };

pub const Command = struct {
    name: []const u8,
    aliases: []const u8 = "",
    description: []const u8,
};

pub const commands = [_]Command{
    .{ .name = "help", .description = "Show help and keybindings" },
    .{ .name = "model", .description = "Show or select the active model" },
    .{ .name = "providers", .description = "Show provider status" },
    .{ .name = "session", .aliases = "sessions", .description = "New, list or resume sessions" },
    .{ .name = "context", .description = "Inspect workspace context" },
    .{ .name = "files", .description = "Toggle the file sidebar" },
    .{ .name = "diff", .description = "Show pending diff (when available)" },
    .{ .name = "tools", .description = "List registered tools and policy" },
    .{ .name = "theme", .description = "List or switch themes" },
    .{ .name = "reload", .description = "Reload Lua configuration" },
    .{ .name = "keymaps", .description = "Inspect keymaps" },
    .{ .name = "doctor", .description = "Show diagnostics" },
    .{ .name = "clear", .description = "Clear the conversation" },
    .{ .name = "new", .description = "Start a new conversation" },
    .{ .name = "quit", .aliases = "q", .description = "Exit bloob" },
    .{ .name = "export", .description = "Export the conversation (markdown/json)" },
};

const Palette = struct {
    active: bool = false,
    query: std.ArrayList(u8) = .empty,
    selected: usize = 0,
    filtered: std.ArrayList(usize) = .empty,
};

const Help = struct {
    active: bool = false,
    scroll: u16 = 0,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    terminal: *term.Terminal,
    parser: key.Parser,
    editor: editor_mod.Editor,
    conversation: messages.Conversation,
    themes: theme.Registry,
    frame: ?Frame = null,
    size: term.Size = .{},
    running: bool = true,
    dirty: bool = true,
    mode: Mode = .insert,
    agent_phase: AgentPhase = .idle,
    palette: Palette,
    help: Help,
    focus_index: usize = 0,
    focus_buttons: std.ArrayList(ui.LayoutResult.FocusItem) = .empty,
    buttons: std.ArrayList(ui.LayoutResult.ButtonHit) = .empty,
    input_rect: ?Rect = null,
    chat_rect: ?Rect = null,
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    cursor_visible: bool = false,
    chat_scroll: u16 = 0,
    stick_bottom: bool = true,
    notice: []u8 = &.{},
    notice_is_error: bool = false,
    notice_until_ms: i64 = 0,
    spinner: u8 = 0,
    last_ctrl_c_ms: i64 = 0,
    last_input_ms: i64 = 0,
    last_stream_ms: i64 = 0,
    stream_text: []u8 = &.{},
    stream_pos: usize = 0,
    stream_msg_index: ?usize = null,
    mock_mode: bool = true,
    model: []u8 = &.{},
    provider: []u8 = &.{},
    theme_name: []u8 = &.{},
    cwd: []u8 = &.{},
    session_id: []u8 = &.{},
    show_sidebar: bool = true,
    frame_arena: std.heap.ArenaAllocator,
    layout_ids_valid: bool = false,
    commands_lua_count: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, terminal: *term.Terminal, opts: struct {
        model: ?[]const u8 = null,
        theme_name: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
    }) !App {
        var self = App{
            .gpa = gpa,
            .io = io,
            .terminal = terminal,
            .parser = key.Parser.init(gpa),
            .editor = editor_mod.Editor.init(gpa),
            .conversation = messages.Conversation.init(gpa),
            .themes = try theme.Registry.init(gpa),
            .palette = .{},
            .help = .{},
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
        };
        self.model = try gpa.dupe(u8, opts.model orelse "mock/fixture");
        self.provider = try gpa.dupe(u8, if (std.mem.indexOfScalar(u8, self.model, '/')) |i| self.model[0..i] else "mock");
        self.theme_name = try gpa.dupe(u8, opts.theme_name orelse "default");
        _ = self.themes.set(self.theme_name);
        self.cwd = try gpa.dupe(u8, opts.cwd orelse ".");
        self.session_id = try gpa.dupe(u8, "local");
        return self;
    }

    pub fn deinit(self: *App) void {
        self.parser.deinit();
        self.editor.deinit();
        self.conversation.deinit();
        self.themes.deinit();
        if (self.frame) |*f| f.deinit();
        self.palette.query.deinit(self.gpa);
        self.palette.filtered.deinit(self.gpa);
        self.focus_buttons.deinit(self.gpa);
        self.buttons.deinit(self.gpa);
        self.frame_arena.deinit();
        if (self.notice.len > 0) self.gpa.free(self.notice);
        if (self.stream_text.len > 0) self.gpa.free(self.stream_text);
        self.gpa.free(self.model);
        self.gpa.free(self.provider);
        self.gpa.free(self.theme_name);
        self.gpa.free(self.cwd);
        self.gpa.free(self.session_id);
    }

    pub fn nowMs(self: *App) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    pub fn notify(self: *App, msg: []const u8, is_error: bool) void {
        if (self.notice.len > 0) self.gpa.free(self.notice);
        self.notice = self.gpa.dupe(u8, msg) catch &.{};
        self.notice_is_error = is_error;
        self.notice_until_ms = self.nowMs() + 6000;
        self.dirty = true;
    }

    pub fn run(self: *App) !void {
        if (self.conversation.messages.items.len == 0) {
            const m = try self.conversation.add(.system, "bloob is ready. Model: " ++ "mock/fixture", self.nowMs());
            m.usage = .{};
            if (self.model.len > 0) {
                try m.setModel(self.gpa, self.model);
            }
            _ = try self.conversation.add(.assistant, "Welcome to **bloob**, a Lua-programmable coding agent.\n\nType a message and press Enter. Try `/help`.\n\nThe deterministic `mock/fixture` provider is active, so no API key is required.\n\n```zig\nconst bloob = @import(\"bloob\");\n```\n", self.nowMs());
        }
        self.size = self.terminal.size();
        try self.resize();
        var read_buf: [8192]u8 = undefined;
        while (self.running) {
            if (term.pendingTerminate()) break;
            if (term.pendingResize()) {
                self.size = self.terminal.size();
                try self.resize();
            }
            if (term.pendingInterrupt()) {
                self.handleCtrlC();
            }
            const now = self.nowMs();
            self.editor.clock_ms = now;
            self.tick(now);
            if (self.dirty) {
                try self.render();
                self.dirty = false;
            }
            // Flush a lone ESC after a short timeout.
            if (self.parser.buf.items.len == 1 and self.parser.buf.items[0] == 0x1b and now - self.last_input_ms > 40) {
                try self.parser.flushEscape(self, App.handleInput);
            }
            const timeout: i32 = if (self.agent_phase == .streaming) 20 else 60;
            var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN }};
            _ = std.posix.poll(&fds, timeout) catch continue;
            if (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                const n = self.terminal.read(&read_buf) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => return err,
                };
                if (n == 0) break; // EOF
                self.last_input_ms = now;
                try self.parser.feed(read_buf[0..n], self, App.handleInput);
            }
        }
    }

    fn tick(self: *App, now: i64) void {
        if (self.agent_phase == .streaming) {
            self.spinner +%= 1;
            if (now - self.last_stream_ms >= 18) {
                self.last_stream_ms = now;
                if (self.stream_pos < self.stream_text.len) {
                    if (self.stream_msg_index) |idx| {
                        if (idx < self.conversation.messages.items.len) {
                            const m = &self.conversation.messages.items[idx];
                            const remaining = self.stream_text.len - self.stream_pos;
                            const take = @min(remaining, 6);
                            m.text.appendSlice(self.gpa, self.stream_text[self.stream_pos .. self.stream_pos + take]) catch {};
                            self.stream_pos += take;
                            self.dirty = true;
                            if (self.stick_bottom) self.chat_scroll = 0;
                        }
                    }
                    if (self.stream_pos >= self.stream_text.len) {
                        self.finishStreaming(false);
                    }
                } else {
                    self.finishStreaming(false);
                }
            }
        }
        if (self.notice_until_ms > 0 and now > self.notice_until_ms) {
            self.notice_until_ms = 0;
            self.dirty = true;
        }
    }

    fn finishStreaming(self: *App, cancelled: bool) void {
        if (self.stream_msg_index) |idx| {
            if (idx < self.conversation.messages.items.len) {
                const m = &self.conversation.messages.items[idx];
                m.streaming = false;
                if (cancelled) {
                    m.text.appendSlice(self.gpa, "\n\n_[cancelled]_") catch {};
                }
            }
        }
        self.stream_msg_index = null;
        self.stream_pos = 0;
        if (self.stream_text.len > 0) {
            self.gpa.free(self.stream_text);
            self.stream_text = &.{};
        }
        self.agent_phase = if (cancelled) .cancelled else .idle;
        self.dirty = true;
    }

    pub fn handleInput(self: *App, ev: key.Event) !void {
        switch (ev) {
            .key => |k| try self.handleKey(k),
            .paste => |bytes| {
                if (self.palette.active) {
                    try self.palette.query.appendSlice(self.gpa, bytes);
                    self.palette.selected = 0;
                    self.updatePalette();
                } else if (self.help.active) {} else if (self.mode == .insert) {
                    const clean = try text.sanitizeAlloc(self.gpa, bytes, 1024 * 1024);
                    defer self.gpa.free(clean);
                    self.editor.insertText(clean, true) catch |err| {
                        if (err == error.TooLarge) self.notify("Input is too large", true);
                    };
                }
                self.dirty = true;
            },
            .mouse => |m| self.handleMouse(m),
            .focus_in, .focus_out => {},
        }
    }

    fn handleMouse(self: *App, m: key.Mouse) void {
        if (self.palette.active or self.help.active) return;
        if (self.chat_rect) |r| {
            if (m.x >= r.x and m.x < r.x + r.w and m.y >= r.y and m.y < r.y + r.h) {
                if (m.wheel_up) self.chat_scroll +|= 3;
                if (m.wheel_down) {
                    if (self.chat_scroll >= 3) self.chat_scroll -= 3 else self.chat_scroll = 0;
                }
                self.dirty = true;
            }
        }
        if (m.action == .press and m.button == .left) {
            for (self.buttons.items) |b| {
                if (m.x >= b.rect.x and m.x < b.rect.x + b.rect.w and m.y >= b.rect.y and m.y < b.rect.y + b.rect.h) {
                    self.activateButton(b.ref);
                    break;
                }
            }
        }
    }

    fn activateButton(self: *App, ref: i32) void {
        _ = ref;
        self.notify("Lua button callbacks require the Lua runtime (coming next)", false);
    }

    fn handleCtrlC(self: *App) void {
        const now = self.nowMs();
        if (self.agent_phase == .streaming) {
            self.finishStreaming(true);
            self.notify("Request cancelled", false);
            return;
        }
        if (self.palette.active or self.help.active) {
            self.palette.active = false;
            self.help.active = false;
            self.dirty = true;
            return;
        }
        if (self.editor.text.items.len > 0) {
            self.editor.clear();
            self.dirty = true;
            return;
        }
        if (now - self.last_ctrl_c_ms < 1200) {
            self.running = false;
        } else {
            self.last_ctrl_c_ms = now;
            self.notify("Press Ctrl-C again to quit", false);
        }
    }

    fn handleKey(self: *App, k: key.Key) !void {
        if (self.palette.active) {
            try self.handlePaletteKey(k);
            return;
        }
        if (self.help.active) {
            switch (k.code) {
                .esc, .f1 => self.help.active = false,
                .up => self.help.scroll -|= 1,
                .down => self.help.scroll +|= 1,
                .page_up => self.help.scroll -|= 10,
                .page_down => self.help.scroll +|= 10,
                else => {},
            }
            self.dirty = true;
            return;
        }
        // Global keys.
        if (k.code == .char and k.mods.ctrl) {
            switch (k.char) {
                'q' => {
                    self.running = false;
                    return;
                },
                'p' => {
                    self.openPalette();
                    return;
                },
                'r' => {
                    self.notify("Reload requires the Lua runtime (coming next)", false);
                    return;
                },
                's' => {
                    if (self.mode == .insert) try self.submit();
                    return;
                },
                'c' => {
                    self.handleCtrlC();
                    return;
                },
                'a' => {
                    self.editor.moveHome();
                    self.dirty = true;
                    return;
                },
                'e' => {
                    self.editor.moveEnd();
                    self.dirty = true;
                    return;
                },
                'u' => {
                    self.editor.deleteToLineStart();
                    self.dirty = true;
                    return;
                },
                'k' => {
                    self.editor.deleteToLineEnd();
                    self.dirty = true;
                    return;
                },
                'w' => {
                    self.editor.deleteWordBackward();
                    self.dirty = true;
                    return;
                },
                'j' => {
                    if (self.mode == .insert) self.editor.insertNewline() catch {};
                    self.dirty = true;
                    return;
                },
                'l' => {
                    self.chat_scroll = 0;
                    self.stick_bottom = true;
                    self.dirty = true;
                    return;
                },
                'n' => {
                    self.newConversation();
                    return;
                },
                else => {},
            }
        }
        if (k.code == .f1) {
            self.help.active = true;
            self.help.scroll = 0;
            self.dirty = true;
            return;
        }
        if (k.code == .page_up) {
            if (self.chat_rect) |r| {
                const max = self.maxScroll();
                self.chat_scroll = @min(max, self.chat_scroll +| @as(u16, @intCast(@max(1, r.h -| 2))));
                self.stick_bottom = false;
            }
            self.dirty = true;
            return;
        }
        if (k.code == .page_down) {
            const step: u16 = if (self.chat_rect) |r| @intCast(@max(1, r.h -| 2)) else 5;
            if (self.chat_scroll > step) self.chat_scroll -= step else {
                self.chat_scroll = 0;
                self.stick_bottom = true;
            }
            self.dirty = true;
            return;
        }
        if (k.code == .esc) {
            if (self.mode == .insert) self.mode = .normal else self.mode = .insert;
            self.dirty = true;
            return;
        }
        if (self.mode == .normal) {
            try self.handleNormalKey(k);
            return;
        }
        // Insert mode editing.
        switch (k.code) {
            .enter => {
                if (k.mods.alt or k.mods.ctrl) {
                    self.editor.insertNewline() catch {};
                } else {
                    try self.submit();
                }
                self.dirty = true;
            },
            .backspace => {
                self.editor.backspace();
                self.dirty = true;
            },
            .delete => {
                self.editor.deleteForward();
                self.dirty = true;
            },
            .left => {
                if (k.mods.ctrl) self.editor.moveWordLeft() else self.editor.moveLeft();
                self.dirty = true;
            },
            .right => {
                if (k.mods.ctrl) self.editor.moveWordRight() else self.editor.moveRight();
                self.dirty = true;
            },
            .up => {
                if (k.mods.ctrl) {
                    self.editor.historyPrev();
                } else self.editor.moveUp();
                self.dirty = true;
            },
            .down => {
                if (k.mods.ctrl) {
                    self.editor.historyNext();
                } else self.editor.moveDown();
                self.dirty = true;
            },
            .home => {
                self.editor.moveHome();
                self.dirty = true;
            },
            .end => {
                self.editor.moveEnd();
                self.dirty = true;
            },
            .tab => {
                if (k.mods.shift) {
                    if (self.focus_index == 0) self.focus_index = self.focus_buttons.items.len else self.focus_index -= 1;
                } else {
                    self.focus_index += 1;
                    if (self.focus_buttons.items.len > 0) self.focus_index %= self.focus_buttons.items.len;
                }
                self.dirty = true;
            },
            .char => {
                if (k.mods.ctrl or k.mods.alt) return;
                self.editor.insertCodepoint(k.char) catch {
                    self.notify("Input is too large", true);
                };
                self.dirty = true;
            },
            else => {},
        }
    }

    fn handleNormalKey(self: *App, k: key.Key) !void {
        switch (k.code) {
            .char => {
                switch (k.char) {
                    'i' => self.mode = .insert,
                    ':' => self.openPalette(),
                    'g' => {
                        self.chat_scroll = self.maxScroll();
                        self.stick_bottom = false;
                    },
                    'G' => {
                        self.chat_scroll = 0;
                        self.stick_bottom = true;
                    },
                    'j' => {
                        if (self.chat_scroll > 0) self.chat_scroll -= 1;
                    },
                    'k' => {
                        self.chat_scroll +|= 1;
                        self.stick_bottom = false;
                    },
                    'n' => self.newConversation(),
                    'q' => self.running = false,
                    '/' => self.openPalette(),
                    else => {},
                }
            },
            .enter => try self.activateFocused(),
            .tab => {
                self.focus_index += 1;
                if (self.focus_buttons.items.len > 0) self.focus_index %= self.focus_buttons.items.len;
            },
            .up => {
                if (self.chat_scroll > 0) self.chat_scroll -= 1;
            },
            .down => self.chat_scroll +|= 1,
            .page_up => self.chat_scroll = @min(self.maxScroll(), self.chat_scroll +| 10),
            .page_down => {
                if (self.chat_scroll > 10) self.chat_scroll -= 10 else {
                    self.chat_scroll = 0;
                    self.stick_bottom = true;
                }
            },
            else => {},
        }
        self.dirty = true;
    }

    fn activateFocused(self: *App) !void {
        if (self.focus_index == 0) {
            self.mode = .insert;
            return;
        }
        const idx = (self.focus_index - 1) % @max(1, self.focus_buttons.items.len);
        if (idx < self.focus_buttons.items.len) {
            if (self.focus_buttons.items[idx].ref) |ref| self.activateButton(ref);
        }
    }

    fn maxScroll(self: *App) u16 {
        _ = self;
        return 10000;
    }

    fn submit(self: *App) !void {
        if (self.agent_phase == .streaming) {
            self.notify("Already streaming — press Ctrl-C to cancel", true);
            return;
        }
        const value = try self.editor.submit();
        defer self.gpa.free(value);
        if (value.len == 0) return;
        if (value[0] == '/') {
            try self.runSlash(value);
            return;
        }
        _ = try self.conversation.add(.user, value, self.nowMs());
        self.chat_scroll = 0;
        self.stick_bottom = true;
        if (self.mock_mode) {
            try self.startMock(value);
        } else {
            _ = try self.conversation.add(.assistant, "", self.nowMs());
            self.agent_phase = .idle;
            self.notify("Provider integration is not yet wired in this build", true);
        }
        self.dirty = true;
    }

    fn startMock(self: *App, prompt: []const u8) !void {
        const response = try std.fmt.allocPrint(self.gpa,
            "You said:\n\n> {s}\n\nThis response is produced by bloob's deterministic **fixture provider**. It streams in small deltas so the UI, cancellation and persistence paths can be tested without network access.\n\n```zig\nconst std = @import(\"std\");\npub fn main() !void {{\n    std.debug.print(\"hello from bloob\\n\", .{{}});\n}}\n```\n\n- Lua configuration and the composable UI are next.\n- Try `/help`, `/theme catppuccin`, or `/tools`.\n", .{truncatePrompt(prompt)});
        if (self.stream_text.len > 0) self.gpa.free(self.stream_text);
        self.stream_text = response;
        self.stream_pos = 0;
        const idx = self.conversation.messages.items.len;
        _ = try self.conversation.addEmpty(.assistant, self.nowMs());
        self.conversation.messages.items[idx].streaming = true;
        try self.conversation.messages.items[idx].setModel(self.gpa, self.model);
        self.stream_msg_index = idx;
        self.agent_phase = .streaming;
        self.last_stream_ms = self.nowMs();
    }

    fn truncatePrompt(prompt: []const u8) []const u8 {
        if (prompt.len > 600) return prompt[0..600];
        return prompt;
    }

    fn runSlash(self: *App, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line[1..], " \t");
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        const name = parts.next() orelse return;
        const args = std.mem.trim(u8, trimmed[name.len..], " \t");
        try self.runCommand(name, args);
    }

    pub fn runCommand(self: *App, name: []const u8, args: []const u8) !void {
        if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "keymaps")) {
            self.help.active = true;
            self.help.scroll = 0;
        } else if (std.mem.eql(u8, name, "quit") or std.mem.eql(u8, name, "q")) {
            self.running = false;
        } else if (std.mem.eql(u8, name, "clear")) {
            self.conversation.clear();
            self.chat_scroll = 0;
            self.notify("Conversation cleared", false);
        } else if (std.mem.eql(u8, name, "new") or std.mem.eql(u8, name, "session")) {
            if (std.mem.eql(u8, args, "new") or name.len == 3) self.newConversation() else self.notify("Session persistence is coming next", false);
        } else if (std.mem.eql(u8, name, "theme")) {
            if (args.len == 0) {
                self.notify("Themes: default, light, monochrome, catppuccin", false);
            } else if (self.themes.set(args)) {
                if (self.theme_name.len > 0) self.gpa.free(self.theme_name);
                self.theme_name = try self.gpa.dupe(u8, args);
                self.notify("Theme set", false);
            } else self.notify("Unknown theme", true);
        } else if (std.mem.eql(u8, name, "model")) {
            if (args.len > 0) {
                if (self.model.len > 0) self.gpa.free(self.model);
                self.model = try self.gpa.dupe(u8, args);
                if (self.provider.len > 0) self.gpa.free(self.provider);
                const slash = std.mem.indexOfScalar(u8, self.model, '/');
                self.provider = try self.gpa.dupe(u8, if (slash) |idx| self.model[0..idx] else "mock");
                self.mock_mode = std.mem.eql(u8, self.provider, "mock") or std.mem.eql(u8, self.provider, "fixture");
                self.notify("Model selected (runtime provider wiring next)", false);
            } else {
                self.notify("Active model", false);
            }
        } else if (std.mem.eql(u8, name, "providers")) {
            self.notify("mock/fixture: ready; openai: key check pending", false);
        } else if (std.mem.eql(u8, name, "tools")) {
            self.notify("Tools: read_file, list_files, search, edit_file, write_file, shell, git_status, git_diff (runtime wiring next)", false);
        } else if (std.mem.eql(u8, name, "files")) {
            self.show_sidebar = !self.show_sidebar;
            self.notify(if (self.show_sidebar) "Sidebar shown" else "Sidebar hidden", false);
        } else if (std.mem.eql(u8, name, "reload")) {
            self.notify("Reload requires the Lua runtime (coming next)", false);
        } else if (std.mem.eql(u8, name, "doctor")) {
            self.help.active = true;
            self.help.scroll = 0;
            self.notify("Doctor: see help overlay", false);
        } else if (std.mem.eql(u8, name, "export")) {
            self.notify("Session persistence is coming next", false);
        } else {
            self.notify("Unknown command", true);
        }
        self.dirty = true;
    }

    fn newConversation(self: *App) void {
        self.conversation.clear();
        _ = self.conversation.add(.system, "New conversation", self.nowMs()) catch return;
        self.chat_scroll = 0;
        self.stick_bottom = true;
        self.notify("New conversation", false);
    }

    fn openPalette(self: *App) void {
        self.palette.active = true;
        self.palette.query.clearRetainingCapacity();
        self.palette.selected = 0;
        self.updatePalette();
        self.dirty = true;
    }

    fn updatePalette(self: *App) void {
        self.palette.filtered.clearRetainingCapacity();
        const q = self.palette.query.items;
        for (commands, 0..) |c, i| {
            if (q.len == 0 or containsIgnoreCase(c.name, q) or containsIgnoreCase(c.description, q) or containsIgnoreCase(c.aliases, q)) {
                self.palette.filtered.append(self.gpa, i) catch return;
            }
        }
        if (self.palette.selected >= self.palette.filtered.items.len) {
            self.palette.selected = if (self.palette.filtered.items.len == 0) 0 else self.palette.filtered.items.len - 1;
        }
    }

    fn handlePaletteKey(self: *App, k: key.Key) !void {
        switch (k.code) {
            .esc => self.palette.active = false,
            .up => {
                if (self.palette.selected > 0) self.palette.selected -= 1;
            },
            .down => {
                if (self.palette.selected + 1 < self.palette.filtered.items.len) self.palette.selected += 1;
            },
            .backspace => {
                if (self.palette.query.items.len > 0) {
                    self.palette.query.items.len -= 1;
                    self.updatePalette();
                }
            },
            .enter => {
                if (self.palette.filtered.items.len > 0) {
                    const idx = self.palette.filtered.items[self.palette.selected];
                    self.palette.active = false;
                    try self.runCommand(commands[idx].name, "");
                }
            },
            .char => {
                if (k.mods.ctrl or k.mods.alt) return;
                var buf: [4]u8 = undefined;
                try self.palette.query.appendSlice(self.gpa, text.encode(k.char, &buf));
                self.palette.selected = 0;
                self.updatePalette();
            },
            else => {},
        }
        self.dirty = true;
    }

    fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > hay.len) return false;
        var i: usize = 0;
        while (i + needle.len <= hay.len) : (i += 1) {
            var ok = true;
            for (needle, 0..) |c, j| {
                if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(c)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    fn resize(self: *App) !void {
        if (self.frame) |*f| f.deinit();
        self.frame = try Frame.init(self.gpa, @max(1, self.size.cols), @max(1, self.size.rows));
        self.dirty = true;
    }

    fn render(self: *App) !void {
        self.frame_arena.deinit();
        self.frame_arena = std.heap.ArenaAllocator.init(self.gpa);
        const a = self.frame_arena.allocator();
        const pal = self.themes.palette();
        const f = &self.frame.?;
        f.clear(.{ .fg = .{ .semantic = .fg }, .bg = .{ .semantic = .bg } });
        self.focus_buttons.clearRetainingCapacity();
        self.buttons.clearRetainingCapacity();
        self.input_rect = null;
        self.chat_rect = null;
        self.cursor_visible = false;

        const layout = try self.buildNativeLayout(a);
        ui.prepare(layout, .{ .x = 0, .y = 0, .w = self.size.cols, .h = self.size.rows });
        var result = ui.LayoutResult{};
        defer result.deinit(self.gpa);
        try ui.collect(layout, &result, self.gpa);
        for (result.focusables.items) |fi| try self.focus_buttons.append(self.gpa, fi);
        for (result.buttons.items) |b| try self.buttons.append(self.gpa, b);
        self.input_rect = result.input_rect;
        self.chat_rect = result.chat_rect;
        self.layout_ids_valid = true;
        try self.drawNode(f, layout, a);
        if (self.palette.active) try self.drawPalette(f, a);
        if (self.help.active) try self.drawHelp(f, a);
        const ansi = try f.toAnsi(a, &pal, self.terminal.color_mode);
        try self.terminal.writeAll(ansi);
        if (self.cursor_visible and !self.palette.active and !self.help.active) {
            try self.terminal.moveCursor(self.cursor_x, self.cursor_y);
        } else {
            try self.terminal.hideCursor();
        }
    }

    fn buildNativeLayout(self: *App, a: std.mem.Allocator) !*ui.Node {
        const root = try a.create(ui.Node);
        root.* = .{ .kind = .column, .style = .{} };
        const show_side = self.show_sidebar and self.size.cols >= 70;
        const row = try a.create(ui.Node);
        const row_kids = try a.alloc(ui.Node, if (show_side) 2 else 1);
        var row_n: usize = 0;
        if (show_side) {
            row_kids[row_n] = .{
                .kind = .sidebar,
                .id = "sidebar",
                .width = .{ .cells = 24 },
                .border = .rounded,
                .title = "Context",
                .padding = 1,
            };
            row_n += 1;
        }
        row_kids[row_n] = .{
            .kind = .chat,
            .id = "chat",
            .flex = 1,
            .border = .rounded,
            .title = "Conversation",
            .padding = 1,
        };
        row.* = .{ .kind = .row, .children = row_kids[0 .. row_n + 1], .flex = 1 };
        const input = try a.create(ui.Node);
        input.* = .{
            .kind = .input,
            .id = "prompt",
            .height = .{ .cells = 6 },
            .border = .rounded,
            .title = "Prompt  (Enter send · Alt-Enter newline · /help)",
            .padding = 1,
        };
        const status = try a.create(ui.Node);
        status.* = .{ .kind = .statusline, .id = "status", .height = .{ .cells = 1 } };
        const kids = try a.alloc(ui.Node, 3);
        kids[0] = row.*;
        kids[1] = input.*;
        kids[2] = status.*;
        root.children = kids;
        return root;
    }

    fn drawNode(self: *App, f: *Frame, node: *ui.Node, a: std.mem.Allocator) !void {
        if (!node.visible or node.rect.empty()) return;
        const pal = self.themes.palette();
        _ = pal;
        switch (node.kind) {
            .column, .row, .overlay, .tabs, .scroll => {
                for (node.children) |*c| try self.drawNode(f, c, a);
            },
            .panel => {
                if (node.border != .none) {
                    f.drawBorder(node.rect, node.border, .{ .fg = .{ .semantic = .border } }, node.title);
                }
                for (node.children) |*c| try self.drawNode(f, c, a);
            },
            .text => {
                try self.drawTextNode(f, node, a);
            },
            .button => {
                f.clearRect(node.rect, .{ .bg = .{ .semantic = .selection } });
                const label = node.content orelse "";
                const focused = node.focused or blk: {
                    if (self.focus_buttons.items.len > 0) {
                        const idx = (self.focus_index + self.focus_buttons.items.len - 1) % self.focus_buttons.items.len;
                        if (idx < self.focus_buttons.items.len) {
                            const fi = self.focus_buttons.items[idx];
                            break :blk std.mem.eql(u8, fi.id, node.id);
                        }
                    }
                    break :blk false;
                };
                const st = if (focused)
                    Style{ .fg = .{ .semantic = .bg }, .bg = .{ .semantic = .focus }, .attrs = .{ .bold = true } }
                else
                    Style{ .fg = .{ .semantic = .primary }, .bg = .{ .semantic = .selection } };
                f.clearRect(node.rect, st);
                f.putTextInRect(node.rect, 1, 0, label, st);
            },
            .input => try self.drawInput(f, node, a),
            .chat => try self.drawChat(f, node, a),
            .statusline => try self.drawStatus(f, node, a),
            .sidebar => try self.drawSidebar(f, node, a),
            .list => {
                f.clearRect(node.rect, .{});
                var y: u16 = 0;
                for (node.lines) |line| {
                    if (y >= node.rect.h) break;
                    f.putTextInRect(node.rect, 0, y, line, node.text_style);
                    y += 1;
                }
            },
            .diff => try self.drawChat(f, node, a),
            .spacer, .custom => {},
        }
    }

    fn drawTextNode(self: *App, f: *Frame, node: *ui.Node, a: std.mem.Allocator) !void {
        _ = self;
        f.clearRect(node.rect, node.style);
        const content = node.content orelse "";
        var clean = std.ArrayList(u8).empty;
        defer clean.deinit(a);
        try text.sanitizeInto(&clean, a, content);
        var y: u16 = 0;
        var it = std.mem.splitScalar(u8, clean.items, '\n');
        while (it.next()) |line| {
            if (y >= node.rect.h) break;
            _ = f.putTextInRect2(node.rect, 0, y, line, node.text_style);
            y += 1;
        }
    }

    fn drawInput(self: *App, f: *Frame, node: *ui.Node, a: std.mem.Allocator) !void {
        if (node.border != .none) f.drawBorder(node.rect, node.border, .{ .fg = .{ .semantic = if (self.mode == .insert) .focus else .border } }, node.title);
        const inner = node.innerRect();
        if (inner.empty()) return;
        f.clearRect(inner, .{});
        const width = inner.w;
        const lines = try self.editor.layout(a, width);
        const vc = try self.editor.visualCursor(a, width);
        _ = lines;
        var start: usize = 0;
        if (vc.row >= inner.h) start = vc.row - inner.h + 1;
        var row: u16 = 0;
        while (row < inner.h and start + row < vc.lines.len) : (row += 1) {
            const l = vc.lines[start + row];
            const content = self.editor.text.items[l.start..l.end];
            _ = f.putText(inner.x, inner.y + row, content, .{ .fg = .{ .semantic = .fg } }, inner.w);
        }
        if (self.mode == .insert) {
            self.cursor_x = inner.x + @as(u16, @intCast(@min(vc.col, width -| 1)));
            self.cursor_y = inner.y + @as(u16, @intCast(@min(vc.row - start, inner.h -| 1)));
            self.cursor_visible = true;
        }
        if (self.editor.text.items.len == 0) {
            _ = f.putText(inner.x, inner.y, "Ask, edit or use /help", .{ .fg = .{ .semantic = .muted }, .attrs = .{ .italic = true } }, inner.w);
        }
    }

    fn drawChat(self: *App, f: *Frame, node: *ui.Node, a: std.mem.Allocator) !void {
        if (node.border != .none) f.drawBorder(node.rect, node.border, .{ .fg = .{ .semantic = .border } }, node.title);
        const inner = node.innerRect();
        if (inner.empty()) return;
        f.clearRect(inner, .{});
        var b = chat.Builder.init(a, inner.w);
        try b.addConversation(&self.conversation);
        const total: usize = b.lines.items.len;
        const max_start: usize = if (total > inner.h) total - inner.h else 0;
        if (self.stick_bottom) self.chat_scroll = 0;
        if (self.chat_scroll > max_start) self.chat_scroll = @intCast(max_start);
        const end: usize = total -| self.chat_scroll;
        const start: usize = end -| inner.h;
        var row: u16 = 0;
        var i = start;
        while (i < end and row < inner.h) : (i += 1) {
            const line = b.lines.items[i];
            _ = f.putText(inner.x, inner.y + row, line.text, line.style, inner.w);
            row += 1;
        }
        if (self.agent_phase == .streaming and self.stick_bottom) {
            // Spinner in the border title area.
            const sp = "▍▌▋▊▉█▉▊▋▌";
            const idx = (self.spinner / 2) % sp.len;
            if (node.title) |title| {
                _ = title;
            }
            var buf = [_]u8{ sp[idx], 0 };
            _ = &buf;
        }
    }

    fn drawStatus(self: *App, f: *Frame, node: *ui.Node, a: std.mem.Allocator) !void {
        const st = Style{ .fg = .{ .semantic = .bg }, .bg = .{ .semantic = .focus }, .attrs = .{ .bold = true } };
        f.fillRect(node.rect, ' ', st);
        const usage = self.conversation.totalUsage();
        const mode_str = if (self.mode == .insert) "INSERT" else "NORMAL";
        const state_str = switch (self.agent_phase) {
            .idle => "idle",
            .streaming => "streaming",
            .awaiting_approval => "approval",
            .executing_tools => "tools",
            .failed => "failed",
            .cancelled => "cancelled",
        };
        const point = if (self.notice_until_ms > self.nowMs() and self.notice.len > 0) self.notice else "";
        const line = try std.fmt.allocPrint(a, " {s}  {s}  {s}  {s}  {s}{s}{s}", .{
            mode_str,
            self.model,
            state_str,
            self.cwd,
            if (usage.reported) try std.fmt.allocPrint(a, "{d} tok  ", .{usage.total()}) else "",
            if (self.notice_until_ms > self.nowMs() and self.notice.len > 0) "  • " else "",
            point,
        });
        _ = f.putText(node.rect.x, node.rect.y, line, st, node.rect.w);
    }

    fn drawSidebar(self: *App, f: *Frame, node: *ui.Node, a: std.mem.Allocator) !void {
        if (node.border != .none) f.drawBorder(node.rect, node.border, .{ .fg = .{ .semantic = .border } }, node.title);
        const inner = node.innerRect();
        if (inner.empty()) return;
        f.clearRect(inner, .{});
        var y: u16 = 0;
        const header = Style{ .fg = .{ .semantic = .primary }, .attrs = .{ .bold = true } };
        const muted = Style{ .fg = .{ .semantic = .muted } };
        _ = f.putText(inner.x, inner.y + y, "Workspace", header, inner.w);
        y += 1;
        _ = f.putText(inner.x, inner.y + y, truncatePath(self.cwd, inner.w), muted, inner.w);
        y += 2;
        _ = f.putText(inner.x, inner.y + y, "Session", header, inner.w);
        y += 1;
        _ = f.putText(inner.x, inner.y + y, self.session_id, muted, inner.w);
        y += 2;
        _ = f.putText(inner.x, inner.y + y, "Model", header, inner.w);
        y += 1;
        _ = f.putText(inner.x, inner.y + y, self.model, muted, inner.w);
        y += 2;
        _ = f.putText(inner.x, inner.y + y, "Stats", header, inner.w);
        y += 1;
        const usage = self.conversation.totalUsage();
        const stats = try std.fmt.allocPrint(a, "{d} messages\n{d} tokens", .{ self.conversation.messages.items.len, usage.total() });
        var sit = std.mem.splitScalar(u8, stats, '\n');
        while (sit.next()) |line| {
            _ = f.putText(inner.x, inner.y + y, line, muted, inner.w);
            y += 1;
        }
        y += 1;
        _ = f.putText(inner.x, inner.y + y, "Keys", header, inner.w);
        y += 1;
        _ = f.putText(inner.x, inner.y + y, "Ctrl-P palette", muted, inner.w);
        y += 1;
        _ = f.putText(inner.x, inner.y + y, "F1 help", muted, inner.w);
    }

    fn drawPalette(self: *App, f: *Frame, a: std.mem.Allocator) !void {
        const w: u16 = @min(self.size.cols -| 4, 72);
        const h: u16 = @min(self.size.rows -| 4, @as(u16, @intCast(@min(@as(usize, 20), self.palette.filtered.items.len + 4))));
        const x: u16 = (self.size.cols -| w) / 2;
        const y: u16 = (self.size.rows -| h) / 2;
        const r = Rect{ .x = x, .y = y, .w = w, .h = h };
        f.fillRect(r, ' ', .{ .bg = .{ .semantic = .selection } });
        f.drawBorder(r, .rounded, .{ .fg = .{ .semantic = .focus } }, "Commands");
        const inner = r.inner();
        const q = try std.fmt.allocPrint(a, "› {s}▏", .{self.palette.query.items});
        _ = f.putText(inner.x, inner.y, q, .{ .fg = .{ .semantic = .fg } }, inner.w);
        var i: usize = 0;
        while (i + 1 < inner.h and i < self.palette.filtered.items.len) : (i += 1) {
            const cmd = commands[self.palette.filtered.items[i]];
            const selected = i == self.palette.selected;
            const st = if (selected)
                Style{ .fg = .{ .semantic = .bg }, .bg = .{ .semantic = .focus } }
            else
                Style{ .fg = .{ .semantic = .fg } };
            if (selected) f.clearRect(.{ .x = inner.x, .y = inner.y + 1 + @as(u16, @intCast(i)), .w = inner.w, .h = 1 }, st);
            const line = try std.fmt.allocPrint(a, " {s:<14} {s}", .{ cmd.name, cmd.description });
            _ = f.putText(inner.x, inner.y + 1 + @as(u16, @intCast(i)), line, st, inner.w);
        }
    }

    fn drawHelp(self: *App, f: *Frame, a: std.mem.Allocator) !void {
        const w: u16 = @min(self.size.cols -| 4, 84);
        const h: u16 = @min(self.size.rows -| 4, 30);
        const x: u16 = (self.size.cols -| w) / 2;
        const y: u16 = (self.size.rows -| h) / 2;
        const r = Rect{ .x = x, .y = y, .w = w, .h = h };
        f.fillRect(r, ' ', .{ .bg = .{ .semantic = .selection } });
        f.drawBorder(r, .rounded, .{ .fg = .{ .semantic = .focus } }, "bloob help");
        const inner = r.inner();
        const lines = [_][]const u8{
            "bloob — a Lua-programmable terminal coding agent",
            "",
            "Global",
            "  Ctrl-P          command palette",
            "  Ctrl-R          reload Lua config (next milestone)",
            "  Ctrl-Q          quit",
            "  F1              this help",
            "  Esc             insert/normal mode",
            "",
            "Prompt",
            "  Enter / Ctrl-S  send",
            "  Alt-Enter       insert newline (Ctrl-J also works)",
            "  Ctrl-A / Ctrl-E line start/end",
            "  Ctrl-W          delete word",
            "  Ctrl-U / Ctrl-K delete to line start/end",
            "  Tab / Shift-Tab cycle focus, Enter activates focused button",
            "",
            "Conversation",
            "  PageUp/PageDown scroll",
            "  Ctrl-L          jump to latest",
            "  Mouse wheel     scroll",
            "",
            "Slash commands: /help /theme /model /tools /files /new /clear /quit",
            "",
            "Rendering is currently the native fallback layout; the declarative",
            "Lua UI layer is the next milestone.",
        };
        var i: usize = 0;
        while (i < lines.len) : (i += 1) {
            if (i < self.help.scroll) continue;
            const row = i - self.help.scroll;
            if (row >= inner.h) break;
            const st = if (std.mem.endsWith(u8, lines[i], ":") or (lines[i].len > 0 and lines[i][lines[i].len - 1] == ':'))
                Style{ .fg = .{ .semantic = .primary }, .attrs = .{ .bold = true } }
            else
                Style{ .fg = .{ .semantic = .fg } };
            _ = f.putText(inner.x, inner.y + @as(u16, @intCast(row)), lines[i], st, inner.w);
        }
        _ = a;
    }
};

fn truncatePath(path: []const u8, width: u16) []const u8 {
    if (text.displayWidth(path) <= width) return path;
    if (width <= 3) return path[path.len -| width ..];
    var start = path.len;
    var w: usize = 0;
    while (start > 0) {
        const p = start - 1;
        var b = p;
        while (b > 0 and (path[b] & 0xC0) == 0x80) b -= 1;
        const d = text.decode(path, b);
        if (w + text.codepointWidth(d.cp) + 3 > width) break;
        w += text.codepointWidth(d.cp);
        start = b;
    }
    return path[start..];
}
