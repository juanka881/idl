# Idle Core Specification

Status: v1 design specification. Implementation target: Zig 0.17.0, pinned in
`mise.toml`. The language is **Idle**, abbreviated **idl**.

## 1. Purpose and boundaries

Idle is a small configuration and modeling language built around nodes. Its core
parses source into inspectable syntax, including expression structure, without
evaluating that structure. Applications can reuse it for service configuration,
service models, protocol definitions, and other domain languages.

The core provides source text, scanning, parsing, lossless syntax, decoded strings,
and lexical/structural diagnostics. Schemas constrain permitted structures and
values. Applications define references, functions, operators, units, coercions,
and evaluation. Parsing performs no filesystem/network access, environment
lookup, function execution, or schema loading.

Separate specifications build on this core:

- [C ABI](idl-c-abi-spec.md): native interoperability.
- [WebAssembly](idl-wasm-spec.md): a standalone WebAssembly adapter.
- [LSP](idl-lsp-spec.md): editor integration using UTF-8 positions.
- [Schema validation](idl-schema-spec.md): domain constraints and validation.

The core does not depend on these components. Formatting tools and code generators
are also consumers. Prefer correctness, explicit ownership, a hand-written parser,
and full-file reparsing before incremental parsing optimizations.

This document defines syntax and tree structure. API examples describe the initial
Zig interface; they are not implemented functions or a frozen binary layout.

## 2. Nodes

```idl
server 'api' host='0.0.0.0' port=8080 {
    route '/users' method='GET' {
        handler users.list
    }
}
```

A document contains ordered nodes. Each node has a name, zero or more ordered
positional arguments, zero or more ordered named properties, an optional child
body, and zero or more preceding annotations. Arguments precede properties; the
body comes last. An absent body differs from an explicitly empty body in syntax.

```idl
database 'main' engine=postgres port=5432 // valid
database engine=postgres 'main'          // invalid: argument after property
database {} 'main'                       // invalid: entry after body
```

Property names are unique within each node or annotation. Diagnose a duplicate
at its later occurrence and retain the original as a related location. Preserve
both entries rather than choosing a winning value. Repeated child-node names and
repeated annotation names are permitted by the core.

Annotations precede their target on separate logical lines:

```idl
@deprecated 'Use UserV2'
record User {
    field id UUID
}
```

They preserve metadata syntax without introducing domain keywords. Their
attachment and termination rules are specified in the grammar section.

## 3. Boundaries, bodies, and continuation

A newline or `;` terminates a node. EOF or the enclosing body's `}` can terminate
the last node. Blank lines and empty semicolon separators are allowed. A node's
own closing body brace does not remove the separator requirement before a sibling.

```idl
server { host localhost; port 8080 }
first {}; second {} // valid
first {} second {}  // invalid: missing separator
```

One exception permits a body's `{` on a later line. After a complete header, look
across whitespace, comments, and newlines. If `{` is the next significant token,
attach the body to that header. Never look across a semicolon, annotation, another
node, or another significant token. A node cannot acquire a second body.

```idl
server 'api'
// Comments and blank lines can precede the body.

{
    route '/users'
}

server 'api';
{} // invalid: attachment cannot cross a semicolon
```

Outside strings and delimited expressions, backslash continues a logical line.
It is followed by zero or more horizontal whitespace/block-comment items, an
optional line comment, and a physical newline outside comments. It consumes that
newline; following indentation is ordinary whitespace. EOF before that newline
is an error. Continuations cannot split words, numbers, units, or operator tokens.

```idl
server 'api' \ // public listener
    host=localhost \
    port=8080 {
    route '/users'
}
```

Indentation never groups nodes. A newline after `key=` or a prefix operator does
not implicitly continue a bare header. Report a missing value; use backslash or
open a delimited expression before the newline to continue it.

Braces always contain child nodes. There are no object/anonymous-map expressions
in properties, groups, lists, or function arguments. A schema can interpret a
child node as an object and repeated children as a collection:

