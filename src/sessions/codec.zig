//! JSONL encoding and decoding for the session store.
//!
//! This module deliberately depends only on the standard library and the local
//! `types.zig` mirror. It does not know about files, paths, or the Store.
const std = @import("std");
const types = @import("types.zig");

/// Bumped when the on-disk shape changes incompatibly. Readers accept older
/// versions (when they know how to) and reject newer ones.
pub const schema_version: u32 = 1;

/// Bounds. The store and codec both enforce these; they are intentionally
/// generous enough for normal coding sessions while preventing unbounded
/// memory and disk growth from a corrupted or malicious file.
pub const max_header_bytes: usize = 16 * 1024;
pub const max_message_bytes: usize = 4 * 1024 * 1024;
pub const max_text_bytes: usize = 2 * 1024 * 1024;
pub const max_cwd_bytes: usize = 4096;
pub const max_model_bytes: usize = 512;
pub const max_id_bytes: usize = 64;
pub const max_tool_calls: usize = 128;

pub const Error = error{
    CorruptHeader,
    CorruptMessage,
    HeaderTooLarge,
    IncompatibleSchemaVersion,
    InvalidField,
    InvalidSessionId,
    MessageTooLarge,
    TooManyToolCalls,
} || std.mem.Allocator.Error;

/// Metadata represented by the first JSONL line or by the metadata sidecar.
///
/// The parsed form owns all of its strings.
pub const Header = struct {
    schema_version: u32,
    id: []u8,
    cwd: []u8,
    model: []u8,
    created_ms: i64,
    updated_ms: i64,
    message_count: u64,

    pub fn deinit(self: *Header, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.cwd);
        gpa.free(self.model);
        self.* = undefined;
    }
};

/// Borrowed view used when encoding a header, so callers do not need to build
/// an owned `Header` just to write metadata.
pub const HeaderView = struct {
    schema_version: u32 = schema_version,
    id: []const u8,
    cwd: []const u8,
    model: []const u8,
    created_ms: i64,
    updated_ms: i64,
    message_count: u64 = 0,
};

/// Session ids are opaque to callers and are used directly as file names.
/// Restrict them to a safe, portable alphabet so `load`/`delete` cannot escape
/// the data directory.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_bytes) return false;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    for (id) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            else => return false,
        }
    }
    return true;
}

fn roleName(role: anytype) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

fn parseRole(s: []const u8) ?types.Role {
    if (std.mem.eql(u8, s, "system")) return .system;
    if (std.mem.eql(u8, s, "user")) return .user;
    if (std.mem.eql(u8, s, "assistant")) return .assistant;
    if (std.mem.eql(u8, s, "tool")) return .tool;
    return null;
}

const Json = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn init(gpa: std.mem.Allocator) Json {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *Json) void {
        self.out.deinit(self.gpa);
    }

    fn raw(self: *Json, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }

    fn str(self: *Json, s: []const u8) !void {
        try self.out.append(self.gpa, '"');
        for (s) |c| {
            switch (c) {
                '"' => try self.out.appendSlice(self.gpa, "\\\""),
                '\\' => try self.out.appendSlice(self.gpa, "\\\\"),
                '\n' => try self.out.appendSlice(self.gpa, "\\n"),
                '\r' => try self.out.appendSlice(self.gpa, "\\r"),
                '\t' => try self.out.appendSlice(self.gpa, "\\t"),
                0x08 => try self.out.appendSlice(self.gpa, "\\b"),
                0x0c => try self.out.appendSlice(self.gpa, "\\f"),
                else => {
                    if (c < 0x20) {
                        const hex = "0123456789abcdef";
                        try self.out.appendSlice(self.gpa, "\\u00");
                        try self.out.append(self.gpa, hex[c >> 4]);
                        try self.out.append(self.gpa, hex[c & 0xF]);
                    } else {
                        try self.out.append(self.gpa, c);
                    }
                },
            }
        }
        try self.out.append(self.gpa, '"');
    }

    fn int(self: *Json, value: anytype) !void {
        try self.out.print(self.gpa, "{d}", .{value});
    }

    fn boolean(self: *Json, value: bool) !void {
        try self.raw(if (value) "true" else "false");
    }

    fn optionalStr(self: *Json, value: ?[]const u8) !void {
        if (value) |s| try self.str(s) else try self.raw("null");
    }

    fn take(self: *Json) ![]u8 {
        return self.out.toOwnedSlice(self.gpa);
    }
};

