-- PTY harness fixture: deliberately fails at runtime.
--
-- bloob must discard this configuration, recreate a clean Lua runtime with the
-- bundled defaults, report the error in the status line, and remain usable.
error("HARNESS-BROKEN-CONFIG: deliberate test failure")
