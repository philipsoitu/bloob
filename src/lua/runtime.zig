//! Embedded LuaJIT runtime: state lifecycle, protected calls, registry refs,
//! bundled modules, declarative UI conversion, keymaps, events and Lua tools.
const std = @import("std");
const lua = @import("c.zig").c;
const util = @import("util.zig");
const ui = @import("../ui/node.zig");
const style = @import("../style.zig");
const env = @import("../env.zig");

pub const api_version: u32 = 1;
pub const bloob_version = "0.1.0";

const ui_source = @embedFile("../runtime/lua/bloob/ui.lua");
const init_source = @embedFile("../runtime/lua/bloob/init.lua");
const keymap_source = @embedFile("../runtime/lua/bloob/keymap.lua");
const events_source = @embedFile("../runtime/lua/bloob/events.lua");
const tools_source = @embedFile("../runtime/lua/bloob/tools.lua");
const models_source = @embedFile("../runtime/lua/bloob/models.lua");
const config_source = @embedFile("../runtime/lua/bloob/config.lua");
const defaults_source = @embedFile("../runtime/lua/bloob/defaults.lua");

pub const Host = struct {
    ctx: *anyopaque,
    notify: *const fn (ctx: *anyopaque, msg: []const u8, is_error: bool) void,
    request_render: *const fn (ctx: *anyopaque) void,
    quit: *const fn (ctx: *anyopaque) void,
    set_model: *const fn (ctx: *anyopaque, model: []const u8) void,
    set_theme: *const fn (ctx: *anyopaque, name: []const u8) void,
    register_theme: *const fn (ctx: *anyopaque, name: []const u8, palette: *const style.Palette) void,
    run_command: *const fn (ctx: *anyopaque, name: []const u8, args: []const u8) void,
    request_reload: *const fn (ctx: *anyopaque) void,
    read_file: *const fn (ctx: *anyopaque, path: []const u8, out: *?[]u8) bool,

    fn notifyFn(self: *const Host, msg: []const u8, is_error: bool) void {
        self.notify(self.ctx, msg, is_error);
    }
    fn renderFn(self: *const Host) void {
        self.request_render(self.ctx);
    }
};

pub const WidgetContext = struct {
    width: u16 = 80,
    height: u16 = 24,
    cwd: []const u8 = "",
    model: []const u8 = "",
    provider: []const u8 = "",
    theme: []const u8 = "default",
    mode: []const u8 = "insert",
    state: []const u8 = "idle",
    session_id: []const u8 = "",
    busy: bool = false,
    message_count: usize = 0,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    git_branch: []const u8 = "",
};

pub const KeymapAction = union(enum) {
    command: struct { name: []u8, desc: []u8 },
    callback: struct { ref: c_int, desc: []u8 },
};

pub const KeymapEntry = struct {
    mode: []u8,
    lhs: []u8,
    key: @import("../key.zig").Key,
    action: KeymapAction,
    description: []u8,
};

pub const LuaTool = struct {
    name: []u8,
    description: []u8,
    schema_json: []u8,
    permissions: []u8,
    run_ref: c_int,
};

