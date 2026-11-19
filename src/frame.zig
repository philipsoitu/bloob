//! A cell grid and ANSI renderer. All content must already be sanitized.
const std = @import("std");
const text = @import("text.zig");
const style = @import("style.zig");

pub const Style = style.Style;
pub const Rgb = style.Rgb;
pub const Palette = style.Palette;
pub const ColorMode = style.ColorMode;

pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    pub fn right(self: Rect) u16 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) u16 {
        return self.y + self.h;
    }
    pub fn empty(self: Rect) bool {
        return self.w == 0 or self.h == 0;
    }
    pub fn inner(self: Rect) Rect {
        if (self.w < 2 or self.h < 2) return .{ .x = self.x, .y = self.y, .w = 0, .h = 0 };
        return .{ .x = self.x + 1, .y = self.y + 1, .w = self.w - 2, .h = self.h - 2 };
    }
};

pub const Cell = struct {
    cp: u21 = ' ',
    extra: [4]u21 = .{ 0, 0, 0, 0 },
    extra_len: u8 = 0,
    style: Style = .{},
    continuation: bool = false,
};

pub const Frame = struct {
    gpa: std.mem.Allocator,
    width: u16,
    height: u16,
    cells: []Cell,
    base_style: Style = .{},

    pub fn init(gpa: std.mem.Allocator, width: u16, height: u16) !Frame {
        const n = @as(usize, width) * @as(usize, height);
        const cells = try gpa.alloc(Cell, n);
        for (cells) |*c| c.* = .{};
        return .{ .gpa = gpa, .width = width, .height = height, .cells = cells };
    }

    pub fn deinit(self: *Frame) void {
        self.gpa.free(self.cells);
    }

    pub fn clear(self: *Frame, s: Style) void {
        self.base_style = s;
        for (self.cells) |*c| c.* = .{ .style = s };
    }

    pub fn cellAt(self: *Frame, x: u16, y: u16) ?*Cell {
        if (x >= self.width or y >= self.height) return null;
        return &self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    pub fn fillRect(self: *Frame, rect: Rect, cp: u21, s: Style) void {
        if (rect.empty()) return;
        var yy: u16 = 0;
        while (yy < rect.h) : (yy += 1) {
            const y = rect.y +| yy;
            if (y >= self.height) break;
            var xx: u16 = 0;
            while (xx < rect.w) : (xx += 1) {
                const x = rect.x +| xx;
                if (x >= self.width) break;
                const cell = &self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
                cell.* = .{ .cp = cp, .style = s };
            }
        }
    }

    pub fn clearRect(self: *Frame, rect: Rect, s: Style) void {
        self.fillRect(rect, ' ', s);
    }

    /// Place one codepoint. Returns the number of columns used, or 0 when clipped.
    pub fn putCodepoint(self: *Frame, x: u16, y: u16, cp: u21, s: Style) u16 {
        if (y >= self.height or x >= self.width) return 0;
        if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F)) return 0;
        const w = text.codepointWidth(cp);
        if (w == 0) {
            // Attach zero-width marks to the preceding cell when possible.
            if (x == 0) return 0;
            var px = x - 1;
            if (self.cellAt(px, y)) |prev| {
                if (prev.continuation and px > 0) {
                    px -= 1;
                    if (self.cellAt(px, y)) |p2| {
                        if (p2.extra_len < p2.extra.len) {
                            p2.extra[p2.extra_len] = cp;
                            p2.extra_len += 1;
                        }
                        return 0;
                    }
                }
                if (prev.extra_len < prev.extra.len) {
                    prev.extra[prev.extra_len] = cp;
                    prev.extra_len += 1;
                }
            }
            return 0;
        }
        if (w == 2 and x + 1 >= self.width) {
            const c = self.cellAt(x, y) orelse return 0;
            c.* = .{ .cp = ' ', .style = s };
            return 1;
        }
        const c = self.cellAt(x, y) orelse return 0;
        c.* = .{ .cp = cp, .style = s };
        if (w == 2) {
            if (self.cellAt(x + 1, y)) |cont| cont.* = .{ .cp = 0, .style = s, .continuation = true };
        }
        return @intCast(w);
    }

    pub fn putText(self: *Frame, x: u16, y: u16, bytes: []const u8, s: Style, max_cols: u16) u16 {
        var cx = x;
        var i: usize = 0;
        const limit = x + max_cols;
        while (i < bytes.len and cx < limit and cx < self.width) {
            if (bytes[i] == 0x1b) {
                i = text.skipAnsiSequence(bytes, i);
                continue;
            }
            const d = text.decode(bytes, i);
            if (d.len == 0) break;
            i += d.len;
            if (d.cp == '\n') break;
            if (d.cp == '\t') {
                const spaces = 4 - (cx % 4);
                var k: u16 = 0;
                while (k < spaces and cx < limit) : (k += 1) {
                    const used = self.putCodepoint(cx, y, ' ', s);
                    if (used == 0) break;
                    cx += used;
                }
                continue;
            }
            const w = text.codepointWidth(d.cp);
            if (w == 0) {
                _ = self.putCodepoint(cx, y, d.cp, s);
                continue;
            }
            if (cx + w > limit) break;
            const used = self.putCodepoint(cx, y, d.cp, s);
            if (used == 0) continue;
            cx += used;
        }
        return cx - x;
    }

    pub fn putTextInRect(self: *Frame, rect: Rect, x_off: u16, y_off: u16, bytes: []const u8, s: Style) void {
        if (rect.empty() or y_off >= rect.h) return;
        _ = self.putText(rect.x +| x_off, rect.y +| y_off, bytes, s, rect.w -| x_off);
    }

    pub fn putTextInRect2(self: *Frame, rect: Rect, x_off: u16, y_off: u16, bytes: []const u8, s: Style) u16 {
        if (rect.empty() or y_off >= rect.h) return 0;
        return self.putText(rect.x +| x_off, rect.y +| y_off, bytes, s, rect.w -| x_off);
    }

    pub fn drawBorder(self: *Frame, rect: Rect, kind: Border, s: Style, title: ?[]const u8) void {
        if (kind == .none or rect.w < 2 or rect.h < 2) return;
        const chars = switch (kind) {
            .none => unreachable,
            .single => [_]u21{ '┌', '┐', '└', '┘', '─', '│' },
            .rounded => [_]u21{ '╭', '╮', '╰', '╯', '─', '│' },
            .double => [_]u21{ '╔', '╗', '╚', '╝', '═', '║' },
            .heavy => [_]u21{ '┏', '┓', '┗', '┛', '━', '┃' },
        };
        const right = rect.x + rect.w - 1;
        const bottom = rect.y + rect.h - 1;
        _ = self.putCodepoint(rect.x, rect.y, chars[0], s);
        _ = self.putCodepoint(right, rect.y, chars[1], s);
        _ = self.putCodepoint(rect.x, bottom, chars[2], s);
        _ = self.putCodepoint(right, bottom, chars[3], s);
        var x = rect.x + 1;
        while (x < right) : (x += 1) {
            _ = self.putCodepoint(x, rect.y, chars[4], s);
            _ = self.putCodepoint(x, bottom, chars[4], s);
        }
        var y = rect.y + 1;
        while (y < bottom) : (y += 1) {
            _ = self.putCodepoint(rect.x, y, chars[5], s);
            _ = self.putCodepoint(right, y, chars[5], s);
        }
        if (title) |t| {
            if (t.len > 0 and rect.w > 4) {
                const clipped = t[0..@min(t.len, rect.w - 4)];
                self.putTextInRect(rect, 2, 0, clipped, s);
            }
        }
    }

    fn appendInt(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: usize) !void {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        try out.appendSlice(gpa, s);
    }

    fn appendColor(
        out: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
        color: Rgb,
        mode: ColorMode,
        bg: bool,
    ) !void {
        switch (mode) {
            .mono => {},
            .truecolor => {
                try out.appendSlice(gpa, if (bg) "\x1b[48;2;" else "\x1b[38;2;");
                try appendInt(out, gpa, color.r);
                try out.append(gpa, ';');
                try appendInt(out, gpa, color.g);
                try out.append(gpa, ';');
                try appendInt(out, gpa, color.b);
                try out.append(gpa, 'm');
            },
            .ansi256 => {
                try out.appendSlice(gpa, if (bg) "\x1b[48;5;" else "\x1b[38;5;");
                try appendInt(out, gpa, style.nearestXterm(color));
                try out.append(gpa, 'm');
            },
            .ansi16 => {
                const idx = style.nearestAnsi16(color);
                const code: usize = if (bg) 40 + @as(usize, if (idx >= 8) idx - 8 else idx) else 30 + @as(usize, if (idx >= 8) idx - 8 else idx);
                try out.appendSlice(gpa, "\x1b[");
                try appendInt(out, gpa, code);
                if (idx >= 8) try out.append(gpa, ';');
                if (idx >= 8) {
                    try out.appendSlice(gpa, if (bg) "100m" else "1m");
                } else {
                    try out.append(gpa, 'm');
                }
            },
        }
    }

    fn appendStyle(
        out: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
        s: Style,
        palette: *const Palette,
        mode: ColorMode,
    ) !void {
        try out.appendSlice(gpa, "\x1b[0m");
        if (mode != .mono) {
            if (s.fg.resolve(palette)) |fg| try appendColor(out, gpa, fg, mode, false);
            if (s.bg.resolve(palette)) |bg| try appendColor(out, gpa, bg, mode, true);
        }
        if (s.attrs.bold) try out.appendSlice(gpa, "\x1b[1m");
        if (s.attrs.dim) try out.appendSlice(gpa, "\x1b[2m");
        if (s.attrs.italic) try out.appendSlice(gpa, "\x1b[3m");
        if (s.attrs.underline) try out.appendSlice(gpa, "\x1b[4m");
        if (s.attrs.reverse) try out.appendSlice(gpa, "\x1b[7m");
        if (s.attrs.strikethrough) try out.appendSlice(gpa, "\x1b[9m");
    }

    /// Full-frame ANSI serialization. The result uses explicit cursor positioning
    /// for every row, so it never scrolls the alternate screen.
    pub fn toAnsi(
        self: *Frame,
        gpa: std.mem.Allocator,
        palette: *const Palette,
        mode: ColorMode,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, "\x1b[?25l");
        var last_style: ?Style = null;
        var y: u16 = 0;
        while (y < self.height) : (y += 1) {
            try out.appendSlice(gpa, "\x1b[");
            try appendInt(&out, gpa, y + 1);
            try out.appendSlice(gpa, ";1H");
            var x: u16 = 0;
            while (x < self.width) : (x += 1) {
                const cell = self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
                if (cell.continuation) continue;
                if (last_style == null or !last_style.?.eql(cell.style)) {
                    try appendStyle(&out, gpa, cell.style, palette, mode);
                    last_style = cell.style;
                }
                var buf: [4]u8 = undefined;
                const encoded = text.encode(if (cell.cp == 0) ' ' else cell.cp, &buf);
                try out.appendSlice(gpa, encoded);
                var e: u8 = 0;
                while (e < cell.extra_len) : (e += 1) {
                    var ebuf: [4]u8 = undefined;
                    try out.appendSlice(gpa, text.encode(cell.extra[e], &ebuf));
                }
            }
        }
        try out.appendSlice(gpa, "\x1b[0m");
        return out.toOwnedSlice(gpa);
    }

    pub fn renderToBuffer(self: *Frame, buffer: []u8, palette: *const Palette) []const u8 {
        _ = palette;
        var n: usize = 0;
        var y: u16 = 0;
        while (y < self.height) : (y += 1) {
            var x: u16 = 0;
            while (x < self.width) : (x += 1) {
                const cell = self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
                if (cell.continuation) continue;
                var b: [4]u8 = undefined;
                const encoded = text.encode(cell.cp, &b);
                if (n + encoded.len > buffer.len) return buffer[0..n];
                @memcpy(buffer[n..][0..encoded.len], encoded);
                n += encoded.len;
                const cw = text.codepointWidth(cell.cp);
                if (cw > 1) x += @intCast(cw - 1);
            }
            if (y + 1 < self.height) {
                if (n >= buffer.len) break;
                buffer[n] = '\n';
                n += 1;
            }
        }
        return buffer[0..n];
    }
};

