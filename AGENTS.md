# AGENTS.md — working on bloob

## Stack constraints

- Zig 0.17.1 from `nix develop` (the pinned flake).
- LuaJIT 2.1 installed by Nix, consumed through generated C bindings from
  `src/c/lua.h` with `std.Build.addTranslateC`. Zig 0.17 removed `@cImport`;
  do not add ziglua/mlua or another binding layer.
- Terminal backend is owned by bloob (`src/term.zig`, `src/c/sys.h`).
- One Lua state, owned by the UI thread. Never call into Lua from a worker.

## Build and test

```sh
nix develop -c zig build
nix develop -c zig build test
nix develop -c zig build smoke
nix develop -c tests/pty_smoke.sh
nix develop -c luajit examples/verify.lua
./zig-out/bin/bloob --self-test
```

The PTY harness requires util-linux `script` (Linux primary). Keep it
credential-free: use `mock/fixture` or a local SSE server.

## Ownership and safety rules

- The Zig permission/workspace code is authoritative. Lua hooks may tighten a
  decision, never grant one.
- User config/plugins are trusted. Project-local config/plugins are never
  auto-executed. Keep `--safe-mode` and `--no-config` behavior.
- Provider/tool text is untrusted: sanitize at the frame/render border and treat
  tool output as data.
- Preserve terminal state on every controlled exit; add `errdefer`/defer for new
  raw-mode or alternate-screen resources.
- Bound new input/output paths (bytes, entries, iterations, recursion, SSE
  lines). Avoid unbounded `lua_next`/recursion or blocking the UI thread.
- Callbacks held across frames use registry refs with explicit release.

## Layout

- `src/runtime/lua/bloob/` is the embedded Lua source of truth. There is no
  duplicate runtime/lua tree.
- `src/lua/runtime.zig` converts declarative Lua nodes to `src/ui/node.zig`
  nodes; keep the public Lua API backward-compatible or update docs/examples.
- Session format is documented in `docs/sessions.md`; schema changes need a
  migration/version bump.
- Record meaningful decisions in `docs/architecture/decisions.md` and update
  `IMPLEMENTATION_STATUS.md` after tested milestones.

## Style

- Run `zig fmt` on changed Zig files.
- Prefer flat, boring safety code; structured errors over panics.
- No fake success paths, placeholder model output, or inert advertised flags.
