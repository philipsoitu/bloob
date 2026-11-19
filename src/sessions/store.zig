//! Durable, append-only session storage for bloob.
//!
//! Layout (inside the directory passed to `Store.init`):
//!
//!   <id>.jsonl       first line: session header; remaining lines: messages
//!   <id>.meta.json   latest metadata snapshot (atomic temp+rename)
//!
//! The JSONL file is the source of truth for messages. The sidecar is a small
//! cache of the latest metadata so `list` does not have to scan every message
//! and `updateMeta` is O(1) rather than O(session size). If the sidecar is
//! missing or corrupt, the JSONL header is used instead.
//!
//! Only standard library modules and the local `types.zig` mirror are imported, so this
//! file can be tested directly with:
//!
//!   nix develop -c zig test src/sessions/store.zig
const std = @import("std");
const types = @import("types.zig");
const codec = @import("codec.zig");

pub const schema_version = codec.schema_version;

/// Standalone message types used by loaded sessions. Application code can
/// convert them with `compat.zig` (see `docs/sessions.md`).
pub const Message = types.Message;
pub const Conversation = types.Conversation;
pub const Role = types.Role;
pub const Usage = types.Usage;

/// Hard upper bound for one session file. A single message is limited by
/// `codec.max_message_bytes`; this bounds the total conversation.
pub const max_session_bytes: u64 = 64 * 1024 * 1024;

/// Bound on the number of messages loaded into memory at once.
pub const max_messages: usize = 100_000;

const is_windows = @import("builtin").os.tag == .windows;
const private_file_permissions: std.Io.File.Permissions =
    if (is_windows) .default_file else .fromMode(0o600);
const private_dir_permissions: std.Io.File.Permissions =
    if (is_windows) .default_dir else .fromMode(0o700);

const jsonl_suffix = ".jsonl";
const meta_suffix = ".meta.json";

/// Resolve the default sessions directory:
/// `$XDG_DATA_HOME/bloob/sessions` or `$HOME/.local/share/bloob/sessions`.
///
/// The caller owns the returned string. `environ_map` is normally
/// `std.process.Init.environ_map` from `main`.
pub fn defaultDataDir(gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]u8 {
    if (environ_map.get("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) {
            return std.fs.path.join(gpa, &.{ xdg, "bloob", "sessions" });
        }
    }
    if (environ_map.get("HOME")) |home| {
        if (home.len > 0) {
            return std.fs.path.join(gpa, &.{ home, ".local", "share", "bloob", "sessions" });
        }
    }
    return error.NoHomeDirectory;
}

/// One loaded session. `conversation` is owned by the Session and is populated
/// by `Store.load`; `Store.create` starts it empty.
pub const Session = struct {
    gpa: std.mem.Allocator,
    id: []u8,
    path: []u8,
    cwd: []u8,
    model: []u8,
    created_ms: i64,
    updated_ms: i64,
    message_count: u64,
    schema_version: u32 = codec.schema_version,
    /// Number of valid bytes in the JSONL file (header + complete messages).
    bytes: u64 = 0,
    /// True when `load` truncated a corrupt/incomplete trailing line.
    recovered_tail: bool = false,
    conversation: types.Conversation,

    pub fn deinit(self: *Session) void {
        self.conversation.deinit();
        self.gpa.free(self.id);
        self.gpa.free(self.path);
        self.gpa.free(self.cwd);
        self.gpa.free(self.model);
        self.* = undefined;
    }
};

