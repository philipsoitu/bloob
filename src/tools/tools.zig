//! Built-in coding tools with bounds, workspace checks and structured results.
const std = @import("std");
const workspace_mod = @import("../core/workspace.zig");
const permissions = @import("permissions.zig");

pub const Capability = permissions.Capability;

pub const ToolContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    workspace: *const workspace_mod.Workspace,
};

pub const Result = struct {
    content: []const u8,
    is_error: bool = false,
    diff: ?[]const u8 = null,
    summary: []const u8,
    changed_path: ?[]const u8 = null,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        if (self.content.len > 0) gpa.free(self.content);
        if (self.diff) |d| if (d.len > 0) gpa.free(d);
        if (self.summary.len > 0) gpa.free(self.summary);
        if (self.changed_path) |p| gpa.free(p);
    }
};

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
    capability: Capability,
};

pub const defs = [_]ToolDef{
    .{
        .name = "read_file",
        .description = "Read a UTF-8 text file inside the workspace. Returns line-numbered content. Bounded to 256 KiB.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative or absolute path"},"start_line":{"type":"integer"},"end_line":{"type":"integer"}},"required":["path"]}
        ,
        .capability = .workspace_read,
    },
    .{
        .name = "list_files",
        .description = "List files inside the workspace. Ignores build/cache/VCS directories. Bounded entry count.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string"},"recursive":{"type":"boolean"},"max_entries":{"type":"integer"}},"required":[]}
        ,
        .capability = .workspace_read,
    },
    .{
        .name = "search",
        .description = "Search workspace text with ripgrep. Returns file:line:match results, bounded.",
        .schema =
        \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"max_results":{"type":"integer"}},"required":["pattern"]}
        ,
        .capability = .workspace_read,
    },
    .{
        .name = "write_file",
        .description = "Create or replace a workspace file atomically. Requires approval.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        ,
        .capability = .workspace_write,
    },
    .{
        .name = "edit_file",
        .description = "Replace exactly one unique occurrence of old_text with new_text in a workspace file, atomically. Requires approval.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string"},"old_text":{"type":"string"},"new_text":{"type":"string"}},"required":["path","old_text","new_text"]}
        ,
        .capability = .workspace_write,
    },
    .{
        .name = "shell",
        .description = "Run a shell command in the workspace with a timeout and bounded output. Requires approval.",
        .schema =
        \\{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"},"timeout_ms":{"type":"integer"}},"required":["command"]}
        ,
        .capability = .shell,
    },
    .{
        .name = "git_status",
        .description = "Read git status for the workspace.",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
        .capability = .git_read,
    },
    .{
        .name = "git_diff",
        .description = "Read a bounded git diff (optionally staged or for a path).",
        .schema =
        \\{"type":"object","properties":{"staged":{"type":"boolean"},"path":{"type":"string"},"max_bytes":{"type":"integer"}},"required":[]}
        ,
        .capability = .git_read,
    },
    .{
        .name = "git_log",
        .description = "Read recent git log entries.",
        .schema =
        \\{"type":"object","properties":{"max_count":{"type":"integer"}},"required":[]}
        ,
        .capability = .git_read,
    },
};

pub fn findDef(name: []const u8) ?*const ToolDef {
    for (&defs) |*d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}

fn resultError(gpa: std.mem.Allocator, summary: []const u8, detail: []const u8) Result {
    const content = std.fmt.allocPrint(gpa, "error: {s}", .{detail}) catch gpa.dupe(u8, "error") catch &.{};
    return .{
        .content = content,
        .is_error = true,
        .summary = gpa.dupe(u8, summary) catch &.{},
    };
}

fn resultOk(gpa: std.mem.Allocator, summary: []const u8, content: []u8) Result {
    _ = gpa;
    return .{ .content = content, .summary = summary };
}

fn objString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn objInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn objBool(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        else => default,
    };
}

