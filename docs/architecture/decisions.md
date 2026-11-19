# Architecture decisions

## ADR-001: Zig 0.17.1 with `addTranslateC` for LuaJIT headers

**Status:** accepted, forced by the installed compiler.

Zig 0.17.1 **removed the `@cImport` builtin**. The plan and execution contract require direct C ABI interop with LuaJIT and forbid third-party Lua binding layers. We therefore use the installed compiler's supported equivalent:

- `src/c/lua.h` includes the official `lua.h`, `lauxlib.h`, `lualib.h`.
- `build.zig` runs `std.Build.addTranslateC` over that header, passing the include path discovered with `pkg-config --cflags-only-I luajit`.
- Zig code imports the generated module as `@import("luajit")` through `src/lua/c.zig`.
- Linking uses the pkg-config library path and `libluajit-5.1` directly.

No Ziglua/mlua/other binding abstraction is used. This is the only practical way to satisfy the C ABI requirement on 0.17.1. It is not the literal `@cImport` syntax because that syntax no longer exists.

## ADR-002: Own native ANSI terminal backend

The terminal backend is implemented in Zig using `std.posix` for termios/input/poll and a small translated libc header (`src/c/sys.h`) for `ioctl(TIOCGWINSZ)` and `getenv`. This keeps bloob's cell grid, layout, focus, styling and component API independent. libvaxis was not adopted because its Zig 0.17 compatibility is unverified and the project benefits from a small, owned backend.

## ADR-003: Cell-grid renderer with bounded per-frame arena

Every redraw builds a short-lived declarative node tree in an arena, solves layout deterministically, rasterizes into a `Frame` of Unicode cells, and writes a full ANSI frame. Redraws only occur when state is marked dirty. This is simple and avoids stale-pointer lifetimes at the Lua boundary. Dirty-region diffing remains an optimization milestone.

## ADR-004: Lua callbacks and state ownership

There is one Lua state owned by the UI thread. Lua layout/component callbacks run only during rendering. Registry references (`luaL_ref`) hold callbacks; until the Lua runtime milestone is integrated, no Lua state exists. Callbacks will be protected with `lua_pcall` and traceback handlers. Hot reload will build a candidate state and atomically swap it only after successful validation.

## ADR-005: Security boundary is Zig

The permission engine, workspace path checks and approval decisions live in Zig. Lua hooks may tighten policy or request approval, never override an explicit Zig denial. Project-local Lua is disabled by default. LuaJIT FFI is not treated as a sandbox; user configuration is trusted, third-party/project plugins require explicit trust.

## ADR-006: Providers via a streaming transport abstraction

The agent core will define normalized stream events. The offline `mock/fixture` provider is deterministic and always available. Real providers are implemented behind the same interface. If curl is used as a transport in the first real provider slice, it is launched with fixed argv (no shell) and its output is parsed as SSE; this tradeoff will be documented and can later be replaced by `std.http` without touching the agent interface.
