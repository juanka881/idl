# Idle C ABI Specification

Status: initial adapter design. Depends on the [Idle core specification](idl-spec.md).
Implementation location: `dev/idl-c-abi`. This document does not freeze a released
binary ABI or constitute an implemented header.

## 1. Purpose and dependency

Expose the Zig core to native languages through a C-compatible boundary. The
adapter depends on the standalone `idl` module from `dev/idl-lib`; the core never
depends on this adapter. Build native static and shared libraries with a public
`idl.h`. Individual language bindings are separate consumers.

Reuse the core parser. Do not fork its grammar, evaluate expressions, reinterpret
units, choose duplicate-property winners, or add domain validation. Lossless
syntax, error codes, byte spans, and decoded values must agree with the Zig API.

## 2. Document lifecycle

The initial lifecycle surface is illustrated by these C declarations. Implement
the final header and ABI-version policy during adapter implementation:

```c
#include <stddef.h>
#include <stdint.h>

typedef struct idl_document idl_document;

typedef enum idl_status {
    IDL_OK = 0,
    IDL_INVALID_ARGUMENT = 1,
    IDL_OUT_OF_MEMORY = 2,
    IDL_SOURCE_TOO_LARGE = 3,
    IDL_NESTING_LIMIT_EXCEEDED = 4
} idl_status;

typedef struct idl_bytes {
    const uint8_t *data;
    size_t len;
} idl_bytes;

typedef struct idl_span {
    size_t start;
    size_t len;
} idl_span;

idl_status idl_parse(const uint8_t *source, size_t len,
                     idl_document **out_document);
void idl_document_destroy(idl_document *document);
```

`out_document` must be non-null. Set it to null before parsing so every failure
leaves an unambiguous result. A null source pointer is allowed only with zero
length. Input is length-delimited, not NUL-terminated. Embedded NUL does not truncate
input; invalid source bytes are handled through core diagnostics.

Parsing copies source. Input only needs to remain valid for the duration of the
call. `IDL_OK` means that a document was created, including for malformed source;
inspect its diagnostics/has-errors accessor to determine validity. Fatal core
errors map to the corresponding status and return no document.

The adapter owns the allocator and releases memory through
`idl_document_destroy`. Foreign callers must not free library memory themselves.
Destroying null is a no-op; a non-null document is destroyed exactly once. Using
a destroyed document or an invalid native pointer is a caller contract violation.
Do not claim that the adapter can validate arbitrary host pointers.

No Zig error union, slice, allocator object, internal enum layout, exception, or
recoverable-source panic crosses the ABI. Supported fatal parse failures become
status values. Internal programming defects remain implementation defects rather
than being mislabeled as malformed user input.

## 3. Read-only access

Expose count/index or handle-based queries for these capabilities:

| Entity | Required information |
| --- | --- |
| Document | source bytes, top-level nodes, token/trivia stream, diagnostics, has-errors |
| Node/annotation | name, span, ordered arguments and properties; node annotations and optional body |
| Body | presence and ordered children, including explicitly empty bodies |
| Property | name, span, value expression, duplicate occurrences without collapsing |
| Expression | kind, span, raw spelling, children appropriate to its kind |
| Literal | string style/decoded availability, numeric radix/spelling, number/unit components, boolean/null/symbol kind |
| Call | symbolic name and ordered arguments |
| Unary/binary/group | operator/operand information and grouping syntax |
| Diagnostic | code, severity, message, span, optional related span |
| Token/trivia | kind, byte span, missing/skipped status and ordering |

Opaque entity references belong to one document and expire with it. Accessors
must distinguish an invalid index, an absent optional value, and a present empty
value. Do not expose mutable internal pointers or flatten properties into a map.

Strings and source excerpts use pointer-plus-length UTF-8 views; raw source views
may contain invalid UTF-8. Decoded malformed strings are absent, not silently
replaced with empty strings. No view promises a NUL terminator. Returned text and
syntax views remain valid until document destruction; querying must not invalidate
previous views. Hosts needing longer lifetimes copy the bytes.

All spans use `size_t` byte offsets/lengths on the native target. Public numeric tags
and status values need explicitly assigned values in the finalized header. Do not
reuse Zig enum ordinals implicitly. Getter result structures must use C-compatible
field types and documented layouts. Adapter implementation must define concrete
getter signatures before shipping; this initial design fixes capabilities and
lifetime rules rather than every symbol in that future header.

## 4. Build and compatibility

Keep the adapter in `dev/idl-c-abi` with its own Zig build/package files and C
consumer tests. Link the same core module used by Zig callers. Static and shared
builds must expose the same API. Do not require a .NET runtime or a Zig compiler
in a native application that consumes an already-built library.

Define an explicit ABI version before the first release. Changes to internal Zig
types must not force changes to foreign layouts. Custom host allocator callbacks,
generated language bindings, and distribution packaging are later work.

## 5. Acceptance checks

- Compile a C consumer against `idl.h` and link it to both static and shared builds.
- Compare document structure, raw bytes, strings, spans, and diagnostics with the
  Zig API on shared fixtures, including expression and recovery cases.
- Release/overwrite input after parse and verify document views remain intact.
- Test empty input, embedded NUL, malformed UTF-8, null arguments, bad indices,
  absent bodies/decoded values, and present empty values.
- Confirm syntax errors return documents while allocation/depth failures do not.
- Repeatedly parse, traverse, and destroy without leaks or freeing across allocators.