pub const CommandInfo = struct {
    name: []u8,
    description: []u8,
};

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    L: util.State,
    host: Host,
    layout_ref: c_int = lua.LUA_NOREF,
    ui_ref: c_int = lua.LUA_NOREF,
    command_dispatch_ref: c_int = lua.LUA_NOREF,
    events_dispatch_ref: c_int = lua.LUA_NOREF,
    tool_invoke_ref: c_int = lua.LUA_NOREF,
    route_ref: c_int = lua.LUA_NOREF,
    setup_ref: c_int = lua.LUA_NOREF,
    frame_callback_refs: std.ArrayList(c_int) = .empty,
    keymaps: std.ArrayList(KeymapEntry) = .empty,
    commands: std.ArrayList(CommandInfo) = .empty,
    tools: std.ArrayList(LuaTool) = .empty,
    config_sources: std.ArrayList([]u8) = .empty,
    last_error: ?[]u8 = null,
    config_error: ?[]u8 = null,
    startup_ms: i64 = 0,
    render_depth: u8 = 0,
    api_version: u32 = api_version,
    leader: u21 = '\\',

    pub fn init(gpa: std.mem.Allocator, io: std.Io, host: Host) !*Runtime {
        const self = try gpa.create(Runtime);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .L = undefined, .host = host };
        const L = lua.luaL_newstate() orelse return error.LuaStateUnavailable;
        self.L = L;
        errdefer lua.lua_close(L);
        lua.luaL_openlibs(L);
        self.startup_ms = std.Io.Clock.awake.now(io).toMilliseconds();
        try self.installBaseModules();
        try self.runBundled("bloob.ui", ui_source);
        try self.runBundled("bloob.keymap", keymap_source);
        try self.runBundled("bloob.events", events_source);
        try self.runBundled("bloob.tools", tools_source);
        try self.runBundled("bloob.models", models_source);
        try self.runBundled("bloob.config", config_source);
        try self.runBundled("bloob", init_source);
        try self.runBundled("@defaults", defaults_source);
        self.ui_ref = self.refModule("bloob.ui");
        self.command_dispatch_ref = self.refModuleField("bloob", "_run_command");
        self.events_dispatch_ref = self.refModuleField("bloob.events", "_dispatch");
        self.tool_invoke_ref = self.refModuleField("bloob.tools", "_invoke");
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        self.releaseFrameRefs();
        {
            util.unref(self.L, self.layout_ref);
            util.unref(self.L, self.ui_ref);
            util.unref(self.L, self.command_dispatch_ref);
            util.unref(self.L, self.events_dispatch_ref);
            util.unref(self.L, self.tool_invoke_ref);
            util.unref(self.L, self.route_ref);
            util.unref(self.L, self.setup_ref);
            for (self.keymaps.items) |*km| {
                self.gpa.free(km.mode);
                self.gpa.free(km.lhs);
                self.gpa.free(km.description);
                switch (km.action) {
                    .command => |c| {
                        self.gpa.free(c.name);
                        self.gpa.free(c.desc);
                    },
                    .callback => |cb| {
                        util.unref(self.L, cb.ref);
                        self.gpa.free(cb.desc);
                    },
                }
            }
            self.keymaps.deinit(self.gpa);
            for (self.tools.items) |*t| {
                util.unref(self.L, t.run_ref);
                self.gpa.free(t.name);
                self.gpa.free(t.description);
                self.gpa.free(t.schema_json);
                self.gpa.free(t.permissions);
            }
            self.tools.deinit(self.gpa);
            for (self.commands.items) |*c| {
                self.gpa.free(c.name);
                self.gpa.free(c.description);
            }
            self.commands.deinit(self.gpa);
            for (self.config_sources.items) |s| self.gpa.free(s);
            self.config_sources.deinit(self.gpa);
            if (self.last_error) |e| self.gpa.free(e);
            if (self.config_error) |e| self.gpa.free(e);
            lua.lua_close(self.L);
        }
        self.frame_callback_refs.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn setError(self: *Runtime, msg: []const u8) void {
        if (self.last_error) |e| self.gpa.free(e);
        self.last_error = self.gpa.dupe(u8, msg) catch null;
    }

    pub fn lastError(self: *Runtime) []const u8 {
        return self.last_error orelse "";
    }

    fn releaseFrameRefs(self: *Runtime) void {
        for (self.frame_callback_refs.items) |ref| util.unref(self.L, ref);
        self.frame_callback_refs.clearRetainingCapacity();
    }

    fn refModule(self: *Runtime, name: []const u8) c_int {
        const L = self.L;
        const top = util.top(L);
        defer util.setTop(L, top);
        lua.lua_getglobal(L, "package");
        lua.lua_getfield(L, -1, "loaded");
        util.pushString(L, name);
        lua.lua_gettable(L, -2);
        if (!util.isTable(L, -1)) return lua.LUA_NOREF;
        return util.makeRef(L);
    }

    fn refModuleField(self: *Runtime, module: []const u8, field: [:0]const u8) c_int {
        const L = self.L;
        const top = util.top(L);
        defer util.setTop(L, top);
        lua.lua_getglobal(L, "package");
        lua.lua_getfield(L, -1, "loaded");
        util.pushString(L, module);
        lua.lua_gettable(L, -2);
        if (!util.isTable(L, -1)) return lua.LUA_NOREF;
        lua.lua_getfield(L, -1, field.ptr);
        if (!util.isFunction(L, -1)) return lua.LUA_NOREF;
        return util.makeRef(L);
    }

    fn runBundled(self: *Runtime, name: []const u8, source: []const u8) !void {
        var err = std.ArrayList(u8).empty;
        defer err.deinit(self.gpa);
        util.loadBuffer(self.L, source, name, &err, self.gpa) catch {
            const msg = err.items;
            self.setError(msg);
            return error.LuaError;
        };
    }

    pub fn loadConfig(self: *Runtime, path: []const u8) !void {
        const L = self.L;
        const code = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(4 * 1024 * 1024)) catch |e| {
            const msg = try std.fmt.allocPrint(self.gpa, "cannot read config {s}: {s}", .{ path, @errorName(e) });
            defer self.gpa.free(msg);
            self.setError(msg);
            return error.ConfigRead;
        };
        defer self.gpa.free(code);
        const path_z = try util.dupeZ(self.gpa, path);
        defer self.gpa.free(path_z);
        const top = util.top(L);
        defer util.setTop(L, top);
        var err = std.ArrayList(u8).empty;
        defer err.deinit(self.gpa);
        const rc = lua.luaL_loadbuffer(L, code.ptr, code.len, path_z.ptr);
        if (rc != 0) {
            if (util.getString(L, -1)) |m| try err.appendSlice(self.gpa, m);
            if (self.config_error) |e| self.gpa.free(e);
            self.config_error = self.gpa.dupe(u8, err.items) catch null;
            self.setError(err.items);
            return error.ConfigSyntax;
        }
        util.pcall(L, 0, 0, &err, self.gpa) catch {
            if (self.config_error) |e| self.gpa.free(e);
            self.config_error = self.gpa.dupe(u8, err.items) catch null;
            self.setError(err.items);
            return error.ConfigRuntime;
        };
        try self.addConfigSource(path);
        // Prepare a private module search path scoped to the user's bloob directory.
        const dir = dirName(path);
        const extra = try std.fmt.allocPrint(self.gpa, "{s}/lua/?.lua;{s}/lua/?/init.lua;{s}/?.lua;{s}/?/init.lua;", .{ dir, dir, dir, dir });
        defer self.gpa.free(extra);
        const extra_z = try util.dupeZ(self.gpa, extra);
        defer self.gpa.free(extra_z);
        util.getGlobal(L, "package");
        util.field(L, -1, "path");
        if (util.getString(L, -1)) |old| {
            const combined = try std.mem.concat(self.gpa, u8, &.{ extra, old });
            defer self.gpa.free(combined);
            util.pushString(L, combined);
            lua.lua_setfield(L, -3, "path");
        }
        util.pop(L, 2);
    }

    pub fn addConfigSource(self: *Runtime, path: []const u8) !void {
        for (self.config_sources.items) |s| {
            if (std.mem.eql(u8, s, path)) return;
        }
        try self.config_sources.append(self.gpa, try self.gpa.dupe(u8, path));
    }

    pub fn configSources(self: *const Runtime) []const []u8 {
        return self.config_sources.items;
    }

    pub fn execString(self: *Runtime, source: []const u8, name: []const u8) !void {
        var err = std.ArrayList(u8).empty;
        defer err.deinit(self.gpa);
        util.loadBuffer(self.L, source, name, &err, self.gpa) catch {
            self.setError(err.items);
            return error.LuaError;
        };
    }

    // ---------- C function installation ----------

    fn makeClosure(L: util.State, rt: *Runtime, func: lua.lua_CFunction) void {
        lua.lua_pushlightuserdata(L, rt);
        lua.lua_pushcclosure(L, func, 1);
    }

    fn selfFromUpvalue(L: util.State) *Runtime {
        const p = lua.lua_touserdata(L, lua.lua_upvalueindex(1)) orelse return undefined;
        return @ptrCast(@alignCast(p));
    }

    fn installFn(L: util.State, rt: *Runtime, table_idx: c_int, name: [:0]const u8, func: lua.lua_CFunction) void {
        const abs = if (table_idx < 0) util.top(L) + table_idx + 1 else table_idx;
        makeClosure(L, rt, func);
        lua.lua_setfield(L, abs, name.ptr);
    }

    fn newBaseTable(L: util.State, name: []const u8) void {
        util.newTable(L);
        util.pushString(L, name);
        util.setLoaded(L, name);
    }

    fn installBaseModules(self: *Runtime) !void {
        const L = self.L;
        // bloob
        util.newTable(L);
        util.setFieldString(L, -1, "version", bloob_version);
        util.setFieldInt(L, -1, "api_version", api_version);
        util.setFieldBool(L, -1, "lua51", true);
        util.setFieldString(L, -1, "runtime", "luajit-2.1");
        util.setFieldString(L, -1, "platform", @tagName(@import("builtin").os.tag));
        lua.lua_pushboolean(L, 1);
        lua.lua_setfield(L, -2, "lua_ffi_available");
        self.installBlurbFunctions(-1);
        lua.lua_pushvalue(L, -1);
        lua.lua_setglobal(L, "bloob");
        util.setLoaded(L, "bloob");
        util.pop(L, 1);

        // bloob.ui
        util.newTable(L);
        self.installUiFunctions(-1);
        util.setLoaded(L, "bloob.ui");
        util.pop(L, 1);

        // bloob.keymap
        util.newTable(L);
        self.installKeymapFunctions(-1);
        util.setLoaded(L, "bloob.keymap");
        util.pop(L, 1);

        // bloob.events
        util.newTable(L);
        util.setLoaded(L, "bloob.events");
        util.pop(L, 1);

        // bloob.tools
        util.newTable(L);
        self.installToolFunctions(-1);
        util.setLoaded(L, "bloob.tools");
        util.pop(L, 1);

        // bloob.models
        util.newTable(L);
        self.installModelFunctions(-1);
        util.setLoaded(L, "bloob.models");
        util.pop(L, 1);

        // bloob.config
        util.newTable(L);
        self.installConfigFunctions(-1);
        util.setLoaded(L, "bloob.config");
        util.pop(L, 1);

        // Extra empty namespace tables.
        const extra = [_][]const u8{ "bloob.agent", "bloob.plugins", "bloob.storage", "bloob.command" };
        for (extra) |name| {
            util.newTable(L);
            util.setLoaded(L, name);
            util.pop(L, 1);
        }
    }

    fn installBlurbFunctions(self: *Runtime, table: c_int) void {
        const L = self.L;
        installFn(L, self, table, "_notify", c_notify);
        installFn(L, self, table, "_quit", c_quit);
        installFn(L, self, table, "_set_model", c_set_model);
        installFn(L, self, table, "_current_model", c_current_model);
        installFn(L, self, table, "_request_render", c_request_render);
        installFn(L, self, table, "_request_reload", c_request_reload);
        installFn(L, self, table, "_run_command", c_run_command);
        installFn(L, self, table, "_setup", c_setup);
        installFn(L, self, table, "_state", c_state);
        installFn(L, self, table, "_config_sources", c_config_sources);
        installFn(L, self, table, "_register_command", c_register_command);
        installFn(L, self, table, "_read_file", c_read_file);
        installFn(L, self, table, "_log", c_log);
    }

    fn installUiFunctions(self: *Runtime, table: c_int) void {
        const L = self.L;
        installFn(L, self, table, "_set_layout", c_ui_set_layout);
        installFn(L, self, table, "_theme_register", c_ui_theme_register);
        installFn(L, self, table, "_theme_set", c_ui_theme_set);
        installFn(L, self, table, "_notify", c_notify);
        installFn(L, self, table, "_request_render", c_request_render);
        installFn(L, self, table, "_command", c_run_command);
        installFn(L, self, table, "_quit", c_quit);
    }

    fn installKeymapFunctions(self: *Runtime, table: c_int) void {
        const L = self.L;
        installFn(L, self, table, "_set_fn", c_keymap_set_fn);
        installFn(L, self, table, "_set_cmd", c_keymap_set_cmd);
        installFn(L, self, table, "_del", c_keymap_del);
        installFn(L, self, table, "_leader", c_keymap_leader);
    }

    fn installToolFunctions(self: *Runtime, table: c_int) void {
        const L = self.L;
        installFn(L, self, table, "_register", c_tool_register);
        installFn(L, self, table, "_list", c_tool_list);
    }

    fn installModelFunctions(self: *Runtime, table: c_int) void {
        const L = self.L;
        installFn(L, self, table, "_set_route", c_model_set_route);
        installFn(L, self, table, "_set_model", c_set_model);
        installFn(L, self, table, "_current_model", c_current_model);
    }

    fn installConfigFunctions(self: *Runtime, table: c_int) void {
        const L = self.L;
        installFn(L, self, table, "_sources", c_config_sources);
        installFn(L, self, table, "_reload", c_request_reload);
    }

    // ---------- Layout conversion ----------

    fn pushWidgetCtx(self: *Runtime, ctx: WidgetContext) void {
        const L = self.L;
        util.newTable(L);
        util.setFieldInt(L, -1, "width", ctx.width);
        util.setFieldInt(L, -1, "height", ctx.height);
        util.setFieldString(L, -1, "cwd", ctx.cwd);
        util.setFieldString(L, -1, "model", ctx.model);
        util.setFieldString(L, -1, "provider", ctx.provider);
        util.setFieldString(L, -1, "theme", ctx.theme);
        util.setFieldString(L, -1, "mode", ctx.mode);
        util.setFieldString(L, -1, "state", ctx.state);
        util.setFieldString(L, -1, "session_id", ctx.session_id);
        util.setFieldString(L, -1, "git_branch", ctx.git_branch);
        util.setFieldBool(L, -1, "busy", ctx.busy);
        util.setFieldInt(L, -1, "message_count", @intCast(ctx.message_count));
        util.setFieldInt(L, -1, "prompt_tokens", @intCast(ctx.prompt_tokens));
        util.setFieldInt(L, -1, "completion_tokens", @intCast(ctx.completion_tokens));
        util.setFieldInt(L, -1, "total_tokens", @intCast(ctx.prompt_tokens + ctx.completion_tokens));
        util.setFieldString(L, -1, "bloob_version", bloob_version);
        util.setFieldInt(L, -1, "api_version", api_version);
        // agents is intentionally an empty read-only-shaped list for now.
        util.newTable(L);
        lua.lua_setfield(L, -2, "agents");
        installFn(L, self, -1, "notify", c_ctx_notify);
        installFn(L, self, -1, "read_file", c_ctx_read_file);
        installFn(L, self, -1, "command", c_ctx_command);
    }

    pub fn buildLayout(self: *Runtime, arena: std.mem.Allocator, ctx: WidgetContext) !*ui.Node {
        const L = self.L;
        self.releaseFrameRefs();
        const top = util.top(L);
        defer util.setTop(L, top);
        if (self.layout_ref < 0) return error.NoLayout;
        util.pushRef(L, self.layout_ref);
        if (util.isFunction(L, -1)) {
            self.pushWidgetCtx(ctx);
            util.pcall(L, 1, 1, null, self.gpa) catch {
                self.setError("layout function failed");
                return error.LayoutError;
            };
        }
        if (!util.isTable(L, -1)) {
            self.setError("ui.set_layout expects a node table or function");
            return error.InvalidLayout;
        }
        var conv = Converter{
            .rt = self,
            .arena = arena,
            .ctx = ctx,
            .node_count = 0,
        };
        return conv.convert(-1, 0) catch |err| {
            self.setError(conv.error_message orelse "invalid UI layout");
            return err;
        };
    }

    pub fn renderWidget(self: *Runtime, arena: std.mem.Allocator, name: []const u8, ctx: WidgetContext, depth: usize) !*ui.Node {
        const L = self.L;
        const top = util.top(L);
        defer util.setTop(L, top);
        if (self.ui_ref < 0) return error.NoUiModule;
        util.pushRef(L, self.ui_ref);
        util.field(L, -1, "_render_widget");
        if (!util.isFunction(L, -1)) return error.NoWidgetRenderer;
        util.pushString(L, name);
        self.pushWidgetCtx(ctx);
        util.pcall(L, 2, 1, null, self.gpa) catch {
            self.setError("widget failed");
            return error.WidgetError;
        };
        if (!util.isTable(L, -1)) return error.InvalidWidget;
        var conv = Converter{ .rt = self, .arena = arena, .ctx = ctx, .node_count = 0 };
        return conv.convert(-1, depth + 1);
    }

    // ---------- Commands, keymaps, events, tools ----------

    pub fn commandCount(self: *const Runtime) usize {
        return self.commands.items.len;
    }
    pub fn commandAt(self: *const Runtime, i: usize) CommandInfo {
        return self.commands.items[i];
    }

    pub fn runCommand(self: *Runtime, name: []const u8, args: []const u8) bool {
        const L = self.L;
        if (self.command_dispatch_ref < 0) return false;
        const top = util.top(L);
        defer util.setTop(L, top);
        util.pushRef(L, self.command_dispatch_ref);
        util.pushString(L, name);
        util.pushString(L, args);
        self.pushWidgetCtx(.{});
        var err = std.ArrayList(u8).empty;
        defer err.deinit(self.gpa);
        util.pcall(L, 3, 2, &err, self.gpa) catch {
            self.host.notifyFn(if (err.items.len > 0) err.items else "Lua command failed", true);
            return false;
        };
        const ok = util.getBool(L, -2);
        if (!ok) {
            if (util.getString(L, -1)) |msg| self.host.notifyFn(msg, true);
        }
        return ok;
    }

    pub fn findKey(self: *Runtime, mode: []const u8, key: @import("../key.zig").Key) ?KeymapEntry {
        for (self.keymaps.items) |*km| {
            if (!keyEquals(km.key, key)) continue;
            if (std.mem.eql(u8, km.mode, mode) or std.mem.eql(u8, km.mode, "global")) return km.*;
        }
        return null;
    }

    pub fn invokeCallback(self: *Runtime, ref: c_int) bool {
        const L = self.L;
        const top = util.top(L);
        defer util.setTop(L, top);
        util.pushRef(L, ref);
        if (!util.isFunction(L, -1)) return false;
        var err = std.ArrayList(u8).empty;
        defer err.deinit(self.gpa);
        util.pcall(L, 0, 0, &err, self.gpa) catch {
            self.host.notifyFn(if (err.items.len > 0) err.items else "Lua callback failed", true);
            return false;
        };
        self.host.renderFn();
        return true;
    }

    pub const EventDecision = enum { pass, deny, ask };

    pub fn emit(self: *Runtime, event: []const u8, payload_json: []const u8) EventDecision {
        const L = self.L;
        if (self.events_dispatch_ref < 0) return .pass;
        const top = util.top(L);
        defer util.setTop(L, top);
        util.pushRef(L, self.events_dispatch_ref);
        util.pushString(L, event);
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, payload_json, .{}) catch {
            util.newTable(L);
            util.pcall(L, 2, 1, null, self.gpa) catch return .pass;
            return .pass;
        };
        defer parsed.deinit();
        pushJsonValue(L, parsed.value) catch {
            util.newTable(L);
        };
        util.pcall(L, 2, 1, null, self.gpa) catch return .pass;
        if (util.getString(L, -1)) |s| {
            if (std.mem.eql(u8, s, "deny")) return .deny;
            if (std.mem.eql(u8, s, "ask")) return .ask;
        }
        if (util.isTable(L, -1)) {
            util.field(L, -1, "action");
            defer util.pop(L, 1);
            if (util.getString(L, -1)) |s| {
                if (std.mem.eql(u8, s, "deny")) return .deny;
                if (std.mem.eql(u8, s, "ask")) return .ask;
            }
        }
        return .pass;
    }

    pub fn routeModel(self: *Runtime, task: []const u8, current: []const u8) ?[]u8 {
        const L = self.L;
        if (self.route_ref < 0) return null;
        const top = util.top(L);
        defer util.setTop(L, top);
        util.pushRef(L, self.route_ref);
        util.newTable(L);
        util.setFieldString(L, -1, "task", task);
        util.setFieldString(L, -1, "model", current);
        util.pcall(L, 1, 1, null, self.gpa) catch return null;
        const m = util.getString(L, -1) orelse return null;
        return self.gpa.dupe(u8, m) catch null;
    }

    pub fn toolByName(self: *Runtime, name: []const u8) ?*LuaTool {
        for (self.tools.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    pub fn invokeTool(self: *Runtime, tool: *LuaTool, args_json: []const u8) ?[]u8 {
        const L = self.L;
        const top = util.top(L);
        defer util.setTop(L, top);
        util.pushRef(L, tool.run_ref);
        self.pushWidgetCtx(.{});
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, args_json, .{}) catch {
            util.newTable(L);
            util.pcall(L, 2, 1, null, self.gpa) catch return null;
            return luaToJson(self.gpa, L, -1);
        };
        defer parsed.deinit();
        pushJsonValue(L, parsed.value) catch {
            util.newTable(L);
        };
        var errbuf = std.ArrayList(u8).empty;
        defer errbuf.deinit(self.gpa);
        util.pcall(L, 2, 1, &errbuf, self.gpa) catch {
            return null;
        };
        return luaToJson(self.gpa, L, -1);
    }

    fn convertDim(L: util.State, idx: c_int, field_name: [:0]const u8) ui.Dim {
        util.field(L, idx, field_name);
        defer util.pop(L, 1);
        return dimFromValue(L, -1);
    }

    fn dimFromValue(L: util.State, idx: c_int) ui.Dim {
        if (util.getNumber(L, idx)) |n| {
            if (n > 0 and n < 1) return .{ .percent = @floatCast(n) };
            if (n <= 0) return .auto;
            return .{ .cells = @intFromFloat(@min(n, 65535)) };
        }
        if (util.getString(L, idx)) |s| {
            const t = std.mem.trim(u8, s, " ");
            if (std.mem.endsWith(u8, t, "%")) {
                const p = std.fmt.parseFloat(f32, t[0 .. t.len - 1]) catch 100;
                return .{ .percent = @max(0, @min(1, p / 100)) };
            }
            if (std.fmt.parseInt(u16, t, 10)) |n| return .{ .cells = n } else |_| {}
        }
        return .auto;
    }

    fn styleFromTable(L: util.State, idx: c_int) style.Style {
        var s = style.Style{};
        if (!util.isTable(L, idx)) {
            if (util.getString(L, idx)) |str| {
                if (std.meta.stringToEnum(style.Semantic, str)) |sem| {
                    s.fg = .{ .semantic = sem };
                } else if (style.Rgb.fromHex(str) != null) {
                    s.fg = style.Color.parse(str);
                } else {
                    s.attrs = style.parseAttrs(str);
                }
            }
            return s;
        }
        util.field(L, idx, "fg");
        if (util.getString(L, -1)) |c| s.fg = style.Color.parse(c);
        util.pop(L, 1);
        util.field(L, idx, "bg");
        if (util.getString(L, -1)) |c| s.bg = style.Color.parse(c);
        util.pop(L, 1);
        s.attrs.bold = util.fieldBool(L, idx, "bold", false);
        s.attrs.dim = util.fieldBool(L, idx, "dim", false);
        s.attrs.italic = util.fieldBool(L, idx, "italic", false);
        s.attrs.underline = util.fieldBool(L, idx, "underline", false);
        s.attrs.reverse = util.fieldBool(L, idx, "reverse", false);
        s.attrs.strikethrough = util.fieldBool(L, idx, "strikethrough", false);
        if (util.fieldString(L, idx, "style")) |attrs| s.attrs = style.parseAttrs(attrs);
        return s;
    }

    fn nodeKindFromString(s: []const u8) ?ui.Kind {
        return std.meta.stringToEnum(ui.Kind, s);
    }

    const Converter = struct {
        rt: *Runtime,
        arena: std.mem.Allocator,
        ctx: WidgetContext,
        node_count: usize,
        error_message: ?[]const u8 = null,

        fn dup(self: *Converter, s: []const u8) ![]const u8 {
            return try self.arena.dupe(u8, s);
        }

        fn convert(self: *Converter, idx: c_int, depth: usize) anyerror!*ui.Node {
            if (depth > 64) return error.LayoutTooDeep;
            self.node_count += 1;
            if (self.node_count > 4096) return error.LayoutTooLarge;
            const L = self.rt.L;
            if (!util.isTable(L, idx)) return error.ExpectedNodeTable;
            const kind_s = util.fieldString(L, idx, "__bloob") orelse "";
            const kind = nodeKindFromString(kind_s) orelse return error.UnknownNodeKind;
            // Widgets are expanded by calling the registered Lua component.
            if (kind == .custom) {
                const name = util.fieldString(L, idx, "name") orelse return error.WidgetMissingName;
                const n = self.rt.renderWidget(self.arena, name, self.ctx, depth) catch |err| {
                    self.error_message = self.rt.lastError();
                    return err;
                };
                return n;
            }
            if (kind == .widget) {
                const name = util.fieldString(L, idx, "name") orelse return error.WidgetMissingName;
                return self.rt.renderWidget(self.arena, name, self.ctx, depth) catch |err| {
                    self.error_message = self.rt.lastError();
                    return err;
                };
            }
            const node = try self.arena.create(ui.Node);
            node.* = .{ .kind = kind };
            if (util.fieldString(L, idx, "id")) |v| node.id = try self.dup(v);
            if (util.fieldString(L, idx, "title")) |v| node.title = try self.dup(v);
            if (util.fieldString(L, idx, "content")) |v| node.content = try self.dup(v);
            node.width = convertDim(L, idx, "width");
            node.height = convertDim(L, idx, "height");
            if (util.fieldNumber(L, idx, "flex")) |v| node.flex = @max(0, @as(f32, @floatCast(v)));
            if (util.fieldInt(L, idx, "min_width")) |v| node.min_width = @intCast(@max(0, @min(v, 65535)));
            if (util.fieldInt(L, idx, "min_height")) |v| node.min_height = @intCast(@max(0, @min(v, 65535)));
            if (util.fieldInt(L, idx, "max_width")) |v| node.max_width = @intCast(@max(0, @min(v, 65535)));
            if (util.fieldInt(L, idx, "max_height")) |v| node.max_height = @intCast(@max(0, @min(v, 65535)));
            if (util.fieldInt(L, idx, "padding")) |v| node.padding = @intCast(@max(0, @min(v, 64)));
            if (util.fieldInt(L, idx, "gap")) |v| node.gap = @intCast(@max(0, @min(v, 64)));
            if (util.fieldString(L, idx, "border")) |v| node.border = @import("../frame.zig").parseBorder(v);
            node.visible = util.fieldBool(L, idx, "visible", true);
            node.focusable = util.fieldBool(L, idx, "focusable", false);
            if (kind == .input) node.focusable = true;
            util.field(L, idx, "style");
            node.style = styleFromTable(L, -1);
            util.pop(L, 1);
            util.field(L, idx, "text_style");
            node.text_style = styleFromTable(L, -1);
            util.pop(L, 1);
            if (util.fieldString(L, idx, "color")) |c| node.text_style.fg = style.Color.parse(c);
            if (util.fieldString(L, idx, "bg")) |c| node.text_style.bg = style.Color.parse(c);
            // Button label shorthand.
            if (kind == .button) {
                if (node.content == null) {
                    if (util.fieldString(L, idx, "label")) |v| node.content = try self.dup(v);
                }
                node.focusable = true;
                util.field(L, idx, "on_press");
                if (util.isFunction(L, -1)) {
                    const ref = util.makeRef(L);
                    try self.rt.frame_callback_refs.append(self.rt.gpa, ref);
                    node.button_ref = ref;
                } else {
                    util.pop(L, 1);
                }
            } else if (kind == .list) {
                if (util.fieldTable(L, idx, "lines")) {
                    const n = util.len(L, -1);
                    var lines = try self.arena.alloc([]const u8, n);
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        util.rawGet(L, -1, @intCast(i + 1));
                        lines[i] = if (util.getString(L, -1)) |v| try self.dup(v) else "";
                        util.pop(L, 1);
                    }
                    node.lines = lines;
                    util.pop(L, 1);
                }
            }
            // Children: array of nodes, or props.children.
            if (util.fieldTable(L, idx, "children")) {
                const n = util.len(L, -1);
                var children = try self.arena.alloc(ui.Node, n);
                var count: usize = 0;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    util.rawGet(L, -1, @intCast(i + 1));
                    const child = try self.convert(-1, depth + 1);
                    children[count] = child.*;
                    count += 1;
                    util.pop(L, 1);
                }
                node.children = children[0..count];
                util.pop(L, 1);
            }
            // The root may be a panel around everything; no special casing needed.
            return node;
        }
    };

    fn keyEquals(a: @import("../key.zig").Key, b: @import("../key.zig").Key) bool {
        return a.code == b.code and a.char == b.char and
            a.mods.ctrl == b.mods.ctrl and a.mods.alt == b.mods.alt and a.mods.shift == b.mods.shift;
    }

    // ---------- C callbacks ----------

    fn c_notify(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        const msg = util.getString(l, 1) orelse return 0;
        const is_error = util.getBool(l, 2);
        const owned = rt.gpa.dupe(u8, msg) catch return 0;
        defer rt.gpa.free(owned);
        rt.host.notifyFn(owned, is_error);
        return 0;
    }

    fn c_quit(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        rt.host.quit(rt.host.ctx);
        return 0;
    }

    fn c_request_render(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        selfFromUpvalue(l).host.renderFn();
        return 0;
    }

    fn c_request_reload(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        rt.host.request_reload(rt.host.ctx);
        return 0;
    }

    fn c_set_model(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        const model = util.getString(l, 1) orelse return 0;
        const owned = rt.gpa.dupe(u8, model) catch return 0;
        defer rt.gpa.free(owned);
        rt.host.set_model(rt.host.ctx, owned);
        return 0;
    }

    fn c_current_model(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        _ = selfFromUpvalue(l);
        util.pushString(l, "");
        return 1;
    }

    fn c_log(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        _ = selfFromUpvalue(l);
        if (util.getString(l, 1)) |msg| std.log.info("[lua] {s}", .{msg});
        return 0;
    }

    fn c_run_command(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        const name = util.getString(l, 1) orelse return 0;
        const args = util.getString(l, 2) orelse "";
        const name_owned = rt.gpa.dupe(u8, name) catch return 0;
        defer rt.gpa.free(name_owned);
        const args_owned = rt.gpa.dupe(u8, args) catch return 0;
        defer rt.gpa.free(args_owned);
        rt.host.run_command(rt.host.ctx, name_owned, args_owned);
        return 0;
    }

    fn c_setup(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        _ = selfFromUpvalue(l);
        if (!util.isTable(l, 1)) {
            lua.lua_pushstring(l, "bloob.setup expects a table");
            _ = lua.lua_error(l);
            return 0;
        }
        util.field(l, 1, "model");
        if (util.getString(l, -1)) |m| util.setFieldString(l, 1, "model_selected", m);
        util.pop(l, 1);
        return 0;
    }

    fn c_state(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        _ = selfFromUpvalue(l);
        util.newTable(l);
        return 1;
    }

    fn c_config_sources(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        util.newTable(l);
        for (rt.config_sources.items, 0..) |s, i| {
            util.pushString(l, s);
            util.rawSet(l, -2, @intCast(i + 1));
        }
        return 1;
    }

    fn c_register_command(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        const name = util.getString(l, 1) orelse return 0;
        const desc = util.getString(l, 2) orelse "";
        const name_owned = rt.gpa.dupe(u8, name) catch return 0;
        const desc_owned = rt.gpa.dupe(u8, desc) catch {
            rt.gpa.free(name_owned);
            return 0;
        };
        for (rt.commands.items) |*c| {
            if (std.mem.eql(u8, c.name, name_owned)) {
                rt.gpa.free(name_owned);
                rt.gpa.free(desc_owned);
                rt.gpa.free(c.description);
                c.description = desc_owned;
                return 0;
            }
        }
        rt.commands.append(rt.gpa, .{ .name = name_owned, .description = desc_owned }) catch {
            rt.gpa.free(name_owned);
            rt.gpa.free(desc_owned);
        };
        return 0;
    }

    fn c_ui_set_layout(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        if (!util.isTable(l, 1) and !util.isFunction(l, 1)) {
            lua.lua_pushstring(l, "ui.set_layout expects a node table or function");
            _ = lua.lua_error(l);
            return 0;
        }
        if (rt.layout_ref >= 0) util.unref(l, rt.layout_ref);
        lua.lua_pushvalue(l, 1);
        rt.layout_ref = util.makeRef(l);
        return 0;
    }

    fn parsePalette(l: util.State, idx: c_int) style.Palette {
        var p = style.Palette.empty();
        if (!util.isTable(l, idx)) return p;
        const fields = std.meta.fieldNames(style.Semantic);
        for (fields) |name| {
            if (std.meta.stringToEnum(style.Semantic, name)) |sem| {
                util.field(l, idx, name);
                if (util.getString(l, -1)) |c| {
                    const color = style.Color.parse(c);
                    const rgb = switch (color) {
                        .rgb => |v| v,
                        .xterm => |n| blk: {
                            const tmp = style.Palette.empty();
                            _ = tmp;
                            break :blk rgbFromXterm(n);
                        },
                        .semantic => |s2| p.get(s2),
                        .default => null,
                    };
                    p.set(sem, rgb);
                }
                util.pop(l, 1);
            }
        }
        return p;
    }

    fn rgbFromXterm(n: u8) style.Rgb {
        return switch (n) {
            0 => .{ .r = 0, .g = 0, .b = 0 },
            1 => .{ .r = 128, .g = 0, .b = 0 },
            2 => .{ .r = 0, .g = 128, .b = 0 },
            3 => .{ .r = 128, .g = 128, .b = 0 },
            4 => .{ .r = 0, .g = 0, .b = 128 },
            5 => .{ .r = 128, .g = 0, .b = 128 },
            6 => .{ .r = 0, .g = 128, .b = 128 },
            7 => .{ .r = 192, .g = 192, .b = 192 },
            else => .{ .r = 128, .g = 128, .b = 128 },
        };
    }

    fn c_ui_theme_register(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        const name = util.getString(l, 1) orelse return 0;
        const palette = parsePalette(l, 2);
        rt.host.register_theme(rt.host.ctx, name, &palette);
        return 0;
    }

    fn c_ui_theme_set(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        const name = util.getString(l, 1) orelse return 0;
        rt.host.set_theme(rt.host.ctx, name);
        return 0;
    }

    fn c_keymap_set_fn(L: ?*lua.lua_State) callconv(.c) c_int {
        return keymapSet(L, false);
    }
    fn c_keymap_set_cmd(L: ?*lua.lua_State) callconv(.c) c_int {
        return keymapSet(L, true);
    }

    fn keymapSet(L: ?*lua.lua_State, is_command: bool) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        const mode = util.getString(l, 1) orelse return 0;
        const lhs = util.getString(l, 2) orelse return 0;
        const desc = util.getString(l, 4) orelse "";
        const key = @import("../key.zig").parseSpec(lhs, rt.leader) orelse {
            lua.lua_pushstring(l, "invalid key spec");
            _ = lua.lua_error(l);
            return 0;
        };
        var action: KeymapAction = undefined;
        if (is_command) {
            const cmd = util.getString(l, 3) orelse "";
            action = .{ .command = .{
                .name = rt.gpa.dupe(u8, cmd) catch return 0,
                .desc = rt.gpa.dupe(u8, desc) catch return 0,
            } };
        } else {
            lua.lua_pushvalue(l, 3);
            const ref = util.makeRef(l);
            action = .{ .callback = .{ .ref = ref, .desc = rt.gpa.dupe(u8, desc) catch "" } };
        }
        // Remove an existing mapping for the same mode+lhs.
        var i: usize = 0;
        while (i < rt.keymaps.items.len) : (i += 1) {
            if (std.mem.eql(u8, rt.keymaps.items[i].mode, mode) and std.mem.eql(u8, rt.keymaps.items[i].lhs, lhs)) {
                const old = rt.keymaps.orderedRemove(i);
                rt.gpa.free(old.mode);
                rt.gpa.free(old.lhs);
                rt.gpa.free(old.description);
                switch (old.action) {
                    .command => |c| {
                        rt.gpa.free(c.name);
                        rt.gpa.free(c.desc);
                    },
                    .callback => |cb| {
                        util.unref(rt.L, cb.ref);
                        rt.gpa.free(cb.desc);
                    },
                }
                break;
            }
        }
        rt.keymaps.append(rt.gpa, .{
            .mode = rt.gpa.dupe(u8, mode) catch "",
            .lhs = rt.gpa.dupe(u8, lhs) catch "",
            .key = key,
            .action = action,
            .description = rt.gpa.dupe(u8, desc) catch "",
        }) catch {};
        return 0;
    }

    fn c_keymap_del(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        const mode = util.getString(l, 1) orelse return 0;
        const lhs = util.getString(l, 2) orelse return 0;
        var i: usize = 0;
        while (i < rt.keymaps.items.len) : (i += 1) {
            if (std.mem.eql(u8, rt.keymaps.items[i].mode, mode) and std.mem.eql(u8, rt.keymaps.items[i].lhs, lhs)) {
                const old = rt.keymaps.orderedRemove(i);
                rt.gpa.free(old.mode);
                rt.gpa.free(old.lhs);
                rt.gpa.free(old.description);
                switch (old.action) {
                    .command => |c| {
                        rt.gpa.free(c.name);
                        rt.gpa.free(c.desc);
                    },
                    .callback => |cb| {
                        util.unref(rt.L, cb.ref);
                        rt.gpa.free(cb.desc);
                    },
                }
                break;
            }
        }
        return 0;
    }

    fn c_keymap_leader(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        if (util.getString(l, 1)) |s| {
            const d = @import("../text.zig").decode(s, 0);
            if (d.len > 0) rt.leader = d.cp;
        }
        var buf: [4]u8 = undefined;
        util.pushString(l, @import("../text.zig").encode(rt.leader, &buf));
        return 1;
    }

    fn c_tool_register(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        if (!util.isTable(l, 1)) return 0;
        const name = util.fieldString(l, 1, "name") orelse return 0;
        const desc = util.fieldString(l, 1, "description") orelse "";
        // Serialize schema to JSON for provider requests.
        util.field(l, 1, "schema");
        const schema_json: []u8 = luaToJson(rt.gpa, l, -1) orelse (rt.gpa.dupe(u8, "{}") catch return 0);
        util.pop(l, 1);
        util.field(l, 1, "permissions");
        const perms: []u8 = luaToJson(rt.gpa, l, -1) orelse (rt.gpa.dupe(u8, "[]") catch return 0);
        util.pop(l, 1);
        util.field(l, 1, "run");
        if (!util.isFunction(l, -1)) {
            util.pop(l, 1);
            lua.lua_pushstring(l, "tools.register requires a run function");
            _ = lua.lua_error(l);
            return 0;
        }
        const ref = util.makeRef(l);
        for (rt.tools.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) {
                util.unref(l, t.run_ref);
                rt.gpa.free(t.description);
                rt.gpa.free(t.schema_json);
                rt.gpa.free(t.permissions);
                t.description = rt.gpa.dupe(u8, desc) catch "";
                t.schema_json = schema_json;
                t.permissions = perms;
                t.run_ref = ref;
                return 0;
            }
        }
        rt.tools.append(rt.gpa, .{
            .name = rt.gpa.dupe(u8, name) catch "",
            .description = rt.gpa.dupe(u8, desc) catch "",
            .schema_json = schema_json,
            .permissions = perms,
            .run_ref = ref,
        }) catch {};
        return 0;
    }

    fn c_tool_list(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        util.newTable(l);
        for (rt.tools.items, 0..) |t, i| {
            util.newTable(l);
            util.setFieldString(l, -1, "name", t.name);
            util.setFieldString(l, -1, "description", t.description);
            util.setFieldString(l, -1, "schema", t.schema_json);
            util.rawSet(l, -3, @intCast(i + 1));
        }
        return 1;
    }

    fn c_model_set_route(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        if (!util.isFunction(l, 1)) return 0;
        lua.lua_pushvalue(l, 1);
        if (rt.route_ref >= 0) util.unref(l, rt.route_ref);
        rt.route_ref = util.makeRef(l);
        return 0;
    }

    fn c_read_file(L: ?*lua.lua_State) callconv(.c) c_int {
        const l = L orelse return 0;
        const rt = selfFromUpvalueFree(l);
        const path = util.getString(l, 1) orelse return 0;
        var out: ?[]u8 = null;
        const ok = rt.host.read_file(rt.host.ctx, path, &out);
        if (!ok or out == null) {
            lua.lua_pushnil(l);
            util.pushString(l, "read denied or failed");
            return 2;
        }
        defer rt.gpa.free(out.?);
        util.pushString(l, out.?);
        return 1;
    }
};

