const std = @import("std");

fn pkgFlags(b: *std.Build, pkg: []const u8, mode: []const u8) []const u8 {
    return b.run(&.{ "pkg-config", mode, pkg });
}

fn addFlagPaths(
    b: *std.Build,
    mod: *std.Build.Module,
    flags: []const u8,
    comptime flag: []const u8,
    comptime method: enum { include, lib },
) void {
    _ = b;
    var it = std.mem.tokenizeAny(u8, std.mem.trim(u8, flags, " \n\t\r"), " \n\t\r");
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, flag)) {
            const dir = arg[flag.len..];
            if (dir.len == 0) continue;
            switch (method) {
                .include => mod.addIncludePath(.{ .cwd_relative = dir }),
                .lib => mod.addLibraryPath(.{ .cwd_relative = dir }),
            }
        }
    }
}

fn configureLuaLink(b: *std.Build, mod: *std.Build.Module) void {
    const libs = pkgFlags(b, "luajit", "--libs-only-L");
    addFlagPaths(b, mod, libs, "-L", .lib);
    // The pkg-config name is luajit; the actual linker name is luajit-5.1.
    mod.linkSystemLibrary("luajit-5.1", .{ .use_pkg_config = .no });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cflags = pkgFlags(b, "luajit", "--cflags-only-I");

    const luajit_headers = b.addTranslateC(.{
        .root_source_file = b.path("src/c/lua.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    var inc_it = std.mem.tokenizeAny(u8, std.mem.trim(u8, cflags, " \n\t\r"), " \n\t\r");
    while (inc_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-I") and arg.len > 2) {
            luajit_headers.addIncludePath(.{ .cwd_relative = arg[2..] });
        }
    }
    const luajit = luajit_headers.createModule();

    const system_headers = b.addTranslateC(.{
        .root_source_file = b.path("src/c/sys.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const csys = system_headers.createModule();

    const imports = [_]std.Build.Module.Import{
        .{ .name = "luajit", .module = luajit },
        .{ .name = "csys", .module = csys },
    };

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &imports,
    });
    configureLuaLink(b, app_mod);
    app_mod.addIncludePath(.{ .cwd_relative = "." });

    const exe = b.addExecutable(.{
        .name = "bloob",
        .root_module = app_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run bloob");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &imports,
    });
    configureLuaLink(b, test_mod);
    test_mod.addIncludePath(.{ .cwd_relative = "." });

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_tests.step);

    const smoke_cmd = b.addRunArtifact(exe);
    smoke_cmd.step.dependOn(b.getInstallStep());
    smoke_cmd.addArgs(&.{ "--no-config", "--print", "--model", "mock/fixture", "hello bloob" });
    const smoke_step = b.step("smoke", "Run noninteractive fixture smoke test");
    smoke_step.dependOn(&smoke_cmd.step);

    const doc_test_cmd = b.addRunArtifact(exe);
    doc_test_cmd.step.dependOn(b.getInstallStep());
    doc_test_cmd.addArgs(&.{ "--no-config", "--print", "--model", "mock/fixture", "--json", "hello bloob" });
    const doc_test_step = b.step("smoke-json", "Run noninteractive JSON smoke test");
    doc_test_step.dependOn(&doc_test_cmd.step);

    const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src") } });
    const fmt_step = b.step("fmt", "Format Zig sources");
    fmt_step.dependOn(&fmt.step);
}
