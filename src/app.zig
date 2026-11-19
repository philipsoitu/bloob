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
const lua_runtime = @import("lua/runtime.zig");
const workspace_mod = @import("core/workspace.zig");
const permissions = @import("tools/permissions.zig");
const tools = @import("tools/tools.zig");
const provider_stream = @import("providers/stream.zig");
const provider_registry = @import("providers/registry.zig");
const provider_request = @import("providers/request.zig");
const prompts = @import("agent/prompts.zig");
const env = @import("env.zig");

const Frame = frame_mod.Frame;
const Rect = frame_mod.Rect;
const Style = style.Style;

pub const Mode = enum { insert, normal };
pub const AgentPhase = enum { idle, streaming, awaiting_approval, executing_tools, failed, cancelled };

pub const PendingTool = struct {
    id: []u8,
    name: []u8,
    args: []u8,

    pub fn deinit(self: *PendingTool, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.args);
    }
};

pub const MockTool = struct {
    name: []u8,
    args: []u8,

    pub fn deinit(self: *MockTool, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.args);
    }
};

pub const ApprovalChoice = enum { deny, allow_once, allow_session };

pub const Approval = struct {
    tool: PendingTool,
    preview: tools.Preview,
    choice: ApprovalChoice = .deny,
    scroll: u16 = 0,

    pub fn deinit(self: *Approval, gpa: std.mem.Allocator) void {
        self.tool.deinit(gpa);
        self.preview.deinit(gpa);
    }
};

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
    lua: ?*lua_runtime.Runtime = null,
    lua_config_path: ?[]u8 = null,
    lua_config_error: ?[]u8 = null,
    reload_requested: bool = false,
    lua_layout_failed: bool = false,
    command_depth: u8 = 0,
    workspace: ?workspace_mod.Workspace = null,
    permission_engine: permissions.Engine = undefined,
    pending_tools: std.ArrayList(PendingTool) = .empty,
    tool_index: usize = 0,
    tool_iterations: u32 = 0,
    approval: ?Approval = null,
    mock_tool: ?MockTool = null,
    last_tool_summary: []u8 = &.{},
    provider_stream: ?*provider_stream.Stream = null,
    provider_emit_pos: usize = 0,

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
            .permission_engine = permissions.Engine.init(gpa),
        };
        self.model = try gpa.dupe(u8, opts.model orelse "mock/fixture");
        self.provider = try gpa.dupe(u8, if (std.mem.indexOfScalar(u8, self.model, '/')) |i| self.model[0..i] else "mock");
        self.theme_name = try gpa.dupe(u8, opts.theme_name orelse "default");
        _ = self.themes.set(self.theme_name);
        self.cwd = try gpa.dupe(u8, opts.cwd orelse ".");
        self.session_id = try gpa.dupe(u8, "local");
        self.workspace = workspace_mod.Workspace.init(gpa, io, self.cwd) catch null;
        if (self.workspace) |*w| self.permission_engine.workspace = w;
        self.mock_mode = std.mem.startsWith(u8, self.provider, "mock") or std.mem.startsWith(u8, self.provider, "fixture");
        return self;
    }

    pub fn initLua(self: *App, explicit_config: ?[]const u8, no_config: bool) void {
        var path: ?[]u8 = null;
        var explicit = false;
        if (!no_config) {
            if (explicit_config) |p| {
                path = self.gpa.dupe(u8, p) catch null;
                explicit = true;
            } else if (defaultConfigPath(self.gpa)) |p| {
                if (fileExists(self.io, p)) path = p else self.gpa.free(p);
            }
        }
        self.lua_config_path = path;
        const lua_host = self.host();
        const rt = lua_runtime.Runtime.init(self.gpa, self.io, lua_host) catch |err| {
            const msg = std.fmt.allocPrint(self.gpa, "Lua runtime unavailable: {s}",  .{@errorName(err)}) catch "Lua runtime unavailable";
            defer self.gpa.free(msg);
            self.notify(msg, true);
            return;
        };
        var ok = true;
        if (path) |p| {
            rt.loadConfig(p) catch {
                const msg = self.gpa.dupe(u8, rt.lastError()) catch null;
                ok = false;
                if (self.lua_config_error) |old| self.gpa.free(old);
                self.lua_config_error = msg;
            };
        } else if (explicit) {
            ok = false;
            self.notify("Config file not found", true);
        }
        if (!ok) {
            rt.deinit();
            const fallback = lua_runtime.Runtime.init(self.gpa, self.io, lua_host) catch |err| {
                const msg = std.fmt.allocPrint(self.gpa, "Lua runtime unavailable: {s}",  .{@errorName(err)}) catch "Lua runtime unavailable";
                defer self.gpa.free(msg);
                self.notify(msg, true);
                return;
            };
            self.lua = fallback;
            if (self.lua_config_error) |msg| {
                self.notify(msg, true);
            } else {
                self.notify("Configuration failed; using safe defaults", true);
            }
        } else {
            self.lua = rt;
            var srcs = std.ArrayList(u8).empty;
            defer srcs.deinit(self.gpa);
            for (rt.configSources(), 0..) |s, i| {
                if (i > 0) srcs.appendSlice(self.gpa, ", ") catch {};
                srcs.appendSlice(self.gpa, s) catch {};
            }
            if (srcs.items.len > 0) self.notify("Loaded config", false);
        }
        self.dirty = true;
    }

    fn host(self: *App) lua_runtime.Host {
        return .{
            .ctx = self,
            .notify = hostNotify,
            .request_render = hostRender,
            .quit = hostQuit,
            .set_model = hostSetModel,
            .set_theme = hostSetTheme,
            .register_theme = hostRegisterTheme,
            .run_command = hostRunCommand,
            .request_reload = hostReload,
            .read_file = hostReadFile,
        };
    }

    pub fn setModel(self: *App, model: []const u8) void {
        const owned = self.gpa.dupe(u8, model) catch return;
        if (self.model.len > 0) self.gpa.free(self.model);
        self.model = owned;
        const slash = std.mem.indexOfScalar(u8, self.model, '/');
        if (self.provider.len > 0) self.gpa.free(self.provider);
        const provider_name = if (slash) |idx| self.model[0..idx] else "mock";
        self.provider = self.gpa.dupe(u8, provider_name) catch (self.gpa.dupe(u8, "mock") catch return);
        self.mock_mode = std.mem.startsWith(u8, self.provider, "mock") or std.mem.startsWith(u8, self.provider, "fixture");
        self.dirty = true;
    }

    pub fn reloadLua(self: *App) void {
        const old_theme = self.gpa.dupe(u8, self.theme_name) catch null;
        const old_model = self.gpa.dupe(u8, self.model) catch null;
        const lua_host = self.host();
        const candidate = lua_runtime.Runtime.init(self.gpa, self.io, lua_host) catch |err| {
            const msg = std.fmt.allocPrint(self.gpa, "reload failed: {s}",  .{@errorName(err)}) catch "reload failed";
            defer self.gpa.free(msg);
            self.notify(msg, true);
            return;
        };
        var ok = true;
        if (self.lua_config_path) |p| {
            candidate.loadConfig(p) catch {
                ok = false;
                self.notify(candidate.lastError(), true);
            };
        }
        if (ok) {
            var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_inst.deinit();
            _ = candidate.buildLayout(arena_inst.allocator(), self.snapshot()) catch {
                ok = false;
                self.notify(candidate.lastError(), true);
            };
        }
        if (!ok) {
            candidate.deinit();
            if (old_theme) |t| {
                if (self.themes.set(t)) {
                    if (self.theme_name.len > 0) self.gpa.free(self.theme_name);
                    self.theme_name = self.gpa.dupe(u8, t) catch &.{};
                }
            }
            if (old_model) |m| self.setModel(m);
            if (old_theme) |t| self.gpa.free(t);
            if (old_model) |m| self.gpa.free(m);
            self.notify("Reload failed; previous configuration kept", true);
            return;
        }
        if (old_theme) |t| self.gpa.free(t);
        if (old_model) |m| self.gpa.free(m);
        if (self.lua) |old| old.deinit();
        self.lua = candidate;
        self.focus_buttons.clearRetainingCapacity();
        self.buttons.clearRetainingCapacity();
        self.focus_index = 0;
        if (self.lua_config_error) |e| {
            self.gpa.free(e);
            self.lua_config_error = null;
        }
        self.notify("Configuration reloaded", false);
        self.dirty = true;
    }

    pub fn snapshot(self: *App) lua_runtime.WidgetContext {
        const usage = self.conversation.totalUsage();
        return .{
            .width = self.size.cols,
            .height = self.size.rows,
            .cwd = self.cwd,
            .model = self.model,
            .provider = self.provider,
            .theme = self.theme_name,
            .mode = if (self.mode == .insert) "insert" else "normal",
            .state = switch (self.agent_phase) {
                .idle => "idle",
                .streaming => "streaming",
                .awaiting_approval => "awaiting_approval",
                .executing_tools => "executing_tools",
                .failed => "failed",
                .cancelled => "cancelled",
            },
            .session_id = self.session_id,
            .busy = self.agent_phase == .streaming or self.agent_phase == .executing_tools,
            .message_count = self.conversation.messages.items.len,
            .prompt_tokens = usage.prompt_tokens,
            .completion_tokens = usage.completion_tokens,
        };
    }

    pub fn deinit(self: *App) void {
        if (self.provider_stream) |s| s.deinit();
        if (self.approval) |*a| a.deinit(self.gpa);
        for (self.pending_tools.items) |*p| p.deinit(self.gpa);
        self.pending_tools.deinit(self.gpa);
        if (self.last_tool_summary.len > 0) self.gpa.free(self.last_tool_summary);
        if (self.mock_tool) |*m| m.deinit(self.gpa);
        self.permission_engine.deinit();
        if (self.workspace) |*w| w.deinit();
        if (self.lua) |l| l.deinit();
        if (self.lua_config_path) |p| self.gpa.free(p);
        if (self.lua_config_error) |e| self.gpa.free(e);
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
        if (self.workspace) |*w| self.permission_engine.workspace = w;
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
            if (self.reload_requested) {
                self.reload_requested = false;
                self.reloadLua();
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
            var fds: [3]std.posix.pollfd = undefined;
            var nfds: usize = 1;
            fds[0] = .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN };
            if (self.provider_stream) |s| {
                if (s.stdoutFd()) |fd| {
                    fds[nfds] = .{ .fd = fd, .events = std.posix.POLL.IN };
                    nfds += 1;
                }
                if (s.stderrFd()) |fd| {
                    fds[nfds] = .{ .fd = fd, .events = std.posix.POLL.IN };
                    nfds += 1;
                }
            }
            _ = std.posix.poll(fds[0..nfds], timeout) catch continue;
            if (nfds > 1) {
                var provider_ready = false;
                var pi: usize = 1;
                while (pi < nfds) : (pi += 1) {
                    if (fds[pi].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) provider_ready = true;
                }
                if (provider_ready) self.pumpProvider();
            }
            if (self.provider_stream != null and self.provider_stream.?.acc.done) self.syncProvider();
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
        var tool_proposed = false;
        if (self.stream_msg_index) |idx| {
            if (idx < self.conversation.messages.items.len) {
                const m = &self.conversation.messages.items[idx];
                m.streaming = false;
                if (cancelled) {
                    m.text.appendSlice(self.gpa, "\n\n_[cancelled]_") catch {};
                } else if (self.mock_tool) |mt| {
                    const call_id = std.fmt.allocPrint(self.gpa, "call_{d}", .{self.conversation.next_id}) catch "call_0";
                    defer self.gpa.free(call_id);
                    m.addToolCall(self.gpa, call_id, mt.name, mt.args) catch {};
                    tool_proposed = true;
                }
            }
        }
        self.stream_msg_index = null;
        self.stream_pos = 0;
        if (self.stream_text.len > 0) {
            self.gpa.free(self.stream_text);
            self.stream_text = &.{};
        }
        if (self.mock_tool) |*m| m.deinit(self.gpa);
        self.mock_tool = null;
        if (tool_proposed) {
            self.agent_phase = .executing_tools;
            self.beginToolLoop();
        } else {
            self.agent_phase = if (cancelled) .cancelled else .idle;
        }
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

    fn tryLuaKeymap(self: *App, k: key.Key) bool {
        if (k.code == .char and k.mods.ctrl and (k.char == 'c' or k.char == 'q')) return false;
        const l = self.lua orelse return false;
        const mode_str = if (self.mode == .insert) "insert" else "normal";
        const entry = l.findKey(mode_str, k) orelse return false;
        switch (entry.action) {
            .command => |c| {
                self.runCommand(c.name, "") catch |err| {
                    const msg = std.fmt.allocPrint(self.gpa, "keymap command failed: {s}",  .{@errorName(err)}) catch "keymap command failed";
                    defer self.gpa.free(msg);
                    self.notify(msg, true);
                };
            },
            .callback => |cb| {
                _ = l.invokeCallback(cb.ref);
            },
        }
        self.dirty = true;
        return true;
    }

    fn activateButton(self: *App, ref: i32) void {
        if (self.lua) |l| {
            _ = l.invokeCallback(ref);
            self.dirty = true;
        }
    }

    fn handleCtrlC(self: *App) void {
        if (self.approval != null) {
            self.denyApproval();
            self.notify("Tool call denied", false);
            return;
        }
        const now = self.nowMs();
        if (self.agent_phase == .streaming) {
            if (self.cancelProvider()) {
                self.notify("Request cancelled", false);
            } else {
                self.finishStreaming(true);
                self.notify("Request cancelled", false);
            }
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
        if (self.approval != null) {
            self.handleApprovalKey(k);
            return;
        }
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
                    self.reload_requested = true;
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
            if (self.tryLuaKeymap(k)) return;
            try self.handleNormalKey(k);
            return;
        }
        if (self.tryLuaKeymap(k)) return;
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
        if (self.focus_buttons.items.len == 0) {
            self.mode = .insert;
            return;
        }
        if (self.focus_index >= self.focus_buttons.items.len) self.focus_index = 0;
        const fi = self.focus_buttons.items[self.focus_index];
        switch (fi.kind) {
            .input => self.mode = .insert,
            .button => if (fi.ref) |ref| self.activateButton(ref),
        }
    }

    fn focusedButton(self: *App, node: *ui.Node) bool {
        if (self.focus_buttons.items.len == 0) return false;
        if (self.focus_index >= self.focus_buttons.items.len) return false;
        const fi = self.focus_buttons.items[self.focus_index];
        if (fi.kind != .button) return false;
        if (fi.ref != null and node.button_ref != null) return fi.ref.? == node.button_ref.?;
        return node.id.len > 0 and std.mem.eql(u8, fi.id, node.id);
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
            try self.startProviderRequest();
        }
        self.dirty = true;
    }

    fn jsonEscapeDup(self: *App, value: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.gpa);
        try appendJsonStringPublic(self.gpa, &out, value);
        return out.toOwnedSlice(self.gpa);
    }

    fn detectMockTool(self: *App, prompt: []const u8) ?MockTool {
        const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "read ")) {
            const path = std.mem.trim(u8, trimmed[5..], " ");
            if (path.len == 0) return null;
            const inner = self.jsonInnerDup(path) catch return null;
            defer self.gpa.free(inner);
            return .{
                .name = self.gpa.dupe(u8, "read_file") catch return null,
                .args = std.fmt.allocPrint(self.gpa, "{{\"path\":\"{s}\"}}", .{inner}) catch return null,
            };
        }
        if (std.mem.startsWith(u8, trimmed, "list files")) {
            return .{
                .name = self.gpa.dupe(u8, "list_files") catch return null,
                .args = self.gpa.dupe(u8, "{\"recursive\":true,\"max_entries\":200}") catch return null,
            };
        }
        if (std.mem.startsWith(u8, trimmed, "create ")) {
            const path = std.mem.trim(u8, trimmed[7..], " ");
            if (path.len == 0) return null;
            const p = self.jsonInnerDup(path) catch return null;
            defer self.gpa.free(p);
            const c = self.jsonInnerDup("Created by the bloob offline fixture.\n") catch return null;
            defer self.gpa.free(c);
            return .{
                .name = self.gpa.dupe(u8, "write_file") catch return null,
                .args = std.fmt.allocPrint(self.gpa, "{{\"path\":\"{s}\",\"content\":\"{s}\"}}", .{ p, c }) catch return null,
            };
        }
        if (std.mem.startsWith(u8, trimmed, "run ")) {
            const command = std.mem.trim(u8, trimmed[4..], " ");
            if (command.len == 0) return null;
            const inner = self.jsonInnerDup(command) catch return null;
            defer self.gpa.free(inner);
            return .{
                .name = self.gpa.dupe(u8, "shell") catch return null,
                .args = std.fmt.allocPrint(self.gpa, "{{\"command\":\"{s}\",\"timeout_ms\":15000}}", .{inner}) catch return null,
            };
        }
        return null;
    }

    fn jsonInnerDup(self: *App, value: []const u8) ![]u8 {
        const quoted = try self.jsonEscapeDup(value);
        defer self.gpa.free(quoted);
        if (quoted.len < 2) return self.gpa.dupe(u8, "");
        return self.gpa.dupe(u8, quoted[1 .. quoted.len - 1]);
    }
    fn beginToolLoop(self: *App) void {
        self.tool_iterations += 1;
        if (self.tool_iterations > 8) {
            self.notify("Tool iteration limit reached; stopping this turn", true);
            self.agent_phase = .failed;
            return;
        }
        for (self.pending_tools.items) |*p| p.deinit(self.gpa);
        self.pending_tools.clearRetainingCapacity();
        const last = self.conversation.last() orelse return;
        if (last.role != .assistant or last.tool_calls.items.len == 0) {
            self.finishTurnIdle();
            return;
        }
        for (last.tool_calls.items) |tc| {
            self.pending_tools.append(self.gpa, .{
                .id = self.gpa.dupe(u8, tc.id) catch continue,
                .name = self.gpa.dupe(u8, tc.name) catch continue,
                .args = self.gpa.dupe(u8, tc.args) catch continue,
            }) catch continue;
        }
        self.tool_index = 0;
        self.dirty = true;
        self.processNextTool();
    }

    fn finishTurnIdle(self: *App) void {
        if (self.agent_phase != .cancelled and self.agent_phase != .failed) self.agent_phase = .idle;
        self.tool_iterations = 0;
        self.dirty = true;
    }

    fn processNextTool(self: *App) void {
        if (self.tool_index >= self.pending_tools.items.len) {
            self.continueAfterTools();
            return;
        }
        const call = self.pending_tools.items[self.tool_index];
        const ctx = self.toolContext() orelse {
            self.appendToolMessage(call, "Workspace unavailable", true);
            self.tool_index += 1;
            self.processNextTool();
            return;
        };
        var prev = tools.preview(ctx, call.name, call.args);
        defer prev.deinit(self.gpa);
        var cap: permissions.Capability = .custom;
        if (tools.findDef(call.name)) |def| cap = def.capability;
        var decision = self.permission_engine.evaluate(.{
            .tool = call.name,
            .capability = cap,
            .paths = prev.paths,
            .command = prev.command,
            .summary = prev.summary,
            .diff = prev.diff,
        });
        if (self.lua) |l| {
            const tool_esc = self.jsonInnerDup(call.name) catch "";
            defer if (tool_esc.len > 0) self.gpa.free(tool_esc);
            const args_esc = self.jsonInnerDup(call.args) catch "";
            defer if (args_esc.len > 0) self.gpa.free(args_esc);
            const payload = std.fmt.allocPrint(self.gpa, "{{\"tool\":\"{s}\",\"arguments\":\"{s}\",\"summary\":\"{s}\"}}", .{ tool_esc, args_esc, self.jsonInnerDup(prev.summary) catch "" }) catch null;
            if (payload) |p| {
                defer self.gpa.free(p);
                switch (l.emit("tool.before_execute", p)) {
                    .deny => decision = .deny,
                    .ask => if (decision == .allow) {
                        decision = .ask;
                    },
                    .pass => {},
                }
            }
        }
        if (decision == .deny) {
            self.appendToolMessage(call, "Denied by the Zig permission policy.", true);
            self.tool_index += 1;
            self.processNextTool();
            return;
        }
        if (decision == .ask) {
            if (self.approval) |*a| a.deinit(self.gpa);
            self.approval = .{
                .tool = .{
                    .id = self.gpa.dupe(u8, call.id) catch "",
                    .name = self.gpa.dupe(u8, call.name) catch "",
                    .args = self.gpa.dupe(u8, call.args) catch "",
                },
                .preview = prev,
                .choice = .deny,
            };
            // Prevent double free of the preview that moved into the approval.
            prev = .{ .summary = "" };
            self.agent_phase = .awaiting_approval;
            self.notify("Tool approval required", false);
            self.dirty = true;
            return;
        }
        self.executeToolCall(call);
    }

    fn executeToolCall(self: *App, call: PendingTool) void {
        const ctx = self.toolContext() orelse {
            self.appendToolMessage(call, "Workspace unavailable", true);
            self.tool_index += 1;
            self.processNextTool();
            return;
        };
        self.agent_phase = .executing_tools;
        if (tools.findDef(call.name) != null) {
            var res = tools.execute(ctx, call.name, call.args);
            defer res.deinit(self.gpa);
            if (res.changed_path) |path| {
                if (self.lua) |l| self.emitFileWrite(l, path);
            }
            const content = if (res.diff) |d|
                std.fmt.allocPrint(self.gpa, "{s}\n\n{s}", .{ res.content, d }) catch res.content
            else
                res.content;
            const owned = content.ptr != res.content.ptr;
            defer if (owned) self.gpa.free(content);
            self.setLastToolSummary(res.summary);
            self.appendToolMessage(call, content, res.is_error);
        } else if (self.lua) |l| {
            if (l.toolByName(call.name)) |lt| {
                const out = l.invokeTool(lt, call.args);
                if (out) |json| {
                    defer self.gpa.free(json);
                    self.appendToolMessage(call, json, false);
                } else {
                    self.appendToolMessage(call, "Lua tool failed", true);
                }
            } else {
                self.appendToolMessage(call, "Unknown tool", true);
            }
        } else {
            self.appendToolMessage(call, "Unknown tool", true);
        }
        self.tool_index += 1;
        self.processNextTool();
    }

    fn emitFileWrite(self: *App, l: *lua_runtime.Runtime, path: []const u8) void {
        const esc = self.jsonEscapeDup(path) catch return;
        defer self.gpa.free(esc);
        const payload = std.fmt.allocPrint(self.gpa, "{{\"path\":\"{s}\"}}", .{esc}) catch return;
        defer self.gpa.free(payload);
        _ = l.emit("file.after_write", payload);
    }

    fn setLastToolSummary(self: *App, summary: []const u8) void {
        if (self.last_tool_summary.len > 0) self.gpa.free(self.last_tool_summary);
        self.last_tool_summary = self.gpa.dupe(u8, summary) catch &.{};
    }

    fn appendToolMessage(self: *App, call: PendingTool, content: []const u8, is_error: bool) void {
        const safe = @import("text.zig").sanitizeAlloc(self.gpa, content, 128 * 1024) catch self.gpa.dupe(u8, "tool output unavailable") catch "";
        defer if (safe.len > 0) self.gpa.free(safe);
        const m = self.conversation.add(.tool, safe, self.nowMs()) catch return;
        m.setToolResult(self.gpa, call.id, call.name, is_error) catch {};
        self.dirty = true;
    }

    fn toolContext(self: *App) ?tools.ToolContext {
        if (self.workspace) |*ws| {
            return .{ .gpa = self.gpa, .io = self.io, .workspace = ws };
        }
        return null;
    }

    fn continueAfterTools(self: *App) void {
        self.tool_iterations = 0;
        if (self.mock_mode) {
            const summary = if (self.last_tool_summary.len > 0) self.last_tool_summary else "Tool execution completed.";
            const msg = std.fmt.allocPrint(self.gpa, "Fixture tool loop complete. {s}\n\nThe result is shown above. No model was contacted; this is the deterministic offline fixture.", .{summary}) catch "Fixture tool loop complete.";
            defer self.gpa.free(msg);
            _ = self.conversation.add(.assistant, msg, self.nowMs()) catch {};
            self.agent_phase = .idle;
            self.dirty = true;
            return;
        }
        self.startProviderRequest() catch |err| {
            const msg = std.fmt.allocPrint(self.gpa, "provider request failed: {s}", .{@errorName(err)}) catch "provider request failed";
            defer self.gpa.free(msg);
            self.notify(msg, true);
            self.agent_phase = .failed;
        };
    }

    fn collectToolSchemas(self: *App) ![]provider_request.ToolSchema {
        var list = std.ArrayList(provider_request.ToolSchema).empty;
        errdefer list.deinit(self.gpa);
        for (&tools.defs) |*d| {
            try list.append(self.gpa, .{
                .name = d.name,
                .description = d.description,
                .schema_json = d.schema,
            });
        }
        if (self.lua) |l| {
            for (l.tools.items) |t| {
                try list.append(self.gpa, .{
                    .name = t.name,
                    .description = t.description,
                    .schema_json = t.schema_json,
                });
            }
        }
        return list.toOwnedSlice(self.gpa);
    }

    fn providerErrorMessage(self: *App, err: anyerror) []const u8 {
        _ = self;
        return switch (err) {
            error.MissingApiKey => "API key is not set. Export OPENAI_API_KEY or ANTHROPIC_API_KEY (or use --model mock/fixture).",
            error.MissingBaseUrl => "BLOOB_COMPAT_BASE_URL is not set for the compatible provider.",
            error.InvalidModel => "Model must be provider/model (for example openai/<model-id>).",
            error.UnsupportedProvider => "Unsupported provider. Supported: mock, openai, anthropic, compat.",
            else => "Provider configuration error.",
        };
    }

    fn startProviderRequest(self: *App) !void {
        if (self.mock_mode) return;
        var resolved = provider_registry.resolve(self.gpa, self.model) catch |err| {
            const message = std.fmt.allocPrint(self.gpa, "[provider error] {s}", .{self.providerErrorMessage(err)}) catch "[provider error]";
            defer self.gpa.free(message);
            const m = self.conversation.add(.assistant, message, self.nowMs()) catch return;
            m.usage = .{};
            self.agent_phase = .failed;
            self.notify(message, true);
            return;
        };
        defer resolved.deinit();
        const schemas = self.collectToolSchemas() catch return error.OutOfMemory;
        defer self.gpa.free(schemas);
        const system = prompts.systemPrompt(self.gpa, self.workspaceRoot()) catch return error.OutOfMemory;
        defer self.gpa.free(system);
        const body = switch (resolved.kind) {
            .openai => provider_request.buildOpenAi(self.gpa, resolved.model, system, &self.conversation, schemas) catch return error.OutOfMemory,
            .anthropic => provider_request.buildAnthropic(self.gpa, resolved.model, system, &self.conversation, schemas, 8192) catch return error.OutOfMemory,
        };
        defer self.gpa.free(body);
        const s = provider_stream.Stream.start(self.gpa, self.io, resolved.kind, resolved.url, resolved.api_key, body) catch |err| {
            const msg = std.fmt.allocPrint(self.gpa, "Failed to start provider transport: {s}", .{@errorName(err)}) catch "Failed to start provider transport";
            defer self.gpa.free(msg);
            self.notify(msg, true);
            self.agent_phase = .failed;
            return err;
        };
        if (self.provider_stream) |old| old.deinit();
        self.provider_stream = s;
        self.provider_emit_pos = 0;
        const idx = self.conversation.messages.items.len;
        _ = self.conversation.addEmpty(.assistant, self.nowMs()) catch {
            s.deinit();
            self.provider_stream = null;
            return error.OutOfMemory;
        };
        self.conversation.messages.items[idx].streaming = true;
        self.conversation.messages.items[idx].setModel(self.gpa, self.model) catch {};
        self.stream_msg_index = idx;
        self.agent_phase = .streaming;
        self.last_stream_ms = self.nowMs();
        self.stick_bottom = true;
        self.chat_scroll = 0;
        self.dirty = true;
        if (self.lua) |l| {
            const model_esc = self.jsonInnerDup(self.model) catch "";
            defer if (model_esc.len > 0) self.gpa.free(model_esc);
            const payload = std.fmt.allocPrint(self.gpa, "{{\"model\":\"{s}\"}}", .{model_esc}) catch null;
            if (payload) |p| {
                defer self.gpa.free(p);
                _ = l.emit("model.before_request", p);
            }
        }
    }

    fn workspaceRoot(self: *App) []const u8 {
        if (self.workspace) |*w| return w.root;
        return self.cwd;
    }

    fn pumpProvider(self: *App) void {
        if (self.provider_stream) |s| {
            s.pump();
            self.syncProvider();
        }
    }

    fn syncProvider(self: *App) void {
        const s = self.provider_stream orelse return;
        if (self.stream_msg_index) |idx| {
            if (idx < self.conversation.messages.items.len) {
                if (self.provider_emit_pos < s.acc.text.items.len) {
                    const msg = &self.conversation.messages.items[idx];
                    msg.text.appendSlice(self.gpa, s.acc.text.items[self.provider_emit_pos..]) catch {};
                    self.provider_emit_pos = s.acc.text.items.len;
                    if (self.stick_bottom) self.chat_scroll = 0;
                    self.dirty = true;
                }
                const msg = &self.conversation.messages.items[idx];
                if (s.acc.usage.reported) msg.usage = s.acc.usage;
            }
        }
        if (s.acc.done) self.finalizeProvider();
    }

    fn finalizeProvider(self: *App) void {
        const s = self.provider_stream orelse return;
        self.provider_stream = null;
        var cancelled = false;
        _ = &cancelled;
        var had_tools = false;
        if (self.stream_msg_index) |idx| {
            if (idx < self.conversation.messages.items.len) {
                const msg = &self.conversation.messages.items[idx];
                msg.streaming = false;
                msg.usage = s.acc.usage;
                if (s.acc.error_message) |err| {
                    if (msg.text.items.len > 0) msg.text.appendSlice(self.gpa, "\n\n") catch {};
                    msg.text.appendSlice(self.gpa, "[provider error] ") catch {};
                    msg.text.appendSlice(self.gpa, err) catch {};
                }
                for (s.acc.tool_calls.items) |tc| {
                    if (tc.name.items.len == 0) continue;
                    const call_id = if (tc.id.items.len > 0) tc.id.items else std.fmt.allocPrint(self.gpa, "call_{d}", .{self.conversation.next_id}) catch "call_0";
                    defer if (tc.id.items.len == 0) self.gpa.free(call_id);
                    const args = if (tc.args.items.len > 0) tc.args.items else "{}";
                    msg.addToolCall(self.gpa, call_id, tc.name.items, args) catch {};
                    had_tools = true;
                }
            }
        }
        const err = s.acc.error_message;
        const finish = s.acc.finish_reason;
        _ = finish;
        if (err) |e| {
            const msg = std.fmt.allocPrint(self.gpa, "Provider error: {s}", .{e}) catch "Provider error";
            defer self.gpa.free(msg);
            self.notify(msg, true);
        }
        self.stream_msg_index = null;
        self.provider_emit_pos = 0;
        s.deinit();
        if (err != null) {
            self.agent_phase = .failed;
        } else if (had_tools) {
            self.agent_phase = .executing_tools;
            self.beginToolLoop();
        } else {
            self.agent_phase = .idle;
            if (self.lua) |l| {
                const usage = self.conversation.totalUsage();
                const payload = std.fmt.allocPrint(self.gpa, "{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"reported\":{s}}}", .{ usage.prompt_tokens, usage.completion_tokens, if (usage.reported) "true" else "false" }) catch null;
                if (payload) |p| {
                    defer self.gpa.free(p);
                    _ = l.emit("model.usage", p);
                }
            }
        }
        self.dirty = true;
    }

    fn cancelProvider(self: *App) bool {
        const s = self.provider_stream orelse return false;
        self.provider_stream = null;
        s.deinit();
        if (self.stream_msg_index) |idx| {
            if (idx < self.conversation.messages.items.len) {
                const msg = &self.conversation.messages.items[idx];
                msg.streaming = false;
                if (msg.text.items.len > 0) msg.text.appendSlice(self.gpa, "\n\n") catch {};
                msg.text.appendSlice(self.gpa, "_[cancelled]_") catch {};
            }
        }
        self.stream_msg_index = null;
        self.provider_emit_pos = 0;
        self.agent_phase = .cancelled;
        self.dirty = true;
        return true;
    }
    fn denyApproval(self: *App) void {
        const a = self.approval orelse return;
        var approval = a;
        self.approval = null;
        self.appendToolMessage(approval.tool, "Denied by the user.", true);
        approval.deinit(self.gpa);
        self.tool_index += 1;
        self.agent_phase = .executing_tools;
        self.processNextTool();
    }

    fn confirmApproval(self: *App) void {
        const a = self.approval orelse return;
        var approval = a;
        self.approval = null;
        switch (approval.choice) {
            .deny => {
                self.appendToolMessage(approval.tool, "Denied by the user.", true);
                approval.deinit(self.gpa);
                self.tool_index += 1;
                self.agent_phase = .executing_tools;
                self.processNextTool();
            },
            .allow_once, .allow_session => {
                if (approval.choice == .allow_session) self.permission_engine.allowSession(approval.tool.name);
                const id = self.gpa.dupe(u8, approval.tool.id) catch {
                    approval.deinit(self.gpa);
                    return;
                };
                const name = self.gpa.dupe(u8, approval.tool.name) catch {
                    self.gpa.free(id);
                    approval.deinit(self.gpa);
                    return;
                };
                const args = self.gpa.dupe(u8, approval.tool.args) catch {
                    self.gpa.free(id);
                    self.gpa.free(name);
                    approval.deinit(self.gpa);
                    return;
                };
                approval.deinit(self.gpa);
                const copied = PendingTool{ .id = id, .name = name, .args = args };
                defer {
                    var c = copied;
                    c.deinit(self.gpa);
                }
                self.executeToolCall(copied);
            },
        }
    }
    fn handleApprovalKey(self: *App, k: key.Key) void {
        const a = &(self.approval orelse return);
        switch (k.code) {
            .esc => self.denyApproval(),
            .char => {
                if (k.mods.ctrl) return;
                switch (k.char) {
                    'a' => {
                        a.choice = .allow_once;
                        self.confirmApproval();
                    },
                    's' => {
                        a.choice = .allow_session;
                        self.confirmApproval();
                    },
                    'd', 'n' => self.denyApproval(),
                    else => {},
                }
            },
            .left, .right, .tab => {
                a.choice = switch (a.choice) {
                    .deny => if (k.code == .right or k.code == .tab) .allow_once else .allow_session,
                    .allow_once => if (k.code == .right or k.code == .tab) .allow_session else .deny,
                    .allow_session => if (k.code == .right or k.code == .tab) .deny else .allow_once,
                };
                self.dirty = true;
            },
            .enter => self.confirmApproval(),
            .page_up => {
                a.scroll -|= 5;
                self.dirty = true;
            },
            .page_down => {
                a.scroll +|= 5;
                self.dirty = true;
            },
            else => {},
        }
    }

    fn startMock(self: *App, prompt: []const u8) !void {
        if (self.mock_tool) |*m| m.deinit(self.gpa);
        self.mock_tool = self.detectMockTool(prompt);
        const suffix: []const u8 = if (self.mock_tool != null)
            "\n\n_The fixture is proposing a tool call. Approval and results are handled by the real Zig tool engine._\n"
        else
            "\n\n- Lua configuration and the composable UI are next.\n- Try `/help`, `/theme catppuccin`, or `/tools`.\n";
        const response = try std.fmt.allocPrint(self.gpa,
            "You said:\n\n> {s}\n\nThis response is produced by bloob's deterministic **fixture provider**. It streams in small deltas so the UI, cancellation and persistence paths can be tested without network access.\n\n```zig\nconst std = @import(\"std\");\npub fn main() !void {{\n    std.debug.print(\"hello from bloob\\n\", .{{}});\n}}\n```{s}", .{ truncatePrompt(prompt), suffix });
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
                self.setModel(args);
                self.notify("Model selected", false);
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
            self.reload_requested = true;
        } else if (std.mem.eql(u8, name, "doctor")) {
            self.help.active = true;
            self.help.scroll = 0;
            self.notify("Doctor: see help overlay", false);
        } else if (std.mem.eql(u8, name, "export")) {
            self.notify("Session persistence is coming next", false);
        } else {
            if (self.lua) |l| {
                if (l.runCommand(name, args)) {
                    self.dirty = true;
                    return;
                }
            }
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

    fn commandTotal(self: *App) usize {
        const extra = if (self.lua) |l| l.commandCount() else 0;
        return commands.len + extra;
    }

    fn commandNameAt(self: *App, i: usize) []const u8 {
        if (i < commands.len) return commands[i].name;
        if (self.lua) |l| {
            const j = i - commands.len;
            if (j < l.commandCount()) return l.commandAt(j).name;
        }
        return "";
    }

    fn commandDescAt(self: *App, i: usize) []const u8 {
        if (i < commands.len) return commands[i].description;
        if (self.lua) |l| {
            const j = i - commands.len;
            if (j < l.commandCount()) return l.commandAt(j).description;
        }
        return "";
    }

    fn commandAliasesAt(self: *App, i: usize) []const u8 {
        _ = self;
        if (i < commands.len) return commands[i].aliases;
        return "";
    }

    fn updatePalette(self: *App) void {
        self.palette.filtered.clearRetainingCapacity();
        const q = self.palette.query.items;
        const total = self.commandTotal();
        var i: usize = 0;
        while (i < total) : (i += 1) {
            if (q.len == 0 or containsIgnoreCase(self.commandNameAt(i), q) or containsIgnoreCase(self.commandDescAt(i), q) or containsIgnoreCase(self.commandAliasesAt(i), q)) {
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
                    const cmd_name = self.commandNameAt(idx);
                    const owned = try self.gpa.dupe(u8, cmd_name);
                    defer self.gpa.free(owned);
                    self.palette.active = false;
                    try self.runCommand(owned, "");
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

        var layout: *ui.Node = undefined;
        if (self.lua) |l| {
            layout = l.buildLayout(a, self.snapshot()) catch blk: {
                if (!self.lua_layout_failed) {
                    self.lua_layout_failed = true;
                    const msg = std.fmt.allocPrint(a, "UI layout error: {s}", .{l.lastError()}) catch "UI layout error";
                    self.notify(msg, true);
                }
                break :blk try self.buildNativeLayout(a);
            };
            if (!self.lua_layout_failed) {}
        } else {
            layout = try self.buildNativeLayout(a);
        }
        ui.prepare(layout, .{ .x = 0, .y = 0, .w = self.size.cols, .h = self.size.rows });
        var result = ui.LayoutResult{};
        defer result.deinit(self.gpa);
        try ui.collect(layout, &result, self.gpa);
        for (result.focusables.items) |fi| try self.focus_buttons.append(self.gpa, fi);
        // The prompt is always the primary focus target, regardless of where it
        // appears in the layout tree.
        for (self.focus_buttons.items, 0..) |fi, idx| {
            if (fi.kind == .input and idx != 0) {
                const moved = self.focus_buttons.orderedRemove(idx);
                try self.focus_buttons.insert(self.gpa, 0, moved);
                break;
            }
        }
        if (self.focus_buttons.items.len == 0 or self.focus_index >= self.focus_buttons.items.len) self.focus_index = 0;
        for (result.buttons.items) |b| try self.buttons.append(self.gpa, b);
        self.input_rect = result.input_rect;
        self.chat_rect = result.chat_rect;
        self.layout_ids_valid = true;
        try self.drawNode(f, layout, a);
        if (self.approval != null) try self.drawApproval(f, a);
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
            .height = .{ .cells = 8 },
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
                const focused = node.focused or self.focusedButton(node);
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
            .spacer, .custom, .widget => {},
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

    fn drawApproval(self: *App, f: *Frame, a: std.mem.Allocator) !void {
        const approval = &self.approval.?;
        const w: u16 = @min(self.size.cols -| 4, 100);
        const h: u16 = @min(self.size.rows -| 4, 30);
        const x: u16 = (self.size.cols -| w) / 2;
        const y: u16 = (self.size.rows -| h) / 2;
        const r = Rect{ .x = x, .y = y, .w = w, .h = h };
        f.fillRect(r, ' ', .{ .bg = .{ .semantic = .selection } });
        f.drawBorder(r, .double, .{ .fg = .{ .semantic = .warning } }, "Approval required");
        const inner = r.inner();
        var row: u16 = 0;
        const title = Style{ .fg = .{ .semantic = .warning }, .attrs = .{ .bold = true } };
        const normal = Style{ .fg = .{ .semantic = .fg } };
        const muted = Style{ .fg = .{ .semantic = .muted } };
        const line1 = try std.fmt.allocPrint(a, "Tool: {s}", .{approval.tool.name});
        _ = f.putText(inner.x, inner.y + row, line1, title, inner.w);
        row += 2;
        const line2 = try std.fmt.allocPrint(a, "{s}", .{approval.preview.summary});
        _ = f.putText(inner.x, inner.y + row, line2, normal, inner.w);
        row += 1;
        if (approval.preview.command) |cmd| {
            const cline = try std.fmt.allocPrint(a, "Command: {s}", .{cmd});
            _ = f.putText(inner.x, inner.y + row, cline, .{ .fg = .{ .semantic = .warning } }, inner.w);
            row += 1;
        }
        for (approval.preview.paths) |p| {
            _ = f.putText(inner.x, inner.y + row, p, muted, inner.w);
            row += 1;
        }
        row += 1;
        if (approval.preview.diff) |diff| {
            _ = f.putText(inner.x, inner.y + row, "Diff preview:", title, inner.w);
            row += 1;
            var it = std.mem.splitScalar(u8, diff, '\n');
            var idx: u16 = 0;
            while (it.next()) |line| {
                if (idx < approval.scroll) {
                    idx += 1;
                    continue;
                }
                if (row >= inner.y + inner.h -| 3) break;
                const st = if (line.len > 0 and line[0] == '+') Style{ .fg = .{ .semantic = .diff_added } } else if (line.len > 0 and line[0] == '-') Style{ .fg = .{ .semantic = .diff_removed } } else if (line.len > 0 and line[0] == '@') Style{ .fg = .{ .semantic = .diff_hunk } } else normal;
                _ = f.putText(inner.x, inner.y + row, line, st, inner.w);
                row += 1;
                idx += 1;
                if (idx > 500) break;
            }
        } else {
            _ = f.putText(inner.x, inner.y + row, "No file diff or command preview.", muted, inner.w);
            row += 1;
        }
        const btn_row = inner.h -| 2;
        const deny_st = if (approval.choice == .deny) Style{ .fg = .{ .semantic = .bg }, .bg = .{ .semantic = .warning }, .attrs = .{ .bold = true } } else Style{ .fg = .{ .semantic = .warning } };
        const once_st = if (approval.choice == .allow_once) Style{ .fg = .{ .semantic = .bg }, .bg = .{ .semantic = .success }, .attrs = .{ .bold = true } } else Style{ .fg = .{ .semantic = .success } };
        const sess_st = if (approval.choice == .allow_session) Style{ .fg = .{ .semantic = .bg }, .bg = .{ .semantic = .success }, .attrs = .{ .bold = true } } else Style{ .fg = .{ .semantic = .success } };
        _ = f.putText(inner.x, inner.y + btn_row, "  Deny (d/Esc)  ", deny_st, inner.w);
        _ = f.putText(inner.x + 17, inner.y + btn_row, "  Allow once (a)  ", once_st, inner.w -| 17);
        _ = f.putText(inner.x + 36, inner.y + btn_row, "  Allow session (s)  ", sess_st, inner.w -| 36);
        _ = f.putText(inner.x, inner.y + btn_row + 1, "The Zig permission engine is authoritative. Lua hooks can only tighten this decision.", muted, inner.w);
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
            const cmd_idx = self.palette.filtered.items[i];
            const cmd_name = self.commandNameAt(cmd_idx);
            const cmd_desc = self.commandDescAt(cmd_idx);
            const selected = i == self.palette.selected;
            const st = if (selected)
                Style{ .fg = .{ .semantic = .bg }, .bg = .{ .semantic = .focus } }
            else
                Style{ .fg = .{ .semantic = .fg } };
            if (selected) f.clearRect(.{ .x = inner.x, .y = inner.y + 1 + @as(u16, @intCast(i)), .w = inner.w, .h = 1 }, st);
            const line = try std.fmt.allocPrint(a, " {s:<14} {s}", .{ cmd_name, cmd_desc });
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
            "  Ctrl-R          reload Lua config",
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

fn defaultConfigPath(gpa: std.mem.Allocator) ?[]u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(gpa, "{s}/bloob/init.lua", .{xdg}) catch null;
    }
    if (env.get("HOME")) |home| {
        return std.fmt.allocPrint(gpa, "{s}/.config/bloob/init.lua", .{home}) catch null;
    }
    return null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn hostNotify(ctx: *anyopaque, msg: []const u8, is_error: bool) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.notify(msg, is_error);
}
fn hostRender(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.dirty = true;
}
fn hostQuit(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.running = false;
}
fn hostSetModel(ctx: *anyopaque, model: []const u8) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.setModel(model);
}
fn hostSetTheme(ctx: *anyopaque, name: []const u8) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.themes.set(name)) {
        if (self.theme_name.len > 0) self.gpa.free(self.theme_name);
        self.theme_name = self.gpa.dupe(u8, name) catch &.{};
        self.dirty = true;
    }
}
fn hostRegisterTheme(ctx: *anyopaque, name: []const u8, palette: *const style.Palette) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.themes.register(name, palette.*) catch {};
}
fn hostRunCommand(ctx: *anyopaque, name: []const u8, args: []const u8) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.command_depth > 8) {
        self.notify("command recursion limit reached", true);
        return;
    }
    self.command_depth += 1;
    defer self.command_depth -= 1;
    self.runCommand(name, args) catch |err| {
        const msg = std.fmt.allocPrint(self.gpa, "command failed: {s}",  .{@errorName(err)}) catch "command failed";
        defer self.gpa.free(msg);
        self.notify(msg, true);
    };
}
fn hostReload(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.reload_requested = true;
}
fn hostReadFile(ctx: *anyopaque, path: []const u8, out: *?[]u8) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(256 * 1024)) catch return false;
    out.* = data;
    return true;
}

pub fn appendJsonStringPublic(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    try out.appendSlice(gpa, "\\u00");
                    try out.append(gpa, hex[c >> 4]);
                    try out.append(gpa, hex[c & 0xF]);
                } else {
                    try out.append(gpa, c);
                }
            },
        }
    }
    try out.append(gpa, '"');
}
