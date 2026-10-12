# Idle language support for VS Code

This extension associates `.idl` files with Idle and provides basic syntax
highlighting plus syntax diagnostics from the native `idl-lsp` server. The
server parses each accepted document snapshot with the shared Zig `idl` core.
The extension translates VS Code's UTF-16 edit and diagnostic positions to the
server's negotiated UTF-8 positions.

The editor client sends incremental document changes, while the server reparses
the full current text after each accepted update. Diagnostics cover syntax only;
the extension does not evaluate configuration, validate schemas, load files,
provide completion or hover, or format documents. The TextMate grammar is a
lightweight lexical highlighter. It cannot always distinguish contextual
operators such as `and` and `or`, or string markers from operators, without
parser context; the native server remains authoritative for syntax.

The extension is unsupported in untrusted workspaces. Its server path is an
absolute executable configured with `idle.serverPath`.

Production TypeScript lives under `src/`. Node unit tests and their helpers are
under `tests/`, organized by client, editor, transport, and syntax layer. The
native subprocess test is under `tests/integration/`; the installed VS Code
Extension Host runner and suite are under `e2e/`. The build preserves these
boundaries under `out/src/`, `out/tests/`, and `out/e2e/`.

## Build and use

Build the server and then install and compile the extension's development
dependencies:

```text
cd dev/idl-lsp
zig build
cd ../idl-vscode
pnpm install
pnpm run build
```

The `idle.serverPath` setting must be the absolute path of
`dev/idl-lsp/zig-out/bin/idl-lsp.exe` on Windows, or
`dev/idl-lsp/zig-out/bin/idl-lsp` on Linux and macOS. For local development,
open the repository in VS Code and press F5. In the new Extension Development
Host window, set `idle.serverPath` in the host's user settings, then open an
`.idl` fixture. The repository's launch configuration builds the native server
and extension and opens the repository in the host.

Use **Idle: Restart Language Server** from the Command Palette to restart the
server. Open Idle documents are replayed from their current editor snapshots.

## Tests

```text
pnpm test
pnpm run typecheck
pnpm run test:native
pnpm run test:extension
```

`pnpm test` runs the fast client, transport, coordinate conversion, and grammar
tests. The grammar test tokenizes the shared
`dev/idl-lib/tests/fixtures/kitchen-sink.idl` fixture. `test:native` launches
the built server as a subprocess and checks negotiation, parsing, edits,
close/reopen, and restart replay. Set `IDLE_SERVER_PATH` to an absolute
executable path to override the default sibling build output.

`test:extension` launches the installed VS Code Extension Host, by default
`C:\Program Files\Microsoft VS Code\Code.exe`. Set
`VSCODE_EXECUTABLE_PATH` to use another installed executable and
`IDLE_SERVER_PATH` to select a different server. The harness creates a unique
workspace and user-data/extensions directories under ignored `.test-workspace`
and `.test-data` package directories, then removes only those per-run
directories. It does not use the normal VS Code profile.
