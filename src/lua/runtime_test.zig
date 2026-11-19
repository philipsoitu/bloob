const std = @import("std");
const runtime_mod = @import("runtime.zig");
const ui = @import("../ui/node.zig");

const TestHost = struct {
    notified: std.ArrayList(u8) = .empty,
    rendered: bool = false,
    quit_called: bool = false,
    model: std.ArrayList(u8) = .empty,
    theme: std.ArrayList(u8) = .empty,
    palette_count: usize = 0,
    reload: bool = false,
    command_count: usize = 0,

    fn notify(ctx: *anyopaque, msg: []const u8, is_error: bool) void {
        _ = is_error;
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.notified.clearRetainingCapacity();
        self.notified.appendSlice(std.testing.allocator, msg) catch {};
    }
    fn render(ctx: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.rendered = true;
    }
    fn quit(ctx: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.quit_called = true;
    }
    fn setModel(ctx: *anyopaque, model: []const u8) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.model.clearRetainingCapacity();
        self.model.appendSlice(std.testing.allocator, model) catch {};
    }
    fn setTheme(ctx: *anyopaque, name: []const u8) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.theme.clearRetainingCapacity();
        self.theme.appendSlice(std.testing.allocator, name) catch {};
    }
    fn registerTheme(ctx: *anyopaque, name: []const u8, palette: *const @import("../style.zig").Palette) void {
        _ = name;
        _ = palette;
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.palette_count += 1;
    }
    fn runCommand(ctx: *anyopaque, name: []const u8, args: []const u8) void {
        _ = name;
        _ = args;
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.command_count += 1;
    }
    fn requestReload(ctx: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        self.reload = true;
    }
    fn readFile(ctx: *anyopaque, path: []const u8, out: *?[]u8) bool {
        _ = ctx;
        out.* = std.testing.allocator.dupe(u8, path) catch return false;
        return true;
    }

    fn host(self: *TestHost) runtime_mod.Host {
        return .{
            .ctx = self,
            .notify = notify,
            .request_render = render,
            .quit = quit,
            .set_model = setModel,
            .set_theme = setTheme,
            .register_theme = registerTheme,
            .run_command = runCommand,
            .request_reload = requestReload,
            .read_file = readFile,
        };
    }
};

test "lua runtime boots bundled modules and builds default layout" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var host = TestHost{};
    defer host.notified.deinit(std.testing.allocator);
    defer host.model.deinit(std.testing.allocator);
    defer host.theme.deinit(std.testing.allocator);
    const rt = try runtime_mod.Runtime.init(std.testing.allocator, io, host.host());
    defer rt.deinit();
    const arena = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(arena);
    defer arena_inst.deinit();
    const layout = try rt.buildLayout(arena_inst.allocator(), .{ .width = 100, .height = 40 });
    try std.testing.expectEqual(ui.Kind.column, layout.kind);
    try std.testing.expect(layout.children.len == 3);
    try std.testing.expectEqual(ui.Kind.row, layout.children[0].kind);
    try std.testing.expectEqualStrings("conversation", layout.children[0].children[1].id);
}

test "lua calls Zig function and Zig invokes Lua callback" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var host = TestHost{};
    defer host.notified.deinit(std.testing.allocator);
    defer host.model.deinit(std.testing.allocator);
    defer host.theme.deinit(std.testing.allocator);
    const rt = try runtime_mod.Runtime.init(std.testing.allocator, io, host.host());
    defer rt.deinit();
    try rt.execString(
        \\local bloob = require("bloob")
        \\local ui = require("bloob.ui")
        \\bloob.command.register("test.hello", {
        \\  description = "test command",
        \\  run = function(ctx)
        \\    ui.notify("hello from lua")
        \\  end,
        \\})
    , "=test");
    try std.testing.expect(rt.runCommand("test.hello", ""));
    try std.testing.expectEqualStrings("hello from lua", host.notified.items);
    try std.testing.expectEqual(@as(usize, 1), rt.commandCount());
}

