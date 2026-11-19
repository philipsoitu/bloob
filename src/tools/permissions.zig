//! Authoritative Zig permission engine. Lua hooks may tighten decisions later.
const std = @import("std");
const workspace_mod = @import("../core/workspace.zig");

pub const Capability = enum {
    workspace_read,
    workspace_write,
    shell,
    network,
    git_read,
    git_write,
    custom,
};

pub const Decision = enum { allow, ask, deny };

pub const Scope = enum { once, session, workspace };

pub const Policy = struct {
    read: Decision = .allow,
    write: Decision = .ask,
    shell: Decision = .ask,
    network: Decision = .ask,
    git_read: Decision = .allow,
    git_write: Decision = .ask,
    custom: Decision = .ask,
};

pub const Request = struct {
    tool: []const u8,
    capability: Capability,
    paths: []const []const u8 = &.{},
    command: ?[]const u8 = null,
    summary: []const u8 = "",
    diff: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    policy: Policy = .{},
    session_allowed: std.StringHashMap(void),
    workspace: ?*const workspace_mod.Workspace = null,

    pub fn init(gpa: std.mem.Allocator) Engine {
        return .{ .gpa = gpa, .session_allowed = std.StringHashMap(void).init(gpa) };
    }

    pub fn deinit(self: *Engine) void {
        var it = self.session_allowed.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.session_allowed.deinit();
    }

    fn base(self: *const Engine, cap: Capability) Decision {
        return switch (cap) {
            .workspace_read => self.policy.read,
            .workspace_write => self.policy.write,
            .shell => self.policy.shell,
            .network => self.policy.network,
            .git_read => self.policy.git_read,
            .git_write => self.policy.git_write,
            .custom => self.policy.custom,
        };
    }

    pub fn evaluate(self: *Engine, req: Request) Decision {
        // Ground denials cannot be overridden by configuration or plugins.
        for (req.paths) |p| {
            if (workspace_mod.Workspace.isSensitivePath(p)) return .deny;
            if (self.workspace) |ws| {
                if (!workspace_mod.Workspace.isWithin(ws.root, p)) return .deny;
            }
        }
        const d = self.base(req.capability);
        if (d == .deny) return .deny;
        if (self.session_allowed.contains(req.tool)) return .allow;
        return d;
    }

    pub fn allowSession(self: *Engine, tool: []const u8) void {
        const owned = self.gpa.dupe(u8, tool) catch return;
        self.session_allowed.put(owned, {}) catch self.gpa.free(owned);
    }

    pub fn clearSession(self: *Engine) void {
        var it = self.session_allowed.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.session_allowed.clearRetainingCapacity();
    }

    pub fn parseDecision(s: []const u8) Decision {
        if (std.mem.eql(u8, s, "allow")) return .allow;
        if (std.mem.eql(u8, s, "deny")) return .deny;
        return .ask;
    }
};

test "permission defaults" {
    var e = Engine.init(std.testing.allocator);
    defer e.deinit();
    try std.testing.expectEqual(Decision.allow, e.evaluate(.{ .tool = "read_file", .capability = .workspace_read }));
    try std.testing.expectEqual(Decision.ask, e.evaluate(.{ .tool = "shell", .capability = .shell }));
    try std.testing.expectEqual(Decision.deny, e.evaluate(.{ .tool = "read_file", .capability = .workspace_read, .paths = &.{"/home/x/.ssh/id_rsa"} }));
}

test "ground denial and sibling-prefix path safety" {
    var e = Engine.init(std.testing.allocator);
    defer e.deinit();
    e.policy.read = .deny;
    try std.testing.expectEqual(Decision.deny, e.evaluate(.{ .tool = "read_file", .capability = .workspace_read }));
    e.allowSession("read_file");
    try std.testing.expectEqual(Decision.deny, e.evaluate(.{ .tool = "read_file", .capability = .workspace_read }));
    e.policy.read = .allow;
    const ws = @import("../core/workspace.zig").Workspace{ .gpa = std.testing.allocator, .io = std.testing.io, .root = @constCast("/ws/proj") };
    e.workspace = &ws;
    try std.testing.expectEqual(Decision.deny, e.evaluate(.{ .tool = "read_file", .capability = .workspace_read, .paths = &.{"/ws/proj-evil/secret"} }));
    try std.testing.expectEqual(Decision.allow, e.evaluate(.{ .tool = "read_file", .capability = .workspace_read, .paths = &.{"/ws/proj/file"} }));
}

test "explicit write allow stays allow" {
    var e = Engine.init(std.testing.allocator);
    defer e.deinit();
    e.policy.write = .allow;
    try std.testing.expectEqual(Decision.allow, e.evaluate(.{ .tool = "write_file", .capability = .workspace_write }));
}
