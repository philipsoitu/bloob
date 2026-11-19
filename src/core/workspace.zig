//! Workspace root, canonical path resolution and path safety checks.
const std = @import("std");
const env = @import("../env.zig");

pub const ResolveError = error{
    OutsideWorkspace,
    SensitivePath,
    InvalidPath,
    PathNotFound,
    SymlinkEscape,
} || std.mem.Allocator.Error || anyerror;

pub const Workspace = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Workspace {
        const root_z = std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch |err| switch (err) {
            else => {
                // If the path does not exist, fall back to lexical resolution.
                const resolved = try std.fs.path.resolve(gpa, &.{path});
                return .{ .gpa = gpa, .io = io, .root = @constCast(resolved) };
            },
        };
        const root = try gpa.dupe(u8, root_z);
        gpa.free(root_z);
        return .{ .gpa = gpa, .io = io, .root = root };
    }

    pub fn deinit(self: *Workspace) void {
        self.gpa.free(self.root);
    }

    pub fn displayRoot(self: *const Workspace) []const u8 {
        return self.root;
    }

    fn isWithin(root: []const u8, path: []const u8) bool {
        if (std.mem.eql(u8, root, path)) return true;
        if (!std.mem.startsWith(u8, path, root)) return false;
        if (path.len <= root.len) return false;
        if (root.len == 1 and root[0] == '/') return true;
        return path[root.len] == '/';
    }

    pub fn isSensitivePath(path: []const u8) bool {
        const base = std.fs.path.basename(path);
        const sensitive = [_][]const u8{
            ".env", ".env.local", ".env.production", ".npmrc", ".pypirc",
            ".netrc", ".git-credentials", "credentials", "credentials.json",
            "id_rsa", "id_ed25519", "id_ecdsa", "known_hosts",
        };
        for (sensitive) |s| {
            if (std.mem.eql(u8, base, s)) return true;
            if (std.mem.startsWith(u8, base, ".env.")) return true;
        }
        if (std.mem.indexOf(u8, path, "/.ssh/") != null) return true;
        if (std.mem.indexOf(u8, path, "/.aws/") != null) return true;
        if (std.mem.indexOf(u8, path, "/.gnupg/") != null) return true;
        return false;
    }

    /// Resolve an existing path for reading. Symlinks are followed and must stay
    /// inside the workspace.
    pub fn resolveRead(self: *const Workspace, user_path: []const u8) ResolveError![]u8 {
        if (user_path.len == 0) return error.InvalidPath;
        const joined = if (std.fs.path.isAbsolute(user_path))
            try self.gpa.dupe(u8, user_path)
        else
            try std.fs.path.resolve(self.gpa, &.{ self.root, user_path });
        defer self.gpa.free(joined);
        if (isSensitivePath(joined)) {
            // Do not even resolve credentials; distinguish sensitive before realpath.
            return error.SensitivePath;
        }
        const resolved_z = std.Io.Dir.cwd().realPathFileAlloc(self.io, joined, self.gpa) catch |err| switch (err) {
            error.FileNotFound => return error.PathNotFound,
            else => return err,
        };
        defer self.gpa.free(resolved_z);
        if (!isWithin(self.root, resolved_z)) return error.SymlinkEscape;
        return try self.gpa.dupe(u8, resolved_z);
    }

    /// Resolve a target for writing. If it exists, the canonical parent and
    /// symlink checks apply. New files are resolved through the canonical parent.
    pub fn resolveWrite(self: *const Workspace, user_path: []const u8) ResolveError![]u8 {
        if (user_path.len == 0) return error.InvalidPath;
        const joined = if (std.fs.path.isAbsolute(user_path))
            try self.gpa.dupe(u8, user_path)
        else
            try std.fs.path.resolve(self.gpa, &.{ self.root, user_path });
        defer self.gpa.free(joined);
        if (isSensitivePath(joined)) return error.SensitivePath;
        const parent = std.fs.path.dirname(joined) orelse return error.InvalidPath;
        const base = std.fs.path.basename(joined);
        if (std.mem.eql(u8, base, "..") or std.mem.eql(u8, base, ".")) return error.InvalidPath;
        const parent_z = std.Io.Dir.cwd().realPathFileAlloc(self.io, parent, self.gpa) catch |err| switch (err) {
            error.FileNotFound => return error.PathNotFound,
            else => return err,
        };
        defer self.gpa.free(parent_z);
        if (!isWithin(self.root, parent_z)) return error.SymlinkEscape;
        // Refuse .git internals for writes.
        if (std.mem.indexOf(u8, joined, "/.git/") != null) return error.SensitivePath;
        const result = try std.fs.path.join(self.gpa, &.{ parent_z, base });
        return result;
    }

    pub fn relative(self: *const Workspace, abs: []const u8) []const u8 {
        if (isWithin(self.root, abs)) {
            if (abs.len == self.root.len) return ".";
            return abs[self.root.len + 1 ..];
        }
        return abs;
    }

    pub fn gitBranch(self: *const Workspace, gpa: std.mem.Allocator) ?[]u8 {
        const out: ?[]u8 = null;
        _ = gpa;
        _ = self;
        return out;
    }
};

test "sensitive paths" {
    try std.testing.expect(Workspace.isSensitivePath("/home/u/project/.env"));
    try std.testing.expect(Workspace.isSensitivePath("/home/u/.ssh/id_ed25519"));
    try std.testing.expect(!Workspace.isSensitivePath("/home/u/project/src/main.zig"));
}