pub fn execute(ctx: ToolContext, name: []const u8, args_json: []const u8) Result {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, args_json, .{}) catch {
        return resultError(ctx.gpa, name, "invalid JSON arguments");
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return resultError(ctx.gpa, name, "arguments must be a JSON object"),
    };
    if (std.mem.eql(u8, name, "read_file")) return readFile(ctx, root);
    if (std.mem.eql(u8, name, "list_files")) return listFiles(ctx, root);
    if (std.mem.eql(u8, name, "search")) return search(ctx, root);
    if (std.mem.eql(u8, name, "write_file")) return writeFile(ctx, root);
    if (std.mem.eql(u8, name, "edit_file")) return editFile(ctx, root);
    if (std.mem.eql(u8, name, "shell")) return shell(ctx, root);
    if (std.mem.eql(u8, name, "git_status")) return gitCommand(ctx, &.{ "status", "--short", "--branch" }, "git status");
    if (std.mem.eql(u8, name, "git_diff")) return gitDiff(ctx, root);
    if (std.mem.eql(u8, name, "git_log")) return gitLog(ctx, root);
    return resultError(ctx.gpa, name, "unknown tool");
}

fn readFile(ctx: ToolContext, obj: std.json.ObjectMap) Result {
    const path = objString(obj, "path") orelse return resultError(ctx.gpa, "read_file", "missing path");
    const abs = ctx.workspace.resolveRead(path) catch |err| return resultError(ctx.gpa, "read_file", @errorName(err));
    defer ctx.gpa.free(abs);
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, abs, ctx.gpa, .limited(256 * 1024)) catch |err| {
        if (err == error.StreamTooLong) {
            return resultError(ctx.gpa, "read_file", "file exceeds 256 KiB limit");
        }
        return resultError(ctx.gpa, "read_file", @errorName(err));
    };
    defer ctx.gpa.free(data);
    for (data) |b| {
        if (b == 0) return resultError(ctx.gpa, "read_file", "binary file (contains NUL)");
    }
    const start_line: usize = if (objInt(obj, "start_line")) |n| @intCast(@max(1, n)) else 1;
    const end_line: usize = if (objInt(obj, "end_line")) |n| @intCast(@max(1, n)) else std.math.maxInt(usize);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(ctx.gpa);
    var line_no: usize = 1;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line_no > end_line) break;
        if (line_no >= start_line) {
            const formatted = std.fmt.allocPrint(ctx.gpa, "{d:>6}\t{s}\n", .{ line_no, line }) catch break;
            defer ctx.gpa.free(formatted);
            out.appendSlice(ctx.gpa, formatted) catch break;
            if (out.items.len > 256 * 1024) {
                out.appendSlice(ctx.gpa, "… [truncated]\n") catch {};
                break;
            }
        }
        line_no += 1;
    }
    const summary = std.fmt.allocPrint(ctx.gpa, "read {s} ({d} lines)", .{ ctx.workspace.relative(abs), line_no - 1 }) catch ctx.gpa.dupe(u8, "read file") catch "";
    return resultOk(ctx.gpa, summary, out.toOwnedSlice(ctx.gpa) catch ctx.gpa.dupe(u8, "") catch &.{});
}

