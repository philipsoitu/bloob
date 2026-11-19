//! Conversion between the session store's standalone `types.zig` mirror and
//! the application's `src/messages.zig` types.
//!
//! The store itself only imports `types.zig` so that
//! `nix develop -c zig test src/sessions/store.zig` works without widening the
//! module root. Application code imports this file to move loaded sessions into
//! the normal conversation model (and to persist existing messages).
const std = @import("std");
const native = @import("../messages.zig");
const types = @import("types.zig");

fn roleFromNative(role: native.Role) types.Role {
    return switch (role) {
        .system => .system,
        .user => .user,
        .assistant => .assistant,
        .tool => .tool,
    };
}

fn roleToNative(role: types.Role) native.Role {
    return switch (role) {
        .system => .system,
        .user => .user,
        .assistant => .assistant,
        .tool => .tool,
    };
}

pub fn fromNative(gpa: std.mem.Allocator, src: *const native.Message) !types.Message {
    var dst = types.Message.init(gpa, src.id, roleFromNative(src.role));
    errdefer dst.deinit(gpa);
    try dst.text.appendSlice(gpa, src.text.items);
    for (src.tool_calls.items) |tc| {
        try dst.addToolCall(gpa, tc.id, tc.name, tc.args);
    }
    if (src.tool_call_id) |id| dst.tool_call_id = try gpa.dupe(u8, id);
    if (src.tool_name) |name| dst.tool_name = try gpa.dupe(u8, name);
    dst.tool_is_error = src.tool_is_error;
    dst.streaming = src.streaming;
    dst.timestamp_ms = src.timestamp_ms;
    if (src.model) |model| try dst.setModel(gpa, model);
    dst.usage = .{
        .prompt_tokens = src.usage.prompt_tokens,
        .completion_tokens = src.usage.completion_tokens,
        .reported = src.usage.reported,
    };
    return dst;
}

pub fn toNative(gpa: std.mem.Allocator, src: *const types.Message) !native.Message {
    var dst = native.Message.init(gpa, src.id, roleToNative(src.role));
    errdefer dst.deinit(gpa);
    try dst.text.appendSlice(gpa, src.text.items);
    for (src.tool_calls.items) |tc| {
        try dst.addToolCall(gpa, tc.id, tc.name, tc.args);
    }
    if (src.tool_call_id) |id| dst.tool_call_id = try gpa.dupe(u8, id);
    if (src.tool_name) |name| dst.tool_name = try gpa.dupe(u8, name);
    dst.tool_is_error = src.tool_is_error;
    dst.streaming = src.streaming;
    dst.timestamp_ms = src.timestamp_ms;
    if (src.model) |model| try dst.setModel(gpa, model);
    dst.usage = .{
        .prompt_tokens = src.usage.prompt_tokens,
        .completion_tokens = src.usage.completion_tokens,
        .reported = src.usage.reported,
    };
    return dst;
}

pub fn conversationFromNative(gpa: std.mem.Allocator, src: *const native.Conversation) !types.Conversation {
    var dst = types.Conversation.init(gpa);
    errdefer dst.deinit();
    dst.next_id = src.next_id;
    for (src.messages.items) |*message| {
        var converted = try fromNative(gpa, message);
        errdefer converted.deinit(gpa);
        try dst.messages.append(gpa, converted);
    }
    return dst;
}

pub fn conversationToNative(gpa: std.mem.Allocator, src: *const types.Conversation) !native.Conversation {
    var dst = native.Conversation.init(gpa);
    errdefer dst.deinit();
    dst.next_id = src.next_id;
    for (src.messages.items) |*message| {
        var converted = try toNative(gpa, message);
        errdefer converted.deinit(gpa);
        try dst.messages.append(gpa, converted);
    }
    return dst;
}
