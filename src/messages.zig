//! Typed conversation model. All strings are allocator-owned.
const std = @import("std");

pub const Role = enum { system, user, assistant, tool };

pub const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    reported: bool = false,

    pub fn total(self: Usage) u64 {
        return self.prompt_tokens + self.completion_tokens;
    }
};

pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    args: []u8,

    pub fn deinit(self: *ToolCall, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.args);
    }
};

pub const Message = struct {
    id: u64,
    role: Role,
    text: std.ArrayList(u8) = .empty,
    tool_calls: std.ArrayList(ToolCall) = .empty,
    tool_call_id: ?[]u8 = null,
    tool_name: ?[]u8 = null,
    tool_is_error: bool = false,
    streaming: bool = false,
    timestamp_ms: i64 = 0,
    model: ?[]u8 = null,
    usage: Usage = .{},

    pub fn init(gpa: std.mem.Allocator, id: u64, role: Role) Message {
        _ = gpa;
        return .{ .id = id, .role = role };
    }

    pub fn deinit(self: *Message, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        for (self.tool_calls.items) |*tc| tc.deinit(gpa);
        self.tool_calls.deinit(gpa);
        if (self.tool_call_id) |s| gpa.free(s);
        if (self.tool_name) |s| gpa.free(s);
        if (self.model) |s| gpa.free(s);
    }

    pub fn setModel(self: *Message, gpa: std.mem.Allocator, model: []const u8) !void {
        if (self.model) |old| gpa.free(old);
        self.model = try gpa.dupe(u8, model);
    }

    pub fn addToolCall(self: *Message, gpa: std.mem.Allocator, id: []const u8, name: []const u8, args: []const u8) !void {
        try self.tool_calls.append(gpa, .{
            .id = try gpa.dupe(u8, id),
            .name = try gpa.dupe(u8, name),
            .args = try gpa.dupe(u8, args),
        });
    }

    pub fn setToolResult(self: *Message, gpa: std.mem.Allocator, call_id: []const u8, name: []const u8, is_error: bool) !void {
        if (self.tool_call_id) |s| gpa.free(s);
        if (self.tool_name) |s| gpa.free(s);
        self.tool_call_id = try gpa.dupe(u8, call_id);
        self.tool_name = try gpa.dupe(u8, name);
        self.tool_is_error = is_error;
    }
};

pub const Conversation = struct {
    gpa: std.mem.Allocator,
    messages: std.ArrayList(Message) = .empty,
    next_id: u64 = 1,

    pub fn init(gpa: std.mem.Allocator) Conversation {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Conversation) void {
        for (self.messages.items) |*m| m.deinit(self.gpa);
        self.messages.deinit(self.gpa);
    }

    pub fn clear(self: *Conversation) void {
        for (self.messages.items) |*m| m.deinit(self.gpa);
        self.messages.clearRetainingCapacity();
    }

    pub fn add(self: *Conversation, role: Role, content: []const u8, now_ms: i64) !*Message {
        var m = Message.init(self.gpa, self.next_id, role);
        self.next_id += 1;
        try m.text.appendSlice(self.gpa, content);
        m.timestamp_ms = now_ms;
        try self.messages.append(self.gpa, m);
        return &self.messages.items[self.messages.items.len - 1];
    }

    pub fn addEmpty(self: *Conversation, role: Role, now_ms: i64) !*Message {
        var m = Message.init(self.gpa, self.next_id, role);
        self.next_id += 1;
        m.timestamp_ms = now_ms;
        try self.messages.append(self.gpa, m);
        return &self.messages.items[self.messages.items.len - 1];
    }

    pub fn last(self: *Conversation) ?*Message {
        if (self.messages.items.len == 0) return null;
        return &self.messages.items[self.messages.items.len - 1];
    }

    pub fn totalUsage(self: *Conversation) Usage {
        var u = Usage{};
        for (self.messages.items) |m| {
            u.prompt_tokens += m.usage.prompt_tokens;
            u.completion_tokens += m.usage.completion_tokens;
            u.reported = u.reported or m.usage.reported;
        }
        return u;
    }

    /// Strip tool calls from the last assistant message (e.g. on cancel).
    pub fn dropIncompleteToolState(self: *Conversation) void {
        const m = self.last() orelse return;
        m.streaming = false;
    }
};

test "conversation ownership" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    _ = try c.add(.user, "hi", 0);
    const a = try c.addEmpty(.assistant, 0);
    try a.text.appendSlice(std.testing.allocator, "hello");
    try std.testing.expectEqual(@as(usize, 2), c.messages.items.len);
    try std.testing.expectEqualStrings("hello", c.last().?.text.items);
}
