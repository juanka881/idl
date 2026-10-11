# Idle WebAssembly Specification

Status: initial adapter design. Depends on the [Idle core specification](idl-spec.md).
Implementation location: `dev/idl-wasm`.

## 1. Target and relationship to the core

Build the core and a thin adapter for `wasm32-freestanding`. The module must work in
browsers and server-side JavaScript without WASI, filesystem access, environment
access, or network imports. Parsing is synchronous and uses explicit module-owned
memory. Hosts can place it in a worker if needed.

The adapter directly depends on `dev/idl-lib`. It shares parsing behavior with the
[native C ABI](idl-c-abi-spec.md), but does not require a native pointer layout or
C structure-return ABI to be meaningful to JavaScript. Neither adapter depends on
the other. No grammar, evaluator, or schema system is implemented in the wrapper.

## 2. Memory and lifecycle contract

Expose these operations through WebAssembly-compatible scalar parameters/results:

1. Allocate a host-fillable input buffer in linear memory.
2. Release that buffer through its matching module operation.
3. Parse a byte range and return a status plus an opaque document handle.
4. Inspect the source, syntax, decoded values, and diagnostics through the handle.
5. Destroy the document and invalidate all of its entity references and views.

The exact export signatures and descriptor layouts must be finalized during
adapter implementation. Use `u32` offsets/lengths and scalar status/tag values for
the wasm32 boundary. Do not export Zig slices or native structs by assumption.
Reserve document handle zero for no document; validate handles and ranges before
access. Handle reuse must not make stale references silently valid for a later
document: use generation-aware handles or an equivalent checked table.

A normal host flow is:

```text
encode source to UTF-8 bytes
allocate module input buffer
refresh the host's linear-memory view
copy bytes into that buffer
parse(pointer, byte_length)
release input buffer in all success/failure paths
inspect document if parse returned one
copy any results needed after destruction
destroy document
```

Parsing copies input into the document, matching the Zig ownership contract.
Release input immediately after parse returns. Malformed input still creates a
document with diagnostics; allocation/size/depth failures return no document.
Clean up partial allocations on all failure paths.

Memory growth can replace/detach JavaScript views. A host must refresh its
`Uint8Array`/`DataView` after any call that may allocate or grow memory and before
using returned ranges. Offsets to existing document storage remain valid until
that document is destroyed; stale JavaScript views are a separate concern.

Decoded text is UTF-8. Raw source may contain invalid UTF-8 and must remain
accessible as bytes without lossy decoding. Accept explicit byte buffers as well
as a host convenience path from JavaScript strings. Character-to-byte conversion
in that convenience path belongs to the host; all returned spans are bytes.

## 3. Syntax access

Provide the same logical capabilities as the C adapter: ordered nodes, arguments,
properties, annotations, optional child bodies, expression kinds and operands,
lists, calls, literal components, tokens/trivia, and diagnostics.

Use checked document-local entity handles or indices. Every query distinguishes
missing/optional data from a present empty sequence and from an invalid request.
Return pointer/length descriptors for text and raw bytes. All borrowed results
expire when their document is destroyed.

Do not require serializing the entire document as JSON. In particular, numeric
radix, spellings, and unit suffixes must survive without JavaScript `Number` conversion.
The host may build its own objects or serialize selected data as a convenience.

Function calls and operator expressions are syntax only. A call-shaped value must
not invoke a JavaScript function as a side effect of parsing or traversal.

## 4. Build and acceptance checks

Keep build files, exports, and host integration checks under `dev/idl-wasm`.
The standalone build imports the Zig core package and exports memory plus its
lifecycle/query functions. A shipped JavaScript package is later packaging work;
a small host harness is sufficient to test the adapter.

- Instantiate without WASI or filesystem/network imports.
- Compare structures, decoded values, diagnostics, and spans with native fixtures.
- Test malformed UTF-8 through byte-buffer input rather than string conversion.
- Grow memory between host operations and verify refreshed views still access
  correct document bytes.
- Test empty input, invalid ranges/handles, stale handles, allocation failure,
  source-size/depth limits, and release on all error paths.
- Verify documents survive input-buffer release and expire only on destruction.
- Demonstrate calls/lists/operators are returned as structure without execution.
