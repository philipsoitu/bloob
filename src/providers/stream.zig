//! Streaming provider transports. The first implementation uses curl as a
//! bounded subprocess transport with fixed argv (never a shell). Provider
//! protocol parsing lives here; the agent/UI consume a normalized accumulator.
const std = @import("std");
const messages = @import("../messages.zig");
const sys = @import("../c.zig").sys;

pub const Kind = enum { openai, anthropic };

pub const PartialToolCall = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *PartialToolCall, gpa: std.mem.Allocator) void {
        self.id.deinit(gpa);
        self.name.deinit(gpa);
        self.args.deinit(gpa);
    }
};

pub const Accumulator = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    tool_calls: std.ArrayList(PartialToolCall) = .empty,
    usage: messages.Usage = .{},
    finish_reason: []u8 = &.{},
    done: bool = false,
    error_message: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator) Accumulator {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Accumulator) void {
        self.text.deinit(self.gpa);
        for (self.tool_calls.items) |*t| t.deinit(self.gpa);
        self.tool_calls.deinit(self.gpa);
        if (self.finish_reason.len > 0) self.gpa.free(self.finish_reason);
        if (self.error_message) |e| self.gpa.free(e);
    }

    fn setError(self: *Accumulator, msg: []const u8) void {
        if (self.error_message) |e| self.gpa.free(e);
        self.error_message = self.gpa.dupe(u8, msg) catch null;
    }

    fn ensureTool(self: *Accumulator, index: usize) !*PartialToolCall {
        if (index > 64) return error.TooManyToolCalls;
        while (self.tool_calls.items.len <= index) {
            try self.tool_calls.append(self.gpa, .{});
        }
        return &self.tool_calls.items[index];
    }

    pub fn addText(self: *Accumulator, bytes: []const u8) void {
        if (self.text.items.len + bytes.len > 16 * 1024 * 1024) {
            self.setError("provider response text exceeds 16 MiB");
            return;
        }
        self.text.appendSlice(self.gpa, bytes) catch {};
    }

    pub fn setFinish(self: *Accumulator, reason: []const u8) void {
        if (reason.len == 0) return;
        if (self.finish_reason.len > 0) self.gpa.free(self.finish_reason);
        self.finish_reason = self.gpa.dupe(u8, reason) catch &.{};
    }

    pub fn hasTools(self: *const Accumulator) bool {
        for (self.tool_calls.items) |t| {
            if (t.name.items.len > 0) return true;
        }
        return false;
    }
};

