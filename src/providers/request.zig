//! Provider request serialization. All text is JSON-escaped; tool schemas are
//! embedded as JSON objects and never constructed by string concatenation.
const std = @import("std");
const messages = @import("../messages.zig");

pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8,
    schema_json: []const u8,
};

pub const Json = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Json {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Json) void {
        self.out.deinit(self.gpa);
    }
    pub fn raw(self: *Json, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }
    pub fn str(self: *Json, s: []const u8) !void {
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
    pub fn key(self: *Json, k: []const u8) !void {
        try self.str(k);
        try self.out.append(self.gpa, ':');
    }
    pub fn take(self: *Json) ![]u8 {
        return self.out.toOwnedSlice(self.gpa);
    }
};

fn roleName(role: messages.Role) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

fn appendOpenAiTools(j: *Json, tools: []const ToolSchema) !void {
    if (tools.len == 0) return;
    try j.out.appendSlice(j.gpa, ",\"tools\":[");
    for (tools, 0..) |t, i| {
        if (i > 0) try j.out.append(j.gpa, ',');
        try j.raw("{\"type\":\"function\",\"function\":{");
        try j.key("name");
        try j.str(t.name);
        try j.out.append(j.gpa, ',');
        try j.key("description");
        try j.str(t.description);
        try j.out.append(j.gpa, ',');
        try j.key("parameters");
        if (t.schema_json.len > 0) try j.raw(t.schema_json) else try j.raw("{}");
        try j.raw("}}");
    }
    try j.out.append(j.gpa, ']');
}