```idl
service 'api' {
    retry {
        attempts 3
        delay 100ms
    }
}
```

`options={attempts=3}` and `[{attempts=3}]` are invalid.

## 4. Values and expression contexts

Values have expression representations: literals, symbols, lists, function calls,
grouping, unary expressions, and binary expressions. The core never evaluates them.

| Context | Syntax |
| --- | --- |
| Bare node/annotation header | Individual literal, symbol, list, call, group, or prefix `!` applied to another header value |
| Inside grouping, list, or function-argument delimiters | Full unary and binary expressions |

Within expression delimiters, newlines and comments between components are
whitespace. Commas, not newlines, separate list elements and function arguments.
Backslash continuation is unnecessary there but remains accepted as whitespace.

```idl
sample 10 -2                 // two numeric arguments
sample (10 - 2)              // one grouped binary expression
sample !enabled             // one unary expression
sample (-offset)            // unary arithmetic on a symbol
setting result=(10 * 2)
setting enabled=(ready and !disabled)
setting result=clamp(
    base + adjustment,
    0,
    100,
)
somelist [1, 2, 3]
somelist [
    1,
    base + offset,
    clamp(x, 0, 100),
]
```

`sample 10 - 2` is invalid: a bare negative literal requires the minus to touch
the number. `result=base + offset` requires grouping. `sample a and b` has three
symbol arguments, not an operator expression.

Negative literals such as `-2` and `-30ms` work directly in headers. Other unary
arithmetic requires a delimited expression. Prefix `!` may repeat and precede any
header value, with optional horizontal spacing. Operand type validity belongs to
the schema/application layer.

## 5. Grouping, lists, and function calls

Parentheses group exactly one expression. `(1, 2)` and `()` are invalid: there is
no tuple or named-tuple value. Preserve grouping delimiters for tooling without
introducing a tuple value type.

Lists contain comma-separated, ordered expressions. Empty lists and one trailing
comma are allowed; `[1,,2]` and `[1 2]` are invalid.

A function-call expression contains a symbolic function name and ordered
positional expressions. Its opening `(` must touch the name without whitespace or
comments. Empty argument lists and one trailing comma are allowed. Named arguments,
computed callees, and call-result chaining are excluded.

```idl
setting result=abs(10 + foobar('string'))
setting result=math.clamp(x, 0, 100)
sample foo(1)        // one call argument
sample foo (1)       // a symbol and a grouped number
setting result=foo() // valid even if the application does not know foo
```

Inside a full expression, `foo (1)` is invalid: it has adjacent expressions without
an operator. At document level `sample(1)` is invalid; the node name needs spacing
before an argument, as in `sample (1)`.

Dotted symbols remain whole names. `users.list` is not a member-access AST.
Indexing, member-access operators, and computed function names are not v1 features.
A literal keyword such as `true` cannot be a function name in value position.

## 6. Operators

Precedence is fixed, highest to lowest:

| Level | Operators | Associativity |
| --- | --- | --- |
| Prefix | `+` `-` `!` | right |
| Multiplicative | `*` `/` `%` | left |
| Additive | `+` `-` | left |
| Relational | `<` `<=` `>` `>=` | left |
| Equality | `==` `!=` | left |
| Conjunction | `and` | left |
| Disjunction | `or` | left |

Symbolic operators need no surrounding whitespace. Recognize the longest valid
operator token, so `!=` is one token. Lowercase `and` and `or` require word
boundaries and are contextual infix operators where an operator is expected.
They remain names/symbols elsewhere, including `[and, or]`.

```text
(a + b * c)     => Add(a, Multiply(b, c))
(a - b - c)     => Subtract(Subtract(a, b), c)
(!a or b and c) => Or(Not(a), And(b, c))
(a < b < c)     => LessThan(LessThan(a, b), c)
```

There is no special chained-comparison behavior. Applications may reject operand
types. The core defines tree structure, not evaluation, coercion, short-circuiting,
dimensional arithmetic, or arithmetic overflow.