fn listFiles(ctx: ToolContext, obj: std.json.ObjectMap) Result {
    const rel = objString(obj, "path") orelse ".";
    const recursive = objBool(obj, "recursive", true);
    const max_entries: usize = if (objInt(obj, "max_entries")) |n| @intCast(@max(1, @min(n, 2000))) else 500;
    const abs = ctx.workspace.resolveRead(rel) catch |err| return resultError(ctx.gpa, "list_files", @errorName(err));
    defer ctx.gpa.free(abs);
    var dir = std.Io.Dir.cwd().openDir(ctx.io, abs, .{ .iterate = true }) catch |err| return resultError(ctx.gpa, "list_files", @errorName(err));
    defer dir.close(ctx.io);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(ctx.gpa);
    var count: usize = 0;
    if (recursive) {
        var walker = dir.walk(ctx.gpa) catch |err| return resultError(ctx.gpa, "list_files", @errorName(err));
        defer walker.deinit();
        while (walker.next(ctx.io) catch null) |entry| {
            if (entry.kind == .directory) {
                if (shouldIgnore(entry.path)) continue;
            }
            if (shouldIgnore(entry.path)) continue;
            const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
            const line = std.fmt.allocPrint(ctx.gpa, "{s}{s}\n", .{ entry.path, suffix }) catch continue;
            defer ctx.gpa.free(line);
            out.appendSlice(ctx.gpa, line) catch break;
            count += 1;
            if (count >= max_entries) {
                out.appendSlice(ctx.gpa, "… [truncated]\n") catch {};
                break;
            }
        }
    } else {
        var it = dir.iterate();
        while (it.next(ctx.io) catch null) |entry| {
            if (shouldIgnore(entry.name)) continue;
            const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
            const line = std.fmt.allocPrint(ctx.gpa, "{s}{s}\n", .{ entry.name, suffix }) catch continue;
            defer ctx.gpa.free(line);
            out.appendSlice(ctx.gpa, line) catch break;
            count += 1;
            if (count >= max_entries) break;
        }
    }
    const summary = std.fmt.allocPrint(ctx.gpa, "listed {d} entries", .{count}) catch ctx.gpa.dupe(u8, "list files") catch "";
    return resultOk(ctx.gpa, summary, out.toOwnedSlice(ctx.gpa) catch ctx.gpa.dupe(u8, "") catch &.{});
}

fn shouldIgnore(path: []const u8) bool {
    const ignored = [_][]const u8{ ".git/", ".zig-cache/", "zig-out/", "node_modules/", "target/", ".venv/", "__pycache__/" };
    for (ignored) |ig| {
        if (std.mem.startsWith(u8, path, ig)) return true;

    }
    return false;
}

fn captureProcess(ctx: ToolContext, argv: []const []const u8, cwd: ?[]const u8, max_bytes: usize) !struct { output: []u8, term: std.process.Child.Term } {
    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(ctx.gpa);
    if (child.stdout) |file| {
        var reader = file.reader(ctx.io, &.{});
        const data = reader.interface.allocRemaining(ctx.gpa, .limited(max_bytes)) catch |err| {
            child.kill(ctx.io);
            _ = child.wait(ctx.io) catch {};
            if (err == error.StreamTooLong) {
                out.appendSlice(ctx.gpa, "… [output truncated]\n") catch {};
                return .{ .output = out.toOwnedSlice(ctx.gpa) catch &.{}, .term = .{ .exited = 124 } };
            }
            return err;
        };
        defer ctx.gpa.free(data);
        try out.appendSlice(ctx.gpa, data);
    }
    const term = try child.wait(ctx.io);
    return .{ .output = try out.toOwnedSlice(ctx.gpa), .term = term };
}

fn search(ctx: ToolContext, obj: std.json.ObjectMap) Result {
    const pattern = objString(obj, "pattern") orelse return resultError(ctx.gpa, "search", "missing pattern");
    const rel = objString(obj, "path") orelse ".";
    const abs = ctx.workspace.resolveRead(rel) catch |err| return resultError(ctx.gpa, "search", @errorName(err));
    defer ctx.gpa.free(abs);
    const max_results: usize = if (objInt(obj, "max_results")) |n| @intCast(@max(1, @min(n, 1000))) else 200;
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(ctx.gpa);
    argv.appendSlice(ctx.gpa, &.{ "rg", "-n", "--no-heading", "--color", "never", "--max-count", "100" }) catch {};
    if (objString(obj, "glob")) |glob| {
        argv.appendSlice(ctx.gpa, &.{ "--glob", glob }) catch {};
    }
    argv.append(ctx.gpa, "--") catch {};
    argv.append(ctx.gpa, pattern) catch {};
    argv.append(ctx.gpa, abs) catch {};
    const cap = captureProcess(ctx, argv.items, ctx.workspace.root, 256 * 1024) catch |err| {
        return resultError(ctx.gpa, "search", @errorName(err));
    };
    defer ctx.gpa.free(cap.output);
    if (cap.term == .exited and cap.term.exited == 1) {
        return resultOk(ctx.gpa, ctx.gpa.dupe(u8, "search: no matches") catch "", ctx.gpa.dupe(u8, "") catch &.{});
    }
    var lines: usize = 0;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(ctx.gpa);
    var it = std.mem.splitScalar(u8, cap.output, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (lines >= max_results) {
            out.appendSlice(ctx.gpa, "… [truncated]\n") catch {};
            break;
        }
        out.appendSlice(ctx.gpa, line) catch break;
        out.append(ctx.gpa, '\n') catch break;
        lines += 1;
    }
    const summary = std.fmt.allocPrint(ctx.gpa, "search: {d} matches", .{lines}) catch ctx.gpa.dupe(u8, "search") catch "";
    return resultOk(ctx.gpa, summary, out.toOwnedSlice(ctx.gpa) catch &.{});
}