/// Lightweight row returned by `Store.list`. All strings are owned; call
/// `deinit` for each row and then free the containing slice.
pub const SessionInfo = struct {
    id: []u8,
    cwd: []u8,
    model: []u8,
    created_ms: i64,
    updated_ms: i64,
    message_count: u64,
    schema_version: u32,

    pub fn deinit(self: *SessionInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.cwd);
        gpa.free(self.model);
        self.* = undefined;
    }
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    data_dir: []u8,

    /// `data_dir` is the sessions directory itself (not `$XDG_DATA_HOME`).
    /// It is created if necessary and made private (0700 on POSIX).
    pub fn init(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8) !Store {
        const resolved = try std.fs.path.resolve(gpa, &.{data_dir});
        errdefer gpa.free(resolved);

        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, resolved);

        var dir = try cwd.openDir(io, resolved, .{ .iterate = true });
        defer dir.close(io);
        try dir.setPermissions(io, private_dir_permissions);

        return .{ .gpa = gpa, .io = io, .data_dir = resolved };
    }

    pub fn deinit(self: *Store) void {
        self.gpa.free(self.data_dir);
        self.* = undefined;
    }

    fn nowMs(self: *const Store) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }

    fn generateId(self: *const Store) ![]u8 {
        var raw: [16]u8 = undefined;
        self.io.randomSecure(&raw) catch self.io.random(&raw);
        const hex = "0123456789abcdef";
        var out: [32]u8 = undefined;
        for (raw, 0..) |b, i| {
            out[i * 2] = hex[b >> 4];
            out[i * 2 + 1] = hex[b & 0x0f];
        }
        return self.gpa.dupe(u8, &out);
    }

    fn pathFor(self: *const Store, id: []const u8, suffix: []const u8) ![]u8 {
        const name = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ id, suffix });
        defer self.gpa.free(name);
        return std.fs.path.join(self.gpa, &.{ self.data_dir, name });
    }

    fn writeAtomic(self: *const Store, path: []const u8, data: []const u8, replace: bool) !void {
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .permissions = private_file_permissions,
            .replace = replace,
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, data);
        try atomic.file.sync(self.io);
        if (replace) {
            try atomic.replace(self.io);
        } else {
            try atomic.link(self.io);
        }
    }

    fn headerView(session: *const Session) codec.HeaderView {
        return .{
            .schema_version = session.schema_version,
            .id = session.id,
            .cwd = session.cwd,
            .model = session.model,
            .created_ms = session.created_ms,
            .updated_ms = session.updated_ms,
            .message_count = session.message_count,
        };
    }

    /// Atomically replace the metadata sidecar. The JSONL header is left alone;
    /// readers prefer the sidecar, and the header remains a usable fallback if
    /// the sidecar is deleted or the session file is copied elsewhere.
    fn writeMeta(self: *const Store, session: *const Session) !void {
        const line = try codec.encodeMetaFile(self.gpa, headerView(session));
        defer self.gpa.free(line);
        const data = try std.fmt.allocPrint(self.gpa, "{s}\n", .{line});
        defer self.gpa.free(data);
        const path = try self.pathFor(session.id, meta_suffix);
        defer self.gpa.free(path);
        try self.writeAtomic(path, data, true);
    }

    fn readMeta(self: *const Store, id: []const u8) !?codec.Header {
        const path = try self.pathFor(id, meta_suffix);
        defer self.gpa.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.gpa,
            .limited(codec.max_header_bytes + 1),
        ) catch |err| switch (err) {
            error.FileNotFound, error.StreamTooLong => return null,
            else => return err,
        };
        defer self.gpa.free(data);
        const line = std.mem.trimEnd(u8, data, "\r\n \t");
        if (line.len == 0) return null;
        return codec.parseMeta(self.gpa, line, "meta") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    fn createAttempt(self: *Store, cwd_path: []const u8, model: []const u8) !Session {
        const id = try self.generateId();
        const path = self.pathFor(id, jsonl_suffix) catch |err| {
            self.gpa.free(id);
            return err;
        };
        const cwd_copy = self.gpa.dupe(u8, cwd_path) catch |err| {
            self.gpa.free(path);
            self.gpa.free(id);
            return err;
        };
        const model_copy = self.gpa.dupe(u8, model) catch |err| {
            self.gpa.free(cwd_copy);
            self.gpa.free(path);
            self.gpa.free(id);
            return err;
        };

        const now = self.nowMs();
        var session = Session{
            .gpa = self.gpa,
            .id = id,
            .path = path,
            .cwd = cwd_copy,
            .model = model_copy,
            .created_ms = now,
            .updated_ms = now,
            .message_count = 0,
            .conversation = types.Conversation.init(self.gpa),
        };
        errdefer session.deinit();

        const line = try codec.encodeHeader(self.gpa, headerView(&session));
        defer self.gpa.free(line);
        const data = try std.fmt.allocPrint(self.gpa, "{s}\n", .{line});
        defer self.gpa.free(data);
        session.bytes = data.len;

        try self.writeAtomic(session.path, data, false);
        self.writeMeta(&session) catch |err| {
            std.Io.Dir.cwd().deleteFile(self.io, session.path) catch {};
            return err;
        };
        return session;
    }

    /// Create a new session with a random opaque id, write its header, and
    /// return it with an empty conversation.
    pub fn create(self: *Store, cwd: []const u8, model: []const u8) !Session {
        var attempt: usize = 0;
        while (attempt < 8) : (attempt += 1) {
            const result = self.createAttempt(cwd, model);
            if (result) |session| return session else |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            }
        }
        return error.IdCollision;
    }

    fn readHeaderFromFile(self: *const Store, dir: std.Io.Dir, name: []const u8) !codec.Header {
        var file = try dir.openFile(self.io, name, .{});
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        if (size == 0) return error.CorruptHeader;
        const to_read: usize = @intCast(@min(size, codec.max_header_bytes + 1));
        var buf: [codec.max_header_bytes + 1]u8 = undefined;
        const n = try file.readPositionalAll(self.io, buf[0..to_read], 0);
        const newline = std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse return error.CorruptHeader;
        const line = std.mem.trimEnd(u8, buf[0..newline], "\r");
        return codec.parseMeta(self.gpa, line, "session");
    }

    /// List valid sessions, newest first. Corrupt, oversized, or future-schema
    /// entries are skipped rather than failing the whole listing.
    pub fn list(self: *Store) ![]SessionInfo {
        var items: std.ArrayList(SessionInfo) = .empty;
        errdefer {
            for (items.items) |*info| info.deinit(self.gpa);
            items.deinit(self.gpa);
        }

        var dir = try std.Io.Dir.cwd().openDir(self.io, self.data_dir, .{ .iterate = true });
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, jsonl_suffix)) continue;
            const id_len = entry.name.len - jsonl_suffix.len;
            if (id_len == 0 or id_len > codec.max_id_bytes) continue;
            const id = entry.name[0..id_len];
            if (!codec.validId(id)) continue;

            var header = self.readHeaderFromFile(dir, entry.name) catch continue;
            defer header.deinit(self.gpa);
            if (!std.mem.eql(u8, header.id, id)) continue;

            var meta_opt = self.readMeta(id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            defer if (meta_opt) |*m| m.deinit(self.gpa);

            const src: *const codec.Header = if (meta_opt) |*m|
                (if (std.mem.eql(u8, m.id, id)) m else &header)
            else
                &header;

            const info_id = try self.gpa.dupe(u8, src.id);
            errdefer self.gpa.free(info_id);
            const info_cwd = try self.gpa.dupe(u8, src.cwd);
            errdefer self.gpa.free(info_cwd);
            const info_model = try self.gpa.dupe(u8, src.model);
            errdefer self.gpa.free(info_model);
            try items.append(self.gpa, .{
                .id = info_id,
                .cwd = info_cwd,
                .model = info_model,
                .created_ms = src.created_ms,
                .updated_ms = src.updated_ms,
                .message_count = src.message_count,
                .schema_version = src.schema_version,
            });
        }

        std.mem.sort(SessionInfo, items.items, {}, struct {
            fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
                if (a.updated_ms == b.updated_ms) return std.mem.lessThan(u8, a.id, b.id);
                return a.updated_ms > b.updated_ms;
            }
        }.lessThan);

        return items.toOwnedSlice(self.gpa);
    }

    const Analysis = struct {
        header: codec.Header,
        valid_end: usize,
        message_count: u64,
        recovered: bool,
    };

    fn hasNonWhitespaceAfter(data: []const u8, from: usize) bool {
        if (from >= data.len) return false;
        for (data[from..]) |c| {
            if (!std.ascii.isWhitespace(c)) return true;
        }
        return false;
    }

    /// Validate and decode a complete JSONL buffer.
    ///
    /// A corrupt/incomplete trailing line is tolerated: `valid_end` points just
    /// past the last complete, valid record. Corruption before a later record is
    /// a hard error because silently dropping a middle message would corrupt the
    /// conversation.
    fn analyze(
        gpa: std.mem.Allocator,
        data: []const u8,
        collect: ?*types.Conversation,
    ) !Analysis {
        var header_opt: ?codec.Header = null;
        errdefer if (header_opt) |*h| h.deinit(gpa);

        var pos: usize = 0;
        var first = true;
        var valid_end: usize = 0;
        var count: u64 = 0;
        var recovered = false;

        while (pos < data.len) {
            const newline = std.mem.indexOfScalarPos(u8, data, pos, '\n');
            const line_end = if (newline) |n| n + 1 else data.len;
            const raw_line = data[pos..if (newline) |n| n else data.len];
            const line = std.mem.trimEnd(u8, raw_line, "\r");

            if (first) {
                if (newline == null) return error.CorruptHeader;
                header_opt = try codec.parseMeta(gpa, line, "session");
                first = false;
                valid_end = line_end;
                pos = line_end;
                continue;
            }

            if (line.len == 0) {
                valid_end = line_end;
                pos = line_end;
                continue;
            }

            if (line.len > codec.max_message_bytes) {
                if (hasNonWhitespaceAfter(data, line_end)) return error.SessionTooLarge;
                recovered = true;
                break;
            }

            // A final line without a newline was not committed completely.
            if (newline == null) {
                recovered = true;
                break;
            }

            const parsed_message = codec.parseMessage(gpa, line);
            if (parsed_message) |message_value| {
                var message = message_value;
                if (collect) |conversation| {
                    conversation.messages.append(gpa, message) catch |err| {
                        message.deinit(gpa);
                        return err;
                    };
                } else {
                    var tmp = message;
                    tmp.deinit(gpa);
                }
                count += 1;
                valid_end = line_end;
                pos = line_end;
            } else |err| {
                if (hasNonWhitespaceAfter(data, line_end)) {
                    return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.MessageTooLarge, error.TooManyToolCalls => error.SessionTooLarge,
                        else => error.CorruptSession,
                    };
                }
                recovered = true;
                break;
            }
        }

        if (first) return error.CorruptHeader;
        const header = header_opt.?;
        header_opt = null;
        return .{
            .header = header,
            .valid_end = valid_end,
            .message_count = count,
            .recovered = recovered,
        };
    }

    fn truncateTo(self: *Store, path: []const u8, len: usize) !void {
        var file = try std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_write });
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        if (size < len) return error.CorruptSession;
        try file.setLength(self.io, @intCast(len));
        try file.sync(self.io);
    }

    /// Load and validate one session. A corrupt trailing line is truncated on
    /// disk before returning so the next append is safe. Newer schema versions
    /// fail with `error.IncompatibleSchemaVersion`.
    pub fn load(self: *Store, id: []const u8) !Session {
        if (!codec.validId(id)) return error.InvalidSessionId;

        const jsonl_path = try self.pathFor(id, jsonl_suffix);
        defer self.gpa.free(jsonl_path);
        const data = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            jsonl_path,
            self.gpa,
            .limited(max_session_bytes),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.SessionTooLarge,
            else => return err,
        };
        defer self.gpa.free(data);

        var conversation = types.Conversation.init(self.gpa);
        errdefer conversation.deinit();
        const analysis = try analyze(self.gpa, data, &conversation);
        var header = analysis.header;
        defer header.deinit(self.gpa);

        if (!std.mem.eql(u8, header.id, id)) return error.SessionIdMismatch;

        var meta_opt = self.readMeta(id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        defer if (meta_opt) |*m| m.deinit(self.gpa);

        const src: *const codec.Header = if (meta_opt) |*m|
            (if (std.mem.eql(u8, m.id, id) and m.schema_version <= schema_version) m else &header)
        else
            &header;

        var id_owned: ?[]u8 = try self.gpa.dupe(u8, id);
        errdefer if (id_owned) |s| self.gpa.free(s);
        var path_owned: ?[]u8 = try self.pathFor(id, jsonl_suffix);
        errdefer if (path_owned) |s| self.gpa.free(s);
        var cwd_owned: ?[]u8 = try self.gpa.dupe(u8, src.cwd);
        errdefer if (cwd_owned) |s| self.gpa.free(s);
        var model_owned: ?[]u8 = try self.gpa.dupe(u8, src.model);
        errdefer if (model_owned) |s| self.gpa.free(s);

        var session = Session{
            .gpa = self.gpa,
            .id = id_owned.?,
            .path = path_owned.?,
            .cwd = cwd_owned.?,
            .model = model_owned.?,
            .created_ms = src.created_ms,
            .updated_ms = src.updated_ms,
            .message_count = analysis.message_count,
            .schema_version = src.schema_version,
            .bytes = @intCast(analysis.valid_end),
            .recovered_tail = analysis.recovered,
            .conversation = conversation,
        };
        id_owned = null;
        path_owned = null;
        cwd_owned = null;
        model_owned = null;
        conversation = types.Conversation.init(self.gpa);
        errdefer session.deinit();

        if (analysis.recovered) {
            try self.truncateTo(session.path, analysis.valid_end);
            // Refresh the sidecar with the actual recovered count. Failure here
            // is not fatal; the JSONL header remains a valid fallback.
            self.writeMeta(&session) catch {};
        }

        // The sidecar/header may have an older timestamp than the last message
        // if a previous run crashed between appending and metadata refresh.
        if (session.conversation.last()) |last| {
            session.updated_ms = @max(session.updated_ms, last.timestamp_ms);
        }
        return session;
    }

    /// Append one message as a new JSONL line. The message is copied; the caller
    /// retains ownership and may keep using it. The append is synced to disk and
    /// the metadata sidecar is refreshed.
    pub fn appendMessage(self: *Store, session: *Session, message: anytype) !void {
        const line = try codec.encodeMessage(self.gpa, message);
        defer self.gpa.free(line);

        if (session.message_count >= max_messages) return error.TooManyMessages;

        const line_size: u64 = @intCast(line.len + 1);
        const cwd = std.Io.Dir.cwd();
        var file = try cwd.openFile(self.io, session.path, .{ .mode = .read_write });
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.size > max_session_bytes or line_size > max_session_bytes - stat.size) {
            return error.SessionTooLarge;
        }
        if (stat.size > 0) {
            var last_byte: [1]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &last_byte, stat.size - 1);
            if (n != 1 or last_byte[0] != '\n') return error.CorruptTrailingLine;
        }

        var buf: [8 * 1024]u8 = undefined;
        var writer = file.writer(self.io, &buf);
        try writer.seekTo(stat.size);
        try writer.interface.writeAll(line);
        try writer.interface.writeAll("\n");
        try writer.interface.flush();
        try file.sync(self.io);

        session.message_count += 1;
        session.bytes = stat.size + line_size;
        session.updated_ms = self.nowMs();
        try self.writeMeta(session);
    }

    /// Update mutable metadata (cwd/model/timestamps/count) and atomically
    /// replace the sidecar. Does not rewrite or re-encode the conversation.
    pub fn updateMeta(self: *Store, session: *Session) !void {
        if (!codec.validId(session.id)) return error.InvalidSessionId;
        std.Io.Dir.cwd().access(self.io, session.path, .{}) catch |err| return err;
        session.updated_ms = self.nowMs();
        try self.writeMeta(session);
    }

    /// Delete both the session JSONL and its metadata sidecar. Missing files are
    /// tolerated as long as at least one of them existed.
    pub fn delete(self: *Store, id: []const u8) !void {
        if (!codec.validId(id)) return error.InvalidSessionId;
        const cwd = std.Io.Dir.cwd();
        const jsonl = try self.pathFor(id, jsonl_suffix);
        defer self.gpa.free(jsonl);
        const meta = try self.pathFor(id, meta_suffix);
        defer self.gpa.free(meta);

        var removed = false;
        const jsonl_result = cwd.deleteFile(self.io, jsonl);
        if (jsonl_result) |_| {
            removed = true;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const meta_result = cwd.deleteFile(self.io, meta);
        if (meta_result) |_| {
            removed = true;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        if (!removed) return error.FileNotFound;
    }
};

/// Free every row and the slice returned by `Store.list`.
pub fn freeInfoList(gpa: std.mem.Allocator, infos: []SessionInfo) void {
    for (infos) |*info| info.deinit(gpa);
    gpa.free(infos);
}

fn testTempDir(gpa: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    return std.fs.path.join(gpa, &.{ path_buf[0..n], "sessions" });
}

fn appendRaw(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    const stat = try file.stat(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.seekTo(stat.size);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn writeRaw(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .permissions = private_file_permissions },
    });
}