test "lua custom widget and signals render" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var host = TestHost{};
    defer host.notified.deinit(std.testing.allocator);
    defer host.model.deinit(std.testing.allocator);
    defer host.theme.deinit(std.testing.allocator);
    const rt = try runtime_mod.Runtime.init(std.testing.allocator, io, host.host());
    defer rt.deinit();
    try rt.execString(
        \\local ui = require("bloob.ui")
        \\local count = ui.signal(2)
        \\ui.register("test.counter", function(ctx)
        \\  return ui.row({
        \\    ui.text("Count: " .. count:get()),
        \\    ui.button("+", { on_press = function() count:set(count:get() + 1) end }),
        \\  }, { gap = 1 })
        \\end)
        \\ui.set_layout(function(ctx)
        \\  return ui.column({
        \\    ui.widget("test.counter", { height = 1 }),
        \\    ui.chat({ flex = 1 }),
        \\    ui.input({ height = 3 }),
        \\    ui.statusline(),
        \\  })
        \\end)
    , "=widget");
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const layout = try rt.buildLayout(arena_inst.allocator(), .{ .width = 60, .height = 20 });
    try std.testing.expectEqual(ui.Kind.column, layout.kind);
    try std.testing.expectEqual(ui.Kind.row, layout.children[0].kind);
    try std.testing.expectEqualStrings("Count: 2", layout.children[0].children[0].content.?);
    try std.testing.expectEqualStrings("+", layout.children[0].children[1].content.?);
}

test "lua keymap registration" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var host = TestHost{};
    defer host.notified.deinit(std.testing.allocator);
    defer host.model.deinit(std.testing.allocator);
    defer host.theme.deinit(std.testing.allocator);
    const rt = try runtime_mod.Runtime.init(std.testing.allocator, io, host.host());
    defer rt.deinit();
    try rt.execString(
        \\local keymap = require("bloob.keymap")
        \\keymap.set("normal", "<C-p>", "help", { desc = "help" })
    , "=keymap");
    const key = @import("../key.zig").parseSpec("<C-p>", '\\').?;
    const found = rt.findKey("normal", key) orelse return error.NotFound;
    try std.testing.expectEqualStrings("help", found.action.command.name);
}

test "bad layout returns an error instead of crashing" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var host = TestHost{};
    defer host.notified.deinit(std.testing.allocator);
    defer host.model.deinit(std.testing.allocator);
    defer host.theme.deinit(std.testing.allocator);
    const rt = try runtime_mod.Runtime.init(std.testing.allocator, io, host.host());
    defer rt.deinit();
    try rt.execString(
        \\local ui = require("bloob.ui")
        \\ui.set_layout(function() return { __bloob = "not-a-kind" } end)
    , "=bad");
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    try std.testing.expectError(error.UnknownNodeKind, rt.buildLayout(arena_inst.allocator(), .{}));
}

test "lua custom tool registration and ctx read_file" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var host = TestHost{};
    defer host.notified.deinit(std.testing.allocator);
    defer host.model.deinit(std.testing.allocator);
    defer host.theme.deinit(std.testing.allocator);
    const rt = try runtime_mod.Runtime.init(std.testing.allocator, io, host.host());
    defer rt.deinit();
    try rt.execString(
        \\local tools = require("bloob.tools")
        \\tools.register("echo_path", {
        \\  description = "Echo a path through ctx:read_file",
        \\  schema = { type = "object", properties = { path = { type = "string" } }, required = { "path" } },
        \\  permissions = { "workspace.read" },
        \\  run = function(ctx, args)
        \\    local content = ctx:read_file(args.path)
        \\    return { path = args.path, content = content }
        \\  end,
        \\})
    , "=tool");
    const tool = rt.toolByName("echo_path") orelse return error.MissingTool;
    const out = rt.invokeTool(tool, "{\"path\":\"src/main.zig\"}") orelse return error.ToolFailed;
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"path\":\"src/main.zig\"") != null);
    try std.testing.expect(rt.tools.items.len == 1);
}