fn validateHeaderView(view: HeaderView) Error!void {
    if (!validId(view.id)) return error.InvalidSessionId;
    if (view.cwd.len == 0 or view.cwd.len > max_cwd_bytes) return error.InvalidField;
    if (std.mem.indexOfScalar(u8, view.cwd, 0) != null) return error.InvalidField;
    if (view.model.len > max_model_bytes) return error.InvalidField;
    if (std.mem.indexOfScalar(u8, view.model, 0) != null) return error.InvalidField;
}

fn encodeMeta(gpa: std.mem.Allocator, view: HeaderView, typ: []const u8) Error![]u8 {
    try validateHeaderView(view);
    var j = Json.init(gpa);
    errdefer j.deinit();

    try j.raw("{\"type\":");
    try j.str(typ);
    try j.raw(",\"schema_version\":");
    try j.int(view.schema_version);
    try j.raw(",\"id\":");
    try j.str(view.id);
    try j.raw(",\"created_at_ms\":");
    try j.int(view.created_ms);
    try j.raw(",\"updated_at_ms\":");
    try j.int(view.updated_ms);
    try j.raw(",\"cwd\":");
    try j.str(view.cwd);
    try j.raw(",\"model\":");
    try j.str(view.model);
    try j.raw(",\"message_count\":");
    try j.int(view.message_count);
    try j.raw("}");

    if (j.out.items.len > max_header_bytes) return error.HeaderTooLarge;
    return j.take();
}

pub fn encodeHeader(gpa: std.mem.Allocator, view: HeaderView) Error![]u8 {
    return encodeMeta(gpa, view, "session");
}

pub fn encodeMetaFile(gpa: std.mem.Allocator, view: HeaderView) Error![]u8 {
    return encodeMeta(gpa, view, "meta");
}

/// Encode one message as a single JSON object (no trailing newline).
pub fn encodeMessage(gpa: std.mem.Allocator, m: anytype) Error![]u8 {
    if (m.text.items.len > max_text_bytes) return error.MessageTooLarge;
    if (m.tool_calls.items.len > max_tool_calls) return error.TooManyToolCalls;
    if (m.model) |model| {
        if (model.len > max_model_bytes) return error.InvalidField;
    }

    var j = Json.init(gpa);
    errdefer j.deinit();

    try j.raw("{\"type\":");
    try j.str("message");
    try j.raw(",\"id\":");
    try j.int(m.id);
    try j.raw(",\"role\":");
    try j.str(roleName(m.role));
    try j.raw(",\"text\":");
    try j.str(m.text.items);
    try j.raw(",\"timestamp_ms\":");
    try j.int(m.timestamp_ms);
    try j.raw(",\"model\":");
    try j.optionalStr(m.model);
    // Streaming is a transient UI state. It is written as false so a resumed
    // session never appears to be in the middle of a live model response.
    try j.raw(",\"streaming\":false");
    try j.raw(",\"tool_calls\":[");
    for (m.tool_calls.items, 0..) |tc, i| {
        if (i > 0) try j.raw(",");
        try j.raw("{\"id\":");
        try j.str(tc.id);
        try j.raw(",\"name\":");
        try j.str(tc.name);
        try j.raw(",\"args\":");
        try j.str(tc.args);
        try j.raw("}");
    }
    try j.raw("],\"tool_call_id\":");
    try j.optionalStr(m.tool_call_id);
    try j.raw(",\"tool_name\":");
    try j.optionalStr(m.tool_name);
    try j.raw(",\"tool_is_error\":");
    try j.boolean(m.tool_is_error);
    try j.raw(",\"usage\":{\"prompt_tokens\":");
    try j.int(m.usage.prompt_tokens);
    try j.raw(",\"completion_tokens\":");
    try j.int(m.usage.completion_tokens);
    try j.raw(",\"reported\":");
    try j.boolean(m.usage.reported);
    try j.raw("}}");

    if (j.out.items.len > max_message_bytes) return error.MessageTooLarge;
    return j.take();
}