pub fn buildOpenAi(
    gpa: std.mem.Allocator,
    model: []const u8,
    system_prompt: []const u8,
    conv: *const messages.Conversation,
    tools: []const ToolSchema,
) ![]u8 {
    var j = Json.init(gpa);
    defer j.deinit();
    try j.raw("{\"model\":");
    try j.str(model);
    try j.raw(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");
    try j.raw("{\"role\":\"system\",\"content\":");
    try j.str(system_prompt);
    try j.raw("}");
    for (conv.messages.items) |*m| {
        if (m.role == .system) continue;
        try j.out.append(gpa, ',');
        try j.raw("{\"role\":");
        try j.str(roleName(m.role));
        try j.raw(",\"content\":");
        try j.str(m.text.items);
        if (m.role == .assistant and m.tool_calls.items.len > 0) {
            try j.raw(",\"tool_calls\":[");
            for (m.tool_calls.items, 0..) |tc, i| {
                if (i > 0) try j.out.append(gpa, ',');
                try j.raw("{\"id\":");
                try j.str(tc.id);
                try j.raw(",\"type\":\"function\",\"function\":{\"name\":");
                try j.str(tc.name);
                try j.raw(",\"arguments\":");
                try j.str(tc.args);
                try j.raw("}}");
            }
            try j.out.append(gpa, ']');
        }
        if (m.role == .tool) {
            try j.raw(",\"tool_call_id\":");
            try j.str(m.tool_call_id orelse "");
        }
        try j.out.append(gpa, '}');
    }
    try j.out.append(gpa, ']');
    try appendOpenAiTools(&j, tools);
    try j.out.append(gpa, '}');
    return j.take();
}

fn anthropicBlocksOpen() []const u8 {
    return "\"content\":[";
}

/// Anthropic messages require alternating roles. Consecutive conversation
/// messages of the same effective role are merged into one content block array.
pub fn buildAnthropic(
    gpa: std.mem.Allocator,
    model: []const u8,
    system_prompt: []const u8,
    conv: *const messages.Conversation,
    tools: []const ToolSchema,
    max_tokens: u32,
) ![]u8 {
    var j = Json.init(gpa);
    defer j.deinit();
    try j.raw("{\"model\":");
    try j.str(model);
    try j.raw(",\"max_tokens\":");
    const max_buf = try std.fmt.allocPrint(gpa, "{d}", .{max_tokens});
    defer gpa.free(max_buf);
    try j.raw(max_buf);
    try j.raw(",\"stream\":true,\"system\":");
    try j.str(system_prompt);
    try j.raw(",\"messages\":[");
    var open = false;
    var current_role: []const u8 = "";
    var emitted_any = false;
    for (conv.messages.items) |*m| {
        if (m.role == .system) continue;
        const role: []const u8 = if (m.role == .tool) "user" else if (m.role == .assistant) "assistant" else "user";
        var bj = Json.init(gpa);
        defer bj.deinit();
        if (m.role == .tool) {
            try bj.raw("{\"type\":\"tool_result\",\"tool_use_id\":");
            try bj.str(m.tool_call_id orelse "");
            try bj.raw(",\"content\":");
            try bj.str(m.text.items);
            if (m.tool_is_error) try bj.raw(",\"is_error\":true");
            try bj.out.append(gpa, '}');
        } else {
            if (m.text.items.len > 0) {
                try bj.raw("{\"type\":\"text\",\"text\":");
                try bj.str(m.text.items);
                try bj.out.append(gpa, '}');
            }
            if (m.role == .assistant) {
                for (m.tool_calls.items) |tc| {
                    if (bj.out.items.len > 0) try bj.out.append(gpa, ',');
                    try bj.raw("{\"type\":\"tool_use\",\"id\":");
                    try bj.str(tc.id);
                    try bj.raw(",\"name\":");
                    try bj.str(tc.name);
                    try bj.raw(",\"input\":");
                    if (tc.args.len > 0) try bj.raw(tc.args) else try bj.raw("{}");
                    try bj.out.append(gpa, '}');
                }
            }
        }
        if (bj.out.items.len == 0) continue;
        if (!open or !std.mem.eql(u8, role, current_role)) {
            if (open) try j.out.appendSlice(gpa, "] },");
            if (!emitted_any and std.mem.eql(u8, role, "assistant")) continue;
            try j.raw("{\"role\":");
            try j.str(role);
            try j.out.append(gpa, ',');
            try j.out.appendSlice(gpa, anthropicBlocksOpen());
            open = true;
            current_role = role;
            emitted_any = true;
        } else {
            try j.out.append(gpa, ',');
        }
        try j.out.appendSlice(gpa, bj.out.items);
    }
    if (open) try j.out.appendSlice(gpa, "] }");
    try j.out.appendSlice(gpa, "]");
    if (tools.len > 0) {
        try j.out.appendSlice(gpa, ",\"tools\":[");
        for (tools, 0..) |t, i| {
            if (i > 0) try j.out.append(gpa, ',');
            try j.raw("{\"name\":");
            try j.str(t.name);
            try j.raw(",\"description\":");
            try j.str(t.description);
            try j.raw(",\"input_schema\":");
            if (t.schema_json.len > 0) try j.raw(t.schema_json) else try j.raw("{}");
            try j.out.append(gpa, '}');
        }
        try j.out.append(gpa, ']');
    }
    try j.out.append(gpa, '}');
    return j.take();
}
test "openai request serializes messages, tools and tool calls" {
    const gpa = std.testing.allocator;
    var conv = messages.Conversation.init(gpa);
    defer conv.deinit();
    _ = try conv.add(.user, "hello \"world\"", 0);
    const a = try conv.addEmpty(.assistant, 0);
    try a.text.appendSlice(gpa, "checking");
    try a.addToolCall(gpa, "call_1", "read_file", "{\"path\":\"README.md\"}");
    const t = try conv.add(.tool, "file contents", 0);
    try t.setToolResult(gpa, "call_1", "read_file", false);
    const tools = [_]ToolSchema{.{ .name = "read_file", .description = "read", .schema_json = "{\"type\":\"object\"}" }};
    const body = try buildOpenAi(gpa, "gpt-x", "You are bloob.", &conv, &tools);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello \\\"world\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parameters\":{\"type\":\"object\"}") != null);
}

test "anthropic request serializes tool results" {
    const gpa = std.testing.allocator;
    var conv = messages.Conversation.init(gpa);
    defer conv.deinit();
    _ = try conv.add(.user, "hello", 0);
    const t = try conv.add(.tool, "result", 0);
    try t.setToolResult(gpa, "toolu_1", "read_file", true);
    const body = try buildAnthropic(gpa, "claude-x", "system", &conv, &.{}, 1024);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"is_error\":true") != null);
}