fn shell(ctx: ToolContext, obj: std.json.ObjectMap) Result {
    const command = objString(obj, "command") orelse return resultError(ctx.gpa, "shell", "missing command");
    const timeout_ms: u64 = if (objInt(obj, "timeout_ms")) |n| @intCast(@max(100, @min(n, 120000))) else 30000;
    const cwd_rel = objString(obj, "cwd") orelse ".";
    const cwd_abs = ctx.workspace.resolveRead(cwd_rel) catch |err| return resultError(ctx.gpa, "shell", @errorName(err));
    defer ctx.gpa.free(cwd_abs);
    const timeout_s = timeout_ms / 1000;
    const secs = std.fmt.allocPrint(ctx.gpa, "{d}s", .{@max(1, timeout_s)}) catch "30s";
    defer ctx.gpa.free(secs);
    // Use coreutils timeout when available; stderr is merged into stdout by the
    // shell invocation so output is captured without a second pipe deadlock.
    const merged = std.fmt.allocPrint(ctx.gpa, "{s} 2>&1", .{command}) catch command;
    defer if (merged.ptr != command.ptr) ctx.gpa.free(merged);
    const argv = [_][]const u8{ "timeout", "--signal=TERM", secs, "/bin/sh", "-c", merged };
    const cap = captureProcess(ctx, &argv, cwd_abs, 256 * 1024) catch |err| {
        return resultError(ctx.gpa, "shell", @errorName(err));
    };
    const code: u8 = switch (cap.term) {
        .exited => |c| c,
        else => 255,
    };
    const summary = std.fmt.allocPrint(ctx.gpa, "shell exit {d}", .{code}) catch ctx.gpa.dupe(u8, "shell") catch "";
    var res = resultOk(ctx.gpa, summary, cap.output);
    if (code != 0) res.is_error = true;
    if (code == 124) {
        res.is_error = true;
        const msg = std.fmt.allocPrint(ctx.gpa, "\n[command timed out after {d}s]\n", .{timeout_s}) catch "";
        defer ctx.gpa.free(msg);
        const old = res.content;
        res.content = std.mem.concat(ctx.gpa, u8, &.{ old, msg }) catch old;
        if (res.content.ptr != old.ptr) ctx.gpa.free(old);
    }
    return res;
}

fn gitCommand(ctx: ToolContext, args: []const []const u8, summary_base: []const u8) Result {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(ctx.gpa);
    argv.appendSlice(ctx.gpa, &.{ "git", "--no-pager" }) catch {};
    argv.appendSlice(ctx.gpa, args) catch {};
    const cap = captureProcess(ctx, argv.items, ctx.workspace.root, 256 * 1024) catch |err| {
        return resultError(ctx.gpa, summary_base, @errorName(err));
    };
    const code: u8 = switch (cap.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        const msg = std.fmt.allocPrint(ctx.gpa, "{s} (exit {d})\n", .{ summary_base, code }) catch summary_base;
        defer ctx.gpa.free(msg);
        const old = cap.output;
        const combined = std.mem.concat(ctx.gpa, u8, &.{ msg, old }) catch old;
        if (combined.ptr != old.ptr) ctx.gpa.free(old);
        var res = resultOk(ctx.gpa, ctx.gpa.dupe(u8, summary_base) catch "", combined);
        res.is_error = true;
        return res;
    }
    return resultOk(ctx.gpa, ctx.gpa.dupe(u8, summary_base) catch "", cap.output);
}

