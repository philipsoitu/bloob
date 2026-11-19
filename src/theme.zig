const std = @import("std");
const style = @import("style.zig");

pub const Rgb = style.Rgb;
pub const Semantic = style.Semantic;
pub const Palette = style.Palette;

pub const Theme = struct {
    name: []const u8,
    palette: Palette,
};

pub const builtin_default = Palette.init(.{
    .{ .r = 220, .g = 223, .b = 228 }, // default
    .{ .r = 220, .g = 223, .b = 228 }, // fg
    .{ .r = 24, .g = 26, .b = 31 }, // bg
    .{ .r = 137, .g = 180, .b = 250 }, // primary
    .{ .r = 198, .g = 160, .b = 246 }, // secondary
    .{ .r = 120, .g = 126, .b = 140 }, // muted
    .{ .r = 158, .g = 206, .b = 106 }, // success
    .{ .r = 229, .g = 192, .b = 123 }, // warning
    .{ .r = 224, .g = 108, .b = 117 }, // error
    .{ .r = 86, .g = 182, .b = 194 }, // info
    .{ .r = 68, .g = 71, .b = 90 }, // border
    .{ .r = 54, .g = 58, .b = 79 }, // selection
    .{ .r = 97, .g = 175, .b = 239 }, // focus
    .{ .r = 198, .g = 160, .b = 246 }, // tool
    .{ .r = 224, .g = 108, .b = 117 }, // tool_error
    .{ .r = 158, .g = 206, .b = 106 }, // diff_added
    .{ .r = 224, .g = 108, .b = 117 }, // diff_removed
    .{ .r = 86, .g = 182, .b = 194 }, // diff_hunk
    .{ .r = 229, .g = 192, .b = 123 }, // code
    .{ .r = 198, .g = 160, .b = 246 }, // heading
    .{ .r = 97, .g = 175, .b = 239 }, // user
    .{ .r = 158, .g = 206, .b = 106 }, // assistant
    .{ .r = 198, .g = 160, .b = 246 }, // accent
    .{ .r = 97, .g = 175, .b = 239 }, // cursor
});

pub const builtin_light = Palette.init(.{
    .{ .r = 30, .g = 34, .b = 42 }, // default
    .{ .r = 30, .g = 34, .b = 42 }, // fg
    .{ .r = 250, .g = 250, .b = 248 }, // bg
    .{ .r = 36, .g = 92, .b = 170 }, // primary
    .{ .r = 128, .g = 60, .b = 170 }, // secondary
    .{ .r = 108, .g = 112, .b = 122 }, // muted
    .{ .r = 36, .g = 128, .b = 62 }, // success
    .{ .r = 160, .g = 110, .b = 10 }, // warning
    .{ .r = 190, .g = 45, .b = 55 }, // error
    .{ .r = 20, .g = 120, .b = 130 }, // info
    .{ .r = 190, .g = 190, .b = 185 }, // border
    .{ .r = 222, .g = 230, .b = 242 }, // selection
    .{ .r = 36, .g = 92, .b = 170 }, // focus
    .{ .r = 128, .g = 60, .b = 170 }, // tool
    .{ .r = 190, .g = 45, .b = 55 }, // tool_error
    .{ .r = 36, .g = 128, .b = 62 }, // diff_added
    .{ .r = 190, .g = 45, .b = 55 }, // diff_removed
    .{ .r = 20, .g = 120, .b = 130 }, // diff_hunk
    .{ .r = 160, .g = 110, .b = 10 }, // code
    .{ .r = 128, .g = 60, .b = 170 }, // heading
    .{ .r = 36, .g = 92, .b = 170 }, // user
    .{ .r = 36, .g = 128, .b = 62 }, // assistant
    .{ .r = 128, .g = 60, .b = 170 }, // accent
    .{ .r = 36, .g = 92, .b = 170 }, // cursor
});