test "create, append, load roundtrip with tool calls and usage" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try testTempDir(gpa, io, &tmp);
    defer gpa.free(data_dir);

    var store = try Store.init(gpa, io, data_dir);
    defer store.deinit();

    // Restrictive permissions.
    const dir_stat = try std.Io.Dir.cwd().statFile(io, data_dir, .{});
    if (!is_windows) try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_stat.permissions.toMode() & 0o777);

    var session = try store.create("/work/project", "mock/fixture");
    defer session.deinit();
    try std.testing.expect(codec.validId(session.id));
    try std.testing.expect(session.bytes > 0);

    const file_stat = try std.Io.Dir.cwd().statFile(io, session.path, .{});
    if (!is_windows) try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), file_stat.permissions.toMode() & 0o777);

    var user = types.Message.init(gpa, 1, .user);
    defer user.deinit(gpa);
    try user.text.appendSlice(gpa, "read the \"README\"\nplease");
    user.timestamp_ms = 1000;
    try store.appendMessage(&session, &user);

    var assistant = types.Message.init(gpa, 2, .assistant);
    defer assistant.deinit(gpa);
    try assistant.text.appendSlice(gpa, "I will read it.");
    try assistant.setModel(gpa, "mock/fixture");
    assistant.timestamp_ms = 2000;
    assistant.usage = .{ .prompt_tokens = 12, .completion_tokens = 5, .reported = true };
    try assistant.addToolCall(gpa, "call_1", "read_file", "{\"path\":\"README.md\"}");
    try store.appendMessage(&session, &assistant);

    var tool = types.Message.init(gpa, 3, .tool);
    defer tool.deinit(gpa);
    try tool.text.appendSlice(gpa, "file contents");
    try tool.setToolResult(gpa, "call_1", "read_file", false);
    tool.timestamp_ms = 3000;
    try store.appendMessage(&session, &tool);

    var loaded = try store.load(session.id);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("/work/project", loaded.cwd);
    try std.testing.expectEqualStrings("mock/fixture", loaded.model);
    try std.testing.expectEqual(@as(u64, 3), loaded.message_count);
    try std.testing.expectEqual(@as(usize, 3), loaded.conversation.messages.items.len);
    try std.testing.expectEqualStrings("read the \"README\"\nplease", loaded.conversation.messages.items[0].text.items);
    try std.testing.expectEqual(types.Role.assistant, loaded.conversation.messages.items[1].role);
    try std.testing.expectEqualStrings("call_1", loaded.conversation.messages.items[1].tool_calls.items[0].id);
    try std.testing.expectEqual(@as(u64, 12), loaded.conversation.messages.items[1].usage.prompt_tokens);
    try std.testing.expectEqualStrings("call_1", loaded.conversation.messages.items[2].tool_call_id.?);
    try std.testing.expectEqualStrings("read_file", loaded.conversation.messages.items[2].tool_name.?);

    // The first line is a parseable JSONL header, not an arbitrary prefix.
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, session.path, gpa, .limited(max_session_bytes));
    defer gpa.free(raw);
    const first_newline = std.mem.indexOfScalar(u8, raw, '\n').?;
    var header = try codec.parseMeta(gpa, raw[0..first_newline], "session");
    defer header.deinit(gpa);
    try std.testing.expectEqual(schema_version, header.schema_version);
    try std.testing.expectEqualStrings(session.id, header.id);
}