fn pushJsonValue(L: util.State, value: std.json.Value) !void {
    switch (value) {
        .null => lua.lua_pushnil(L),
        .bool => |b| lua.lua_pushboolean(L, if (b) 1 else 0),
        .integer => |i| lua.lua_pushinteger(L, @intCast(i)),
        .float => |f| lua.lua_pushnumber(L, f),
        .number_string => |s| util.pushString(L, s),
        .string => |s| util.pushString(L, s),
        .array => |arr| {
            util.newTable(L);
            for (arr.items, 0..) |v, i| {
                try pushJsonValue(L, v);
                util.rawSet(L, -2, @intCast(i + 1));
            }
        },
        .object => |obj| {
            util.newTable(L);
            var it = obj.iterator();
            while (it.next()) |entry| {
                util.pushString(L, entry.key_ptr.*);
                try pushJsonValue(L, entry.value_ptr.*);
                lua.lua_settable(L, -3);
            }
        },
    }
}

fn luaToJson(gpa: std.mem.Allocator, L: util.State, idx: c_int) ?[]u8 {
    var out = std.ArrayList(u8).empty;
    serializeLua(gpa, L, idx, &out, 0) catch |err| {
        std.debug.print("serialize error: {s} top={d}\n", .{ @errorName(err), util.top(L) });
        out.deinit(gpa);
        return null;
    };
    return out.toOwnedSlice(gpa) catch null;
}

