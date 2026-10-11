# Implement the Idle v1 Zig Core

Status: complete. All five stages are implemented in `dev/idl-lib` and reviewed.
The core passes the package checks, external consumer run, and wasm32 compile check.

## Objective and sources of truth

Implement an independently reusable Zig package in `dev/idl-lib`, exporting the
module `idl`, from the [core specification](../../doc/idl-spec.md). Use Zig 0.17.0 from
the existing root `mise.toml`. Keep the specification authoritative if an example
or implementation detail in this plan appears to disagree with it; resolve any
real contradiction in the specification explicitly before changing behavior.

The [C ABI](../../doc/idl-c-abi-spec.md), [WebAssembly](../../doc/idl-wasm-spec.md),
[LSP](../../doc/idl-lsp-spec.md), and [schema](../../doc/idl-schema-spec.md) documents are
consumer contracts. Do not implement those packages during this core task.

Success means a tested, allocator-aware parser producing immutable, lossless,
recoverable syntax, plus a small public Zig API. Do not implement evaluation,
filesystem loading, a CLI, schema validation, a formatter, code generation, or
incremental parsing as part of the core milestone.

## Locked language decisions

- Nodes have names, ordered arguments, ordered properties, annotations, and an
  optional child body. Arguments precede properties; bodies come last. Duplicate
  properties are errors, while repeated child names are valid.
- Newline/semicolon ends a node; enclosing `}` and EOF can end the last child.
  A next-line `{` attaches across whitespace/comments, never across a semicolon or
  another significant token. A node cannot have two bodies.
- Backslash explicitly continues bare headers. Block comments can span lines and
  act entirely as whitespace. Indentation has no grammatical meaning.
- Braces contain nodes only. There are no object literals, tuples, or named tuples.
- Bare arguments/properties admit literals, symbols, lists, calls, groups, and
  prefix `!`. `sample 10 -2` is two numbers; `sample (10 - 2)` is one expression.
- Full operators work inside groups, lists, and function argument lists. Use
  `+ - * / %`, comparisons, `== !=`, lowercase `and or`, and prefix `+ - !`.
  No `&& ||`, power, bitwise, shift, assignment, or ternary expressions.
- Lists/calls require commas, permit a trailing comma, and allow newlines between
  components. `foo(1)` is a call; `foo (1)` is not. Calls have symbolic names and
  positional arguments. Dotted names remain whole symbols.
- Parentheses group one expression; empty groups and comma tuples are errors.
- Decimal spelling follows JSON's numeric grammar. **Also support `0x`/`0X`
  hexadecimal integers**, including signed header literals. Preserve spelling and
  radix without machine-number conversion. Hexadecimal prefixes are reserved and
  require a digit; consume hex digits before considering a unit suffix.
- Number-with-unit values use adjacent ASCII letters. Decimal exponent recognition
  requires digits. `1em` is `1` + `em`; `1e3ms` is `1e3` + `ms`; `1e` is `1` + `e`.
  `0x10B` is entirely hexadecimal; `0x10ms` is hex `0x10` + unit `ms`.
- Single-quoted strings can span lines. Ordinary strings preserve physical line
  endings/indentation. `|'...'` dedents; `>'...'` dedents and folds paragraphs.
  Process layout before decoding escapes; preserve raw source for every style.
- Bare words are broad Unicode words with explicit exclusions. Header names can
  contain hyphens; expression symbols cannot. Paths and URLs require quotes.
- All spans and physical line positions use UTF-8 byte offsets. Malformed source
  yields diagnostics and a tree; fatal allocation/resource failure yields no tree.

## Package and public API

Create this core-only layout:

```text
dev/idl-lib/
├── build.zig
├── build.zig.zon
├── README.md
├── src/
│   ├── root.zig
│   ├── text.zig
│   ├── diagnostics.zig
│   ├── syntax.zig
│   ├── literals.zig
│   ├── scanner.zig
│   └── parser.zig
└── tests/
    ├── conformance.zig
    ├── ownership.zig
    └── fixtures/
```

`build.zig` exports module `idl` and a `test` step running unit and integration
tests. `build.zig.zon` declares the package and minimum Zig version without external
dependencies. Use the installed compiler's current build APIs, not older Zig
examples. Re-export public types and functions from `src/root.zig`.

Implement these entry points, matching the core specification:

