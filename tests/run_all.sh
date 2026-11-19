#!/usr/bin/env bash
# Build, run unit tests and run the noninteractive PTY smoke harness.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

printf '== nix develop -c zig build ==\n'
( cd "$ROOT" && nix develop -c zig build ) || exit 1

printf '\n== nix develop -c zig build test ==\n'
( cd "$ROOT" && nix develop -c zig build test ) || exit 1

printf '\n== tests/pty_smoke.sh ==\n'
BLOOB_PTY_SKIP_BUILD=1 "$ROOT/tests/pty_smoke.sh"