In a full expression, signs are operators even before numbers: `(-2)` contains
unary minus over a positive literal. In a bare header, contiguous `-2` is a signed
numeric literal. Preserve that syntactic distinction; do not constant-fold it.

Exclude `&&`, `||`, power, bitwise, shift, assignment, and ternary operators. Single
`=` only introduces header properties. Functions such as `pow(10, 2)` or
`shift_left(10, 1)` can describe application-defined operations.

## 7. Names, symbols, and keywords

Names and symbols are broad Unicode words without normalization or case folding.
A bare symbol excludes whitespace, control characters, and this punctuation:

```text
' " \ / ( ) [ ] { } = ; @ , < > | + - * % ! & ^ ? ~
```

Node, property, and annotation names follow the same rule except that they allow
hyphens. A name is nonempty and cannot begin with an ASCII digit, `-` followed by
a digit, or `.` followed by a digit. Symbols also exclude numeric-looking prefixes;
malformed numeric input must not silently become a symbol. Quoted names are not
supported in v1.

Dots, underscores, colons, and other nonexcluded characters may occur in words.
Paths and URLs require quotes because slash is reserved. Hyphenated literal text
also requires quotes; inside full expressions `max-size` means subtraction.
`cache-size=10` remains a valid property.

```idl
node-schema service
setting mode='read-only' cache-size=10
setting reference=models.User
```

Scanning/parsing must distinguish header-name context from expression-symbol
context. Property-name recognition uses a following single `=`, not `==`, on the
same logical header line, with intervening spacing permitted.

Only `true`, `false`, and `null` are literal keywords in value position. They may
be node/property names. Domain words such as `service`, `record`, and `schema`
are never reserved. `nan` and `inf` remain symbols.

## 8. Numbers and units

```text
digits           := ASCII_DIGIT+
unsigned-decimal := ("0" | NONZERO_DIGIT ASCII_DIGIT*)
                    ("." digits)? (("e" | "E") ("+" | "-")? digits)?
unsigned-hex     := ("0x" | "0X") HEX_DIGIT+
unsigned-number  := unsigned-hex | unsigned-decimal
signed-number    := "-"? unsigned-number
unit             := ASCII_LETTER+
```

Bare headers use signed numbers; full expressions parse signs as operators. A
number-with-unit is a number immediately followed by ASCII letters. Retain numeric,
unit, and full spans without interpreting units. `30 ms` is two header arguments.

Recognize an exponent only when complete, preferring a complete exponent over a
unit prefix. After a number/unit candidate require a real token boundary; do not
split malformed suffixes into additional adjacent values.

`0x` and `0X` are reserved hexadecimal prefixes and take priority over interpreting
`x` as a unit. Require at least one hex digit (`0-9`, `a-f`, `A-F`), then consume
the longest hex digit sequence before considering a unit suffix. Hexadecimal
numbers are integers: there is no hexadecimal fraction or exponent syntax. Store
the radix with the raw numeric spelling; do not eagerly convert to a machine integer.

| Input | Classification |
| --- | --- |
| `42`, `3.14`, `1e-3`, `1e1000` | number |
| `-42` in a bare header | signed number |
| `30ms`, `10MiB`, `1em` | number with unit |
| `1e3ms` | number `1e3`, unit `ms` |
| `1e` | number `1`, unit `e` |
| `0xFF`, `0Xff`, `0x10B` | hexadecimal numbers; `B` in the last example is a digit |
| `-0xFF` in a bare header | signed hexadecimal number |
| `0x10ms` | hexadecimal number `0x10`, unit `ms` |
| `0x`, `0xms`, `0x1.2`, `0x1p2` | malformed hexadecimal input |
| `01`, `.5`, `1.`, `1.2.3`, `30ms2` | malformed numeric input |
| `+42` in a bare header | invalid; use `(+42)` for unary plus |

There is no leading plus in a numeric literal, octal/binary syntax,
digit separator, NaN, or infinity literal. Units are case-sensitive `A-Z`/`a-z`.
Suffixes such as `%` and `°C` are excluded; `%` is an expression operator.