```text
parse(allocator: std.mem.Allocator, source: []const u8) ParseError!*Document
Document.destroy(self: *Document) void
Document.source(self: *const Document) SourceText
Document.nodes(self: *const Document) []const Node
Document.tokens(self: *const Document) []const Token
Document.diagnostics(self: *const Document) []const Diagnostic
Document.hasErrors(self: *const Document) bool
```

`ParseError` is `error{OutOfMemory, SourceTooLarge, NestingLimitExceeded}`. A source
with syntax errors still returns a document. Do not add an implicit strict/fail-fast
parse mode; callers can inspect `hasErrors()`.

The document is allocated at a stable address using the caller's allocator before
initializing its arena. It stores the backing allocator, owns the arena and copied
source, and is destroyed exactly once. The allocator context must outlive it.
Use `errdefer` so source-copy, parser, literal-decoding, and finalization failures
release all partial allocations. No global allocator or mutable parser state.

Use arena-owned immutable structs, pointers, and finalized slices for v1, avoiding
an index-based public API or incremental tree architecture. Internal scratch lists
may grow during construction; publish their slices only after finalization. Never
retain a pointer into a scratch list that can move on append.

## Syntax and storage model

- `TextSpan`: `start` and `len`, both `usize`, with an exclusive end. Guard all
  range construction and slicing against overflow and out-of-bounds access.
- `SourceText`: immutable source view and physical-line lookup support. Start the
  line index with byte zero; count LF, CRLF, and CR throughout the entire source.
- `Diagnostic`: stable code, severity, message, span, and optional related span.
  Allocate formatted messages in the document arena; keep code strings stable.
- `Node`: name span, full span, annotations, ordered expression arguments, ordered
  properties, and optional `Body`. `Body` retains delimiters and ordered children.
- `Annotation`: name/span and ordered arguments/properties, without a body.
- `Property`: name span, equals token, value expression, and full span.
- `Expression`: tagged payload for number, number-with-unit, string, boolean, null,
  symbol, list, call, grouping, unary, binary, missing, or invalid syntax. Recursive
  operands use arena-owned pointers; element sequences use immutable slices.
- Number payloads preserve numeric span and radix (`decimal` or `hexadecimal`);
  unit-bearing numbers additionally preserve a unit span. Header negative literals
  include their sign in the numeric span. In full expressions the sign is unary
  syntax instead of a signed literal payload.
- Strings retain raw token span, style, and optional decoded byte slice. Absence
  of decoded content means malformed syntax, not an empty decoded string.
- `Token` retains kind, span, leading trivia, and missing status. EOF owns final
  trivia. Keep real tokens in source order and preserve synthetic markers without
  claiming source bytes for them.

Retain delimiters/grouping in syntax even where consumers treat the enclosed value
transparently. Do not collapse repeated properties, evaluate operators, decode a
symbol into a reference, or resolve function names during parsing.

## Implementation stages

### 1. Build, source, ownership, and diagnostics

- [x] Scaffold only `dev/idl-lib` and establish the exported module/test target.
- [x] Implement spans, checked slices, copied source, physical line indexing, and
  document construction/destruction.
- [x] Validate UTF-8 while building source information. Preserve malformed bytes
  and emit located errors; make at least one-byte progress on invalid input.
  Avoid duplicate UTF-8 diagnostics from later scanning/decoding of the same bytes.
- [x] Establish stable diagnostic codes and fatal-error cleanup.
- [x] Test empty source, EOF slices, overflow-safe bounds, Unicode positions,
  line endings, source-copy independence, and allocator failure.

### 2. Contextual scanner and literal helpers

- [x] Implement byte cursor, punctuation/operator scanning, lookahead, and captured
  leading trivia. Token/trivia coverage must be complete and nonoverlapping.
- [x] Distinguish header-name and expression contexts. Before reading a header
  value, recognize a candidate name followed by single `=` on the same logical
  line. Lookahead must not allocate diagnostics or emit tokens until committed.
- [x] Implement horizontal/newline trivia, non-nesting comments, and continuation.
  Newlines inside comments/strings affect the line map but not header termination.
- [x] Scan decimal/hex spelling and unit boundaries without machine conversion.
  Keep signs separate lexically so the parser can recognize header negative
  literals or expression operators. Reject malformed candidate tails as a whole
  instead of creating adjacent values.
- [x] Scan ordinary quoted strings and preserve raw boundaries. Recognize `|`/`>`
  string style contextually at value starts; between operands `>` is an operator.