pub const Border = enum { none, single, rounded, double, heavy };

pub fn parseBorder(s: []const u8) Border {
    if (std.mem.eql(u8, s, "rounded")) return .rounded;
    if (std.mem.eql(u8, s, "double")) return .double;
    if (std.mem.eql(u8, s, "heavy")) return .heavy;
    if (std.mem.eql(u8, s, "single") or std.mem.eql(u8, s, "line")) return .single;
    return .none;
}

test "frame text and wide chars" {
    var f = try Frame.init(std.testing.allocator, 10, 3);
    defer f.deinit();
    f.clear(.{});
    const used = f.putText(0, 0, "a界b", .{}, 10);
    try std.testing.expectEqual(@as(u16, 4), used);
    try std.testing.expectEqual(@as(u21, '界'), f.cellAt(1, 0).?.cp);
    try std.testing.expect(f.cellAt(2, 0).?.continuation);
    try std.testing.expectEqual(@as(u21, 'b'), f.cellAt(3, 0).?.cp);
}

test "frame strips injected ANSI and controls" {
    var f = try Frame.init(std.testing.allocator, 40, 2);
    defer f.deinit();
    f.clear(.{});
    _ = f.putText(0, 0, "safe\x1b]0;pwned\x07 text\x1b[2J!", .{}, 40);
    var out_buf: [4096]u8 = undefined;
    const plain = f.renderToBuffer(&out_buf, undefined);
    try std.testing.expect(std.mem.indexOf(u8, plain, "pwned") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "safe text!") != null);
    const ansi = try f.toAnsi(std.testing.allocator, &@import("theme.zig").builtin_default, .mono);
    defer std.testing.allocator.free(ansi);
    try std.testing.expect(std.mem.indexOf(u8, ansi, "pwned") == null);
}