fn fieldString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn fieldInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| blk: {
            if (!std.math.isFinite(f)) break :blk null;
            const min: f64 = -9.223372036854776e18;
            const max: f64 = 9.223372036854776e18;
            if (f < min or f > max) break :blk null;
            break :blk @intFromFloat(f);
        },
        else => null,
    };
}

fn fieldBool(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        else => default,
    };
}

fn parseJsonObject(gpa: std.mem.Allocator, line: []const u8, comptime corrupt: Error) Error!std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return corrupt,
    };
}

/// Parse a header or metadata sidecar line. `expected_type` is `"session"` for
/// the JSONL header and `"meta"` for the sidecar.
pub fn parseMeta(gpa: std.mem.Allocator, line: []const u8, expected_type: []const u8) Error!Header {
    if (line.len > max_header_bytes) return error.HeaderTooLarge;
    var parsed = try parseJsonObject(gpa, line, error.CorruptHeader);
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.CorruptHeader,
    };

    const typ = fieldString(obj, "type") orelse return error.CorruptHeader;
    if (!std.mem.eql(u8, typ, expected_type)) return error.CorruptHeader;

    const sv_i = fieldInt(obj, "schema_version") orelse return error.CorruptHeader;
    if (sv_i <= 0) return error.CorruptHeader;
    if (sv_i > @as(i64, schema_version)) return error.IncompatibleSchemaVersion;
    const sv: u32 = @intCast(sv_i);

    const id_s = fieldString(obj, "id") orelse return error.CorruptHeader;
    if (!validId(id_s)) return error.InvalidSessionId;
    const cwd_s = fieldString(obj, "cwd") orelse return error.CorruptHeader;
    const model_s = fieldString(obj, "model") orelse return error.CorruptHeader;
    if (cwd_s.len == 0 or cwd_s.len > max_cwd_bytes) return error.InvalidField;
    if (std.mem.indexOfScalar(u8, cwd_s, 0) != null) return error.InvalidField;
    if (model_s.len > max_model_bytes) return error.InvalidField;
    if (std.mem.indexOfScalar(u8, model_s, 0) != null) return error.InvalidField;
    const created = fieldInt(obj, "created_at_ms") orelse return error.CorruptHeader;
    const updated = fieldInt(obj, "updated_at_ms") orelse created;
    const count_i = fieldInt(obj, "message_count") orelse 0;
    if (count_i < 0) return error.CorruptHeader;

    const id = try gpa.dupe(u8, id_s);
    errdefer gpa.free(id);
    const cwd = try gpa.dupe(u8, cwd_s);
    errdefer gpa.free(cwd);
    const model = try gpa.dupe(u8, model_s);

    return .{
        .schema_version = sv,
        .id = id,
        .cwd = cwd,
        .model = model,
        .created_ms = created,
        .updated_ms = updated,
        .message_count = @intCast(count_i),
    };
}

