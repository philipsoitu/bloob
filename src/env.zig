//! Environment access via libc (std.posix has no getenv in Zig 0.17).
const std = @import("std");
const sys = @import("c.zig").sys;

pub fn get(name: [:0]const u8) ?[]const u8 {
    const p = sys.getenv(name.ptr) orelse return null;
    return std.mem.span(p);
}