Numbers preserve spelling and radix rather than assuming `i64` or `f64`.
`1e1000` is valid even when a consumer's machine conversion overflows. Conversion
must be explicit and must not silently substitute infinity for a finite decimal.

## 9. Strings

Ordinary strings use single quotes and may contain physical newlines. Their
decoded values preserve Unicode content, indentation, and LF/CRLF/CR exactly.
Double quotes are not string delimiters.

Escapes are `\\`, `\'`, `\n`, `\r`, `\t`, `\b`, `\f`, and `\u{H...}` with one
to six hexadecimal digits representing a Unicode scalar. Reject surrogates and
values above U+10FFFF. Invalid/incomplete escapes produce diagnostics; malformed
strings have no authoritative decoded value, but retain raw source. A backslash
followed by a physical newline inside a string is an invalid escape, not header
continuation.

Unterminated strings consume through EOF unless a closing quote is found, and
produce a token plus a diagnostic. A newline is not a string recovery boundary.

### 9.1 Marked strings

`|'...'` is dedented literal text. `>'...'` is dedented folded text. Both are string
values. The marker must touch the quote and is recognized where a value/operand
can begin. Between operands `>` remains a comparison:

```idl
setting text=|'one line'
setting test=(left>'right')    // comparison with an ordinary string
setting test=(left > >'right') // comparison with a folded string
```

For marked strings, process raw content in this order:

1. Remove one physical newline immediately following the opening quote, if any.
2. If the closing quote is on its own line preceded only by spaces/tabs, remove
   that indentation and the immediately preceding physical newline, if present.
   Remove a sole shared framing newline only once for an empty block.
3. Remove the longest exact common space/tab prefix from all nonblank content
   lines. Tabs are not expanded. Whitespace-only lines become empty. When there
   are no nonblank lines, there is no common prefix.
4. For `|`, retain remaining physical newlines. For `>`, apply folding below.
5. Decode escapes. An explicit `\n` therefore cannot be folded as layout.

Inline marked strings use the same rules without requiring framing newlines.

### 9.2 Folding

For `>`, normalize remaining physical newlines to LF. After dedentation, lines are
empty, ordinary text, or more-indented text (nonblank and still starting with a
space/tab).

- Replace a break between adjacent ordinary lines with one space.
- Between ordinary lines separated by `k` empty lines, retain `k` LF bytes.
- Preserve all breaks around/within more-indented text, including paragraph
  boundaries touching such lines.
- Preserve remaining leading/trailing empty-line breaks after framing removal.
- Do not trim other content or append an implicit final newline.

```idl
message |'
    first
    second
'
// Decoded: first\nsecond

message >'
    first
    second

    third
'
// Decoded: first second\nthird

message >'
    introduction
      indented code
    conclusion
'
// Decoded: introduction\n  indented code\nconclusion
```

An explicit final `\n` requests a final newline. With CRLF source, ordinary strings
and `|` preserve content CRLF; `>` produces LF. These examples show escaped decoded
values in comments and assume LF source.

## 10. Whitespace, comments, and Unicode

Horizontal whitespace is space U+0020, tab U+0009, vertical tab U+000B, or form feed
U+000C. Newlines are LF, CRLF, or CR. CRLF is one physical newline spanning two
bytes; vertical tab and form feed do not end lines.

Non-ASCII Unicode whitespace (U+0085, U+00A0, U+1680, U+2000-U+200A, U+2028,
U+2029, U+202F, U+205F, U+3000) is neither bare-word content nor source spacing in
v1, but can be represented in strings and occur in comments. Strings still obey
the control-character escape rules below. U+FEFF is not implicit whitespace or bare
word content. A leading UTF-8 BOM produces a diagnostic rather than being removed.

Reject other C0/C1 controls outside strings/comments. Strings allow literal tab
and supported newlines; other C0/C1 controls require escapes. Comments preserve
control bytes, but invalid UTF-8 is diagnosed everywhere. Retain original bytes
rather than replacing malformed sequences; malformed strings lack decoded values.

