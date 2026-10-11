# Working on Idle

Idle (`idl`) is a small configuration language with a reusable native Zig core.
It parses nodes and expressions into syntax; applications and higher layers give
that syntax meaning. Keep the core small and independent of consumers.

## Start here

Read these before changing code:

1. [Alignment log](.agents/alignment.md): the user's corrections, reasons, and
   before/after examples. Apply its current conventions throughout maintained
   source, tests, build files, and code examples.
2. [Core specification](doc/idl-spec.md): the authority for language and core API
   behavior. An implementation or plan must not silently override it.
3. The relevant plan in [.agents/plans/](.agents/plans/). The
   [core implementation plan](.agents/plans/idl-core-implementation.md) is complete;
   its stages, conformance matrix, and completion record explain the existing core.
4. [Package README](dev/idl-lib/README.md): dependency setup, public API use,
   ownership, and verification commands.

Current user instructions take precedence over repository guidance. Resolve real
specification contradictions explicitly before changing language behavior.

## Repository map

| Location | Purpose |
| --- | --- |
| `dev/` | All implementation projects |
| `dev/idl-lib/` | Native Zig core; exports the module `idl` |
| `dev/idl-lib/src/root.zig` | Public exports, document ownership, parse entry point |
| `dev/idl-lib/src/text.zig` | Source spans and physical line positions |
| `dev/idl-lib/src/diagnostics.zig` | Diagnostic types, codes, and messages |
| `dev/idl-lib/src/syntax.zig` | Tokens, trivia, and syntax types |
| `dev/idl-lib/src/scanner.zig` | Contextual tokenization and trivia |
| `dev/idl-lib/src/literals.zig` | String validation, layout, and decoding |
| `dev/idl-lib/src/parser.zig` | Expressions, nodes, annotations, and recovery |
| `dev/idl-lib/tests/` | Public conformance, ownership tests, and IDL fixtures |
| `doc/` | Core and companion specifications |
| `.agents/plans/` | Implementation plans and their progress/completion records |
| `.agents/alignment.md` | Running log of user corrections |
| `mise.toml` | Pinned Zig toolchain |

The [C ABI](doc/idl-c-abi-spec.md), [WebAssembly](doc/idl-wasm-spec.md),
[LSP](doc/idl-lsp-spec.md), and [schema](doc/idl-schema-spec.md) are separate
specifications built on the core. They are not implemented by the completed core
plan. Follow their specified `dev/` locations when those tasks are requested.
The LSP design negotiates UTF-8 positions only; no UTF-16 fallback is planned for
its initial implementation.

## Implementation and review workflow

- The primary agent owns planning, specification interpretation, and design
  decisions. Sub-agents report gaps and ambiguities to it rather than choosing
  language behavior, architecture, or scope on their own.
- Use **GPT-6 Luna with high reasoning effort** for implementation and
  **GPT-6.1 Sol with high reasoning effort** for independent review, following the
  user's established assignments. If a requested model is unavailable, report
  the limitation and use an already authorized fallback when one exists.
- Give each agent a concrete task: relevant spec/plan sections, current stage,
  allowed files, requirements, constraints, acceptance checks, and where to stop.
  The reviewer reads and reports findings; the implementer makes the approved
  changes. Avoid concurrent writers to the same files.
- Work in plan order. Complete and review each stage before starting the next.
  For style corrections, apply one correction across the agreed scope, review it,
  and resolve gaps before moving to the next correction.
- Keep plans in `.agents/plans/` and specifications in `doc/`. Update plan status
  with actual evidence; do not restart completed stages or claim checks that were
  not run. Use focused plans for new substantive milestones.
- Record new user corrections in `.agents/alignment.md`, with a heading, issue,
  correction, reason, scope, and before/after example where useful. Preserve prior
  entries and identify later refinements. The primary agent maintains this log.
- Continue authorized work without repeatedly requesting approval for routine
  reversible steps. Ask for missing intent when it affects the result. Give
  concise progress updates and finish with changes, verification, and limitations.

## Code conventions

The alignment log contains the detailed examples. In summary:

- Prefer simple statements, clear intent, and focused responsibilities over clever
  one-liners or abstractions that combine unrelated cases.
- Extract complex conditions into meaningful intermediate values and predicates.
  Prefer positive valid-state names and reject invalid states with early guards.
  Preserve short-circuit prerequisites before subtraction, indexing, or unwrapping.
- Construct returned structs in named locals, then return them. Use `const` for
  unmutated locals and `var` when mutation is required.
- Put nonempty struct/object fields on separate lines, including nested and
  call-site initializers. Empty initializers and scalar arrays need no expansion.
- Prefer initialized variables and braced assignment statements to `if/else`
  value expressions. Avoid redundant assignments of an existing default.
- Use explicit bodies for conditionals, loops, cleanup, and action-taking switch
  branches or `catch`/`orelse` alternatives. Simple value mappings stay concise.
- Separate logical steps with blank lines. Keep predicates with their guards and
  setup with its paired normal `defer`. Usually separate `errdefer` hooks. Give
  returns a visual pause after preceding work without padding block boundaries.
- Declare used standard-library types and namespaces as file-level aliases, such
  as `Allocator`, `ArrayList`, `testing`, and `mem`. Keep full dependency paths in
  the alias declarations. Avoid unused aliases and naming collisions.

Preserve document-owned source and arena lifetime, immutable published syntax,
UTF-8 byte spans, lossless real-token/trivia coverage, recoverable malformed input,
and cleanup on allocation failure. Consult the spec and plan for exact contracts.
The core parses expressions; it does not evaluate them or perform schema checks,
filesystem loading, or network access.

## Toolchain and verification

Use the Zig version pinned in `mise.toml` (currently `0.17.0`) and the installed
compiler's APIs. Run package checks from `dev/idl-lib`:

```text
zig fmt --check build.zig build.zig.zon src tests
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
```

The environment may restrict the default Zig cache. In PowerShell, from the
package directory, use the ignored package-local caches:

```powershell
$env:ZIG_LOCAL_CACHE_DIR = Join-Path (Get-Location) '.zig-cache'
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path (Get-Location) '.zig-global-cache'
```

Run checks appropriate to the change. Parser, ownership, or recovery changes need
the relevant behavioral tests and Debug/ReleaseSafe checks. For public packaging
or portability changes, also use the external-consumer and wasm32 compile checks
described in the plan. Distinguish compile-only WebAssembly checks from runtime
integration. Pure spacing/documentation changes can use formatting and a focused
diff or content check; do not add tests that merely mirror style edits.

Use `rg` for searches. Keep temporary audit files and external smoke consumers in
ignored temporary/cache locations. Do not commit caches, `zig-out`, or review
artifacts. Preserve unrelated user changes and inspect the staged diff.

## Commits

Use Conventional Commits: `type(scope): concise description`, with an optional
scope. Examples: `feat(core): implement the Idle parser`,
`fix(parser): preserve siblings during recovery`, and
`docs(agents): document contribution workflows`.

Choose the type for the actual change, and describe its purpose and relevant
verification in the body when useful. Before a requested commit, review the
staged file list and diff, check for generated artifacts, and run appropriate
verification. Report the commit hash and outcome. Do not push or publish unless
the user requests it.