- [x] Implement escapes and marked-string layout in `literals.zig`. Validate escape
  locations against original source before transforming layout so diagnostics
  retain raw spans; decode valid escapes after dedentation/folding.
- [x] Test literal and trivia behavior independently of complete documents.

### 3. Delimited expressions

- [x] Implement a Pratt/precedence-climbing parser using the exact precedence
  table in the core specification. All binary levels are left-associative; prefix
  operators nest rightward. Do not add chained-comparison semantics.
- [x] Parse primary values, one-expression groups, comma-separated lists, and
  adjacent-name function calls. Preserve missing elements/closers for recovery.
- [x] Recognize `and`/`or` as operators only in infix position with word boundaries;
  allow them as symbols in operand position. Test `[and, or]` and `(a and or)`.
- [x] Enforce call adjacency, forbidden tuples/objects/computed calls, and comma
  requirements. Newlines are whitespace inside expression containers.
- [x] Count active containers and prefix operations toward the shared nesting
  limit of 256. Flat element lists and left-associative chains do not consume one
  nesting level per item. Avoid recursive traversal of arbitrarily long flat
  binary chains in test helpers and core inspection utilities.
- [x] Test exact AST shapes, precedence, grouping, spans, and contextual markers.

### 4. Nodes, properties, annotations, and bodies

- [x] Parse document nodes using individual header values, not unrestricted infix
  expressions. Permit signed numeric literals and prefix `!` in bare headers.
- [x] Require spacing between separate arguments; preserve argument/property order.
  Record duplicate properties with both occurrences and a related original span.
- [x] Parse node bodies and share nesting accounting with expressions.
- [x] Implement body attachment lookahead over newlines/comments, bounded by a
  semicolon or any other significant token. Preserve those newlines as trivia.
- [x] Implement annotations on logical lines and attachment over blank lines and
  comments. Diagnose orphans at EOF, closing braces, and semicolon barriers.
- [x] Reject missing separators between same-line siblings and entries after a
  body. Keep repeated children and absent/empty body distinctions intact.
- [x] Finalize document-owned public slices only after successful construction.

### 5. Recovery and conformance

- [x] Audit every parser loop for progress. Retain bad source as unknown tokens or
  skipped syntax; do not duplicate coverage if reclassifying tokens as trivia.
- [x] Insert missing nodes/tokens at zero-width source positions when recovery
  permits. Synchronize inside the correct delimiter nesting level.
- [x] Recover header errors at logical newlines, semicolons, closing braces, or EOF;
  expression errors at commas/compatible closers without stealing a parent's
  closer. Strings and block comments remain indivisible scanner tokens/trivia.
- [x] Build fixtures asserting semantic syntax shape, diagnostics/codes/spans,
  decoded strings, and complete original-source retention.
- [x] Exercise allocation failure at every allocation point using the installed
  Zig testing allocator/failure facilities. Verify cleanup on depth-limit errors.
- [x] Document usage, lifetime rules, and the test command in the package README.

## Required conformance matrix

Use actual byte fixtures where line endings or malformed UTF-8 matter. Avoid tests
that merely restate implementation internals; assert public behavior and spans.

| Area | Required cases |
| --- | --- |
| Source | empty input; EOF; accented/supplementary Unicode; invalid/truncated UTF-8; CRLF/CR/LF; bounds overflow |
| Headers | arguments before properties; duplicate keys; same/next-line bodies; semicolon barriers; repeated children; missing separators |
| Trivia | final comments/whitespace; multiline comments between entries; unterminated comments; continuation with comments; continuation at EOF |
| Annotations | multiple annotations; blank/comment gaps; multiline delimited values; orphan at EOF/brace/semicolon |
| Contexts | `sample 10 -2`; `sample (10 - 2)`; `sample !enabled`; rejected bare infix; `foo(1)` versus `foo (1)` |
| Operators | every tier; left-associative subtraction/comparison; nested unary; `and`/`or` word boundaries and operand-position symbols |
| Delimiters | nested lists/calls/groups; empty list/call; trailing comma; missing comma/element/closer; tuple/object/computed-call rejection |
| Decimals/units | `-0`, `1e1000`, `1e-3`, `1em`, `1e3ms`, `1e`, `30ms`; invalid `01`, `.5`, `1.`, `1.2.3`, `30ms2` |
| Hexadecimal | `0xFF`, `0Xff`, `-0xFF`, `(-0xFF)`, `0x10B`, `0x10ms`, large values; invalid `0x`, `0xms`, `0x1.2`, `0x1p2` |
| Strings | ordinary multiline preservation; LF/CRLF marked strings; exact dedent with tabs; blank lines; paragraph folding; more-indented lines |
| Escapes | escaped quote/backslash; `\u{1F600}`; invalid scalar/surrogate; unknown/truncated escapes; escaped versus physical newline |
| Marker/operator | `left>'right'` versus `left > >'right'`; marker/quote adjacency; invalid marker usage |
| Recovery | missing property value followed by sibling; multiple independent errors; mismatched nested closers; malformed calls; unterminated string |
| Lifetime | caller input overwritten after parse; borrowed views live through document lifetime; repeated destroy cycles; every allocation failure |
| Limits | accepted depth boundary; fatal excess depth with cleanup; long flat lists/operator chains without artificial depth rejection |

