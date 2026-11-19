//! Small, validated marshaling helpers over the LuaJIT C API.
const std = @import("std");
const lua = @import("c.zig").c;

pub const State = *lua.lua_State;
pub const Status = struct {
    pub const ok = 0;
};

pub fn pushString(L: State, s: []const u8) void {
    lua.lua_pushlstring(L, s.ptr, s.len);
}

pub fn pushLStringZ(L: State, s: []const u8) void {
    lua.lua_pushlstring(L, s.ptr, s.len);
}

pub fn getString(L: State, idx: c_int) ?[]const u8 {
    var len_out: usize = 0;
    const p = lua.lua_tolstring(L, idx, &len_out);
    if (p == null) return null;
    return @as([*]const u8, @ptrCast(p))[0..len_out];
}

pub fn getInt(L: State, idx: c_int) ?i64 {
    var is_num: c_int = 0;
    const n = lua.lua_tointegerx(L, idx, &is_num);
    if (is_num == 0) return null;
    return @intCast(n);
}

pub fn getNumber(L: State, idx: c_int) ?f64 {
    var is_num: c_int = 0;
    const n = lua.lua_tonumberx(L, idx, &is_num);
    if (is_num == 0) return null;
    return @floatCast(n);
}

pub fn getBool(L: State, idx: c_int) bool {
    return lua.lua_toboolean(L, idx) != 0;
}

pub fn isTable(L: State, idx: c_int) bool {
    return lua.lua_type(L, idx) == lua.LUA_TTABLE;
}

pub fn isFunction(L: State, idx: c_int) bool {
    return lua.lua_type(L, idx) == lua.LUA_TFUNCTION;
}

pub fn isNil(L: State, idx: c_int) bool {
    return lua.lua_type(L, idx) == lua.LUA_TNIL;
}

pub fn field(L: State, idx: c_int, name: [:0]const u8) void {
    lua.lua_getfield(L, idx, name.ptr);
}

pub fn fieldString(L: State, idx: c_int, name: [:0]const u8) ?[]const u8 {
    field(L, idx, name);
    defer lua.lua_pop(L, 1);
    return getString(L, -1);
}

pub fn fieldNumber(L: State, idx: c_int, name: [:0]const u8) ?f64 {
    field(L, idx, name);
    defer lua.lua_pop(L, 1);
    return getNumber(L, -1);
}

pub fn fieldInt(L: State, idx: c_int, name: [:0]const u8) ?i64 {
    field(L, idx, name);
    defer lua.lua_pop(L, 1);
    return getInt(L, -1);
}

pub fn fieldBool(L: State, idx: c_int, name: [:0]const u8, default: bool) bool {
    field(L, idx, name);
    defer lua.lua_pop(L, 1);
    if (isNil(L, -1)) return default;
    return getBool(L, -1);
}

pub fn fieldTable(L: State, idx: c_int, name: [:0]const u8) bool {
    field(L, idx, name);
    if (!isTable(L, -1)) {
        lua.lua_pop(L, 1);
        return false;
    }
    return true;
}

pub fn setFieldString(L: State, idx: c_int, name: [:0]const u8, value: []const u8) void {
    const abs = if (idx < 0) top(L) + idx + 1 else idx;
    pushString(L, value);
    lua.lua_setfield(L, abs, name.ptr);
}

pub fn setFieldInt(L: State, idx: c_int, name: [:0]const u8, value: i64) void {
    const abs = if (idx < 0) top(L) + idx + 1 else idx;
    lua.lua_pushinteger(L, value);
    lua.lua_setfield(L, abs, name.ptr);
}

pub fn setFieldBool(L: State, idx: c_int, name: [:0]const u8, value: bool) void {
    const abs = if (idx < 0) top(L) + idx + 1 else idx;
    lua.lua_pushboolean(L, if (value) 1 else 0);
    lua.lua_setfield(L, abs, name.ptr);
}

pub fn setFieldNumber(L: State, idx: c_int, name: [:0]const u8, value: f64) void {
    const abs = if (idx < 0) top(L) + idx + 1 else idx;
    lua.lua_pushnumber(L, value);
    lua.lua_setfield(L, abs, name.ptr);
}

