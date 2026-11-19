//! Terminal lifecycle, raw mode, size and low-level I/O.
//! Terminal state is restored on every controlled exit path.
const std = @import("std");
const env = @import("env.zig");
const sys = @import("c.zig").sys;

pub const Size = struct {
    cols: u16 = 80,
    rows: u16 = 24,
};

pub const SignalState = struct {
    resize: std.atomic.Value(bool) = .init(false),
    interrupt: std.atomic.Value(bool) = .init(false),
    terminate: std.atomic.Value(bool) = .init(false),
};

var signals: SignalState = .{};

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    switch (sig) {
        .WINCH => signals.resize.store(true, .release),
        .INT => signals.interrupt.store(true, .release),
        .TERM, .HUP, .QUIT => signals.terminate.store(true, .release),
        else => {},
    }
}

fn installSignals() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.WINCH, &act, null);
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.HUP, &act, null);
    std.posix.sigaction(.QUIT, &act, null);
}

pub fn pendingResize() bool {
    return signals.resize.swap(false, .acquire);
}
pub fn pendingInterrupt() bool {
    return signals.interrupt.swap(false, .acquire);
}
pub fn pendingTerminate() bool {
    return signals.terminate.load(.acquire);
}

pub const Terminal = struct {
    orig: ?std.posix.termios = null,
    raw_enabled: bool = false,
    alt_screen: bool = false,
    mouse_enabled: bool = false,
    paste_enabled: bool = false,
    color_mode: @import("style.zig").ColorMode = .ansi16,

    pub fn isTty(fd: std.posix.fd_t) bool {
        return sys.isatty(fd) == 1;
    }

    pub fn init() !Terminal {
        var t = Terminal{};
        if (!isTty(std.posix.STDIN_FILENO) or !isTty(std.posix.STDOUT_FILENO)) {
            return error.NotATerminal;
        }
        t.orig = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return error.NotATerminal;
        var raw = t.orig.?;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw);
        t.raw_enabled = true;
        errdefer t.deinit();
        installSignals();

        // Alternate screen, hidden cursor, bracketed paste, SGR mouse, focus events.
        try t.writeAll("\x1b[?1049h\x1b[?25l\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[?1004h");
        t.alt_screen = true;
        t.mouse_enabled = true;
        t.paste_enabled = true;
        t.color_mode = @import("style.zig").detectColorMode();
        return t;
    }

    pub fn deinit(self: *Terminal) void {
        if (self.raw_enabled) {
            self.writeAll("\x1b[?1004l\x1b[?1006l\x1b[?1000l\x1b[?2004l\x1b[?25h") catch {};
            if (self.alt_screen) self.writeAll("\x1b[?1049l") catch {};
            if (self.orig) |orig| {
                std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, orig) catch {};
            }
            self.raw_enabled = false;
            self.alt_screen = false;
        }
    }

    pub fn size(self: *Terminal) Size {
        _ = self;
        var ws: sys.winsize = undefined;
        const rc = sys.ioctl(std.posix.STDOUT_FILENO, sys.TIOCGWINSZ, &ws);
        if (rc == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
            return .{ .cols = @intCast(ws.ws_col), .rows = @intCast(ws.ws_row) };
        }
        var cols: u16 = 80;
        var rows: u16 = 24;
        if (env.get("COLUMNS")) |v| {
            cols = std.fmt.parseInt(u16, v, 10) catch 80;
        }
        if (env.get("LINES")) |v| {
            rows = std.fmt.parseInt(u16, v, 10) catch 24;
        }
        return .{ .cols = cols, .rows = rows };
    }

    pub fn writeAll(self: *Terminal, bytes: []const u8) !void {
        _ = self;
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = sys.write(std.posix.STDOUT_FILENO, bytes[off..].ptr, bytes.len - off);
            if (rc < 0) return error.WriteFailed;
            if (rc == 0) return error.Unexpected;
            off += @intCast(rc);
        }
    }

    pub fn read(self: *Terminal, buf: []u8) !usize {
        _ = self;
        while (true) {
            return std.posix.read(std.posix.STDIN_FILENO, buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
        }
    }

    pub fn moveCursor(self: *Terminal, x: u16, y: u16) !void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H\x1b[?25h", .{ y + 1, x + 1 }) catch return;
        try self.writeAll(s);
    }

    pub fn hideCursor(self: *Terminal) !void {
        try self.writeAll("\x1b[?25l");
    }

    pub fn bell(self: *Terminal) void {
        _ = self;
        _ = sys.write(std.posix.STDOUT_FILENO, "\x07", 1);
    }
};
