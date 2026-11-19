//! Conversation-to-lines renderer with bounded, ANSI-safe markdown-ish output.
const std = @import("std");
const messages = @import("../messages.zig");
const text = @import("../text.zig");
const style = @import("../style.zig");

pub const Style = style.Style;
pub const LineKind = enum { normal, user, assistant, tool, tool_error, notice, code, heading, meta };

pub const Line = struct {
    text: []const u8,
    style: Style,
    kind: LineKind = .normal,
};

pub const Builder = struct {
    arena: std.mem.Allocator,
    lines: std.ArrayList(Line) = .empty,
    width: u16,

    pub fn init(arena: std.mem.Allocator, width: u16) Builder {
        return .{ .arena = arena, .width = if (width == 0) 1 else width };
    }

    pub fn addRaw(self: *Builder, s: []const u8, st: Style, kind: LineKind) !void {
        try self.lines.append(self.arena, .{ .text = s, .style = st, .kind = kind });
    }

    fn appendLine(self: *Builder, s: []const u8, st: Style, kind: LineKind) !void {
        try self.lines.append(self.arena, .{ .text = s, .style = st, .kind = kind });
    }

    pub fn wrapAndAdd(self: *Builder, content: []const u8, st: Style, kind: LineKind, indent: u16) !void {
        var clean = std.ArrayList(u8).empty;
        defer clean.deinit(self.arena);
        try text.sanitizeInto(&clean, self.arena, content);
        var it = std.mem.splitScalar(u8, clean.items, '\n');
        var first = true;
        while (it.next()) |logical| {
            const prefix = if (first) "" else "";
            first = false;
            try self.wrapOne(logical, st, kind, indent, prefix);
        }
    }

    fn wrapOne(self: *Builder, line: []const u8, st: Style, kind: LineKind, indent: u16, prefix: []const u8) !void {
        const usable: usize = if (self.width > indent) self.width - indent else 1;
        if (line.len == 0) {
            const blank = try self.arena.alloc(u8, indent);
            @memset(blank, ' ');
            try self.appendLine(blank, st, kind);
            return;
        }
        var start: usize = 0;
        var col: usize = 0;
        var last_space: ?usize = null;
        var i: usize = 0;
        var pieces: usize = 0;
        while (i < line.len) {
            const d = text.decode(line, i);
            if (d.len == 0) break;
            const w = text.codepointWidth(d.cp);
            if (d.cp == ' ') last_space = i;
            if (col + w > usable and col > 0) {
                var cut = i;
                if (last_space) |sp| {
                    if (sp > start) cut = sp;
                }
                const seg = std.mem.trimEnd(u8, line[start..cut], " ");
                try self.emitSegment(seg, st, kind, indent, prefix, pieces);
                pieces += 1;
                start = if (cut < line.len and line[cut] == ' ') cut + 1 else cut;
                i = start;
                col = 0;
                last_space = null;
                continue;
            }
            col += w;
            i += d.len;
        }
        if (start <= line.len) {
            const seg = std.mem.trimEnd(u8, line[start..], " ");
            if (seg.len == 0 and pieces > 0) return;
            if (seg.len == 0) {
                const blank = try self.arena.alloc(u8, indent);
                @memset(blank, ' ');
                try self.appendLine(blank, st, kind);
                return;
            }
            try self.emitSegment(seg, st, kind, indent, prefix, pieces);
        }
    }

    fn emitSegment(self: *Builder, seg: []const u8, st: Style, kind: LineKind, indent: u16, prefix: []const u8, piece: usize) !void {
        const pad = if (piece == 0) indent else indent;
        const total = pad + (if (piece == 0) prefix.len else 0) + seg.len;
        const buf = try self.arena.alloc(u8, total);
        @memset(buf[0..pad], ' ');
        var off: usize = pad;
        if (piece == 0 and prefix.len > 0) {
            @memcpy(buf[off..][0..prefix.len], prefix);
            off += prefix.len;
        }
        @memcpy(buf[off..][0..seg.len], seg);
        try self.appendLine(buf, st, kind);
    }

    pub fn addNotice(self: *Builder, msg: []const u8, is_error: bool) !void {
        const st = Style{ .fg = .{ .semantic = if (is_error) .@"error" else .info }, .attrs = .{ .italic = true } };
        try self.wrapAndAdd(msg, st, if (is_error) .tool_error else .notice, 0);
        try self.addRaw("", .{}, .normal);
    }

    pub fn addConversation(self: *Builder, conv: *const messages.Conversation) !void {
        for (conv.messages.items) |*m| {
            switch (m.role) {
                .user => {
                    const prefix = Style{ .fg = .{ .semantic = .user }, .attrs = .{ .bold = true } };
                    try self.addRaw("", .{}, .normal);
                    try self.wrapAndAdd(m.text.items, .{ .fg = .{ .semantic = .fg } }, .user, 2);
                    _ = prefix;
                },
                .assistant => {
                    try self.addRaw("", .{}, .normal);
                    const st = Style{ .fg = .{ .semantic = .fg } };
                    try self.renderMarkdown(m.text.items, st);
                    for (m.tool_calls.items) |tc| {
                        const line = try std.fmt.allocPrint(self.arena, "  ⚙ {s}  {s}", .{ tc.name, truncate(tc.args, 200) });
                        try self.addRaw(line, .{ .fg = .{ .semantic = .tool } }, .tool);
                    }
                    if (m.streaming) {
                        try self.addRaw("  ▍", .{ .fg = .{ .semantic = .cursor } }, .meta);
                    }
                },
                .tool => {
                    const st = Style{ .fg = .{ .semantic = if (m.tool_is_error) .tool_error else .muted } };
                    const name = m.tool_name orelse "tool";
                    const header = try std.fmt.allocPrint(self.arena, "  ↳ {s}{s}", .{ name, if (m.tool_is_error) " (error)" else "" });
                    try self.addRaw(header, st, if (m.tool_is_error) .tool_error else .tool);
                    try self.wrapAndAdd(truncate(m.text.items, 32 * 1024), st, if (m.tool_is_error) .tool_error else .tool, 4);
                },
                .system => {
                    try self.wrapAndAdd(m.text.items, .{ .fg = .{ .semantic = .muted }, .attrs = .{ .italic = true } }, .notice, 0);
                },
            }
        }
    }

    pub fn renderMarkdown(self: *Builder, content: []const u8, base: Style) !void {
        var clean = std.ArrayList(u8).empty;
        defer clean.deinit(self.arena);
        try text.sanitizeInto(&clean, self.arena, content);
        var it = std.mem.splitScalar(u8, clean.items, '\n');
        var in_code = false;
        while (it.next()) |raw| {
            var line = raw;
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
                in_code = !in_code;
                const fence = std.fmt.allocPrint(self.arena, "  ┈┈ {s}", .{std.mem.trim(u8, std.mem.trimStart(u8, line, " "), "`")}) catch "";
                try self.addRaw(fence, .{ .fg = .{ .semantic = .muted } }, .meta);
                continue;
            }
            if (in_code) {
                try self.wrapAndAdd(line, .{ .fg = .{ .semantic = .code }, .bg = .{ .semantic = .selection } }, .code, 2);
                continue;
            }
            const trimmed = std.mem.trimStart(u8, line, " ");
            if (trimmed.len > 0 and trimmed[0] == '#') {
                var level: usize = 0;
                while (level < trimmed.len and trimmed[level] == '#') level += 1;
                const heading = std.mem.trimStart(u8, trimmed[level..], " ");
                const st = Style{ .fg = .{ .semantic = .heading }, .attrs = .{ .bold = true } };
                try self.wrapAndAdd(heading, st, .heading, 0);
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
                const item = try std.fmt.allocPrint(self.arena, "• {s}", .{trimmed[2..]});
                try self.wrapAndAdd(item, base, .normal, 2);
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "> ")) {
                try self.wrapAndAdd(trimmed[2..], .{ .fg = .{ .semantic = .muted }, .attrs = .{ .italic = true } }, .normal, 4);
                continue;
            }
            line = stripInlineMarkers(line);
            try self.wrapAndAdd(line, base, .normal, 0);
        }
    }
};

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

fn stripInlineMarkers(line: []const u8) []const u8 {
    // Keep this allocation-free: markdown emphasis markers are removed only at
    // the edges; inline code/backticks are stripped by the caller in future.
    var s = line;
    s = std.mem.trim(u8, s, "\r");
    return s;
}

test "chat line wrapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator(), 20);
    try b.wrapAndAdd("hello world this is a longer line", .{}, .normal, 0);
    try std.testing.expect(b.lines.items.len >= 2);
    try std.testing.expect(b.lines.items[0].text.len <= 20);
}
