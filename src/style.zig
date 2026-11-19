const std = @import("std");
const env = @import("env.zig");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }

    pub fn fromHex(hex: []const u8) ?Rgb {
        var s = hex;
        if (s.len > 0 and s[0] == '#') s = s[1..];
        if (s.len == 3) {
            const r = std.fmt.charToDigit(s[0], 16) catch return null;
            const g = std.fmt.charToDigit(s[1], 16) catch return null;
            const b = std.fmt.charToDigit(s[2], 16) catch return null;
            return .{ .r = @intCast(r * 17), .g = @intCast(g * 17), .b = @intCast(b * 17) };
        }
        if (s.len == 6) {
            const r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
            const g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
            const b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
            return .{ .r = r, .g = g, .b = b };
        }
        return null;
    }
};

pub const Semantic = enum {
    default,
    fg,
    bg,
    primary,
    secondary,
    muted,
    success,
    warning,
    @"error",
    info,
    border,
    selection,
    focus,
    tool,
    tool_error,
    diff_added,
    diff_removed,
    diff_hunk,
    code,
    heading,
    user,
    assistant,
    accent,
    cursor,
};

pub const semantic_count = @typeInfo(Semantic).@"enum".field_names.len;

pub const Color = union(enum) {
    default,
    semantic: Semantic,
    rgb: Rgb,
    xterm: u8,

    pub fn parse(spec: []const u8) Color {
        const t = std.mem.trim(u8, spec, " \t\r\n");
        if (t.len == 0 or std.mem.eql(u8, t, "default")) return .default;
        if (std.meta.stringToEnum(Semantic, t)) |sem| return .{ .semantic = sem };
        if (Rgb.fromHex(t)) |rgb| return .{ .rgb = rgb };
        if (parseAnsiName(t)) |rgb| return .{ .rgb = rgb };
        if (std.fmt.parseInt(u8, t, 10)) |n| return .{ .xterm = n } else |_| {}
        return .{ .semantic = .fg };
    }

    pub fn resolve(self: Color, palette: *const Palette) ?Rgb {
        return switch (self) {
            .default => null,
            .semantic => |s| palette.get(s),
            .rgb => |c| c,
            .xterm => |n| xtermToRgb(n),
        };
    }
};

pub const Attr = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
};

pub fn parseAttrs(spec: []const u8) Attr {
    var attr: Attr = .{};
    var it = std.mem.tokenizeAny(u8, spec, " ,|+");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "bold")) attr.bold = true;
        if (std.mem.eql(u8, tok, "dim")) attr.dim = true;
        if (std.mem.eql(u8, tok, "italic")) attr.italic = true;
        if (std.mem.eql(u8, tok, "underline")) attr.underline = true;
        if (std.mem.eql(u8, tok, "reverse")) attr.reverse = true;
        if (std.mem.eql(u8, tok, "strikethrough")) attr.strikethrough = true;
    }
    return attr;
}

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attr = .{},

    pub fn eql(a: Style, b: Style) bool {
        return std.meta.eql(a, b);
    }

    pub fn merge(base: Style, over: Style) Style {
        return .{
            .fg = if (over.fg == .default) base.fg else over.fg,
            .bg = if (over.bg == .default) base.bg else over.bg,
            .attrs = .{
                .bold = base.attrs.bold or over.attrs.bold,
                .dim = base.attrs.dim or over.attrs.dim,
                .italic = base.attrs.italic or over.attrs.italic,
                .underline = base.attrs.underline or over.attrs.underline,
                .reverse = base.attrs.reverse or over.attrs.reverse,
                .strikethrough = base.attrs.strikethrough or over.attrs.strikethrough,
            },
        };
    }
};

pub const Palette = struct {
    colors: [semantic_count]?Rgb,

    pub fn init(defaults: [semantic_count]?Rgb) Palette {
        return .{ .colors = defaults };
    }

    pub fn get(self: *const Palette, s: Semantic) ?Rgb {
        return self.colors[@backingInt(s)];
    }

    pub fn set(self: *Palette, s: Semantic, color: ?Rgb) void {
        self.colors[@backingInt(s)] = color;
    }

    pub fn empty() Palette {
        return .{ .colors = std.mem.zeroes([semantic_count]?Rgb) };
    }
};

pub const ColorMode = enum { truecolor, ansi256, ansi16, mono };