test "list is newest-first and updateMeta is visible after load" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try testTempDir(gpa, io, &tmp);
    defer gpa.free(data_dir);

    var store = try Store.init(gpa, io, data_dir);
    defer store.deinit();

    var first = try store.create("/one", "model/a");
    defer first.deinit();
    var second = try store.create("/two", "model/b");
    defer second.deinit();

    gpa.free(first.cwd);
    first.cwd = try gpa.dupe(u8, "/new");
    gpa.free(first.model);
    first.model = try gpa.dupe(u8, "model/c");
    try store.updateMeta(&first);

    const infos = try store.list();
    defer freeInfoList(gpa, infos);
    try std.testing.expectEqual(@as(usize, 2), infos.len);
    var found = false;
    for (infos) |info| {
        if (std.mem.eql(u8, info.id, first.id)) {
            found = true;
            try std.testing.expectEqualStrings("/new", info.cwd);
            try std.testing.expectEqualStrings("model/c", info.model);
            try std.testing.expectEqual(@as(u64, 0), info.message_count);
        }
    }
    try std.testing.expect(found);

    var loaded = try store.load(first.id);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("/new", loaded.cwd);
    try std.testing.expectEqualStrings("model/c", loaded.model);
}

test "corrupt trailing line is truncated and append still works" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try testTempDir(gpa, io, &tmp);
    defer gpa.free(data_dir);

    var store = try Store.init(gpa, io, data_dir);
    defer store.deinit();
    var session = try store.create("/work", "m");
    defer session.deinit();

    var message = types.Message.init(gpa, 1, .user);
    defer message.deinit(gpa);
    try message.text.appendSlice(gpa, "complete");
    try store.appendMessage(&session, &message);

    const valid_size = (try std.Io.Dir.cwd().statFile(io, session.path, .{})).size;
    try appendRaw(io, session.path, "{\"type\":\"message\",\"id\":2,\"role\":\"user\",\"te");

    var loaded = try store.load(session.id);
    defer loaded.deinit();
    try std.testing.expect(loaded.recovered_tail);
    try std.testing.expectEqual(@as(usize, 1), loaded.conversation.messages.items.len);
    try std.testing.expectEqualStrings("complete", loaded.conversation.messages.items[0].text.items);
    try std.testing.expectEqual(valid_size, (try std.Io.Dir.cwd().statFile(io, session.path, .{})).size);

    // The append path sees a clean newline boundary after recovery.
    var more = types.Message.init(gpa, 3, .assistant);
    defer more.deinit(gpa);
    try more.text.appendSlice(gpa, "after recovery");
    try store.appendMessage(&loaded, &more);

    var again = try store.load(session.id);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 2), again.conversation.messages.items.len);
    try std.testing.expectEqualStrings("after recovery", again.conversation.messages.items[1].text.items);
}

