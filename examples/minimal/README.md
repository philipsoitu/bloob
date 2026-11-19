# minimal

The smallest useful `init.lua`: select a built-in theme and the offline fixture
model.

```sh
bloob --config examples/minimal/init.lua
```

`bloob.setup` currently applies `theme`, `model` and `leader`. The broader
configuration table from the design notes (`editor`, `permissions`, `ui`, ...)
is not implemented yet; those keys are ignored rather than rejected.

The default layout is still installed by bloob's bundled defaults because this
example does not call `ui.set_layout`.

See [../../docs/getting-started.md](../../docs/getting-started.md) and
[../../docs/configuration.md](../../docs/configuration.md).