pub fn detectColorMode() ColorMode {
    if (env.get("NO_COLOR") != null) return .mono;
    if (env.get("BLOOB_COLOR")) |v| {
        if (std.mem.eql(u8, v, "mono") or std.mem.eql(u8, v, "none")) return .mono;
        if (std.mem.eql(u8, v, "16")) return .ansi16;
        if (std.mem.eql(u8, v, "256")) return .ansi256;
    }
    if (env.get("COLORTERM")) |v| {
        if (std.mem.indexOf(u8, v, "truecolor") != null or std.mem.indexOf(u8, v, "24bit") != null) return .truecolor;
    }
    if (env.get("TERM")) |v| {
        if (std.mem.indexOf(u8, v, "256color") != null) return .ansi256;
        if (std.mem.eql(u8, v, "dumb")) return .mono;
    }
    return .ansi16;
}

pub fn xtermToRgb(n: u8) Rgb {
    if (n < 16) return ansi16ToRgb(n);
    if (n >= 232) {
        const v: u8 = @intCast(8 + @as(u16, n - 232) * 10);
        return .{ .r = v, .g = v, .b = v };
    }
    const idx: u16 = n - 16;
    const r: u8 = @intCast(@min(255, 55 + @as(u16, idx / 36) * 40));
    const g: u8 = @intCast(@min(255, 55 + @as(u16, (idx / 6) % 6) * 40));
    const b: u8 = @intCast(@min(255, 55 + @as(u16, idx % 6) * 40));
    return .{ .r = r, .g = g, .b = b };
}

fn ansi16ToRgb(n: u8) Rgb {
    const table = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },       .{ .r = 128, .g = 0, .b = 0 },
        .{ .r = 0, .g = 128, .b = 0 },     .{ .r = 128, .g = 128, .b = 0 },
        .{ .r = 0, .g = 0, .b = 128 },     .{ .r = 128, .g = 0, .b = 128 },
        .{ .r = 0, .g = 128, .b = 128 },   .{ .r = 192, .g = 192, .b = 192 },
        .{ .r = 128, .g = 128, .b = 128 }, .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },     .{ .r = 255, .g = 255, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },     .{ .r = 255, .g = 0, .b = 255 },
        .{ .r = 0, .g = 255, .b = 255 },   .{ .r = 255, .g = 255, .b = 255 },
    };
    return table[n % 16];
}

pub fn parseAnsiName(name: []const u8) ?Rgb {
    const pair = [_]struct { []const u8, Rgb }{
        .{ "black", ansi16ToRgb(0) },        .{ "red", ansi16ToRgb(9) },
        .{ "green", ansi16ToRgb(10) },       .{ "yellow", ansi16ToRgb(11) },
        .{ "blue", ansi16ToRgb(12) },        .{ "magenta", ansi16ToRgb(13) },
        .{ "cyan", ansi16ToRgb(14) },        .{ "white", ansi16ToRgb(15) },
        .{ "gray", ansi16ToRgb(8) },         .{ "grey", ansi16ToRgb(8) },
        .{ "bright_black", ansi16ToRgb(8) },
    };
    for (pair) |p| {
        if (std.mem.eql(u8, name, p[0])) return p[1];
    }
    return null;
}

pub fn nearestXterm(rgb: Rgb) u8 {
    var best: u8 = 0;
    var best_dist: u32 = std.math.maxInt(u32);
    var i: u16 = 16;
    while (i < 256) : (i += 1) {
        const c = xtermToRgb(@intCast(i));
        const dr: i32 = @as(i32, c.r) - @as(i32, rgb.r);
        const dg: i32 = @as(i32, c.g) - @as(i32, rgb.g);
        const db: i32 = @as(i32, c.b) - @as(i32, rgb.b);
        const dist: u32 = @intCast(dr * dr + dg * dg + db * db);
        if (dist < best_dist) {
            best_dist = dist;
            best = @intCast(i);
        }
    }
    return best;
}

pub fn nearestAnsi16(rgb: Rgb) u8 {
    var best: u8 = 0;
    var best_dist: u32 = std.math.maxInt(u32);
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        const c = ansi16ToRgb(i);
        const dr: i32 = @as(i32, c.r) - @as(i32, rgb.r);
        const dg: i32 = @as(i32, c.g) - @as(i32, rgb.g);
        const db: i32 = @as(i32, c.b) - @as(i32, rgb.b);
        const dist: u32 = @intCast(dr * dr + dg * dg + db * db);
        if (dist < best_dist) {
            best_dist = dist;
            best = i;
        }
    }
    return best;
}

test "color parsing" {
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, Rgb.fromHex("#ff0000").?);
    try std.testing.expectEqual(Semantic.@"error", Color.parse("error").semantic);
    try std.testing.expectEqual(@as(u8, 196), nearestXterm(.{ .r = 255, .g = 0, .b = 0 }));
}