test "corruption before a later record is a hard error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try testTempDir(gpa, io, &tmp);
    defer gpa.free(data_dir);

    var store = try Store.init(gpa, io, data_dir);
    defer store.deinit();
    var session = try store.create("/work", "m");
    defer session.deinit();

    var valid = types.Message.init(gpa, 2, .assistant);
    defer valid.deinit(gpa);
    try valid.text.appendSlice(gpa, "later record");
    const valid_line = try codec.encodeMessage(gpa, &valid);
    defer gpa.free(valid_line);

    const bad = try std.fmt.allocPrint(gpa, "not-json\n{s}\n", .{valid_line});
    defer gpa.free(bad);
    try appendRaw(io, session.path, bad);

    try std.testing.expectError(error.CorruptSession, store.load(session.id));
}

test "future schema is rejected with a clear error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try testTempDir(gpa, io, &tmp);
    defer gpa.free(data_dir);

    var store = try Store.init(gpa, io, data_dir);
    defer store.deinit();
    var session = try store.create("/work", "m");
    defer session.deinit();

    const raw = try std.Io.Dir.cwd().readFileAlloc(io, session.path, gpa, .limited(max_session_bytes));
    defer gpa.free(raw);
    const needle = "\"schema_version\":";
    const idx = std.mem.indexOf(u8, raw, needle).? + needle.len;
    raw[idx] = '9'; // 1 -> 9, a newer incompatible schema
    try writeRaw(io, session.path, raw);

    try std.testing.expectError(error.IncompatibleSchemaVersion, store.load(session.id));
}