fn gitDiff(ctx: ToolContext, obj: std.json.ObjectMap) Result {
    const staged = objBool(obj, "staged", false);
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(ctx.gpa);
    args.append(ctx.gpa, "diff") catch {};
    if (staged) args.append(ctx.gpa, "--cached") catch {};
    if (objString(obj, "path")) |p| {
        const abs = ctx.workspace.resolveRead(p) catch |err| return resultError(ctx.gpa, "git_diff", @errorName(err));
        defer ctx.gpa.free(abs);
        args.append(ctx.gpa, "--") catch {};
        args.append(ctx.gpa, ctx.workspace.relative(abs)) catch {};
    }
    return gitCommand(ctx, args.items, "git diff");
}

fn gitLog(ctx: ToolContext, obj: std.json.ObjectMap) Result {
    const count: usize = if (objInt(obj, "max_count")) |n| @intCast(@max(1, @min(n, 100))) else 20;
    const count_s = std.fmt.allocPrint(ctx.gpa, "-n{d}", .{count}) catch "-n20";
    defer ctx.gpa.free(count_s);
    return gitCommand(ctx, &.{ "log", "--oneline", "--decorate", count_s }, "git log");
}

const max_file_bytes = 2 * 1024 * 1024;

fn readExisting(ctx: ToolContext, abs: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, abs, ctx.gpa, .limited(max_file_bytes)) catch null;
}

fn writeAtomic(ctx: ToolContext, abs: []const u8, data: []const u8) !void {
    const exists = blk: {
        std.Io.Dir.cwd().access(ctx.io, abs, .{}) catch break :blk false;
        break :blk true;
    };
    var dir = std.Io.Dir.cwd().createFileAtomic(ctx.io, abs, .{
        .permissions = .default_file,
        .replace = exists,
        .make_path = false,
    }) catch |err| return err;
    defer dir.deinit(ctx.io);
    try dir.file.writeStreamingAll(ctx.io, data);
    if (exists) {
        try dir.replace(ctx.io);
    } else {
        try dir.link(ctx.io);
    }
}

fn makeDiff(gpa: std.mem.Allocator, old: []const u8, new: []const u8, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "--- a/");
    try out.appendSlice(gpa, path);
    try out.appendSlice(gpa, "\n+++ b/");
    try out.appendSlice(gpa, path);
    try out.append(gpa, '\n');
    if (old.len == 0) {
        try out.appendSlice(gpa, "@@ new file @@\n");
        var it = std.mem.splitScalar(u8, new, '\n');
        var n: usize = 0;
        while (it.next()) |line| {
            if (line.len == 0 and n > 0) break;
            try out.append(gpa, '+');
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
            n += 1;
            if (n > 200) {
                try out.appendSlice(gpa, "… [diff truncated]\n");
                break;
            }
        }
        return out.toOwnedSlice(gpa);
    }
    var old_it = std.mem.splitScalar(u8, old, '\n');
    var new_it = std.mem.splitScalar(u8, new, '\n');
    // Skip common prefix.
    var old_lines = std.ArrayList([]const u8).empty;
    defer old_lines.deinit(gpa);
    while (old_it.next()) |l| try old_lines.append(gpa, l);
    var new_lines = std.ArrayList([]const u8).empty;
    defer new_lines.deinit(gpa);
    while (new_it.next()) |l| try new_lines.append(gpa, l);
    var prefix: usize = 0;
    while (prefix < old_lines.items.len and prefix < new_lines.items.len and
        std.mem.eql(u8, old_lines.items[prefix], new_lines.items[prefix])) : (prefix += 1)
    {}
    var suffix: usize = 0;
    while (suffix + prefix < old_lines.items.len and suffix + prefix < new_lines.items.len and
        std.mem.eql(u8, old_lines.items[old_lines.items.len - 1 - suffix], new_lines.items[new_lines.items.len - 1 - suffix])) : (suffix += 1)
    {}
    const context: usize = 2;
    const start = prefix -| context;
    const old_end = old_lines.items.len -| suffix;
    const new_end = new_lines.items.len -| suffix;
    try out.appendSlice(gpa, "@@ -");
    try appendInt(gpa, &out, @intCast(start + 1));
    try out.append(gpa, 44);
    try appendInt(gpa, &out, @intCast(old_end - start));
    try out.appendSlice(gpa, " +");
    try appendInt(gpa, &out, @intCast(start + 1));
    try out.append(gpa, 44);
    try appendInt(gpa, &out, @intCast(new_end - start));
    try out.appendSlice(gpa, " @@\n");
    var i = start;
    while (i < prefix and i < old_end) : (i += 1) {
        try out.append(gpa, ' ');
        try out.appendSlice(gpa, old_lines.items[i]);
        try out.append(gpa, '\n');
    }
    const old_changed_end = @min(old_end, prefix + 200);
    i = prefix;
    while (i < old_changed_end) : (i += 1) {
        try out.append(gpa, '-');
        try out.appendSlice(gpa, old_lines.items[i]);
        try out.append(gpa, '\n');
    }
    const new_changed_end = @min(new_end, prefix + 200);
    i = prefix;
    while (i < new_changed_end) : (i += 1) {
        try out.append(gpa, '+');
        try out.appendSlice(gpa, new_lines.items[i]);
        try out.append(gpa, '\n');
    }
    i = old_end;
    var tail: usize = 0;
    while (i < old_lines.items.len and tail < context) : ({
        i += 1;
        tail += 1;
    }) {
        try out.append(gpa, ' ');
        try out.appendSlice(gpa, old_lines.items[i]);
        try out.append(gpa, '\n');
    }
    if (out.items.len > 128 * 1024) {
        out.shrinkRetainingCapacity(128 * 1024);
        try out.appendSlice(gpa, "… [diff truncated]\n");
    }
    return out.toOwnedSlice(gpa);
}

