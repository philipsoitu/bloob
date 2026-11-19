const std = @import("std");
const env = @import("env.zig");
const cli_mod = @import("cli.zig");
const term = @import("term.zig");
const app_mod = @import("app.zig");
const headless = @import("headless.zig");
const sessions_store = @import("sessions/store.zig");

const version = "0.1.0";
const lua_version = "LuaJIT 2.1";

fn stdoutWriter(init: std.process.Init, buf: []u8) std.Io.File.Writer {
    return std.Io.File.stdout().writer(init.io, buf);
}

fn writeStdout(init: std.process.Init, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = stdoutWriter(init, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn printHelp(init: std.process.Init) !void {
    try writeStdout(init, cli_mod.help_text);
}

fn printVersion(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var w = stdoutWriter(init, &buf);
    try w.interface.print("bloob {s}\nzig 0.17.1\n{s}\n", .{ version, lua_version });
    try w.interface.flush();
}

fn listModels(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var w = stdoutWriter(init, &buf);
    try w.interface.writeAll(
        \\Available providers/models (configured at runtime):
        \\  mock/fixture          deterministic offline provider (always available)
        \\
    );
    if (env.get("OPENAI_API_KEY") != null) {
        try w.interface.writeAll("  openai/*              OPENAI_API_KEY detected; set --model openai/<model-id>\n");
    } else {
        try w.interface.writeAll("  openai/*              unavailable: OPENAI_API_KEY is not set\n");
    }
    if (env.get("ANTHROPIC_API_KEY") != null) {
        try w.interface.writeAll("  anthropic/*           ANTHROPIC_API_KEY detected; set --model anthropic/<model-id>\n");
    } else {
        try w.interface.writeAll("  anthropic/*           unavailable: ANTHROPIC_API_KEY is not set\n");
    }
    try w.interface.flush();
}

fn doctor(init: std.process.Init) !void {
    var buf: [16384]u8 = undefined;
    var w = stdoutWriter(init, &buf);
    const is_tty = term.Terminal.isTty(std.posix.STDIN_FILENO) and term.Terminal.isTty(std.posix.STDOUT_FILENO);
    try w.interface.print(
        \\bloob doctor
        \\  version:           {s}
        \\  zig:               0.17.1
        \\  lua:               {s}
        \\  tty stdin/stdout:  {s}
        \\  TERM:              {s}
        \\  COLORTERM:         {s}
        \\  cwd:               {s}
        \\  config:            {s}
        \\  config exists:     {s}
        \\  data dir:          {s}
        \\  OPENAI_API_KEY:    {s}
        \\  ANTHROPIC_API_KEY: {s}
        \\  ripgrep:           {s}
        \\  curl:              {s}
        \\
    , .{
        version,
        lua_version,
        if (is_tty) "yes" else "no",
        env.get("TERM") orelse "(unset)",
        env.get("COLORTERM") orelse "(unset)",
        env.get("PWD") orelse ".",
        env.get("XDG_CONFIG_HOME") orelse "(XDG_CONFIG_HOME unset)",
        "checked at runtime by the Lua runtime",
        env.get("XDG_DATA_HOME") orelse "(XDG_DATA_HOME unset)",
        if (env.get("OPENAI_API_KEY") != null) "set" else "unset",
        if (env.get("ANTHROPIC_API_KEY") != null) "set" else "unset",
        "checked via exec at tool time",
        "checked via exec at tool time",
    });
    try w.interface.flush();
}

fn printMock(init: std.process.Init, prompt: []const u8, json: bool) !void {
    var buf: [32768]u8 = undefined;
    var esc: [8192]u8 = undefined;
    var w = stdoutWriter(init, &buf);
    if (json) {
        // Keep JSON one-object-per-line and ANSI-free.
        try w.interface.writeAll("{\"type\":\"start\",\"provider\":\"mock/fixture\",\"model\":\"mock/fixture\"}\n");
        try w.interface.writeAll("{\"type\":\"text\",\"text\":\"Deterministic fixture response. No model was contacted.\\n\"}\n");
        try w.interface.print("{{\"type\":\"text\",\"text\":\"prompt: {s}\\n\"}}\n", .{try jsonEscape(&esc, prompt)});
        try w.interface.writeAll("{\"type\":\"done\",\"usage\":{\"reported\":false}}\n");
    } else {
        try w.interface.writeAll("[mock/fixture — deterministic offline output; no model was contacted]\n\n");
        try w.interface.writeAll("Deterministic fixture response.\n");
        try w.interface.print("prompt: {s}\n", .{prompt});
    }
    try w.interface.flush();
}

fn jsonEscape(buf: []u8, s: []const u8) ![]const u8 {
    var n: usize = 0;
    for (s) |c| {
        const extra: usize = switch (c) {
            '"', '\\', '\n', '\r', '\t' => 2,
            else => if (c < 0x20) 6 else 1,
        };
        if (n + extra >= buf.len) break;
        switch (c) {
            '"' => {
                buf[n] = '\\';
                buf[n + 1] = '"';
                n += 2;
            },
            '\\' => {
                buf[n] = '\\';
                buf[n + 1] = '\\';
                n += 2;
            },
            '\n' => {
                buf[n] = '\\';
                buf[n + 1] = 'n';
                n += 2;
            },
            '\r' => {
                buf[n] = '\\';
                buf[n + 1] = 'r';
                n += 2;
            },
            '\t' => {
                buf[n] = '\\';
                buf[n + 1] = 't';
                n += 2;
            },
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    buf[n] = '\\';
                    buf[n + 1] = 'u';
                    buf[n + 2] = '0';
                    buf[n + 3] = '0';
                    buf[n + 4] = hex[c >> 4];
                    buf[n + 5] = hex[c & 0xF];
                    n += 6;
                } else {
                    buf[n] = c;
                    n += 1;
                }
            },
        }
    }
    return buf[0..n];
}