`//` ends before the next physical newline or EOF. `/*` ends at the first `*/`
without nesting. An unterminated block comment spans through EOF and produces a
diagnostic. Comment delimiters inside strings are ordinary content.

```idl
server 'api' /*
    all of this is whitespace between header entries
*/ port=8080
```

This is one node. Physical line maps count comment newlines, but logical header
termination ignores them. Newlines inside strings likewise advance physical line
maps without ending the surrounding value.

## 11. Grammar summary

This EBNF describes structure. The preceding context, lexical, spacing, and
next-line-body rules are normative additions. `gap` is nonempty header spacing:
horizontal whitespace, comments, or explicit continuations, but not an unescaped
newline outside comments/strings. `hspace` is its possibly empty counterpart.
Inside expression delimiters token spacing also includes newlines.

```text
document       := separators? (annotated-node separators?)* EOF
annotated-node := annotation* node
annotation     := "@" name (gap header-value)* (gap property)* hspace logical-newline
node           := name (gap header-value)* (gap property)*
                  hspace (body-gap body)? hspace node-end
property       := name hspace "=" hspace header-value
body           := "{" separators? (annotated-node separators?)* "}"
node-end       := newline | ";" | LOOKAHEAD("}") | LOOKAHEAD(EOF)
separators     := (gap | newline | ";")+
body-gap       := (gap | newline)*

header-value   := "!" hspace header-value
                | signed-number unit?
                | string | boolean | null | symbol | list | call | group
group          := "(" expression ")"
list           := "[" (expression ("," expression)* ","?)? "]"
call           := symbol ADJACENT("(")
                  (expression ("," expression)* ","?)? ")"

expression     := disjunction
disjunction    := conjunction ("or" conjunction)*
conjunction    := equality ("and" equality)*
equality       := relational (("==" | "!=") relational)*
relational     := additive (("<" | "<=" | ">" | ">=") additive)*
additive       := multiplicative (("+" | "-") multiplicative)*
multiplicative := unary (("*" | "/" | "%") unary)*
unary          := ("+" | "-" | "!") unary | primary
primary        := unsigned-number unit?
                | string | boolean | null | symbol | list | call | group
```

At a header entry boundary, a name followed by single `=` takes priority as a
property; a value symbol immediately followed by `(` takes priority as a call.
Do not backtrack a malformed call into unrelated arguments. Separate header
arguments require `gap`; properties permit spacing around `=`. An opening body
brace needs no preceding horizontal space and may use the next-line exception.

In this summary, `logical-newline` is a physical newline not absorbed by a string,
block comment, explicit continuation, or expression delimiter. Blank lines and
comments are permitted between `annotation` productions and their target node,
even though the compact `annotation*` production elides that intervening trivia.

Annotations require adjacency between `@` and the name. They end on a logical
newline, cannot have bodies, and cannot use `;` instead of their newline. Ignore
blank lines/comments between annotations and their target; a semicolon interrupts
attachment. An annotation at EOF or before `}` without a target is an error.

## 12. Source model and Zig types

Parse an entire source snapshot as UTF-8 bytes. All offsets, lengths, and physical
line starts are byte-based `usize` values. Spans have inclusive starts and exclusive
ends. Missing syntax uses zero-length spans at insertion positions.

This complete Zig example defines source views, not memory ownership:

```zig
pub const TextSpan = struct {
    start: usize,
    len: usize,

    pub fn end(self: TextSpan) usize {
        return self.start + self.len;
    }
};

pub const SourceText = struct {
    bytes: []const u8,

    pub fn slice(self: SourceText, span: TextSpan) error{OutOfBounds}![]const u8 {
        const span_start_is_in_bounds = span.start <= self.bytes.len;
        if (!span_start_is_in_bounds) {
            return error.OutOfBounds;
        }

        const remaining_source_len = self.bytes.len - span.start;
        const span_fits_remaining_source = span.len <= remaining_source_len;
        if (!span_fits_remaining_source) {
            return error.OutOfBounds;
        }

        return self.bytes[span.start..span.end()];
    }
};

pub const Severity = enum { information, warning, err };

pub const Diagnostic = struct {
    code: []const u8,
    severity: Severity,
    message: []const u8,
    span: TextSpan,
    related_span: ?TextSpan = null,
};
```