pub const builtin_mono = blk: {
    var p = Palette.empty();
    p.set(.fg, .{ .r = 220, .g = 220, .b = 220 });
    p.set(.bg, .{ .r = 0, .g = 0, .b = 0 });
    p.set(.default, .{ .r = 220, .g = 220, .b = 220 });
    p.set(.muted, .{ .r = 150, .g = 150, .b = 150 });
    p.set(.border, .{ .r = 120, .g = 120, .b = 120 });
    p.set(.primary, .{ .r = 255, .g = 255, .b = 255 });
    p.set(.@"error", .{ .r = 255, .g = 255, .b = 255 });
    p.set(.success, .{ .r = 255, .g = 255, .b = 255 });
    p.set(.warning, .{ .r = 255, .g = 255, .b = 255 });
    break :blk p;
};

pub const builtin_catppuccin = Palette.init(.{
    .{ .r = 205, .g = 214, .b = 244 }, // default
    .{ .r = 205, .g = 214, .b = 244 }, // fg
    .{ .r = 30, .g = 30, .b = 46 }, // bg
    .{ .r = 137, .g = 180, .b = 250 }, // primary
    .{ .r = 203, .g = 166, .b = 247 }, // secondary
    .{ .r = 127, .g = 132, .b = 156 }, // muted
    .{ .r = 166, .g = 227, .b = 161 }, // success
    .{ .r = 249, .g = 226, .b = 175 }, // warning
    .{ .r = 243, .g = 139, .b = 168 }, // error
    .{ .r = 148, .g = 226, .b = 213 }, // info
    .{ .r = 88, .g = 91, .b = 112 }, // border
    .{ .r = 69, .g = 71, .b = 90 }, // selection
    .{ .r = 137, .g = 220, .b = 235 }, // focus
    .{ .r = 203, .g = 166, .b = 247 }, // tool
    .{ .r = 243, .g = 139, .b = 168 }, // tool_error
    .{ .r = 166, .g = 227, .b = 161 }, // diff_added
    .{ .r = 243, .g = 139, .b = 168 }, // diff_removed
    .{ .r = 148, .g = 226, .b = 213 }, // diff_hunk
    .{ .r = 249, .g = 226, .b = 175 }, // code
    .{ .r = 203, .g = 166, .b = 247 }, // heading
    .{ .r = 137, .g = 220, .b = 235 }, // user
    .{ .r = 166, .g = 227, .b = 161 }, // assistant
    .{ .r = 203, .g = 166, .b = 247 }, // accent
    .{ .r = 137, .g = 180, .b = 250 }, // cursor
});

pub const Registry = struct {
    gpa: std.mem.Allocator,
    themes: std.StringHashMap(Palette),
    custom_names: std.ArrayList([]u8) = .empty,
    active: []const u8 = "default",

    pub fn init(gpa: std.mem.Allocator) !Registry {
        var r = Registry{
            .gpa = gpa,
            .themes = std.StringHashMap(Palette).init(gpa),
        };
        try r.themes.put("default", builtin_default);
        try r.themes.put("dark", builtin_default);
        try r.themes.put("light", builtin_light);
        try r.themes.put("monochrome", builtin_mono);
        try r.themes.put("mono", builtin_mono);
        try r.themes.put("catppuccin", builtin_catppuccin);
        return r;
    }

    pub fn deinit(self: *Registry) void {
        for (self.custom_names.items) |n| self.gpa.free(n);
        self.custom_names.deinit(self.gpa);
        self.themes.deinit();
    }

    pub fn get(self: *Registry, name: []const u8) ?Palette {
        return self.themes.get(name);
    }

    pub fn activeName(self: *Registry) []const u8 {
        return self.active;
    }

    pub fn set(self: *Registry, name: []const u8) bool {
        if (self.themes.contains(name)) {
            self.active = self.themes.getKey(name) orelse name;
            return true;
        }
        return false;
    }

    pub fn register(self: *Registry, theme_name: []const u8, pal: Palette) !void {
        const owned = try self.gpa.dupe(u8, theme_name);
        errdefer self.gpa.free(owned);
        try self.custom_names.append(self.gpa, owned);
        errdefer _ = self.custom_names.pop();
        try self.themes.put(owned, pal);
    }

    pub fn palette(self: *Registry) Palette {
        return self.themes.get(self.active) orelse builtin_default;
    }
};

test "theme registry" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expect(reg.set("catppuccin"));
    try std.testing.expect(!reg.set("nope"));
}