fn writeFile(ctx: ToolContext, obj: std.json.ObjectMap) Result {
    const path = objString(obj, "path") orelse return resultError(ctx.gpa, "write_file", "missing path");
    const content = objString(obj, "content") orelse return resultError(ctx.gpa, "write_file", "missing content");
    if (content.len > max_file_bytes) return resultError(ctx.gpa, "write_file", "content too large");
    const abs = ctx.workspace.resolveWrite(path) catch |err| return resultError(ctx.gpa, "write_file", @errorName(err));
    defer ctx.gpa.free(abs);
    const old = readExisting(ctx, abs);
    defer if (old) |o| ctx.gpa.free(o);
    const diff = makeDiff(ctx.gpa, old orelse "", content, ctx.workspace.relative(abs)) catch null;
    writeAtomic(ctx, abs, content) catch |err| {
        if (diff) |d| ctx.gpa.free(d);
        return resultError(ctx.gpa, "write_file", @errorName(err));
    };
    const summary = std.fmt.allocPrint(ctx.gpa, "wrote {s} ({d} bytes)", .{ ctx.workspace.relative(abs), content.len }) catch ctx.gpa.dupe(u8, "wrote file") catch "";
    var res = resultOk(ctx.gpa, summary, ctx.gpa.dupe(u8, "File written successfully.\n") catch &.{});
    res.diff = diff;
    res.changed_path = ctx.gpa.dupe(u8, abs) catch null;
    return res;
}