Construct only spans whose end is representable and within source bounds.
`SourceText` and slices are immutable document-borrowed views. ASCII punctuation
can be scanned directly as bytes; decode Unicode scalars where needed. Each scalar
occupies one to four UTF-8 bytes.

For `x 'é😀'` followed by CRLF:

| Content | Byte start | Byte length |
| --- | --- | --- |
| `x` | 0 | 1 |
| string including quotes | 2 | 8 |
| `é` | 3 | 2 |
| `😀` | 5 | 4 |
| CRLF | 10 | 2 |
| EOF / next line start | 12 | 0 |

Physical line maps count newlines inside strings/comments, independently of
logical header boundaries. Protocol negotiation belongs to the LSP adapter.

## 13. Ownership and API contract

The public Zig module is `idl`. These signatures are design notation, not function
implementations:

```text
parse(allocator: std.mem.Allocator, source: []const u8) ParseError!*Document
Document.destroy(self: *Document) void
Document.source(self: *const Document) SourceText
Document.nodes(self: *const Document) []const Node
Document.tokens(self: *const Document) []const Token
Document.diagnostics(self: *const Document) []const Diagnostic
Document.hasErrors(self: *const Document) bool
```

Parsing copies input. Callers can release/change their input after the call. The
stable-address document owns source, syntax, trivia, decoded strings, line index,
and diagnostics. Store the allocator in the owner; `destroy` frees all storage and
the owner itself. Returned views expire at destruction. Do not mutate or shallow
copy ownership. The allocator's backing context must outlive the document.

Use document-scoped arena storage and no global allocator. Allocate the owner at
a stable address before initializing allocator contexts pointing into it. Free
partial storage on fatal failures.

Syntax errors return a document with diagnostics. Fatal allocation/resource errors
return no document. The initial error set is `OutOfMemory`, `SourceTooLarge` for
unrepresentable lengths/index arithmetic, and `NestingLimitExceeded`. Limit nesting
to 256 simultaneously active node bodies, expression containers, or prefix
operations; flat lists and left-associative operator chains do not consume nesting
per element. Clean up when the limit is exceeded instead of overflowing the stack.

Represent numbers by radix and source spans, number-with-unit components separately,
and strings
by raw spans plus style and optional decoded UTF-8 slices, and boolean/null/symbol
values explicitly. Preserve operators and call names. Do not eagerly convert
decimals to machine floats or use untyped object payloads.

Expose arguments, properties, annotations, child bodies, expression operands and
elements, tokens, missing syntax, and skipped source. References and slices are
document-owned. Internal indices/pointers are not a foreign-language ABI.

## 14. Scanning, trivia, and losslessness

Use a stateful scanner over the owned source with small lookahead and parser
context for header names, signed numbers, and expression punctuation. It identifies
token spans, literal spelling, trivia, and lexical diagnostics. A preliminary
whole-file token array is unnecessary, but retain encountered tokens for tooling.

Kinds cover names/symbols, number components, strings, delimiters, operators,
annotation/property punctuation, unknown text, and EOF. Keyword meaning can be
assigned by the parser in context.

Trivia kinds are horizontal whitespace, physical newline, line comment, block
comment, continuation, and parser-produced skipped text. Every source byte belongs
to exactly one real token or trivia range. Token spans exclude trivia. All trivia
belongs to the following token; EOF owns final trivia. Synthetic tokens have no
source bytes. If recovery reclassifies tokens as skipped text, it must not retain
overlapping coverage in the primary token/trivia stream.