pub fn main(process_init: std.process.Init) !u8 {
    var cli = try cli_mod.parse(process_init);
    defer cli.deinit(process_init.gpa);
    if (cli.errors.items.len > 0) {
        var buf: [8192]u8 = undefined;
        var w = stdoutWriter(process_init, &buf);
        for (cli.errors.items) |e| {
            try w.interface.print("bloob: unknown or invalid option: {s}\n", .{e});
        }
        try w.interface.writeAll("Try 'bloob --help'.\n");
        try w.interface.flush();
        return 2;
    }
    if (cli.help) {
        try printHelp(process_init);
        return 0;
    }
    if (cli.version) {
        try printVersion(process_init);
        return 0;
    }
    if (cli.list_models) {
        try listModels(process_init);
        return 0;
    }
    if (cli.list_sessions) {
        try listSessions(process_init);
        return 0;
    }
    if (cli.doctor) {
        try doctor(process_init);
        return 0;
    }
    if (cli.print) |prompt| {
        const model = cli.model orelse "mock/fixture";
        headless.run(process_init.io, process_init.gpa, .{
            .model = model,
            .prompt = prompt,
            .cwd = cli.cwd orelse (env.get("PWD") orelse "."),
            .json = cli.json,
        }) catch |err| {
            if (err != error.ProviderConfiguration and err != error.ProviderError) {
                var buf: [4096]u8 = undefined;
                var w = stdoutWriter(process_init, &buf);
                try w.interface.print("bloob: {s}\n",  .{@errorName(err)});
                try w.interface.flush();
            }
            return 1;
        };
        return 0;
    }
    // Interactive TUI.
    var terminal = term.Terminal.init() catch |err| {
        var buf: [4096]u8 = undefined;
        var w = stdoutWriter(process_init, &buf);
        try w.interface.print("bloob: cannot start interactive TUI: {s}. Use --print for headless mode.\n", .{@errorName(err)});
        try w.interface.flush();
        return 1;
    };
    defer terminal.deinit();
    var app = try app_mod.App.init(process_init.gpa, process_init.io, &terminal, .{
        .model = cli.model,
        .cwd = cli.cwd orelse (env.get("PWD") orelse "."),
    });
    defer app.deinit();
    app.initLua(cli.config, cli.no_config);
    app.initSessions(cli.session, cli.resume_session);
    app.run() catch |err| {
        terminal.deinit();
        var buf: [4096]u8 = undefined;
        var w = stdoutWriter(process_init, &buf);
        try w.interface.print("bloob: fatal error: {s}\n", .{@errorName(err)});
        try w.interface.flush();
        return 1;
    };
    terminal.deinit();
    return 0;
}

fn listSessions(init: std.process.Init) !void {
    const dir = sessions_store.defaultDataDir(init.gpa, init.environ_map) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = stdoutWriter(init, &buf);
        try w.interface.print("bloob: session storage unavailable: {s}\n", .{@errorName(err)});
        try w.interface.flush();
        return;
    };
    defer init.gpa.free(dir);
    var store = sessions_store.Store.init(init.gpa, init.io, dir) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = stdoutWriter(init, &buf);
        try w.interface.print("bloob: session storage unavailable: {s}\n", .{@errorName(err)});
        try w.interface.flush();
        return;
    };
    defer store.deinit();
    const infos = store.list() catch |err| {
        var buf: [4096]u8 = undefined;
        var w = stdoutWriter(init, &buf);
        try w.interface.print("bloob: cannot list sessions: {s}\n", .{@errorName(err)});
        try w.interface.flush();
        return;
    };
    defer sessions_store.freeInfoList(init.gpa, infos);
    var buf: [8192]u8 = undefined;
    var w = stdoutWriter(init, &buf);
    if (infos.len == 0) {
        try w.interface.writeAll("No saved sessions.\n");
    } else {
        try w.interface.writeAll("ID                              UPDATED(ms)      MESSAGES  MODEL                     CWD\n");
        for (infos) |info| {
            try w.interface.print("{s:<31} {d:<15} {d:<9} {s:<24} {s}\n", .{
                info.id,
                @as(u64, @intCast(info.updated_ms)),
                info.message_count,
                info.model,
                info.cwd,
            });
        }
    }
    try w.interface.flush();
}
