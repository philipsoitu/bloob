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

There is one Lua state owned by the UI thread. Lua layout/component callbacks run only during rendering. Registry references (`luaL_ref`) hold callbacks. Callbacks are protected with `lua_pcall` and traceback handlers. Hot reload builds a candidate state and atomically swaps it only after successful config loading and layout validation.

**Current status:** the runtime, bundled modules, declarative UI conversion, custom widgets, keymaps, events, Lua tools and hot reload are implemented. There is still no async Lua API, plugin loader or storage layer.

## ADR-005: Security boundary is Zig

The permission engine, workspace path checks and approval decisions live in Zig. Lua hooks may tighten policy or request approval, never override an explicit Zig denial. Project-local Lua is never loaded implicitly in the current build. LuaJIT FFI is not treated as a sandbox; user configuration is trusted, and third-party/project plugin loading is not implemented.

**Current status:** native tools use the Zig policy and approval modal; `tool.before_execute` hooks can deny or escalate to ask. `--safe-mode` is parsed but not enforced, and Lua tool `permissions` metadata is not enforced yet. See `docs/security.md`.

## ADR-006: Providers via a streaming transport abstraction

The agent core defines normalized stream events. The offline `mock/fixture` provider is deterministic and always available. Real providers are implemented behind the same interface. The first real provider transport uses curl, launched with fixed argv (no shell), and parses its output as SSE; this can later be replaced by `std.http` without touching the agent interface.

**Current status:** interactive OpenAI, Anthropic and OpenAI-compatible streaming exist. Headless `--print` remains fixture-only and does not load the Lua runtime.

## ADR-007: Sessions are append-only JSONL with atomic sidecar metadata

Conversation history is stored in `<id>.jsonl` (header + one message per line)
plus `<id>.meta.json` for cheap listing. Files are 0600, directories 0700.
`load` truncates only an incomplete/malformed trailing line; corruption earlier
in the file is a hard error. Resuming never replays side-effecting tools.
The App appends new messages incrementally and tracks a persisted-count cursor
so streaming messages are only persisted after the stream is finalized.

## ADR-008: Trusted user plugins, no project auto-execution

Plugins load only from the user config directory
(`$XDG_CONFIG_HOME/bloob/plugins/<name>/plugin.lua` or the XDG fallback). They
share the trusted Lua state with `init.lua`; LuaJIT FFI means this is not a
sandbox. `--safe-mode` and `--no-config` disable plugin loading. Project-local
plugins/config never execute automatically. Manifests, capability negotiation,
teardown and untrusted isolation are future work.

## ADR-009: Provider secrets in a temporary curl config

The OpenAI-compatible/Anthropic transport spawns curl with a temporary 0600
config file containing the URL and authorization header; the API key is not in
argv/process listings. The file is removed on stream teardown. The body is sent
through stdin. Base URLs are validated to start with `http://` or `https://`,
and curl is restricted to the corresponding protocol. This is a pragmatic
transport choice behind the provider interface; it can be replaced with
`std.http` without changing the agent/Lua APIs.

## ADR-010: Interactive shell tools run asynchronously

The TUI special-cases the `shell` tool into `src/tools/shell_job.zig`: the child
runs with nonblocking pipes, is polled by the main loop, has a hard deadline and
output cap, and Ctrl-C kills/cancels it. Headless mode retains the simpler
synchronous capture path. Process-tree termination is currently best-effort:
the direct `/bin/sh` child is killed, not an OS process group.
