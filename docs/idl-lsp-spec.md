# Idle Language Server Specification

Status: initial integration design. Depends on the [Idle core specification](idl-spec.md).
Implementation location: `dev/idl-lsp`.

## 1. Purpose and dependency

The language server owns editor sessions and mutable document text, invokes the
core parser, and translates syntax/diagnostics into Language Server Protocol
messages. The core remains independent of the protocol, transport, and editor.

The initial target is LSP 3.17 position negotiation, document synchronization, and
syntax diagnostics. Schema-powered features can depend on
[schema validation](idl-schema-spec.md). Completion, hover, formatting, semantic
tokens, folding, symbols, and navigation are future capabilities; advertise only
features actually implemented.

## 2. UTF-8-only initialization

Inspect `capabilities.general.positionEncodings` in the client's `initialize`
request. It must explicitly include `utf-8`. On success, return
`capabilities.positionEncoding: "utf-8"` in the initialization result, even if the
client lists another encoding first.

If that capability is missing, empty, or omits `utf-8`, return an initialization
error explaining that Idle requires UTF-8 position support, with retry disabled.
Do not accept the session with silently mismatched positions. UTF-16 and UTF-32
conversion/fallback are deliberately unimplemented.

LSP defines UTF-16 as its mandatory/default position encoding. This initial server
therefore intentionally supports a restricted client set rather than claiming
universal LSP compatibility. See the official
[position definition](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#position)
and [server capabilities](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#serverCapabilities).

## 3. Positions and ranges

Use zero-based lines and UTF-8 byte columns. Core spans are absolute byte offsets;
LSP positions are relative to physical line starts. Count all physical newlines,
including those in comments/strings. Treat CRLF as one line break and exclude its
bytes from the preceding line's content length.

```text
absolute_offset = line_start[line] + byte_column
```

Clamp a column beyond its line's length to that line's content end, as prescribed
by LSP 3.17. Treat a line index outside the current line table as an invalid edit
range in this initial adapter. Never place a position between CR and LF. For a
valid negotiated UTF-8 edit,
positions must not split a multibyte scalar. Do not reinterpret byte columns as
Unicode scalar counts or JavaScript string indices.

Core source may be malformed UTF-8; normal editor text arrives through JSON
strings. For diagnostic boundaries inside a malformed sequence, map the start
outward to a preceding valid boundary and the end outward to the next boundary,
while preserving the original byte span in the core result. This must never cause
the adapter to crash or silently alter the owned source.

Example: in `x 'é😀'`, `é` begins at byte column 3, `😀` at 5, and the closing quote
at 9. A CRLF after the quote places the next line at absolute offset 12.

## 4. Document synchronization

The server keeps a versioned UTF-8 text snapshot per open URI. Initially:

- `didOpen`: retain the text/version, parse it, and publish diagnostics.
- `didChange`: apply changes in order to the current snapshot, then fully reparse.
- `didClose`: destroy parse/text state and publish an empty diagnostic list.

Advertise incremental text synchronization with open/close support. A full-content
replacement change is also accepted. Ranged changes use the negotiated byte-column
positions; ranges in a batch refer to the text produced by preceding changes in
that batch. Use the actual ranges rather than deprecated `rangeLength` fields.

Build a proposed updated snapshot before replacing the active state. If a range
is reversed, splits a scalar, or otherwise cannot be applied after protocol
clamping, reject that update without partial mutation. Since `didChange` is a
notification, log/show an actionable synchronization error rather than returning
a nonexistent request response. Mark the document unsynchronized, clear stale
diagnostics, and require a full-content update or close/reopen to resynchronize.

Ignore stale/out-of-order versions rather than overwriting newer state. Associate
parse results and published diagnostics with their document version; never publish
an older result over a newer snapshot. Initial synchronous parsing is sufficient.

A successful text update with malformed Idle still yields a document and source
diagnostics. A fatal core resource failure leaves the current text/version known,
but no current syntax tree; discard old diagnostics and report the resource error
without pretending an old tree describes the new text. Recovery on a later edit
must remain possible.

## 5. Diagnostics and future consumers

Translate core diagnostic byte spans into negotiated UTF-8 ranges. Preserve stable
codes, severity, readable messages, and related locations. Mark their source as
`idl`. Zero-width missing-token spans remain zero-width ranges at the insertion
position, subject to valid position mapping.

Syntax diagnostics do not execute functions or interpret units. Optional schema
diagnostics are a separate source and use the same snapshot/version. Never invent
references or function meaning merely from a dotted name or call expression.

Future formatting must use lossless syntax rather than rewriting from evaluated
values. Incremental text synchronization does not imply incremental parsing; the
core continues to reparse complete snapshots.

## 6. Acceptance checks

- Negotiate UTF-8 when offered; reject missing, empty, UTF-16-only, and UTF-32-only
  capabilities. Always return the selected encoding explicitly on success.
- Map ASCII, accented characters, supplementary scalars, CRLF, CR, LF, EOF,
  empty lines, and zero-width spans correctly.
- Apply sequential edit batches, full replacements, and edits inside multiline
  strings/comments using byte columns.
- Handle protocol clamping, invalid ranges, split scalars, stale versions,
  unsynchronized state, and close/reopen without partial or stale results.
- Publish parser errors from recoverable documents; recover after fatal resource
  failures on subsequent edits; clear diagnostics on close.
- Do not advertise schema, formatting, or navigation features before implementing
  their supporting layers.
