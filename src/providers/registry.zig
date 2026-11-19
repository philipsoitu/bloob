//! Resolve provider/model identifiers to transport configuration and secrets.
const std = @import("std");
const env = @import("../env.zig");
const stream = @import("stream.zig");

pub const Error = error{
    InvalidModel,
    MissingApiKey,
    MissingBaseUrl,
    UnsupportedProvider,
    OutOfMemory,
};

pub const Resolved = struct {
    gpa: std.mem.Allocator,
    provider: []u8,
    model: []u8,
    url: []u8,
    api_key: []u8,
    kind: stream.Kind,

    pub fn deinit(self: *Resolved) void {
        self.gpa.free(self.provider);
        self.gpa.free(self.model);
        self.gpa.free(self.url);
        self.gpa.free(self.api_key);
    }
};

fn joinUrl(gpa: std.mem.Allocator, base: []const u8, suffix: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    if (std.mem.endsWith(u8, trimmed, suffix)) return gpa.dupe(u8, trimmed);
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ trimmed, suffix });
}

pub fn isMock(spec: []const u8) bool {
    return std.mem.startsWith(u8, spec, "mock/") or std.mem.startsWith(u8, spec, "fixture/") or std.mem.eql(u8, spec, "mock");
}

pub fn resolve(gpa: std.mem.Allocator, spec: []const u8) Error!Resolved {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return error.InvalidModel;
    const provider = spec[0..slash];
    const model = spec[slash + 1 ..];
    if (model.len == 0) return error.InvalidModel;
    if (std.mem.eql(u8, provider, "openai")) {
        const key = env.get("OPENAI_API_KEY") orelse return error.MissingApiKey;
        const base = env.get("BLOOB_OPENAI_BASE_URL") orelse env.get("OPENAI_BASE_URL") orelse "https://api.openai.com/v1";
        const url = try joinUrl(gpa, base, "/chat/completions");
        errdefer gpa.free(url);
        return .{
            .gpa = gpa,
            .provider = try gpa.dupe(u8, provider),
            .model = try gpa.dupe(u8, model),
            .url = url,
            .api_key = try gpa.dupe(u8, key),
            .kind = .openai,
        };
    }
    if (std.mem.eql(u8, provider, "anthropic")) {
        const key = env.get("ANTHROPIC_API_KEY") orelse return error.MissingApiKey;
        const base = env.get("BLOOB_ANTHROPIC_BASE_URL") orelse "https://api.anthropic.com";
        const url = try joinUrl(gpa, base, "/v1/messages");
        errdefer gpa.free(url);
        return .{
            .gpa = gpa,
            .provider = try gpa.dupe(u8, provider),
            .model = try gpa.dupe(u8, model),
            .url = url,
            .api_key = try gpa.dupe(u8, key),
            .kind = .anthropic,
        };
    }
    if (std.mem.eql(u8, provider, "compat") or std.mem.eql(u8, provider, "openai-compatible")) {
        const base = env.get("BLOOB_COMPAT_BASE_URL") orelse return error.MissingBaseUrl;
        const key = env.get("BLOOB_COMPAT_API_KEY") orelse env.get("OPENAI_API_KEY") orelse "";
        const url = try joinUrl(gpa, base, "/chat/completions");
        errdefer gpa.free(url);
        return .{
            .gpa = gpa,
            .provider = try gpa.dupe(u8, provider),
            .model = try gpa.dupe(u8, model),
            .url = url,
            .api_key = try gpa.dupe(u8, key),
            .kind = .openai,
        };
    }
    return error.UnsupportedProvider;
}
