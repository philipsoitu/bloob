//! Asynchronous shell process for the interactive TUI. Keeps the UI loop
//! responsive and allows Ctrl-C cancellation. The headless runner uses the
//! simpler synchronous capture path in tools.zig.
const std = @import("std");
const sys = @import("../c.zig").sys;

pub const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    stdout: ?std.Io.File,
    stderr: ?std.Io.File,
    out: std.ArrayList(u8) = .empty,
    err: std.ArrayList(u8) = .empty,
    read_buf: [8192]u8 = undefined,
    eof_out: bool = false,
    eof_err: bool = false,
    waited: bool = false,
    done: bool = false,
    cancelled: bool = false,
    timed_out: bool = false,
    truncated: bool = false,
    max_bytes: usize,
    deadline_ms: i64,
    term: ?std.process.Child.Term = null,

    pub fn start(
        gpa: std.mem.Allocator,
        io: std.Io,
        command: []const u8,
        cwd: []const u8,
        timeout_ms: u64,
        max_bytes: usize,
    ) !*Job {
        var child = try std.process.spawn(io, .{
            .argv = &.{ "/bin/sh", "-c", command },
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        errdefer child.kill(io);
        const self = try gpa.create(Job);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .stdout = child.stdout,
            .stderr = child.stderr,
            .max_bytes = max_bytes,
            .deadline_ms = std.Io.Clock.awake.now(io).toMilliseconds() + @as(i64, @intCast(timeout_ms)),
        };
        self.child.stdout = null;
        self.child.stderr = null;
        if (self.stdout) |f| _ = sys.fcntl(f.handle, sys.F_SETFL, sys.O_NONBLOCK);
        if (self.stderr) |f| _ = sys.fcntl(f.handle, sys.F_SETFL, sys.O_NONBLOCK);
        return self;
    }

    pub fn stdoutFd(self: *Job) ?std.posix.fd_t {
        if (self.stdout) |f| return f.handle;
        return null;
    }
    pub fn stderrFd(self: *Job) ?std.posix.fd_t {
        if (self.stderr) |f| return f.handle;
        return null;
    }

    pub fn pump(self: *Job) void {
        if (self.done) return;
        if (std.Io.Clock.awake.now(self.io).toMilliseconds() >= self.deadline_ms) {
            self.timed_out = true;
            self.cancel();
            return;
        }
        if (self.stdout) |f| {
            const rr: ?usize = std.posix.read(f.handle, &self.read_buf) catch |err| switch (err) {
                error.WouldBlock => null,
                else => 0,
            };
            if (rr) |n| {
                if (n == 0) {
                    self.stdout.?.close(self.io);
                    self.stdout = null;
                    self.eof_out = true;
                } else {
                    if (self.out.items.len + n > self.max_bytes) {
                        const take = self.max_bytes -| self.out.items.len;
                        self.out.appendSlice(self.gpa, self.read_buf[0..take]) catch {};
                        self.out.appendSlice(self.gpa, "\n… [output truncated]\n") catch {};
                        self.truncated = true;
                        self.cancel();
                        return;
                    }
                    self.out.appendSlice(self.gpa, self.read_buf[0..n]) catch {};
                }
            }
        }
        if (self.stderr) |f| {
            const rr: ?usize = std.posix.read(f.handle, &self.read_buf) catch |err| switch (err) {
                error.WouldBlock => null,
                else => 0,
            };
            if (rr) |n| {
                if (n == 0) {
                    self.stderr.?.close(self.io);
                    self.stderr = null;
                    self.eof_err = true;
                } else if (self.err.items.len < 32 * 1024) {
                    self.err.appendSlice(self.gpa, self.read_buf[0..n]) catch {};
                }
            }
        }
        if (self.eof_out and self.eof_err) self.finishWait();
    }

    fn finishWait(self: *Job) void {
        if (self.waited) {
            self.done = true;
            return;
        }
        self.term = self.child.wait(self.io) catch null;
        self.waited = true;
        self.done = true;
    }

    pub fn cancel(self: *Job) void {
        if (self.done) return;
        self.cancelled = true;
        if (self.stdout) |f| {
            f.close(self.io);
            self.stdout = null;
        }
        if (self.stderr) |f| {
            f.close(self.io);
            self.stderr = null;
        }
        if (!self.waited) {
            self.child.kill(self.io);
            self.waited = true;
        }
        self.done = true;
    }

    pub fn exitCode(self: *Job) u8 {
        if (self.timed_out) return 124;
        if (self.cancelled) return 130;
        if (self.term) |t| switch (t) {
            .exited => |c| return c,
            else => return 255,
        };
        return 0;
    }

    pub fn deinit(self: *Job) void {
        if (self.stdout) |f| f.close(self.io);
        if (self.stderr) |f| f.close(self.io);
        if (!self.waited) self.child.kill(self.io);
        self.out.deinit(self.gpa);
        self.err.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};

test "shell job runs and captures output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const job = try Job.start(gpa, io, "printf hi", path_buf[0..n], 5000, 4096);
    defer job.deinit();
    var i: usize = 0;
    while (!job.done and i < 200) : (i += 1) {
        job.pump();
        if (!job.done) std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
    }
    try std.testing.expect(job.done);
    try std.testing.expectEqualStrings("hi", job.out.items);
}