Newline trivia remains visible to header parsing. Newlines inside string tokens
and block comments are not separate node-ending trivia. Continuation trivia owns
its consumed physical newline. Use this single captured-trivia model rather than
competing skip/emit scanner modes. Exact source reproduction can use the retained
source directly without reconstructing it from decoded values.

## 15. Diagnostics and recovery

Diagnostics have stable symbolic codes, severity, readable text, and byte spans.
Lexical diagnostics concern tokens; parser diagnostics concern structure. Domain
diagnostics are separate consumer results. Error diagnostics mean the document is
invalid even when a recoverable tree is returned.

Guarantee forward progress. Preserve malformed regions, insert zero-width missing
tokens when useful, and avoid repeatedly failing at the same position. Synchronize
using nesting-aware commas/closing delimiters inside expressions and logical
newlines, semicolons, closing braces, or EOF between nodes. Do not consume a
parent's closing delimiter to repair a child.

A missing expression closer can keep later lines within the expression until a
usable synchronization point/EOF. Do not treat every newline in a valid expression
as a node boundary.

```idl
server 'api' {
    listener port=
    route '/users' {
```

Recover a `listener` node with a missing `port` value, a sibling `route`, and
missing closing braces. Do not invent a body-level property detached from a node.

Representative codes include `invalid_utf8`, `invalid_number`, `invalid_escape`,
`unterminated_string`, `unterminated_comment`, `expected_value`, `expected_comma`,
`expected_close_delimiter`, `duplicate_property`, `argument_after_property`, and
`unattached_annotation`. Adapters preserve codes; consumers must not classify
errors by parsing English messages.

## 16. Project layout and implementation order

All code belongs under `dev/`. The core is an independently buildable/testable Zig
package at `dev/idl-lib`, exporting module `idl`:

```text
dev/
├── idl-lib/
│   ├── build.zig
│   ├── build.zig.zon
│   ├── src/
│   │   ├── root.zig
│   │   ├── text.zig
│   │   ├── diagnostics.zig
│   │   ├── syntax.zig
│   │   ├── literals.zig
│   │   ├── scanner.zig
│   │   └── parser.zig
│   └── tests/
│       ├── fixtures/
│       └── conformance.zig
├── idl-c-abi/
├── idl-wasm/
├── idl-lsp/
└── idl-schema/
```

Companions depend on the core; the core never imports them. This is the target
layout, not implemented scaffolding. Specifications live in `doc/` at repository
root. Implementation plans live in `.agents/plans/`.

Implement source/diagnostics/ownership, contextual scanning and literals, delimited
expressions, nodes/annotations, recovery, then conformance and allocation-failure
checks. Recovery must inform every stage. Full-file snapshots suffice initially;
editors can apply incremental text changes and then call `parse` again. Incremental
lexing, red/green trees, and subtree reuse remain deferred until profiling warrants
them.

## 17. Acceptance scenarios

- Exact byte preservation and complete, nonoverlapping token/trivia coverage,
  including malformed source and final whitespace/comments.
- Unicode byte spans, invalid UTF-8, supplementary scalars, and LF/CRLF/CR maps.
- Node separators, next-line braces, semicolon attachment barriers, continuations,
  multiline comments, annotations, and absent versus empty bodies.
- Argument ordering, duplicate properties, and repeated child names.
- Signed bare arguments versus grouped operators; call adjacency; contextual
  `and`/`or`; every precedence and associativity tier.
- Nested/empty lists and calls, trailing commas, required separators, invalid
  tuples/objects/computed calls, and unsupported operators.
- Very large decimals/hex integers, exponent/unit and hex-digit/unit boundaries,
  signed hexadecimal literals, and malformed numeric candidates.
- Exact ordinary/dedented/folded strings, CRLF, tabs, blank and more-indented lines,
  escapes, malformed scalars, and string-marker/comparison disambiguation.
- Missing values/commas/closers, unknown text, unterminated strings/comments, and
  multiple errors without stalled recovery.
- Source-copy independence, allocation failures, nesting-limit cleanup, and
  repeated parse/destroy without leaks.
