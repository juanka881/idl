# Idle core

`dev/idl-lib` is the standalone Zig 0.17 package for parsing Idle source. It
exports the Zig module `idl` and has no external dependencies. It parses syntax
into immutable, recoverable nodes and expressions; it does not evaluate values
or load schemas, files, or network resources.

Declare the local package in the consumer's `build.zig.zon`:

```zig
    .dependencies = .{
        .idl_lib = .{
            .path = "../idl-lib",
        },
    },
```

Then import the exported module from the consumer's build script:

```zig
const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const idl_module = b.dependency("idl_lib", .{
        .target = target,
        .optimize = optimize,
    }).module("idl");

    const executable = b.addExecutable(.{
        .name = "config-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "idl",
                    .module = idl_module,
                },
            },
        }),
    });
    b.installArtifact(executable);
}
```

Parse a full source snapshot and inspect its syntax and diagnostics:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const debug = std.debug;
const idl = @import("idl");

pub fn parseConfig(allocator: Allocator, bytes: []const u8) !void {
    const document = try idl.parse(allocator, bytes);
    defer {
        document.destroy();
    }

    const source = document.source();
    for (document.nodes()) |node| {
        const name = try source.slice(node.name_span);
        debug.print("node: {s}\n", .{name});

        for (node.properties) |property| {
            const property_name = try source.slice(property.name_span);
            debug.print("property: {s}\n", .{property_name});
        }
    }

    for (document.diagnostics()) |diagnostic| {
        debug.print("{s}: {s}\n", .{ diagnostic.code, diagnostic.message });
    }

    if (document.hasErrors()) {
        return error.InvalidConfiguration;
    }
}
```

`parse` returns a `Document` for valid and malformed syntax. Its fatal error set
is `error{OutOfMemory, SourceTooLarge, NestingLimitExceeded}`. The parser limits
active bodies, expression containers, and prefix operators to 256 levels; an
excessive source returns `NestingLimitExceeded` without a partial document.

The document owns a copy of the input and all source, line-index, token, decoded
string, diagnostic, and syntax views. Those views remain valid until
`Document.destroy()` and must not be used afterwards. The allocator's backing
context must remain alive until the document is destroyed. Source spans,
positions, and columns use zero-based UTF-8 byte offsets; physical line lookup
recognizes LF, CRLF, and CR. Malformed UTF-8 is preserved in the source and
reported as diagnostics.

Destroy a document exactly once; do not copy it by value. This package provides
the native core API only. It does not include the separate C ABI or WebAssembly
adapters.

The [kitchen-sink fixture](tests/fixtures/kitchen-sink.idl) is a valid,
annotated tour of the supported syntax, including headers, annotations, bodies,
comments, strings, collections, calls, and operators. Its public-parser test
checks the resulting syntax tree and source coverage without evaluating values.

Run the package's unit, ownership, and public conformance tests from this
directory:

```text
zig fmt --check build.zig build.zig.zon src tests
zig build test
zig build test -Doptimize=ReleaseSafe
```
