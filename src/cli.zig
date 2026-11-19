const std = @import("std");

pub const Cli = struct {
    args: std.ArrayList([]const u8) = .empty,
    cwd: ?[]const u8 = null,
    config: ?[]const u8 = null,
    no_config: bool = false,
    safe_mode: bool = false,
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    resume_session: bool = false,
    session: ?[]const u8 = null,
    delete_session: ?[]const u8 = null,
    print: ?[]const u8 = null,
    print_storage: std.ArrayList(u8) = .empty,
    json: bool = false,
    list_models: bool = false,
    list_sessions: bool = false,
    doctor: bool = false,
    version: bool = false,
    help: bool = false,
    self_test: bool = false,
    errors: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Cli, gpa: std.mem.Allocator) void {
        self.args.deinit(gpa);
        self.print_storage.deinit(gpa);
        self.errors.deinit(gpa);
    }
};

fn valueAt(args: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

pub fn parse(init: std.process.Init) !Cli {
    var cli = Cli{};
    var raw = std.ArrayList([]const u8).empty;
    defer raw.deinit(init.gpa);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // argv[0]
    while (it.next()) |arg_z| {
        try raw.append(init.gpa, std.mem.sliceTo(arg_z, 0));
    }
    const args = raw.items;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--cwd")) {
            if (valueAt(args, &i)) |v| cli.cwd = v else try cli.errors.append(init.gpa, "--cwd requires a path");
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--cwd=")) {
            cli.cwd = arg["--cwd=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            if (valueAt(args, &i)) |v| cli.config = v else try cli.errors.append(init.gpa, "--config requires a path");
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-config")) {
            cli.no_config = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--safe-mode")) {
            cli.safe_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--model")) {
            if (valueAt(args, &i)) |v| cli.model = v else try cli.errors.append(init.gpa, "--model requires provider/model");
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--model=")) {
            cli.model = arg["--model=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--provider")) {
            cli.provider = valueAt(args, &i);
            continue;
        }
        if (std.mem.eql(u8, arg, "--resume")) {
            cli.resume_session = true;
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                cli.session = valueAt(args, &i);
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--session")) {
            cli.session = valueAt(args, &i);
            cli.resume_session = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--delete-session")) {
            cli.delete_session = valueAt(args, &i);
            continue;
        }
        if (std.mem.eql(u8, arg, "--print")) {
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                cli.print = valueAt(args, &i);
            } else {
                cli.print = "";
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--print=")) {
            cli.print = arg["--print=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            cli.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--list-models")) {
            cli.list_models = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--list-sessions")) {
            cli.list_sessions = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--doctor")) {
            cli.doctor = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            cli.version = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            cli.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--self-test")) {
            cli.self_test = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            try cli.errors.append(init.gpa, arg);
            continue;
        }
        try cli.args.append(init.gpa, arg);
    }
    if (cli.print) |p| {
        if (p.len == 0 and cli.args.items.len > 0) {
            for (cli.args.items, 0..) |part, idx| {
                if (idx > 0) try cli.print_storage.append(init.gpa, ' ');
                try cli.print_storage.appendSlice(init.gpa, part);
            }
            cli.print = cli.print_storage.items;
        }
    }
    return cli;
}

pub const help_text =
    \\bloob — a Lua-programmable terminal coding agent
    \\
    \\Usage: bloob [options] [prompt]
    \\
    \\Options:
    \\  --cwd PATH           Working directory (default: current directory)
    \\  --config PATH        Load a specific init.lua
    \\  --no-config          Do not load user or project Lua configuration
    \\  --safe-mode          Disable non-bundled plugins
    \\  --model P/M          Select provider/model (e.g. mock/fixture)
    \\  --resume [ID]        Resume a session (latest when ID omitted)
    \\  --session ID         Resume a specific session
    \\  --print [PROMPT]     Headless mode: print assistant response
    \\  --json               With --print, emit JSON events
    \\  --list-models        List configured providers and models
    \\  --list-sessions      List saved sessions
    \\  --delete-session ID  Delete a saved session
    \\  --doctor             Diagnose terminal, config and providers
    \\  --self-test          Validate the noninteractive Lua UI layout
    \\  --version            Print version
    \\  --help               Print this help
    \\
    \\Keys (default):
    \\  Enter / Ctrl-S       Send message        Alt-Enter / Ctrl-J  Insert newline
    \\  Ctrl-C               Cancel / clear      Ctrl-C twice        Quit
    \\  Ctrl-Q               Quit                Ctrl-P              Command palette
    \\  Ctrl-R               Reload config       F1                  Help
    \\  PageUp/PageDown      Scroll chat         Tab / Shift-Tab     Cycle focus
    \\  Esc                  Normal mode         i                   Insert mode
    \\
;
