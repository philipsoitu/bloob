//! Terminal input decoding. Stateful so escape sequences, UTF-8 and bracketed
//! paste can span read() boundaries.
const std = @import("std");
const text = @import("text.zig");

pub const Mods = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub fn any(self: Mods) bool {
        return self.ctrl or self.alt or self.shift;
    }
};

pub const Code = enum {
    char,
    enter,
    esc,
    tab,
    backspace,
    delete,
    insert,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    unknown,
};

pub const Key = struct {
    code: Code,
    char: u21 = 0,
    mods: Mods = .{},

    pub fn isChar(self: Key, c: u21) bool {
        return self.code == .char and self.char == c and !self.mods.ctrl and !self.mods.alt;
    }
};

pub const MouseButton = enum { left, middle, right, none };
pub const MouseAction = enum { press, release, move };

pub const Mouse = struct {
    x: u16 = 0,
    y: u16 = 0,
    button: MouseButton = .none,
    action: MouseAction = .press,
    wheel_up: bool = false,
    wheel_down: bool = false,
};

pub const Event = union(enum) {
    key: Key,
    paste: []const u8,
    mouse: Mouse,
    focus_in,
    focus_out,
};

pub const Parser = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    paste_buf: std.ArrayList(u8) = .empty,
    in_paste: bool = false,

    pub fn init(gpa: std.mem.Allocator) Parser {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Parser) void {
        self.buf.deinit(self.gpa);
        self.paste_buf.deinit(self.gpa);
    }

    pub fn feed(self: *Parser, bytes: []const u8, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) anyerror!void) !void {
        try self.buf.appendSlice(self.gpa, bytes);
        if (!self.in_paste and self.buf.items.len > 64 * 1024) {
            self.buf.clearRetainingCapacity();
            return;
        }
        while (self.buf.items.len > 0) {
            if (self.in_paste) {
                const end_marker = "\x1b[201~";
                if (std.mem.indexOf(u8, self.buf.items, end_marker)) |idx| {
                    try self.paste_buf.appendSlice(self.gpa, self.buf.items[0..idx]);
                    try handler(ctx, .{ .paste = self.paste_buf.items });
                    self.paste_buf.clearRetainingCapacity();
                    self.in_paste = false;
                    self.buf.replaceRange(self.gpa, 0, idx + end_marker.len, &.{}) catch {};
                    continue;
                }
                // Bound paste memory to 4 MiB and keep it in the parser.
                if (self.buf.items.len > 4 * 1024 * 1024) {
                    try handler(ctx, .{ .paste = self.buf.items[0 .. 4 * 1024 * 1024] });
                    self.buf.clearRetainingCapacity();
                }
                return;
            }
            const consumed = try self.parseOne(self.buf.items, ctx, handler);
            if (consumed == 0) return;
            self.buf.replaceRange(self.gpa, 0, consumed, &.{}) catch return;
        }
    }

    /// Used by the event loop after an escape-key timeout (a lone ESC).
    pub fn flushEscape(self: *Parser, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) anyerror!void) !void {
        if (self.buf.items.len == 1 and self.buf.items[0] == 0x1b) {
            try handler(ctx, .{ .key = .{ .code = .esc } });
            self.buf.clearRetainingCapacity();
        }
    }

    fn parseOne(self: *Parser, bytes: []const u8, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) anyerror!void) !usize {
        const b = bytes[0];
        if (b == 0x1b) {
            if (bytes.len == 1) return 0; // Wait for the rest (or flushEscape).
            if (bytes[1] == '[') return self.parseCsi(bytes, ctx, handler);
            if (bytes[1] == 'O') return self.parseSs3(bytes, ctx, handler);
            if (bytes[1] == 0x1b) {
                try handler(ctx, .{ .key = .{ .code = .esc } });
                return 1;
            }
            // Alt + printable / control.
            const d = text.decode(bytes, 1);
            if (d.len == 0 or 1 + d.len > bytes.len) return 0;
            var key = keyFromCodepoint(d.cp);
            key.mods.alt = true;
            try handler(ctx, .{ .key = key });
            return 1 + d.len;
        }
        if (b == '\r') {
            try handler(ctx, .{ .key = .{ .code = .enter } });
            return 1;
        }
        if (b == '\n') {
            try handler(ctx, .{ .key = .{ .code = .enter, .mods = .{ .ctrl = true } } });
            return 1;
        }
        if (b == '\t') {
            try handler(ctx, .{ .key = .{ .code = .tab } });
            return 1;
        }
        if (b == 0x7f) {
            try handler(ctx, .{ .key = .{ .code = .backspace } });
            return 1;
        }
        if (b < 0x20) {
            const mods: Mods = .{ .ctrl = true };
            if (b == 0) {
                try handler(ctx, .{ .key = .{ .code = .char, .char = ' ', .mods = mods } });
            } else {
                try handler(ctx, .{ .key = .{ .code = .char, .char = @as(u21, 'a') + @as(u21, b) - 1, .mods = mods } });
            }
            return 1;
        }
        const d = text.decode(bytes, 0);
        if (d.len == 0) return 1;
        if (d.len > bytes.len) return 0;
        const key = keyFromCodepoint(d.cp);
        if (key.code == .unknown) return d.len;
        try handler(ctx, .{ .key = key });
        return d.len;
    }

    fn parseCsi(self: *Parser, bytes: []const u8, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) anyerror!void) !usize {
        if (bytes.len < 3) return 0;
        // Bracketed paste start.
        if (std.mem.startsWith(u8, bytes, "\x1b[200~")) {
            self.in_paste = true;
            return 6;
        }
        if (std.mem.startsWith(u8, bytes, "\x1b[I")) {
            try handler(ctx, .focus_in);
            return 3;
        }
        if (std.mem.startsWith(u8, bytes, "\x1b[O")) {
            try handler(ctx, .focus_out);
            return 3;
        }
        var i: usize = 2;
        // SGR mouse: ESC [ < b ; x ; y M/m
        if (i < bytes.len and bytes[i] == '<') {
            return self.parseMouse(bytes, ctx, handler);
        }
        const param_start = i;
        while (i < bytes.len and (bytes[i] == ';' or (bytes[i] >= '0' and bytes[i] <= '9') or bytes[i] == '?' or bytes[i] == ':')) : (i += 1) {}
        if (i >= bytes.len) return 0;
        const final = bytes[i];
        if (final < 0x40 or final > 0x7E) {
            // Malformed: drop ESC[.
            return 2;
        }
        const params = bytes[param_start..i];
        const consumed = i + 1;
        var mods: Mods = .{};
        var number: u32 = 0;
        var have_number = false;
        var second: u32 = 0;
        var have_second = false;
        var part: u8 = 0;
        for (params) |c| {
            if (c == ';') {
                part += 1;
                continue;
            }
            if (c < '0' or c > '9') continue;
            const digit: u32 = c - '0';
            if (part == 0) {
                number = number *| 10 +| digit;
                have_number = true;
            } else if (part == 1) {
                second = second *| 10 +| digit;
                have_second = true;
            }
        }
        if (have_second and second >= 1) {
            const m = second - 1;
            if (m & 1 != 0) mods.shift = true;
            if (m & 2 != 0) mods.alt = true;
            if (m & 4 != 0) mods.ctrl = true;
        }
        const code: ?Code = switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'Z' => blk: {
                mods.shift = true;
                break :blk .tab;
            },
            'P' => .f1,
            'Q' => .f2,
            'R' => .f3,
            'S' => .f4,
            '~' => switch (number) {
                1, 7 => .home,
                2 => .insert,
                3 => .delete,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                11 => .f1,
                12 => .f2,
                13 => .f3,
                14 => .f4,
                15 => .f5,
                17 => .f6,
                18 => .f7,
                19 => .f8,
                20 => .f9,
                21 => .f10,
                23 => .f11,
                24 => .f12,
                else => null,
            },
            else => null,
        };
        if (code) |c| {
            try handler(ctx, .{ .key = .{ .code = c, .mods = mods } });
        }
        return consumed;
    }

    fn parseSs3(self: *Parser, bytes: []const u8, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) anyerror!void) !usize {
        _ = self;
        if (bytes.len < 3) return 0;
        const code: ?Code = switch (bytes[2]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'P' => .f1,
            'Q' => .f2,
            'R' => .f3,
            'S' => .f4,
            else => null,
        };
        if (code) |c| try handler(ctx, .{ .key = .{ .code = c } });
        return 3;
    }

    fn parseMouse(self: *Parser, bytes: []const u8, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) anyerror!void) !usize {
        _ = self;
        // ESC [ < b ; x ; y M/m
        var i: usize = 3;
        const nums: [3]?u32 = .{ null, null, null };
        var values = [_]u32{ 0, 0, 0 };
        var idx: usize = 0;
        while (i < bytes.len and idx < 3) : (i += 1) {
            const c = bytes[i];
            if (c >= '0' and c <= '9') {
                values[idx] = values[idx] *| 10 +| (c - '0');
                continue;
            }
            if (c == ';') {
                idx += 1;
                continue;
            }
            break;
        }
        _ = nums;
        if (i >= bytes.len) return 0;
        const final = bytes[i];
        if (final != 'M' and final != 'm') return i + 1;
        const b = values[0];
        var mouse = Mouse{};
        mouse.x = @intCast(if (values[1] > 0) values[1] - 1 else 0);
        mouse.y = @intCast(if (values[2] > 0) values[2] - 1 else 0);
        mouse.action = if (final == 'm') .release else .press;
        mouse.button = switch (b & 3) {
            0 => .left,
            1 => .middle,
            2 => .right,
            else => .none,
        };
        if ((b & 64) != 0) {
            if ((b & 1) != 0) mouse.wheel_down = true else mouse.wheel_up = true;
            mouse.action = .press;
        }
        if ((b & 32) != 0) mouse.action = .move;
        try handler(ctx, .{ .mouse = mouse });
        return i + 1;
    }
};