/// Parse one message line. The returned message owns its strings and must be
/// destroyed with `Message.deinit`.
pub fn parseMessage(gpa: std.mem.Allocator, line: []const u8) Error!types.Message {
    if (line.len > max_message_bytes) return error.MessageTooLarge;
    var parsed = try parseJsonObject(gpa, line, error.CorruptMessage);
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.CorruptMessage,
    };

    const typ = fieldString(obj, "type") orelse return error.CorruptMessage;
    if (!std.mem.eql(u8, typ, "message")) return error.CorruptMessage;

    const role_s = fieldString(obj, "role") orelse return error.CorruptMessage;
    const role = parseRole(role_s) orelse return error.CorruptMessage;
    const id_i = fieldInt(obj, "id") orelse 0;
    const id: u64 = if (id_i < 0) 0 else @intCast(id_i);

    var m = types.Message.init(gpa, id, role);
    errdefer m.deinit(gpa);

    if (fieldString(obj, "text")) |text| {
        if (text.len > max_text_bytes) return error.MessageTooLarge;
        try m.text.appendSlice(gpa, text);
    }
    m.timestamp_ms = fieldInt(obj, "timestamp_ms") orelse 0;
    if (fieldString(obj, "model")) |model| {
        if (model.len > max_model_bytes) return error.InvalidField;
        try m.setModel(gpa, model);
    }
    // Never resume a streaming message as streaming.
    m.streaming = false;

    if (obj.get("tool_calls")) |tcv| {
        const arr = switch (tcv) {
            .array => |a| a,
            else => return error.CorruptMessage,
        };
        if (arr.items.len > max_tool_calls) return error.TooManyToolCalls;
        for (arr.items) |item| {
            if (item != .object) return error.CorruptMessage;
            const tc = item.object;
            const tc_id = fieldString(tc, "id") orelse return error.CorruptMessage;
            const tc_name = fieldString(tc, "name") orelse return error.CorruptMessage;
            const tc_args = fieldString(tc, "args") orelse return error.CorruptMessage;
            try m.addToolCall(gpa, tc_id, tc_name, tc_args);
        }
    }

    if (fieldString(obj, "tool_call_id")) |call_id| {
        m.tool_call_id = try gpa.dupe(u8, call_id);
    }
    if (fieldString(obj, "tool_name")) |tool_name| {
        m.tool_name = try gpa.dupe(u8, tool_name);
    }
    m.tool_is_error = fieldBool(obj, "tool_is_error", false);

    if (obj.get("usage")) |uv| {
        const usage_obj = switch (uv) {
            .object => |o| o,
            else => return error.CorruptMessage,
        };
        const prompt_i = fieldInt(usage_obj, "prompt_tokens") orelse 0;
        const completion_i = fieldInt(usage_obj, "completion_tokens") orelse 0;
        if (prompt_i < 0 or completion_i < 0) return error.CorruptMessage;
        m.usage.prompt_tokens = @intCast(prompt_i);
        m.usage.completion_tokens = @intCast(completion_i);
        m.usage.reported = fieldBool(usage_obj, "reported", false);
    }

    return m;
}

test "session id validation" {
    try std.testing.expect(validId("abc-DEF_0123"));
    try std.testing.expect(!validId(""));
    try std.testing.expect(!validId(".."));
    try std.testing.expect(!validId("../escape"));
    try std.testing.expect(!validId("with/slash"));
    try std.testing.expect(!validId("with.dot"));
}

test "message roundtrip" {
    const gpa = std.testing.allocator;
    var original = types.Message.init(gpa, 7, .assistant);
    defer original.deinit(gpa);
    try original.text.appendSlice(gpa, "hello \"world\"\nline two");
    try original.setModel(gpa, "mock/fixture");
    original.timestamp_ms = 1234;
    try original.addToolCall(gpa, "call_1", "read_file", "{\"path\":\"README.md\"}");
    original.usage = .{ .prompt_tokens = 10, .completion_tokens = 4, .reported = true };

    const line = try encodeMessage(gpa, &original);
    defer gpa.free(line);
    var decoded = try parseMessage(gpa, line);
    defer decoded.deinit(gpa);

    try std.testing.expectEqual(@as(u64, 7), decoded.id);
    try std.testing.expectEqual(types.Role.assistant, decoded.role);
    try std.testing.expectEqualStrings(original.text.items, decoded.text.items);
    try std.testing.expectEqualStrings("mock/fixture", decoded.model.?);
    try std.testing.expectEqual(@as(i64, 1234), decoded.timestamp_ms);
    try std.testing.expectEqual(@as(usize, 1), decoded.tool_calls.items.len);
    try std.testing.expectEqualStrings("call_1", decoded.tool_calls.items[0].id);
    try std.testing.expectEqual(@as(u64, 10), decoded.usage.prompt_tokens);
    try std.testing.expect(decoded.usage.reported);
}

test "header future schema is rejected" {
    const gpa = std.testing.allocator;
    const line =
        \\{"type":"session","schema_version":999,"id":"abc","created_at_ms":1,"updated_at_ms":2,"cwd":"/tmp","model":"m","message_count":0}
    ;
    try std.testing.expectError(error.IncompatibleSchemaVersion, parseMeta(gpa, line, "session"));
}
