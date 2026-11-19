//! Declarative UI node tree and deterministic flex layout.
//! Nodes are short-lived, allocated in a per-frame arena. Lua never receives
//! pointers into this tree.
const std = @import("std");
const frame = @import("../frame.zig");
const style = @import("../style.zig");
const text = @import("../text.zig");

pub const Rect = frame.Rect;
pub const Style = style.Style;
pub const Border = frame.Border;

pub const Kind = enum {
    column,
    row,
    panel,
    text,
    spacer,
    button,
    list,
    scroll,
    input,
    chat,
    statusline,
    sidebar,
    diff,
    tabs,
    overlay,
    custom,
};

pub const Dim = union(enum) {
    auto,
    cells: u16,
    percent: f32,

    pub fn resolve(self: Dim, available: u16, intrinsic: u16) u16 {
        return switch (self) {
            .auto => intrinsic,
            .cells => |n| n,
            .percent => |p| @intFromFloat(@max(0, @min(1, p)) * @as(f32, @floatFromInt(available))),
        };
    }
};

pub const Align = enum { start, center, end, stretch };
pub const Justify = enum { start, center, end, between, around };

pub const Node = struct {
    kind: Kind,
    id: []const u8 = "",
    children: []Node = &.{},
    width: Dim = .auto,
    height: Dim = .auto,
    flex: f32 = 0,
    min_width: u16 = 0,
    min_height: u16 = 0,
    max_width: u16 = 0,
    max_height: u16 = 0,
    padding: u16 = 0,
    gap: u16 = 0,
    border: Border = .none,
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
    lines: []const []const u8 = &.{},
    style: Style = .{},
    text_style: Style = .{},
    align_mode: Align = .stretch,
    justify: Justify = .start,
    visible: bool = true,
    focusable: bool = false,
    focused: bool = false,
    button_ref: ?i32 = null,
    widget_name: ?[]const u8 = null,
    scroll_offset: u32 = 0,

    // Filled by layout.
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn isContainer(self: *const Node) bool {
        return switch (self.kind) {
            .column, .row, .panel, .scroll, .overlay, .tabs => true,
            else => false,
        };
    }

    pub fn innerRect(self: *const Node) Rect {
        var r = self.rect;
        if (self.border != .none) {
            if (r.w >= 2 and r.h >= 2) {
                r.x += 1;
                r.y += 1;
                r.w -= 2;
                r.h -= 2;
            } else return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
        }
        const p = self.padding;
        if (r.w <= p * 2 or r.h <= p * 2) return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
        r.x +|= p;
        r.y +|= p;
        r.w -= p * 2;
        r.h -= p * 2;
        return r;
    }
};

pub const LayoutResult = struct {
    buttons: std.ArrayList(ButtonHit) = .empty,
    focusables: std.ArrayList(FocusItem) = .empty,
    input_rect: ?Rect = null,
    input_id: []const u8 = "",
    chat_rect: ?Rect = null,
    chat_id: []const u8 = "",
    status_rect: ?Rect = null,
    sidebar_rect: ?Rect = null,

    pub const ButtonHit = struct {
        rect: Rect,
        ref: i32,
        id: []const u8,
    };
    pub const FocusItem = struct {
        kind: enum { input, button },
        rect: Rect,
        ref: ?i32,
        id: []const u8,
    };

    pub fn deinit(self: *LayoutResult, gpa: std.mem.Allocator) void {
        self.buttons.deinit(gpa);
        self.focusables.deinit(gpa);
    }
};

pub const Axis = enum { w, h };

pub fn clampSize(node: *const Node, axis: Axis, value: u16) u16 {
    var v = value;
    if (axis == .w) {
        if (node.max_width > 0) v = @min(v, node.max_width);
        v = @max(v, node.min_width);
    } else {
        if (node.max_height > 0) v = @min(v, node.max_height);
        v = @max(v, node.min_height);
    }
    return v;
}

