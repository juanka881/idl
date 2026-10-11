# Idle Schema Validation Specification

Status: initial layer design. The schema-authoring language below is **provisional**,
not a second finalized grammar or an implemented validation engine.
Depends on the [Idle core specification](idl-spec.md).
Implementation location: `dev/idl-schema`.

## 1. Role and dependency

The core determines whether source has valid Idle structure. Schemas constrain
that structure for a domain. Applications interpret or evaluate accepted values.
Keep these responsibilities separate so a domain never needs to replace the parser.

```text
UTF-8 source -> core syntax + diagnostics
                          |
                          v
                 schema validation
                          |
                          v
             application semantics / domain model
```

The schema package depends on `dev/idl-lib`. The core does not load schemas or
import this package. The language server may use both packages; native/Wasm schema
bindings would be additional adapter work rather than automatically part of the
core adapters.

## 2. Validation capabilities

A schema can describe:

- allowed node names and annotations;
- positional argument counts and accepted values;
- allowed, required, and optional properties;
- whether child bodies are allowed or required;
- allowed child-node names and their cardinality;
- literal types, enumerated symbols, numeric ranges, and unit policies;
- permitted expression kinds, operators, function names, and argument shapes;
- documentation, deprecations, references, and application-level defaults.

Validate the parsed structure rather than reparsing source substrings. Grouping
can be transparent to type constraints while remaining available for diagnostics
and tooling. A domain may allow only literals, allow selected calls, or permit a
larger expression subset. Syntactically valid calls can still be invalid under a
schema.

The core already diagnoses duplicate properties, misplaced arguments, bad literal
syntax, and malformed expression structure. Schema validation must not invent
last-wins behavior for core-invalid duplicate properties. Repeated child names
remain available for schema-defined collections/cardinality.

## 3. Domain meaning and expressions

Symbols are not automatically references, enums, environment lookups, or functions.
A schema can constrain their role and an application can resolve their meaning.
Likewise a function-call AST is not authorization to invoke code during parsing.

For a number-with-unit value, inspect the numeric spelling and unit separately.
The core records `30ms` without knowing time units. It also preserves hexadecimal
radix, so consumers must not interpret `0x10ms` as decimal text. A schema may permit `ms` and
`s`, and an application can perform exact conversion as needed. Diagnose unknown
units at the unit span. Avoid compulsory binary floating-point conversion before
validation, especially for large decimal literals or hexadecimal integers.

`nan`, `inf`, `unlimited`, and `automatic` remain ordinary symbols in core syntax.
A domain may assign them special meaning explicitly; they are not global numeric
keywords or universal substitutes for null.

Operators have core-defined precedence and AST structure. An application may
define their meaning, but cannot change the parse tree by installing a new
precedence table. A schema can reject an operator or constrain operands without
evaluating it. Unknown runtime-dependent types should remain unresolved until
application analysis supplies the required information; do not execute calls to
guess their return type.

## 4. Object-like and collection data

Objects use child nodes, because the core has no object literal:

```idl
service 'api' {
    retry {
        attempts 3
        delay 100ms
    }
    tags [public, stable]
    endpoint '/users'
    endpoint '/health'
}
```

A schema may interpret `retry` as one object, `tags` as a list-valued field, and
repeated `endpoint` children as a collection. This meaning does not turn body
children into header properties. A domain needing a list of records can use
repeated record-shaped children instead of object literals inside a list.

Design schemas with short headers and meaningful child nodes. Use list/call/group
delimiters for multiline values rather than forcing many positional arguments or
properties onto continued header lines.

## 5. Authoring model and results

The initial integration can expose schema objects through a Zig API. A textual
schema language is a future design built from ordinary Idle nodes. For example:

```idl
node-schema service {
    argument name type=string required=true
    property visibility type=enum default=internal {
        value public
        value internal
    }
    child retry cardinality=optional
    child endpoint cardinality=many
}
```

This example is valid core syntax. `node-schema`, `argument`, `type`, `default`,
and `cardinality` are hypothetical schema vocabulary with no built-in core meaning.
Do not treat this sketch as a complete schema grammar or implement undocumented
schema semantics from it.

Validation consumes an immutable core document plus a schema and returns separate
domain diagnostics with stable codes and core byte spans. The document must remain
alive while any validation result borrows its syntax/text; an owned result must
copy what it needs. Keep ownership explicit in the eventual API.

For malformed input, validate structurally usable nodes and suppress cascading
domain errors caused solely by missing/error syntax. Do not mutate the parse tree
to insert defaults or resolve references. Defaults and a derived semantic model
belong to an application-owned result with separate provenance.

Schema loading, reference resolution, evaluation, code generation, and the concrete
schema API/authoring grammar require their own implementation decisions. They are
not prerequisites for implementing the core from its first specification.

## 6. Acceptance checks

- The same core tree supports different domain schemas without reparsing.
- Unknown nodes/properties, cardinality, argument counts, annotation policy, and
  required/optional bodies produce correctly located domain diagnostics.
- Repeated child nodes work as collections without weakening duplicate-property
  diagnostics from the core.
- Large decimals, hexadecimal integers, and number/unit values reach validation
  without precision loss.
- Literal-only domains can reject calls/operators; expression-enabled domains can
  validate permitted functions and operand shapes without executing them.
- Missing/error syntax suppresses redundant cascades while independent valid
  regions remain checkable.
- Defaults and semantic results leave source, syntax, and core diagnostics intact.