For all parse results, assert each real token/trivia span is in bounds, primary
coverage is ordered and nonoverlapping, concatenated covered bytes equal original
source, synthetic spans have zero length, and every diagnostic points into source.
Do not make invalid source passing these structural checks appear diagnostically
valid.

## Verification and delivery

From `dev/idl-lib`, the final implementation must pass:

```text
zig fmt --check build.zig build.zig.zon src tests
zig build test
zig build test -Doptimize=ReleaseSafe
```

Also compile a small temporary external Zig consumer importing the exported `idl`
module. Parse a node containing a unit, list, function call, and child body; inspect
the result through public types, then destroy the document. This confirms the
package can be reused without importing internal source files.

Check the public API on wasm32 at compile time as a portability check when the
build exposes the testable core module; do not create the WebAssembly adapter or
claim runtime WebAssembly integration from a compile-only check.

Finish with a report of implemented capabilities, tests actually executed, and
any remaining limitations. Do not mark this plan complete based only on successful
compilation of type examples or on a parser that accepts valid input but drops
malformed source. Leave companion implementations for their own tasks.

## Completion record

Implementation was completed by GPT-6 Luna at high reasoning effort and reviewed
stage by stage by GPT-6.1 Sol at high reasoning effort. The root agent resolved
specification interpretations and reviewed final verification. No unresolved
review blockers remain.

Final checks on the completed source:

- `zig fmt --check build.zig build.zig.zon src tests` passed.
- `zig build test` passed all 78 tests: 37 module, 35 public conformance, and
  6 ownership tests.
- `zig build test -Doptimize=ReleaseSafe` passed the same 78 tests.
- A temporary external package imported the exported `idl` module through
  `b.dependency`, parsed a unit, list, call, and child body, inspected public
  syntax, and destroyed the document successfully in ReleaseSafe.
- The consumer's exported core smoke function compiled for `wasm32-freestanding`
  in ReleaseSafe with a caller-supplied fixed-buffer allocator and trap panic
  handler. This was a compile-time portability check, not a WebAssembly adapter
  or runtime integration test.
- Independent review covered 18 public fixtures, exact expression shapes and
  string layouts, 500 malformed text documents, 600 arbitrary-byte documents,
  and single-byte mutations of a realistic configuration. Checks included
  source coverage, syntax/diagnostic bounds, decoded UTF-8, allocation failures,
  and nesting limits.

Package-local Zig caches were used because the default cache location was not
accessible in the execution environment. Temporary reviewer caches were removed.
The package README documents dependency setup, parsing, ownership, byte positions,
fatal errors, and verification commands.

Implementation conventions resolved during review:

- Node spans begin at the first attached annotation, or at the name when none
  exists. They end at the final header entry or body closer, excluding trailing
  trivia and statement terminators. Annotation spans exclude terminating newlines.
  Missing syntax uses zero-width insertion spans.
- The primary token stream contains real tokens and EOF. Missing delimiter tokens
  remain accessible through the syntax tree without overlapping source coverage.
- Incomplete decimal exponents remain available as units followed by operators:
  `1e-foo` is number `1` with unit `e`, minus symbol `foo` in an expression.
- `left>>'right'` parses like `left > >'right'`: a comparison with a folded string.
  Shift expressions remain invalid.

The C ABI, WebAssembly adapter, LSP, schema layer, and expression evaluation remain
outside this completed core milestone, as specified by the original scope.