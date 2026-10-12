# Idle language server

This is the Zig 0.17 stdlib-only language server package. It depends on the
public `idl` module through the sibling `../idl-lib` package. The server owns
protocol and session state; `idl-lib` remains an independent syntax parser. It
reads and writes Language Server Protocol messages over standard input and
output; logs go to standard error. The server negotiates UTF-8 positions and
reparses the full current text after each accepted open or change notification.

Build the executable from this directory:

```text
zig build
```

The executable is written to `zig-out/bin/idl-lsp.exe` on Windows and
`zig-out/bin/idl-lsp` on other platforms. The VS Code extension's
`idle.serverPath` setting must contain that executable's absolute path.

Run the package checks from this directory:

```text
zig fmt --check build.zig build.zig.zon src tests
zig build
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
```

The server implements document synchronization, Idle syntax diagnostics, and
the lifecycle needed by the extension. It does not evaluate configuration,
perform schema validation, load external files, or implement completion,
hover, or formatting. The parser and language behavior are defined by the
shared core specification and implementation in `../idl-lib`.

The TypeScript extension package has a real subprocess integration suite for
the built server. From `../idl-vscode`, run `pnpm install` and then
`pnpm run test:native`. The suite uses this package's sibling build by default;
set `IDLE_SERVER_PATH` to an absolute executable path to override it.