fn serializeLua(gpa: std.mem.Allocator, L: util.State, idx: c_int, out: *std.ArrayList(u8), depth: usize) !void {
    if (depth > 32) return error.TooDeep;
    const abs = if (idx < 0) util.top(L) + idx + 1 else idx;
    switch (lua.lua_type(L, abs)) {
        lua.LUA_TNIL => try out.appendSlice(gpa, "null"),
        lua.LUA_TBOOLEAN => try out.appendSlice(gpa, if (util.getBool(L, abs)) "true" else "false"),
        lua.LUA_TNUMBER => {
            if (util.getInt(L, abs)) |i| {
                const tmp = try std.fmt.allocPrint(gpa, "{d}", .{i});
                defer gpa.free(tmp);
                try out.appendSlice(gpa, tmp);
            } else if (util.getNumber(L, abs)) |f| {
                const tmp = try std.fmt.allocPrint(gpa, "{d}", .{f});
                defer gpa.free(tmp);
                try out.appendSlice(gpa, tmp);
            } else try out.appendSlice(gpa, "null");
        },
        lua.LUA_TSTRING => {
            const s = util.getString(L, abs) orelse "";
            try appendJsonString(gpa, out, s);
        },
        lua.LUA_TTABLE => {
            const n = util.len(L, abs);
            if (n > 0) {
                try out.append(gpa, '[');
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    if (i > 0) try out.append(gpa, ',');
                    util.rawGet(L, abs, @intCast(i + 1));
                    try serializeLua(gpa, L, -1, out, depth + 1);
                    util.pop(L, 1);
                }
                try out.append(gpa, ']');
            } else {
                try out.append(gpa, '{');
                var first = true;
                lua.lua_pushnil(L);
                while (true) {
                    if (lua.lua_next(L, abs) == 0) break;
                    if (!first) try out.append(gpa, ',');
                    first = false;
                    if (util.getString(L, -2)) |key| {
                        try appendJsonString(gpa, out, key);
                    } else {
                        try out.appendSlice(gpa, "\"key\"");
                    }
                    try out.append(gpa, ':');
                    try serializeLua(gpa, L, -1, out, depth + 1);
                    util.pop(L, 1);
                }
                try out.append(gpa, '}');
            }
        },
        else => try out.appendSlice(gpa, "null"),
    }
}