pub fn intrinsicWidth(node: *const Node, available: u16, depth: usize) u16 {
    if (depth > 32) return 0;
    if (!node.visible) return 0;
    const max_w = if (available == 0) 1000 else available;
    return switch (node.kind) {
        .text => blk: {
            const s = node.content orelse "";
            var widest: u16 = 0;
            var it = std.mem.splitScalar(u8, s, '\n');
            while (it.next()) |line| {
                widest = @max(widest, @as(u16, @intCast(@min(text.displayWidth(line), max_w))));
            }
            break :blk widest;
        },
        .button => blk: {
            const label = node.content orelse "";
            break :blk @intCast(@min(@as(usize, 4) + text.displayWidth(label), max_w));
        },
        .spacer => 0,
        .input, .chat, .statusline, .sidebar, .diff, .scroll => 10,
        .list => blk: {
            var widest: u16 = 0;
            for (node.lines) |line| widest = @max(widest, @as(u16, @intCast(@min(text.displayWidth(line), max_w))));
            break :blk widest;
        },
        .column, .overlay, .tabs => blk: {
            var w: u16 = 0;
            for (node.children) |*c| w = @max(w, intrinsicWidth(c, max_w, depth + 1));
            break :blk w;
        },
        .row => blk: {
            var w: u16 = 0;
            for (node.children, 0..) |*c, i| {
                if (i > 0) w +|= node.gap;
                w +|= intrinsicWidth(c, max_w, depth + 1);
            }
            break :blk w;
        },
        .panel => blk: {
            var w: u16 = 0;
            for (node.children) |*c| w = @max(w, intrinsicWidth(c, max_w, depth + 1));
            if (node.border != .none) w +|= 2;
            w +|= node.padding * 2;
            break :blk w;
        },
        .custom => 0,
    };
}

pub fn textHeight(bytes: []const u8, width: u16) u16 {
    if (width == 0) return 0;
    var lines: u32 = 1;
    var col: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const d = text.decode(bytes, i);
        if (d.len == 0) break;
        i += d.len;
        if (d.cp == '\n') {
            lines += 1;
            col = 0;
            continue;
        }
        const w = text.codepointWidth(d.cp);
        if (col + w > width and col > 0) {
            lines += 1;
            col = 0;
        }
        col += @intCast(w);
    }
    return @intCast(@min(lines, 10000));
}

pub fn intrinsicHeight(node: *const Node, available: u16, depth: usize) u16 {
    if (depth > 32) return 0;
    if (!node.visible) return 0;
    const max_h = if (available == 0) 1000 else available;
    return switch (node.kind) {
        .text => textHeight(node.content orelse "", if (node.rect.w > 0) node.rect.w else available),
        .button, .statusline => 1,
        .spacer => 0,
        .input => 4,
        .chat, .sidebar, .diff, .list, .scroll => 3,
        .column, .overlay, .tabs => blk: {
            var h: u16 = 0;
            for (node.children, 0..) |*c, i| {
                if (i > 0) h +|= node.gap;
                h +|= intrinsicHeight(c, max_h, depth + 1);
            }
            break :blk h;
        },
        .row => blk: {
            var h: u16 = 0;
            for (node.children) |*c| h = @max(h, intrinsicHeight(c, max_h, depth + 1));
            break :blk h;
        },
        .panel => blk: {
            var h: u16 = 0;
            for (node.children) |*c| h = @max(h, intrinsicHeight(c, max_h, depth + 1));
            if (node.border != .none) h +|= 2;
            h +|= node.padding * 2;
            break :blk h;
        },
        .custom => 0,
    };
}

fn allocateAxis(
    children: []Node,
    total: u16,
    gap: u16,
    axis: Axis,
) void {
    const n = children.len;
    if (n == 0) return;
    const total_gap: u32 = if (n > 1) @as(u32, gap) * @as(u32, @intCast(n - 1)) else 0;
    var available: i32 = @as(i32, total) - @as(i32, @intCast(total_gap));
    if (available < 0) available = 0;

    var sizes = std.heap.page_allocator.alloc(u16, n) catch return;
    defer std.heap.page_allocator.free(sizes);
    var fixed_sum: u32 = 0;
    var flex_sum: f32 = 0;
    for (children, 0..) |*c, i| {
        if (!c.visible) {
            sizes[i] = 0;
            continue;
        }
        const dim = if (axis == .w) c.width else c.height;
        switch (dim) {
            .cells => |v| {
                sizes[i] = clampSize(c, axis, v);
                fixed_sum += sizes[i];
            },
            .percent => |p| {
                const v: u16 = @intFromFloat(@max(0.0, @min(1.0, p)) * @as(f32, @floatFromInt(available)));
                sizes[i] = clampSize(c, axis, v);
                fixed_sum += sizes[i];
            },
            .auto => {
                const avail16: u16 = @intCast(available);
                const intrin = if (axis == .w) intrinsicWidth(c, avail16, 0) else intrinsicHeight(c, avail16, 0);
                sizes[i] = clampSize(c, axis, intrin);
                if (c.flex > 0) {
                    sizes[i] = 0;
                } else {
                    fixed_sum += sizes[i];
                }
            },
        }
        flex_sum += c.flex;
    }
    var remaining: i32 = @as(i32, @intCast(available)) - @as(i32, @intCast(fixed_sum));
    if (remaining < 0) remaining = 0;
    if (flex_sum > 0) {
        var leftover: i32 = remaining;
        var last_flex: ?usize = null;
        for (children, 0..) |*c, i| {
            if (c.flex > 0 and c.visible) {
                const share: i32 = @intFromFloat(@as(f32, @floatFromInt(remaining)) * (c.flex / flex_sum));
                var v: u16 = @intCast(@max(0, share));
                v = clampSize(c, axis, v);
                sizes[i] = v;
                leftover -= v;
                last_flex = i;
            }
        }
        if (last_flex) |i| {
            const c = &children[i];
            const v = clampSize(c, axis, @as(u16, @intCast(@max(0, @as(i32, @intCast(sizes[i])) + leftover))));
            sizes[i] = v;
        }
    }
    // Clamp overflow from fixed children deterministically.
    var sum: u32 = 0;
    for (sizes) |s| sum += s;
    sum += total_gap;
    if (sum > total) {
        var excess = sum - total;
        var i: usize = n;
        while (i > 0 and excess > 0) {
            i -= 1;
            const take = @min(excess, sizes[i]);
            sizes[i] -= @intCast(take);
            excess -= take;
        }
    }
    for (children, 0..) |*c, i| {
        if (axis == .w) c.rect.w = sizes[i] else c.rect.h = sizes[i];
    }
}