pub fn keyFromCodepoint(cp: u21) Key {
    if (cp == 27) return .{ .code = .esc };
    if (cp == 13) return .{ .code = .enter };
    if (cp == 9) return .{ .code = .tab };
    if (cp == 127) return .{ .code = .backspace };
    if (cp < 32) return .{ .code = .unknown };
    return .{ .code = .char, .char = cp };
}

fn parseKeyToken(tok: []const u8) ?Key {
    if (tok.len == 0) return null;
    var mods: Mods = .{};
    var body = tok;
    if (tok[0] == '<' and tok[tok.len - 1] == '>') {
        body = tok[1 .. tok.len - 1];
        var parts = std.mem.splitScalar(u8, body, '-');
        var last: []const u8 = "";
        var count: usize = 0;
        while (parts.next()) |p| {
            last = p;
            count += 1;
            if (p.len == 1) {
                switch (p[0]) {
                    'C', 'c' => mods.ctrl = true,
                    'A', 'a' => mods.alt = true,
                    'S', 's' => mods.shift = true,
                    'M', 'm' => mods.alt = true,
                    else => {},
                }
            }
        }
        if (count == 1) {
            body = last;
        } else if (last.len > 0) {
            body = last;
        }
    }
    const code: ?Code = std.meta.stringToEnum(Code, body) orelse blk: {
        if (std.mem.eql(u8, body, "cr") or std.mem.eql(u8, body, "return")) break :blk .enter;
        if (std.mem.eql(u8, body, "bs")) break :blk .backspace;
        if (std.mem.eql(u8, body, "del")) break :blk .delete;
        if (std.mem.eql(u8, body, "ins")) break :blk .insert;
        if (std.mem.eql(u8, body, "pgup")) break :blk .page_up;
        if (std.mem.eql(u8, body, "pgdn")) break :blk .page_down;
        if (std.mem.eql(u8, body, "space")) break :blk .char;
        if (std.mem.eql(u8, body, "esc")) break :blk .esc;
        break :blk null;
    };
    if (code) |c| {
        var k = Key{ .code = c, .mods = mods };
        if (c == .char and std.mem.eql(u8, body, "space")) k.char = ' ';
        return k;
    }
    const d = text.decode(body, 0);
    if (d.len == body.len and d.len > 0) {
        var k = keyFromCodepoint(d.cp);
        k.mods = mods;
        return k;
    }
    return null;
}