pub const Stream = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    kind: Kind,
    child: std.process.Child,
    stdout: ?std.Io.File,
    stderr: ?std.Io.File,
    line: std.ArrayList(u8) = .empty,
    stderr_buf: std.ArrayList(u8) = .empty,
    acc: Accumulator,
    eof_stdout: bool = false,
    eof_stderr: bool = false,
    skip_line: bool = false,
    waited: bool = false,
    config_path: ?[]u8 = null,
    read_buf: [8192]u8 = undefined,

    pub fn start(
        gpa: std.mem.Allocator,
        io: std.Io,
        kind: Kind,
        url: []const u8,
        api_key: []const u8,
        body: []const u8,
    ) !*Stream {
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return error.InvalidUrl;
        if (std.mem.indexOfAny(u8, url, "\"\r\n") != null or std.mem.startsWith(u8, url, "-")) return error.InvalidUrl;
        if (std.mem.indexOfAny(u8, api_key, "\"\r\n") != null) return error.InvalidApiKey;
        const runtime_dir = @import("../env.zig").get("XDG_RUNTIME_DIR") orelse @import("../env.zig").get("TMPDIR") orelse "/tmp";
        const stamp = std.Io.Clock.real.now(io).toMilliseconds();
        const pid: i64 = if (@import("builtin").os.tag == .linux) @intCast(std.os.linux.getpid()) else 0;
        const config_path = try std.fmt.allocPrint(gpa, "{s}/bloob-curl-{d}-{d}.conf", .{ runtime_dir, pid, stamp });
        errdefer gpa.free(config_path);
        const proto = if (std.mem.startsWith(u8, url, "https://")) "=https" else "=http";
        var cfg = std.ArrayList(u8).empty;
        defer cfg.deinit(gpa);
        const head = try std.fmt.allocPrint(
            gpa,
            "url = \"{s}\"\nrequest = \"POST\"\nsilent\nshow-error\nno-buffer\nfail-with-body\nproto = \"{s}\"\nmax-time = 300\nconnect-timeout = 20\nheader = \"Content-Type: application/json\"\n",
            .{ url, proto },
        );
        defer gpa.free(head);
        try cfg.appendSlice(gpa, head);
        switch (kind) {
            .openai => {
                const line = try std.fmt.allocPrint(gpa, "header = \"Authorization: Bearer {s}\"\n", .{api_key});
                defer gpa.free(line);
                try cfg.appendSlice(gpa, line);
            },
            .anthropic => {
                const line = try std.fmt.allocPrint(gpa, "header = \"x-api-key: {s}\"\n", .{api_key});
                defer gpa.free(line);
                try cfg.appendSlice(gpa, line);
                try cfg.appendSlice(gpa, "header = \"anthropic-version: 2023-06-01\"\n");
            },
        }
        try cfg.appendSlice(gpa, "data-binary = \"@-\"\n");
        const private_permissions: std.Io.File.Permissions = @fromBackingInt(@intCast(0o600));
        std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = config_path,
            .data = cfg.items,
            .flags = .{ .permissions = private_permissions },
        }) catch |err| {
            gpa.free(config_path);
            return err;
        };
        errdefer std.Io.Dir.cwd().deleteFile(io, config_path) catch {};
        const argv = [_][]const u8{ "curl", "--config", config_path };
        var child = try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        errdefer child.kill(io);
        if (child.stdin) |in| {
            in.writeStreamingAll(io, body) catch |err| {
                child.kill(io);
                gpa.free(config_path);
                return err;
            };
            in.close(io);
            child.stdin = null;
        }
        const self = try gpa.create(Stream);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .kind = kind,
            .child = child,
            .stdout = child.stdout,
            .stderr = child.stderr,
            .acc = Accumulator.init(gpa),
            .config_path = config_path,
        };
        // Ownership moved to our optional fields; null them on the child so
        // wait/kill do not double-close.
        self.child.stdout = null;
        self.child.stderr = null;
        if (self.stdout) |f| _ = sys.fcntl(f.handle, sys.F_SETFL, sys.O_NONBLOCK);
        if (self.stderr) |f| _ = sys.fcntl(f.handle, sys.F_SETFL, sys.O_NONBLOCK);
        return self;
    }
    pub fn deinit(self: *Stream) void {
        self.closeFiles();
        if (!self.waited) {
            self.child.kill(self.io);
            self.waited = true;
        }
        if (self.config_path) |p| {
            std.Io.Dir.cwd().deleteFile(self.io, p) catch {};
            self.gpa.free(p);
            self.config_path = null;
        }
        self.line.deinit(self.gpa);
        self.stderr_buf.deinit(self.gpa);
        self.acc.deinit();
        self.gpa.destroy(self);
    }

    fn closeFiles(self: *Stream) void {
        if (self.stdout) |f| {
            f.close(self.io);
            self.stdout = null;
        }
        if (self.stderr) |f| {
            f.close(self.io);
            self.stderr = null;
        }
    }

    pub fn stdoutFd(self: *Stream) ?std.posix.fd_t {
        if (self.stdout) |f| return f.handle;
        return null;
    }
    pub fn stderrFd(self: *Stream) ?std.posix.fd_t {
        if (self.stderr) |f| return f.handle;
        return null;
    }

    pub fn pump(self: *Stream) void {
        if (self.stdout) |f| {
            const read_result: ?usize = std.posix.read(f.handle, &self.read_buf) catch |err| switch (err) {
                error.WouldBlock => null,
                else => blk: {
                    self.acc.setError(@errorName(err));
                    self.eof_stdout = true;
                    break :blk null;
                },
            };
            if (read_result) |n| {
                if (n == 0) {
                    if (!self.eof_stdout) {
                        self.eof_stdout = true;
                        if (self.stdout) |sf| {
                            sf.close(self.io);
                            self.stdout = null;
                        }
                        self.flushLine();
                    }
                } else {
                    self.consumeBytes(self.read_buf[0..n]);
                }
            }
        }
        if (self.stderr) |f| {
            const n = std.posix.read(f.handle, &self.read_buf) catch 0;
            if (n == 0) {
                if (!self.eof_stderr) {
                    self.eof_stderr = true;
                    if (self.stderr) |sf| {
                        sf.close(self.io);
                        self.stderr = null;
                    }
                    if (self.stderr_buf.items.len > 0 and self.acc.error_message == null) {
                        self.acc.setError(std.mem.trim(u8, self.stderr_buf.items, " \t\r\n"));
                    }
                }
            } else {
                if (self.stderr_buf.items.len < 16 * 1024) {
                    self.stderr_buf.appendSlice(self.gpa, self.read_buf[0..n]) catch {};
                }
            }
        }
        if (self.eof_stdout and self.eof_stderr and !self.waited) {
            const term = self.child.wait(self.io) catch {
                self.acc.setError("curl process wait failed");
                self.acc.done = true;
                self.waited = true;
                return;
            };
            self.waited = true;
            switch (term) {
                .exited => |code| {
                    if (code != 0 and self.acc.error_message == null) {
                        if (self.stderr_buf.items.len > 0) {
                            self.acc.setError(std.mem.trim(u8, self.stderr_buf.items, " \t\r\n"));
                        } else {
                            const msg = std.fmt.allocPrint(self.gpa, "provider exited with code {d}", .{code}) catch "provider failed";
                            defer self.gpa.free(msg);
                            self.acc.setError(msg);
                        }
                    }
                },
                .signal => |sig| {
                    const msg = std.fmt.allocPrint(self.gpa, "provider terminated by signal {d}", .{@backingInt(sig)}) catch "provider terminated";
                    defer self.gpa.free(msg);
                    self.acc.setError(msg);
                },
                else => self.acc.setError("provider terminated unexpectedly"),
            }
            self.flushLine();
            self.acc.done = true;
        }
    }

    fn consumeBytes(self: *Stream, bytes: []const u8) void {
        for (bytes) |b| {
            if (b == '\n') {
                if (self.skip_line) {
                    self.skip_line = false;
                    self.line.clearRetainingCapacity();
                    continue;
                }
                self.processLine(self.line.items);
                self.line.clearRetainingCapacity();
            } else if (!self.skip_line) {
                if (self.line.items.len >= 1024 * 1024) {
                    self.skip_line = true;
                    self.line.clearRetainingCapacity();
                    self.acc.setError("provider event line exceeds 1 MiB");
                } else self.line.append(self.gpa, b) catch {};
            }
        }
    }

    fn flushLine(self: *Stream) void {
        if (self.line.items.len > 0) {
            self.processLine(self.line.items);
            self.line.clearRetainingCapacity();
        }
    }

    fn processLine(self: *Stream, line_raw: []const u8) void {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "event:")) return;
        if (std.mem.startsWith(u8, line, ":")) return;
        var data = line;
        if (std.mem.startsWith(u8, line, "data: ")) data = line[6..] else if (std.mem.startsWith(u8, line, "data:")) data = line[5..] else return;
        if (std.mem.eql(u8, data, "[DONE]")) {
            self.acc.done = true;
            return;
        }
        switch (self.kind) {
            .openai => self.parseOpenAi(data),
            .anthropic => self.parseAnthropic(data),
        }
    }

    fn setErrorFromJson(self: *Stream, obj: std.json.ObjectMap) void {
        if (obj.get("error")) |errv| {
            switch (errv) {
                .object => |eo| {
                    if (eo.get("message")) |m| {
                        if (m == .string) self.acc.setError(m.string);
                    }
                },
                .string => |s| self.acc.setError(s),
                else => {},
            }
        }
    }

    fn parseOpenAi(self: *Stream, data: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, data, .{}) catch return;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };
        self.setErrorFromJson(obj);
        if (obj.get("usage")) |uv| {
            if (uv == .object) {
                const u = uv.object;
                if (jsonInt(u, "prompt_tokens")) |n| {
                    self.acc.usage.prompt_tokens = std.math.cast(u64, n) orelse std.math.maxInt(u64);
                    self.acc.usage.reported = true;
                }
                if (jsonInt(u, "completion_tokens")) |n| {
                    self.acc.usage.completion_tokens = std.math.cast(u64, n) orelse std.math.maxInt(u64);
                    self.acc.usage.reported = true;
                }
            }
        }
        const choices = switch (obj.get("choices") orelse return) {
            .array => |a| a,
            else => return,
        };
        if (choices.items.len == 0) return;
        const choice = choices.items[0];
        if (choice != .object) return;
        const ch = choice.object;
        if (jsonString(ch, "finish_reason")) |fr| self.acc.setFinish(fr);
        const delta = switch (ch.get("delta") orelse return) {
            .object => |o| o,
            else => return,
        };
        if (jsonString(delta, "content")) |c| self.acc.addText(c);
        const tcs = switch (delta.get("tool_calls") orelse return) {
            .array => |a| a,
            else => return,
        };
        for (tcs.items) |tcv| {
            if (tcv != .object) continue;
            const tc = tcv.object;
            const index: usize = if (jsonInt(tc, "index")) |iv| @intCast(std.math.clamp(iv, 0, 64)) else 0;
            const partial = self.acc.ensureTool(index) catch continue;
            if (jsonString(tc, "id")) |idv| partial.id.appendSlice(self.gpa, idv) catch {};
            if (tc.get("function")) |fv| {
                if (fv == .object) {
                    const fn_obj = fv.object;
                    if (jsonString(fn_obj, "name")) |nv| partial.name.appendSlice(self.gpa, nv) catch {};
                    if (jsonString(fn_obj, "arguments")) |av| {
                        if (partial.args.items.len + av.len <= 1024 * 1024) partial.args.appendSlice(self.gpa, av) catch {} else self.acc.setError("tool arguments exceed 1 MiB");
                    }
                }
            }
        }
    }

    fn parseAnthropic(self: *Stream, data: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, data, .{}) catch return;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };
        const typ = jsonString(obj, "type") orelse "";
        if (std.mem.eql(u8, typ, "error")) {
            self.setErrorFromJson(obj);
            return;
        }
        if (std.mem.eql(u8, typ, "message_start")) {
            if (obj.get("message")) |mv| {
                if (mv == .object) {
                    if (mv.object.get("usage")) |uv| {
                        if (uv == .object) {
                            if (jsonInt(uv.object, "input_tokens")) |n| {
                                self.acc.usage.prompt_tokens = std.math.cast(u64, n) orelse std.math.maxInt(u64);
                                self.acc.usage.reported = true;
                            }
                        }
                    }
                }
            }
            return;
        }
        if (std.mem.eql(u8, typ, "content_block_start")) {
            const idx: usize = if (jsonInt(obj, "index")) |iv| @intCast(std.math.clamp(iv, 0, 64)) else 0;
            if (obj.get("content_block")) |cb| {
                if (cb == .object) {
                    const block = cb.object;
                    const bt = jsonString(block, "type") orelse "";
                    if (std.mem.eql(u8, bt, "tool_use")) {
                        const p = self.acc.ensureTool(idx) catch return;
                        if (jsonString(block, "id")) |idv| p.id.appendSlice(self.gpa, idv) catch {};
                        if (jsonString(block, "name")) |nv| p.name.appendSlice(self.gpa, nv) catch {};
                    }
                }
            }
            return;
        }
        if (std.mem.eql(u8, typ, "content_block_delta")) {
            const idx: usize = if (jsonInt(obj, "index")) |iv| @intCast(std.math.clamp(iv, 0, 64)) else 0;
            if (obj.get("delta")) |dv| {
                if (dv == .object) {
                    const d = dv.object;
                    const dt = jsonString(d, "type") orelse "";
                    if (std.mem.eql(u8, dt, "text_delta")) {
                        if (jsonString(d, "text")) |v| self.acc.addText(v);
                    } else if (std.mem.eql(u8, dt, "input_json_delta")) {
                        const p = self.acc.ensureTool(idx) catch return;
                        if (jsonString(d, "partial_json")) |v| {
                            if (p.args.items.len + v.len <= 1024 * 1024) p.args.appendSlice(self.gpa, v) catch {} else self.acc.setError("tool arguments exceed 1 MiB");
                        }
                    }
                }
            }
            return;
        }
        if (std.mem.eql(u8, typ, "message_delta")) {
            if (obj.get("delta")) |dv| {
                if (dv == .object) {
                    if (jsonString(dv.object, "stop_reason")) |sr| self.acc.setFinish(sr);
                }
            }
            if (obj.get("usage")) |uv| {
                if (uv == .object) {
                    if (jsonInt(uv.object, "output_tokens")) |n| {
                        self.acc.usage.completion_tokens = std.math.cast(u64, n) orelse std.math.maxInt(u64);
                        self.acc.usage.reported = true;
                    }
                }
            }
            return;
        }
        if (std.mem.eql(u8, typ, "message_stop")) {
            self.acc.done = true;
        }
    }
};

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