test "event payload fields and decisions" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var host = TestHost{};
    defer host.notified.deinit(std.testing.allocator);
    defer host.model.deinit(std.testing.allocator);
    defer host.theme.deinit(std.testing.allocator);
    const rt = try runtime_mod.Runtime.init(std.testing.allocator, io, host.host());
    defer rt.deinit();
    try rt.execString(
        \\local events = require("bloob.events")
        \\events.on("probe.event", function(e)
        \\  if e.tool == "shell" then return "deny" end
        \\  if e.tool == "write_file" then return "ask" end
        \\  return nil
        \\end)
    , "=events");
    try std.testing.expectEqual(runtime_mod.Runtime.EventDecision.deny, rt.emit("probe.event", "{\"tool\":\"shell\"}"));
    try std.testing.expectEqual(runtime_mod.Runtime.EventDecision.ask, rt.emit("probe.event", "{\"tool\":\"write_file\"}"));
    try std.testing.expectEqual(runtime_mod.Runtime.EventDecision.pass, rt.emit("probe.event", "{\"tool\":\"read_file\"}"));
}

test "serialize custom tool result with numeric keys" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var host = TestHost{};
    defer host.notified.deinit(std.testing.allocator);
    defer host.model.deinit(std.testing.allocator);
    defer host.theme.deinit(std.testing.allocator);
    const rt = try runtime_mod.Runtime.init(std.testing.allocator, io, host.host());
    defer rt.deinit();
    try rt.execString(
        \\local tools = require("bloob.tools")
        \\tools.register("numeric", {
        \\  description = "numeric result",
        \\  schema = { type = "object" },
        \\  run = function(ctx, args) return { [2] = "a", [4] = "b" } end,
        \\})
    , "=tool");
    const tool = rt.toolByName("numeric") orelse return error.MissingTool;
    const out = rt.invokeTool(tool, "{}") orelse return error.ToolFailed;
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"2\":\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"4\":\"b\"") != null);
}

test "lua keymap callback invocation" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var host = TestHost{};
    defer host.notified.deinit(std.testing.allocator);
    defer host.model.deinit(std.testing.allocator);
    defer host.theme.deinit(std.testing.allocator);
    const rt = try runtime_mod.Runtime.init(std.testing.allocator, io, host.host());
    defer rt.deinit();
    try rt.execString(
        \\local keymap = require("bloob.keymap")
        \\local ui = require("bloob.ui")
        \\keymap.set("normal", "<C-k>", function() ui.notify("callback fired") end)
    , "=keymap");
    const key = @import("../key.zig").parseSpec("<C-k>", '\\').?;
    const found = rt.findKey("normal", key) orelse return error.NotFound;
    switch (found.action) {
        .callback => |cb| try std.testing.expect(rt.invokeCallback(cb.ref)),
        .command => return error.WrongAction,
    }
    try std.testing.expectEqualStrings("callback fired", host.notified.items);
}

test "config loads and can require modules from config directory" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "helper.lua", .data = "return { value = 'from-helper' }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "init.lua", .data =
        \\local helper = require("helper")
        \\local ui = require("bloob.ui")
        \\ui.register("cfg.test", function(ctx) return ui.text(helper.value) end)
        \\ui.set_layout(ui.column({ ui.widget("cfg.test") }))
        \\
    });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const init_path = try std.fs.path.join(gpa, &.{ path_buf[0..n], "init.lua" });
    defer gpa.free(init_path);
    var host = TestHost{};
    defer host.notified.deinit(gpa);
    defer host.model.deinit(gpa);
    defer host.theme.deinit(gpa);
    const rt = try runtime_mod.Runtime.init(gpa, io, host.host());
    defer rt.deinit();
    try rt.loadConfig(init_path);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const layout = try rt.buildLayout(arena.allocator(), .{ .width = 80, .height = 20 });
    try std.testing.expectEqual(ui.Kind.column, layout.kind);
    try std.testing.expectEqualStrings("from-helper", layout.children[0].content.?);
}