fn dirName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        if (i == 0) return "/";
        return path[0..i];
    }
    return ".";
}

fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0x08 => try out.appendSlice(gpa, "\\b"),
            0x0c => try out.appendSlice(gpa, "\\f"),
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

fn c_ctx_notify(L: ?*lua.lua_State) callconv(.c) c_int {
    const l = L orelse return 0;
    const rt = selfFromUpvalueFree(l);
    // ctx:notify(msg[, opts]) => arg 2 is the message.
    const msg = util.getString(l, 2) orelse return 0;
    const is_error = util.getBool(l, 3);
    const owned = rt.gpa.dupe(u8, msg) catch return 0;
    defer rt.gpa.free(owned);
    rt.host.notifyFn(owned, is_error);
    return 0;
}

fn c_ctx_command(L: ?*lua.lua_State) callconv(.c) c_int {
    const l = L orelse return 0;
    const rt = selfFromUpvalueFree(l);
    const name = util.getString(l, 2) orelse return 0;
    const args = util.getString(l, 3) orelse "";
    const n = rt.gpa.dupe(u8, name) catch return 0;
    defer rt.gpa.free(n);
    const a = rt.gpa.dupe(u8, args) catch return 0;
    defer rt.gpa.free(a);
    rt.host.run_command(rt.host.ctx, n, a);
    return 0;
}

fn c_ctx_read_file(L: ?*lua.lua_State) callconv(.c) c_int {
    const l = L orelse return 0;
    const rt = selfFromUpvalueFree(l);
    const path = util.getString(l, 2) orelse {
        lua.lua_pushnil(l);
        util.pushString(l, "path required");
        return 2;
    };
    var out: ?[]u8 = null;
    if (!rt.host.read_file(rt.host.ctx, path, &out) or out == null) {
        lua.lua_pushnil(l);
        util.pushString(l, "read denied or failed (workspace policy)");
        return 2;
    }
    defer rt.gpa.free(out.?);
    util.pushString(l, out.?);
    return 1;
}

fn selfFromUpvalueFree(L: util.State) *Runtime {
    return Runtime.selfFromUpvalue(L);
}
