# hello plugin

Copy this directory to `$XDG_CONFIG_HOME/bloob/plugins/hello/` and start
`bloob`. Use `/hello.plugin` or press `Ctrl-H` in normal mode.

The plugin registers a widget, a command and a keymap. It is loaded only from
the trusted user plugin directory; project-local plugin directories are not
auto-executed. Use `bloob --safe-mode` to disable plugin loading.