pub fn setGlobal(L: State, name: [:0]const u8) void {
    lua.lua_setglobal(L, name.ptr);
}

pub fn getGlobal(L: State, name: [:0]const u8) void {
    lua.lua_getglobal(L, name.ptr);
}

pub fn newTable(L: State) void {
    lua.lua_createtable(L, 0, 0);
}

pub fn rawSet(L: State, idx: c_int, key: i64) void {
    lua.lua_rawseti(L, idx, @intCast(key));
}

pub fn rawGet(L: State, idx: c_int, key: i64) void {
    lua.lua_rawgeti(L, idx, @intCast(key));
}

pub fn len(L: State, idx: c_int) usize {
    return lua.lua_objlen(L, idx);
}

pub fn pop(L: State, n: usize) void {
    lua.lua_pop(L, @as(c_int, @intCast(n)));
}

pub fn top(L: State) c_int {
    return lua.lua_gettop(L);
}

pub fn setTop(L: State, n: c_int) void {
    lua.lua_settop(L, n);
}

pub fn pushRef(L: State, ref: c_int) void {
    lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, ref);
}

pub fn makeRef(L: State) c_int {
    return lua.luaL_ref(L, lua.LUA_REGISTRYINDEX);
}

pub fn unref(L: State, ref: c_int) void {
    if (ref >= 0) lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, ref);
}

pub fn tracebackHandler(L: ?*lua.lua_State) callconv(.c) c_int {
    const Ls: State = L orelse return 0;
    const msg = getString(Ls, 1) orelse "(non-string error)";
    lua.luaL_traceback(Ls, Ls, msg.ptr, 1);
    return 1;
}

fn pushTraceback(L: State) void {
    lua.lua_pushcfunction(L, tracebackHandler);
}

/// Call the function currently below nargs values with a traceback handler.
/// On error, returns error.Lua and leaves the error string at the top of the
/// stack (unless capture_error is null; then the message is discarded).
pub fn pcall(
    L: State,
    nargs: c_int,
    nresults: c_int,
    capture: ?*std.ArrayList(u8),
    gpa: std.mem.Allocator,
) !void {
    const base = lua.lua_gettop(L) - nargs;
    pushTraceback(L);
    lua.lua_insert(L, base);
    const rc = lua.lua_pcall(L, nargs, nresults, base);
    lua.lua_remove(L, base);
    if (rc != 0) {
        if (capture) |buf| {
            if (getString(L, -1)) |msg| {
                buf.appendSlice(gpa, msg) catch {};
            }
        }
        lua.lua_pop(L, 1);
        return error.LuaError;
    }
}

pub fn ownError(gpa: std.mem.Allocator, msg: []const u8) ?[]u8 {
    return gpa.dupe(u8, msg) catch null;
}

pub fn setLoaded(L: State, name: []const u8) void {
    // Stack: table at top. Sets package.loaded[name] = table and global where applicable.
    lua.lua_getglobal(L, "package");
    lua.lua_getfield(L, -1, "loaded");
    lua.lua_pushvalue(L, -3);
    pushString(L, name);
    lua.lua_insert(L, -2);
    lua.lua_settable(L, -3);
    lua.lua_pop(L, 2);
}

pub fn loadBuffer(L: State, source: []const u8, name: []const u8, capture: ?*std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    const rc = lua.luaL_loadbuffer(L, source.ptr, source.len, name.ptr);
    if (rc != 0) {
        if (capture) |buf| {
            if (getString(L, -1)) |msg| buf.appendSlice(gpa, msg) catch {};
        }
        lua.lua_pop(L, 1);
        return error.LuaCompileError;
    }
    try pcall(L, 0, 0, capture, gpa);
}

pub fn formatError(gpa: std.mem.Allocator, context: []const u8, detail: []const u8) []u8 {
    return std.fmt.allocPrint(gpa, "{s}: {s}", .{ context, detail }) catch gpa.dupe(u8, context) catch &.{};
}

pub fn dupeZ(gpa: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const z = try gpa.allocSentinel(u8, s.len, 0);
    @memcpy(z[0..s.len], s);
    return z;
}