pub fn prepare(node: *Node, rect: Rect) void {
    if (!node.visible) {
        node.rect = .{ .x = rect.x, .y = rect.y, .w = 0, .h = 0 };
        return;
    }
    node.rect = rect;
    if (!node.isContainer()) return;

    const inner = node.innerRect();
    if (inner.empty()) return;
    switch (node.kind) {
        .row => {
            allocateAxis(node.children, inner.w, node.gap, .w);
            var x = inner.x;
            for (node.children) |*c| {
                if (!c.visible) continue;
                c.rect.x = x;
                c.rect.y = inner.y;
                if (c.height == .auto and c.kind != .button) c.rect.h = inner.h;
                prepare(c, c.rect);
                x +|= c.rect.w;
                x +|= node.gap;
            }
        },
        .column, .overlay, .tabs, .scroll, .panel => {
            allocateAxis(node.children, inner.h, node.gap, .h);
            var y = inner.y;
            for (node.children) |*c| {
                if (!c.visible) continue;
                c.rect.y = y;
                c.rect.x = inner.x;
                if (c.width == .auto) c.rect.w = inner.w;
                prepare(c, c.rect);
                y +|= c.rect.h;
                y +|= node.gap;
            }
        },
        else => {},
    }
}

pub fn collect(node: *Node, result: *LayoutResult, allocator: std.mem.Allocator) !void {
    if (!node.visible) return;
    switch (node.kind) {
        .input => {
            if (result.input_rect == null) {
                result.input_rect = node.rect;
                result.input_id = node.id;
            }
            if (node.focusable) {
                try result.focusables.append(allocator, .{ .kind = .input, .rect = node.rect, .ref = null, .id = node.id });
            }
        },
        .button => {
            if (node.focusable) {
                try result.focusables.append(allocator, .{ .kind = .button, .rect = node.rect, .ref = node.button_ref, .id = node.id });
            }
            if (node.button_ref) |ref| try result.buttons.append(allocator, .{ .rect = node.rect, .ref = ref, .id = node.id });
        },
        .chat => {
            if (result.chat_rect == null) {
                result.chat_rect = node.rect;
                result.chat_id = node.id;
            }
        },
        .statusline => result.status_rect = node.rect,
        .sidebar => result.sidebar_rect = node.rect,
        else => {},
    }
    for (node.children) |*c| try collect(c, result, allocator);
}

test "layout basic column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kids = try a.alloc(Node, 3);
    kids[0] = .{ .kind = .chat, .flex = 1, .id = "chat" };
    kids[1] = .{ .kind = .input, .height = .{ .cells = 4 }, .id = "input" };
    kids[2] = .{ .kind = .statusline, .height = .{ .cells = 1 }, .id = "status" };
    var root = Node{ .kind = .column, .children = kids };
    prepare(&root, .{ .x = 0, .y = 0, .w = 80, .h = 24 });
    try std.testing.expectEqual(@as(u16, 19), kids[0].rect.h);
    try std.testing.expectEqual(@as(u16, 4), kids[1].rect.h);
    try std.testing.expectEqual(@as(u16, 1), kids[2].rect.h);
    try std.testing.expectEqual(@as(u16, 19), kids[1].rect.y);
}

test "layout row sidebar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kids = try a.alloc(Node, 2);
    kids[0] = .{ .kind = .sidebar, .width = .{ .cells = 22 } };
    kids[1] = .{ .kind = .chat, .flex = 1 };
    var root = Node{ .kind = .row, .children = kids };
    prepare(&root, .{ .x = 0, .y = 0, .w = 80, .h = 20 });
    try std.testing.expectEqual(@as(u16, 22), kids[0].rect.w);
    try std.testing.expectEqual(@as(u16, 58), kids[1].rect.w);
}
