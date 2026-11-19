# bloob implementation status

_Last updated: 2026-11-18 (initial vertical slice)._

## Completed and verified

- **M0 bootstrap**
  - Zig 0.17.1 pinned through the existing flake (no lockfile changes).
  - `build.zig` + `build.zig.zon`; executable, unit tests, noninteractive smoke, JSON smoke and fmt steps.
  - LuaJIT headers consumed with `std.Build.addTranslateC` (see `docs/architecture/decisions.md`; `@cImport` no longer exists in Zig 0.17.1).
  - `zig build`, `zig build test`, `zig build smoke` succeed.
- **Terminal backend**
  - Raw mode, alternate screen, cursor hide/show, bracketed paste, SGR mouse, focus events, resize detection, SIGINT/SIGTERM/SIGHUP/SIGQUIT flags, terminal restoration on controlled exit.
  - Stateful input parser: UTF-8, control keys, arrows/Home/End/Delete/PgUp/PgDn/F1–F12, Alt chords, bracketed paste, mouse wheel/click, incomplete escape handling.
- **UI core**
  - Cell grid with UTF-8 decoding, combining/wide character handling, ANSI-safe sanitization, truecolor/256/16/mono styling, borders, full-frame renderer.
  - Deterministic flex layout (`row`, `column`, `panel`, text measurement, fixed/percent/flex sizes, min/max, padding, gap).
  - Semantic theme palettes: default/dark, light, monochrome, catppuccin.
- **Default application**
  - TUI launches and restores the terminal; chat pane, multiline editor with undo/redo/history, status line, sidebar, help overlay, command palette, slash commands.
  - Deterministic mock streaming with cancellation (Ctrl-C), mouse wheel scrolling, PageUp/PageDown, focus cycling.
  - Headless `--print` and `--json` for the fixture provider, `--doctor`, `--list-models`, `--version`, `--help`.
  - PTY check performed with `script`: typed message streamed fixture output, Ctrl-S submit, Ctrl-Q exits with restoration, exit 0.

## In progress

- LuaJIT runtime integration (`src/lua/`): state lifecycle, protected calls, typed marshaling, callbacks, config loading, modules.
- Declarative Lua UI conversion and custom widgets. The native layout currently used is the fallback; it is not yet driven by Lua.

## Not yet implemented

- Real provider streaming (OpenAI/Anthropic) and normalized agent loop.
- Workspace tools + Zig permission engine + approval modal.
- Session persistence/resume and JSONL store.
- Lua keymaps/events/tools/commands/themes/plugins; hot reload.
- Markdown fidelity, diff viewer, command palette improvements (rich prompt editing, sessions UI).
- Golden/per-frame snapshot tests, PTY automated tests, fuzz tests.
- MCP/LSP/Tree-sitter/subagents/strategies (P2).

## Build/test evidence

```text
nix develop -c zig build
nix develop -c zig build test
nix develop -c zig build smoke
nix develop -c zig build smoke-json
```

At this checkpoint all four complete successfully. `zig build test` runs unit tests for text width/sanitization, colors/themes, frames, input parsing, editor basics, layout, chat wrapping and conversation ownership.

## Known issues / limitations

- Rendering is full-frame on dirty state; no dirty-region diff yet.
- Help text says Lua reload is next; until the runtime lands, Ctrl-R is inert and safely reports status.
- `--json` currently emits fixture events only; real provider event schema is not yet implemented.
- `--self-test` is parsed but not yet wired.
- The default UI's chat content is sanitized and truncated, but rich selectable content is not implemented.
- No session persistence yet.
- `App` is still large; it will be split as Lua UI and agent subsystems land.

## Next exact task

1. Implement `src/lua/runtime.zig`: Lua state lifecycle, protected `luaL_loadfile`/`pcall` with traceback, typed helpers, registry refs, and tests proving Zig↔Lua calls.
2. Register `bloob`, `bloob.ui`, `bloob.keymap`, `bloob.events`, `bloob.command` modules from bundled Lua (`runtime/lua/bloob/*.lua`) and C functions.
3. Convert the Lua declarative layout tree into `ui.Node` (arena-owned strings), render via the existing layout/renderer, and make the default UI itself come from bundled Lua.
4. Add config discovery (`--no-config`, XDG) and atomic hot reload with rollback.
