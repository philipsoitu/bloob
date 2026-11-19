//! Noninteractive runner for --print / --json. No terminal escapes, no prompts:
//! tool operations that need approval are denied by default.
const std = @import("std");
const messages = @import("messages.zig");
const workspace_mod = @import("core/workspace.zig");
const permissions = @import("tools/permissions.zig");
const tools = @import("tools/tools.zig");
const providers = @import("providers/stream.zig");
const registry = @import("providers/registry.zig");
const request = @import("providers/request.zig");
const prompts = @import("agent/prompts.zig");

pub const Options = struct {
    model: []const u8,
    prompt: []const u8,
    cwd: []const u8,
    json: bool = false,
    max_iterations: u32 = 6,
};

const Out = struct {
    io: std.Io,
    json: bool,
    wrote_text: bool = false,

    fn write(self: *Out, bytes: []const u8) !void {
        try std.Io.File.stdout().writeStreamingAll(self.io, bytes);
    }

    fn eventStart(self: *Out, model: []const u8) !void {
        if (!self.json) return;
        const slash = std.mem.indexOfScalar(u8, model, '/');
        const provider = if (slash) |i| model[0..i] else model;
        const model_id = if (slash) |i| model[i + 1 ..] else "";
        var out = std.ArrayList(u8).empty;
        defer out.deinit(std.heap.page_allocator);
        try out.appendSlice(std.heap.page_allocator, "{\"type\":\"start\",\"provider\":");
        try appendJson(std.heap.page_allocator, &out, provider);
        try out.appendSlice(std.heap.page_allocator, ",\"model\":");
        try appendJson(std.heap.page_allocator, &out, model_id);
        try out.appendSlice(std.heap.page_allocator, "}\n");
        try self.write(out.items);
    }

    fn textDelta(self: *Out, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.json) {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(std.heap.page_allocator);
            try out.appendSlice(std.heap.page_allocator, "{\"type\":\"text_delta\",\"text\":");
            try appendJson(std.heap.page_allocator, &out, text);
            try out.appendSlice(std.heap.page_allocator, "}\n");
            try self.write(out.items);
        } else {
            try self.write(text);
            self.wrote_text = true;
        }
    }

    fn eventText(self: *Out, text: []const u8) !void {
        if (self.json) {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(std.heap.page_allocator);
            try out.appendSlice(std.heap.page_allocator, "{\"type\":\"text\",\"text\":");
            try appendJson(std.heap.page_allocator, &out, text);
            try out.appendSlice(std.heap.page_allocator, "}\n");
            try self.write(out.items);
        } else {
            try self.write(text);
        }
    }

    fn eventToolCall(self: *Out, name: []const u8, args: []const u8) !void {
        if (!self.json) return;
        var out = std.ArrayList(u8).empty;
        defer out.deinit(std.heap.page_allocator);
        try out.appendSlice(std.heap.page_allocator, "{\"type\":\"tool_call\",\"name\":");
        try appendJson(std.heap.page_allocator, &out, name);
        try out.appendSlice(std.heap.page_allocator, ",\"arguments\":");
        try appendJson(std.heap.page_allocator, &out, args);
        try out.appendSlice(std.heap.page_allocator, "}\n");
        try self.write(out.items);
    }

    fn eventToolResult(self: *Out, name: []const u8, content: []const u8, is_error: bool) !void {
        if (!self.json) return;
        var out = std.ArrayList(u8).empty;
        defer out.deinit(std.heap.page_allocator);
        try out.appendSlice(std.heap.page_allocator, "{\"type\":\"tool_result\",\"name\":");
        try appendJson(std.heap.page_allocator, &out, name);
        try out.appendSlice(std.heap.page_allocator, ",\"is_error\":");
        try out.appendSlice(std.heap.page_allocator, if (is_error) "true" else "false");
        try out.appendSlice(std.heap.page_allocator, ",\"content\":");
        try appendJson(std.heap.page_allocator, &out, content);
        try out.appendSlice(std.heap.page_allocator, "}\n");
        try self.write(out.items);
    }

    fn eventDone(self: *Out, usage: messages.Usage) !void {
        if (!self.json) {
            if (!self.wrote_text) try self.write("\n");
            return;
        }
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{{\"type\":\"done\",\"usage\":{{\"reported\":{s},\"prompt_tokens\":{d},\"completion_tokens\":{d}}}}}\n", .{
            if (usage.reported) "true" else "false",
            usage.prompt_tokens,
            usage.completion_tokens,
        }) catch return;
        try self.write(s);
    }

    fn eventError(self: *Out, msg: []const u8) !void {
        if (!self.json) {
            try self.write("bloob: ");
            try self.write(msg);
            try self.write("\n");
            return;
        }
        var out = std.ArrayList(u8).empty;
        defer out.deinit(std.heap.page_allocator);
        try out.appendSlice(std.heap.page_allocator, "{\"type\":\"error\",\"message\":");
        try appendJson(std.heap.page_allocator, &out, msg);
        try out.appendSlice(std.heap.page_allocator, "}\n");
        try self.write(out.items);
    }
};