test "delete removes the session and its sidecar" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try testTempDir(gpa, io, &tmp);
    defer gpa.free(data_dir);

    var store = try Store.init(gpa, io, data_dir);
    defer store.deinit();
    var session = try store.create("/work", "m");
    defer session.deinit();

    try store.delete(session.id);
    try std.testing.expectError(error.FileNotFound, store.load(session.id));
    try std.testing.expectError(error.FileNotFound, store.delete(session.id));
}

test "invalid ids cannot escape the data directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try testTempDir(gpa, io, &tmp);
    defer gpa.free(data_dir);

    var store = try Store.init(gpa, io, data_dir);
    defer store.deinit();
    try std.testing.expectError(error.InvalidSessionId, store.load("../escape"));
    try std.testing.expectError(error.InvalidSessionId, store.load("has.dot"));
    try std.testing.expectError(error.InvalidSessionId, store.delete("with/slash"));
}

test "oversized messages are rejected before writing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try testTempDir(gpa, io, &tmp);
    defer gpa.free(data_dir);

    var store = try Store.init(gpa, io, data_dir);
    defer store.deinit();
    var session = try store.create("/work", "m");
    defer session.deinit();

    var huge = types.Message.init(gpa, 1, .user);
    defer huge.deinit(gpa);
    const filler = try gpa.alloc(u8, codec.max_text_bytes + 1);
    defer gpa.free(filler);
    @memset(filler, 'x');
    try huge.text.appendSlice(gpa, filler);
    try std.testing.expectError(error.MessageTooLarge, store.appendMessage(&session, &huge));

    try std.testing.expectEqual(@as(u64, 0), session.message_count);
}

test "default data dir honors XDG then HOME" {
    const gpa = std.testing.allocator;

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("XDG_DATA_HOME", "/xdg/data");
    try environ.put("HOME", "/home/tester");

    const with_xdg = try defaultDataDir(gpa, &environ);
    defer gpa.free(with_xdg);
    try std.testing.expectEqualStrings("/xdg/data/bloob/sessions", with_xdg);

    try environ.put("XDG_DATA_HOME", "");
    const with_home = try defaultDataDir(gpa, &environ);
    defer gpa.free(with_home);
    try std.testing.expectEqualStrings("/home/tester/.local/share/bloob/sessions", with_home);
}