fn editFile(ctx: ToolContext, obj: std.json.ObjectMap) Result {
    const path = objString(obj, "path") orelse return resultError(ctx.gpa, "edit_file", "missing path");
    const old_text = objString(obj, "old_text") orelse return resultError(ctx.gpa, "edit_file", "missing old_text");
    const new_text = objString(obj, "new_text") orelse return resultError(ctx.gpa, "edit_file", "missing new_text");
    const abs = ctx.workspace.resolveWrite(path) catch |err| return resultError(ctx.gpa, "edit_file", @errorName(err));
    defer ctx.gpa.free(abs);
    const old = readExisting(ctx, abs) orelse return resultError(ctx.gpa, "edit_file", "file not found or too large");
    defer ctx.gpa.free(old);
    const first = std.mem.indexOf(u8, old, old_text) orelse return resultError(ctx.gpa, "edit_file", "old_text not found");
    if (std.mem.indexOfPos(u8, old, first + 1, old_text) != null) {
        return resultError(ctx.gpa, "edit_file", "old_text is not unique; provide more context");
    }
    const new = std.mem.concat(ctx.gpa, u8, &.{ old[0..first], new_text, old[first + old_text.len ..] }) catch {
        return resultError(ctx.gpa, "edit_file", "out of memory");
    };
    defer ctx.gpa.free(new);
    const diff = makeDiff(ctx.gpa, old, new, ctx.workspace.relative(abs)) catch null;
    writeAtomic(ctx, abs, new) catch |err| {
        if (diff) |d| ctx.gpa.free(d);
        return resultError(ctx.gpa, "edit_file", @errorName(err));
    };
    const summary = std.fmt.allocPrint(ctx.gpa, "edited {s}", .{ctx.workspace.relative(abs)}) catch ctx.gpa.dupe(u8, "edited file") catch "";
    var res = resultOk(ctx.gpa, summary, ctx.gpa.dupe(u8, "File edited successfully.\n") catch &.{});
    res.diff = diff;
    res.changed_path = ctx.gpa.dupe(u8, abs) catch null;
    return res;
}

test "read, edit, write tools in workspace" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "one\ntwo\nthree\n" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buf);
    const ws = try workspace_mod.Workspace.init(gpa, io, path_buf[0..root_len]);
    defer {
        var w = ws;
        w.deinit();
    }
    const ctx = ToolContext{ .gpa = gpa, .io = io, .workspace = &ws };
    var r = execute(ctx, "read_file", "{\"path\":\"hello.txt\"}");
    defer r.deinit(gpa);
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.content, "two") != null);
    var r2 = execute(ctx, "edit_file", "{\"path\":\"hello.txt\",\"old_text\":\"two\",\"new_text\":\"TWO\"}");
    defer r2.deinit(gpa);
    try std.testing.expect(!r2.is_error);
    try std.testing.expect(r2.diff != null);
    const after = try tmp.dir.readFileAlloc(io, "hello.txt", gpa, .limited(1024));
    defer gpa.free(after);
    try std.testing.expectEqualStrings("one\nTWO\nthree\n", after);
    var r3 = execute(ctx, "write_file", "{\"path\":\"new.txt\",\"content\":\"hi\\n\"}");
    defer r3.deinit(gpa);
    try std.testing.expect(!r3.is_error);
    const tree = try tmp.dir.readFileAlloc(io, "new.txt", gpa, .limited(1024));
    defer gpa.free(tree);
    try std.testing.expectEqualStrings("hi\n", tree);
}

test "path escape is rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buf);
    const ws = try workspace_mod.Workspace.init(gpa, io, path_buf[0..root_len]);
    defer {
        var w = ws;
        w.deinit();
    }
    const ctx = ToolContext{ .gpa = gpa, .io = io, .workspace = &ws };
    var r = execute(ctx, "read_file", "{\"path\":\"../outside.txt\"}");
    defer r.deinit(gpa);
    try std.testing.expect(r.is_error);
}

fn appendInt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: i64) !void {
    const tmp = try std.fmt.allocPrint(gpa, "{d}", .{value});
    defer gpa.free(tmp);
    try out.appendSlice(gpa, tmp);
}

pub const Preview = struct {
    summary: []const u8,
    diff: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
    command: ?[]const u8 = null,

    pub fn deinit(self: *Preview, gpa: std.mem.Allocator) void {
        if (self.summary.len > 0) gpa.free(self.summary);
        if (self.diff) |d| if (d.len > 0) gpa.free(d);
        if (self.paths.len > 0) gpa.free(self.paths);
        if (self.command) |c| gpa.free(c);
    }
};

fn previewError(gpa: std.mem.Allocator, msg: []const u8) Preview {
    return .{ .summary = gpa.dupe(u8, msg) catch "" };
}

