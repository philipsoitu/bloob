//! The generated LuaJIT C bindings. Build creates this module with
//! std.Build.addTranslateC over src/c/lua.h (the installed LuaJIT 2.1 headers).
pub const c = @import("luajit");