fn appendJson(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
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
                } else try out.append(gpa, c);
            },
        }
    }
    try out.append(gpa, '"');
}

fn builtinSchemas(gpa: std.mem.Allocator) ![]request.ToolSchema {
    var list = std.ArrayList(request.ToolSchema).empty;
    errdefer list.deinit(gpa);
    for (&tools.defs) |*d| {
        try list.append(gpa, .{ .name = d.name, .description = d.description, .schema_json = d.schema });
    }
    return list.toOwnedSlice(gpa);
}

pub fn run(init: std.Io, gpa: std.mem.Allocator, opts: Options) !void {
    var out = Out{ .io = init, .json = opts.json };
    var conv = messages.Conversation.init(gpa);
    defer conv.deinit();
    _ = try conv.add(.user, opts.prompt, 0);
    if (registry.isMock(opts.model)) {
        try out.eventStart(opts.model);
        const text = try std.fmt.allocPrint(gpa, "[mock/fixture — deterministic offline output; no model was contacted]\n\nDeterministic fixture response.\nprompt: {s}\n", .{opts.prompt});
        defer gpa.free(text);
        try out.eventText(text);
        try out.eventDone(.{});
        return;
    }
    var resolved = registry.resolve(gpa, opts.model) catch |err| {
        try out.eventError(switch (err) {
            error.MissingApiKey => "API key is not set. Export OPENAI_API_KEY or ANTHROPIC_API_KEY.",
            error.MissingBaseUrl => "BLOOB_COMPAT_BASE_URL is not set.",
            error.InvalidModel => "Model must be provider/model.",
            error.UnsupportedProvider => "Unsupported provider.",
            else => "Provider configuration error.",
        });
        return error.ProviderConfiguration;
    };
    defer resolved.deinit();
    var workspace = workspace_mod.Workspace.init(gpa, init, opts.cwd) catch |err| {
        try out.eventError(@errorName(err));
        return err;
    };
    defer workspace.deinit();
    var perms = permissions.Engine.init(gpa);
    defer perms.deinit();
    perms.workspace = &workspace;
    const schemas = try builtinSchemas(gpa);
    defer gpa.free(schemas);
    const system = try prompts.systemPrompt(gpa, workspace.root);
    defer gpa.free(system);
    try out.eventStart(opts.model);
    var iter: u32 = 0;
    while (iter < opts.max_iterations) : (iter += 1) {
        const body = switch (resolved.kind) {
            .openai => try request.buildOpenAi(gpa, resolved.model, system, &conv, schemas),
            .anthropic => try request.buildAnthropic(gpa, resolved.model, system, &conv, schemas, 8192),
        };
        defer gpa.free(body);
        const s = providers.Stream.start(gpa, init, resolved.kind, resolved.url, resolved.api_key, body) catch |err| {
            const msg = try std.fmt.allocPrint(gpa, "failed to start provider: {s}", .{@errorName(err)});
            defer gpa.free(msg);
            try out.eventError(msg);
            return err;
        };
        defer s.deinit();
        var emit_pos: usize = 0;
        while (!s.acc.done) {
            var fds: [2]std.posix.pollfd = undefined;
            var n: usize = 0;
            if (s.stdoutFd()) |fd| {
                fds[n] = .{ .fd = fd, .events = std.posix.POLL.IN };
                n += 1;
            }
            if (s.stderrFd()) |fd| {
                fds[n] = .{ .fd = fd, .events = std.posix.POLL.IN };
                n += 1;
            }
            if (n == 0) break;
            _ = std.posix.poll(fds[0..n], 1000) catch continue;
            s.pump();
            if (emit_pos < s.acc.text.items.len) {
                try out.textDelta(s.acc.text.items[emit_pos..]);
                emit_pos = s.acc.text.items.len;
            }
        }
        if (emit_pos < s.acc.text.items.len) try out.textDelta(s.acc.text.items[emit_pos..]);
        if (s.acc.error_message) |e| {
            const msg = try std.fmt.allocPrint(gpa, "provider error: {s}", .{e});
            defer gpa.free(msg);
            try out.eventError(msg);
            return error.ProviderError;
        }
        var tool_count: usize = 0;
        for (s.acc.tool_calls.items) |tc| {
            if (tc.name.items.len == 0) continue;
            tool_count += 1;
        }
        const assistant = try conv.addEmpty(.assistant, 0);
        assistant.usage = s.acc.usage;
        if (s.acc.text.items.len > 0) try assistant.text.appendSlice(gpa, s.acc.text.items);
        for (s.acc.tool_calls.items) |tc| {
            if (tc.name.items.len == 0) continue;
            const call_id = if (tc.id.items.len > 0) tc.id.items else "call_headless";
            const args = if (tc.args.items.len > 0) tc.args.items else "{}";
            try assistant.addToolCall(gpa, call_id, tc.name.items, args);
            try out.eventToolCall(tc.name.items, args);
        }
        if (tool_count == 0) {
            try out.eventDone(s.acc.usage);
            return;
        }
        const calls = try gpa.dupe(messages.ToolCall, assistant.tool_calls.items);
        defer gpa.free(calls);
        for (calls) |tc| {
            const def = tools.findDef(tc.name) orelse {
                try out.eventToolResult(tc.name, "unknown tool", true);
                try appendHeadlessToolResult(gpa, &conv, tc, "unknown tool", true);
                continue;
            };
            const decision = perms.evaluate(.{ .tool = def.name, .capability = def.capability });
            if (decision == .ask or decision == .deny) {
                const denied = "denied: headless mode does not auto-approve this tool";
                try out.eventToolResult(def.name, denied, true);
                try appendHeadlessToolResult(gpa, &conv, tc, denied, true);
                continue;
            }
            const ctx = tools.ToolContext{ .gpa = gpa, .io = init, .workspace = &workspace };
            var res = tools.execute(ctx, def.name, tc.args);
            defer res.deinit(gpa);
            try out.eventToolResult(def.name, res.content, res.is_error);
            try appendHeadlessToolResult(gpa, &conv, tc, res.content, res.is_error);
        }
    }
    try out.eventError("maximum tool iterations reached");
    return error.MaxIterations;
}

fn appendHeadlessToolResult(gpa: std.mem.Allocator, conv: *messages.Conversation, tc: messages.ToolCall, content: []const u8, is_error: bool) !void {
    const tm = try conv.add(.tool, content, 0);
    try tm.setToolResult(gpa, tc.id, tc.name, is_error);
}

test "headless module loads" {
    try std.testing.expect(true);
}