pub fn preview(ctx: ToolContext, name: []const u8, args_json: []const u8) Preview {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, args_json, .{}) catch {
        return previewError(ctx.gpa, "invalid tool arguments");
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return previewError(ctx.gpa, "arguments must be a JSON object"),
    };
    if (std.mem.eql(u8, name, "read_file")) {
        const path = objString(obj, "path") orelse return previewError(ctx.gpa, "read_file: missing path");
        return .{ .summary = std.fmt.allocPrint(ctx.gpa, "Read {s}", .{path}) catch "" };
    }
    if (std.mem.eql(u8, name, "list_files")) {
        const path = objString(obj, "path") orelse ".";
        return .{ .summary = std.fmt.allocPrint(ctx.gpa, "List files in {s}", .{path}) catch "" };
    }
    if (std.mem.eql(u8, name, "search")) {
        const pattern = objString(obj, "pattern") orelse "";
        return .{ .summary = std.fmt.allocPrint(ctx.gpa, "Search for {s}", .{pattern}) catch "" };
    }
    if (std.mem.eql(u8, name, "shell")) {
        const command = objString(obj, "command") orelse return previewError(ctx.gpa, "shell: missing command");
        const summary = std.fmt.allocPrint(ctx.gpa, "Run shell command in {s}", .{ctx.workspace.relative(ctx.workspace.root)}) catch "";
        return .{ .summary = summary, .command = ctx.gpa.dupe(u8, command) catch null };
    }
    if (std.mem.eql(u8, name, "git_status")) return .{ .summary = ctx.gpa.dupe(u8, "Read git status") catch "" };
    if (std.mem.eql(u8, name, "git_diff")) return .{ .summary = ctx.gpa.dupe(u8, "Read git diff") catch "" };
    if (std.mem.eql(u8, name, "git_log")) return .{ .summary = ctx.gpa.dupe(u8, "Read git log") catch "" };
    if (std.mem.eql(u8, name, "write_file") or std.mem.eql(u8, name, "edit_file")) {
        const path = objString(obj, "path") orelse return previewError(ctx.gpa, "write: missing path");
        const abs = ctx.workspace.resolveWrite(path) catch |err| return previewError(ctx.gpa, @errorName(err));
        const old = readExisting(ctx, abs) orelse "";
        defer if (old.len > 0) ctx.gpa.free(old);
        var new_content: []const u8 = "";
        var owned_new: ?[]u8 = null;
        defer if (owned_new) |n| ctx.gpa.free(n);
        if (std.mem.eql(u8, name, "write_file")) {
            new_content = objString(obj, "content") orelse "";
        } else {
            const old_text = objString(obj, "old_text") orelse return previewError(ctx.gpa, "edit_file: missing old_text");
            const new_text = objString(obj, "new_text") orelse return previewError(ctx.gpa, "edit_file: missing new_text");
            const first = std.mem.indexOf(u8, old, old_text) orelse return previewError(ctx.gpa, "old_text not found");
            if (std.mem.indexOfPos(u8, old, first + 1, old_text) != null) return previewError(ctx.gpa, "old_text is not unique");
            owned_new = std.mem.concat(ctx.gpa, u8, &.{ old[0..first], new_text, old[first + old_text.len ..] }) catch null;
            new_content = owned_new orelse return previewError(ctx.gpa, "out of memory");
        }
        const diff = makeDiff(ctx.gpa, old, new_content, ctx.workspace.relative(abs)) catch null;
        const summary = std.fmt.allocPrint(ctx.gpa, "{s} {s}", .{ if (std.mem.eql(u8, name, "write_file")) "Write" else "Edit", ctx.workspace.relative(abs) }) catch "";
        var paths: [][]const u8 = ctx.gpa.alloc([]const u8, 1) catch &.{};
        if (paths.len > 0) paths[0] = ctx.gpa.dupe(u8, abs) catch abs;
        ctx.gpa.free(abs);
        return .{ .summary = summary, .diff = diff, .paths = paths };
    }
    return .{ .summary = std.fmt.allocPrint(ctx.gpa, "Run {s}", .{name}) catch "" };
}