test "openai SSE parsing accumulates text, tools and usage" {
    var s = Stream{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .kind = .openai,
        .child = undefined,
        .stdout = null,
        .stderr = null,
        .acc = Accumulator.init(std.testing.allocator),
    };
    defer {
        s.line.deinit(std.testing.allocator);
        s.stderr_buf.deinit(std.testing.allocator);
        s.acc.deinit();
    }
    s.consumeBytes(
        \\data: {"choices":[{"delta":{"content":"Hello "}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"path\":"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"README.md\"}"}}]}}]}
        \\data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}
        \\data: [DONE]
    );
    s.flushLine();
    try std.testing.expectEqualStrings("Hello ", s.acc.text.items);
    try std.testing.expect(s.acc.hasTools());
    try std.testing.expectEqualStrings("read_file", s.acc.tool_calls.items[0].name.items);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", s.acc.tool_calls.items[0].args.items);
    try std.testing.expectEqual(@as(u64, 10), s.acc.usage.prompt_tokens);
    try std.testing.expect(s.acc.done);
}

test "anthropic SSE parsing accumulates text and tool use" {
    var s = Stream{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .kind = .anthropic,
        .child = undefined,
        .stdout = null,
        .stderr = null,
        .acc = Accumulator.init(std.testing.allocator),
    };
    defer {
        s.line.deinit(std.testing.allocator);
        s.stderr_buf.deinit(std.testing.allocator);
        s.acc.deinit();
    }
    s.consumeBytes(
        \\event: message_start
        \\data: {"type":"message_start","message":{"usage":{"input_tokens":12}}}
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"list_files"}}
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}
        \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":4}}
        \\data: {"type":"message_stop"}
    );
    s.flushLine();
    try std.testing.expectEqualStrings("Hi", s.acc.text.items);
    try std.testing.expectEqualStrings("list_files", s.acc.tool_calls.items[1].name.items);
    try std.testing.expectEqual(@as(u64, 12), s.acc.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 4), s.acc.usage.completion_tokens);
    try std.testing.expect(s.acc.done);
}