/// Parse a key spec such as "<C-p>" or "<leader>a". Returns null on malformed specs.
pub fn parseSpec(spec: []const u8, leader: u21) ?Key {
    if (spec.len == 0) return null;
    if (spec.len == 1) {
        const d = text.decode(spec, 0);
        if (d.len != 1) return null;
        return keyFromCodepoint(d.cp);
    }
    if (std.mem.startsWith(u8, spec, "<leader>")) {
        _ = leader;
        return null;
    }
    if (spec[0] == '<') {
        if (std.mem.indexOfScalar(u8, spec, '>')) |close| {
            const head = spec[0 .. close + 1];
            const key = parseKeyToken(head) orelse return null;
            const rest = spec[close + 1 ..];
            if (rest.len == 0) return key;
            // Chords are not supported in the matcher yet; report invalid.
            return null;
        }
    }
    return null;
}

test "basic key parsing" {
    const Sink = struct {
        keys: std.ArrayList(Key) = .empty,
        fn handle(self: *@This(), ev: Event) !void {
            switch (ev) {
                .key => |k| try self.keys.append(std.testing.allocator, k),
                else => {},
            }
        }
    };
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var sink = Sink{};
    defer sink.keys.deinit(std.testing.allocator);
    try p.feed("a\x1b[A\x1b[1;5C\r", &sink, Sink.handle);
    try std.testing.expectEqual(@as(usize, 4), sink.keys.items.len);
    try std.testing.expectEqual(@as(u21, 'a'), sink.keys.items[0].char);
    try std.testing.expectEqual(Code.up, sink.keys.items[1].code);
    try std.testing.expect(sink.keys.items[2].mods.ctrl);
    try std.testing.expectEqual(Code.enter, sink.keys.items[3].code);
}

test "bracketed paste" {
    const Sink = struct {
        pasted: std.ArrayList(u8) = .empty,
        fn handle(self: *@This(), ev: Event) !void {
            if (ev == .paste) try self.pasted.appendSlice(std.testing.allocator, ev.paste);
        }
    };
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var sink = Sink{};
    defer sink.pasted.deinit(std.testing.allocator);
    try p.feed("\x1b[200~hello\nworld\x1b[201~", &sink, Sink.handle);
    try std.testing.expectEqualStrings("hello\nworld", sink.pasted.items);
}

test "key specs" {
    const k = parseSpec("<C-p>", ' ').?;
    try std.testing.expect(k.mods.ctrl);
    try std.testing.expectEqual(@as(u21, 'p'), k.char);
    try std.testing.expect(parseSpec("<leader>a", '\\') == null);
}

test "malformed CSI does not panic" {
    const Sink = struct {
        count: usize = 0,
        fn handle(self: *@This(), ev: Event) !void {
            if (ev == .key) self.count += 1;
        }
    };
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    var sink = Sink{};
    try p.feed("\x1b[1;0A\x1b[99999999999999999999;5C", &sink, Sink.handle);
    try std.testing.expect(sink.count <= 2);
}
