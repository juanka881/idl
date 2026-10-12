# Phase 2: Idle LSP implementation

Status: complete. Authority: `doc/idl-lsp-spec.md` and the
approved Phase 2 plan. Check tasks only after implementation and applicable
verification. Record evidence and unresolved limitations under each stage.

Later TypeScript compiler, file-layout, and mocking corrections are tracked in
[the TypeScript alignment checklist](idl-vscode-typescript-alignment.md). The
stage evidence below records the original implementation checks.

## Architecture and decisions

- Native package `dev/idl-lsp` produces `idl-lsp`, using Zig stdlib and a local
  dependency on the public `idl` module. Core API and behavior remain unchanged.
- Extension `dev/idl-vscode` uses TypeScript, Node built-ins, VS Code API, pnpm,
  and a dedicated modular `LspClient`; no runtime protocol dependency.
- Preserve mise pins: Zig 0.17.0, Node 26.7.0, pnpm 11.23.0.
- Separate framing, JSON-RPC, supported LSP types, lifecycle, documents, position
  mapping, and diagnostics. Entry points only compose modules and run them.
- Synchronous stdio server; stdout contains protocol only, stderr operational logs.
- Incremental text synchronization followed by one complete parse per accepted
  batch. No incremental parsing, schemas, completion, formatting, navigation,
  semantic tokens, evaluation, binary bundling, downloads, publishing, or browser
  extension support in this phase.
- Server negotiates UTF-8 only. Extension converts VS Code UTF-16 coordinates at
  its boundary. Configure an absolute executable using `idle.serverPath`, spawn
  without a shell, and run one server per extension host.

## Stage checklist

Baseline (2026-10-11): primary verified the pinned tool versions and installed
VS Code 1.141.0. Existing core `zig fmt --check build.zig build.zig.zon src tests`,
`zig build test --summary all`, and `zig build test -Doptimize=ReleaseSafe --summary all`
passed (build tests cached). User's existing mise changes are preserved.

- [x] Stage 1: Package foundations reviewed.
- [x] Stage 2: Transport and initialization reviewed.
- [x] Stage 3: Documents and transactional edits reviewed.
- [x] Stage 4: Parsing and diagnostics reviewed.
- [x] Stage 5: VS Code client reviewed.
- [x] Stage 6: Highlighting and integration reviewed.
- [x] Final acceptance and handoff.

### Stage 1: Package foundations

- [x] Create packages, scripts, test entry points, and artifact ignores.
- [x] Connect the server to the public core module through a local dependency.
- [x] Configure TypeScript/pnpm development dependencies and lockfile.
- [x] Define injectable session output and client startup/shutdown/message APIs.
- [x] Establish ownership for snapshots, parse trees, buffers, pending requests.
- [x] Provide in-memory harnesses and verify both builds.
- [x] Sol reviews; Luna fixes findings; primary records evidence.

Evidence: Luna implemented foundations; Sol independently accepted after fixing
ownership contract documentation, owned test captures, and style findings. Native
fmt, Debug (3 tests), ReleaseSafe (3 tests), and executable build passed; reviewer
also ran a fresh Debug cache (3/3). Extension `pnpm test` built TypeScript and passed
2 tests. Node tests use `--test-isolation=none` because sandbox child-process
isolation returned EPERM. Dependency installation needed network access; generated
store, node_modules, output and Zig artifacts are ignored.

### Stage 2: Transport and initialization

Primary clarification during review: drop response-shaped peer messages before
error-response paths, including malformed responses and null-ID errors, to avoid
reply loops. `initialized` accepts absent/object params; invalid forms are ignored.
`shutdown` and `exit` accept absent/null params only; invalid shutdown parameters
return InvalidParams without changing state, and invalid exit notifications are
ignored. Unknown fields in accepted objects remain permitted.

- [x] Implement Content-Length framing, buffered fragmented/coalesced reads,
      serialized writes, 8 KiB header and 16 MiB body limits.
- [x] Validate envelopes/parameters, string/integer IDs; malformed complete JSON
      receives protocol errors; unrecoverable/truncated framing closes transport.
- [x] Implement initialize/initialized/shutdown/exit and lifecycle validation.
- [x] Unknown requests receive method-not-found; unknown notifications get no reply.
- [x] Require explicitly offered UTF-8; reject unsupported initialization with
      explanation and retry disabled.
- [x] Advertise UTF-8, open/close, incremental changes only.
- [x] Verify transport/lifecycle/negotiation independently of parsing.
- [x] Sol reviews; Luna fixes findings; primary records evidence.

Evidence: Sol accepted Stage 2 after response-loop, lifecycle-parameter, and
style corrections. Luna verified fmt, Debug 17/17, ReleaseSafe 17/17, and native
build. A bounded installed-executable stdio smoke received initialize/shutdown
responses and exited 0 after shutdown/exit with null params.
Primary independently verified five real-process negotiation cases (UTF-8 alone,
UTF-8 second, empty, UTF-16-only, UTF-32-only), Unicode request-ID round trips,
retry=false rejections, response counts and exit statuses. Node child spawning
required sandbox escalation; the bounded approved test then passed.

### Stage 3: Documents and transactional edits

Primary implementation detail: validate document versions as signed 32-bit LSP
integers and position components as LSP unsigned integers (0 through 2^31-1).
For malformed changes with an identifiable open URI, retain the snapshot and mark
unsynchronized; advance the observed watermark only when a valid newer version is
available. Stale changes remain ignored. The document layer returns outcomes;
the session layer owns notifications and actionable error reporting.

- [x] Own URI, text, line index, committed/highest observed versions,
      synchronization state, and optional parse tree independently.
- [x] Build sequential batch edits privately and commit atomically; accept full
      replacements/ranges, ignore rangeLength, allow empty version-advance batches.
- [x] Map UTF-8 columns, LF/CRLF/CR, excluding terminators; clamp long columns;
      reject invalid lines, reversed normalized ranges, and split scalars.
- [x] Never place positions between CR/LF; ignore stale versions <= highest seen.
- [x] Invalid update retains committed text, discards stale tree/diagnostics,
      marks unsynchronized, and reports actionable URI-specific error.
- [x] Unsynchronized recovery begins with full replacement or close/reopen.
- [x] Duplicate opens/unknown-document edits log and ignore; repeated closes safe.
- [x] Verify transaction rollback, Unicode, versions, recovery.
- [x] Sol reviews; Luna fixes findings; primary records evidence.

Evidence: Sol accepted Stage 3, including the additional regression for sequential
Unicode edits inside actual multiline strings and block comments. Native fmt,
Debug 36/36, ReleaseSafe 36/36, executable build, and diff whitespace check passed.
Allocation-failure sweeps verify failed opens leave no entry and failed proposals
retain committed text while invalidating synchronization; session tests cover
stale-before-validation, invalid versions, clears, recovery, and close/reopen.

### Stage 4: Parsing and diagnostics

Measured performance decision: Debug native didOpen took 112/203 ms for 2,000/4,000
missing-value lines, but 1,269/4,954 ms for 2,000/4,000 duplicate properties on one
line. Primary approved binary search over existing line starts and a valid-UTF-8
scalar-boundary fast path, validating source once per mapAll. Keep an explicit
malformed-byte fallback; no core/parser or JSON serializer optimization. Preserve
all mapping behavior and record post-change measurements before stage acceptance.
Post-change Debug measurements: 2,000/4,000 missing-value lines took 83/88 ms;
2,000/4,000 single-line duplicate properties took 50/74 ms, with identical
diagnostic counts. Both sets were bounded didOpen subprocess measurements ending
at stdin EOF (exit 1 expected because these profiling runs omit shutdown).

- [x] Parse on open and once per accepted batch; destroy replaced trees and close state.
- [x] Publish URI/version/source idl, core codes/messages/severities and supported
      related locations (same URI, fallback message "Related location").
- [x] Clamp terminator positions, round nonempty spans outward to boundaries;
      contiguous malformed-byte runs are indivisible mapping segments.
- [x] Zero-width ranges snap to preceding valid boundary and stay zero-width;
      preserve original core bytes/spans.
- [x] Recoverable syntax errors publish; fatal parsing retains current text/version
      but clears tree/diagnostics and reports operational error.
- [x] Close publishes empty diagnostics; later ranged edits recover after fatal parse.
- [x] Verify diagnostic mapping, allocation cleanup, nesting-failure recovery.
- [x] Sol reviews; Luna fixes findings; primary records evidence.

Evidence: Sol accepted final parse/diagnostic implementation, optimized mapper,
ownership and style. Native fmt/build and Debug/ReleaseSafe 50/50 tests passed.
Tests cover all severity mappings, bounds, malformed/truncated bytes adjacent to
valid scalars, related-information negotiation, serialized metadata, empty-batch
reparse, close clearing, nesting failure with ranged repair, and allocation cleanup.
Primary independently ran a real-process exchange: kitchen-sink opened without
diagnostics; `node é😀 value=` produced a zero-width expected_value diagnostic at
the correct UTF-8 EOF column; a ranged insertion repaired it; both documents
cleared on close; shutdown/exit returned 0. Test passed under bounded approved
subprocess execution.

### Stage 5: Modular VS Code client

Primary defaults: startup timeout 10 seconds, ordinary request timeout 5 seconds,
shutdown timeout 3 seconds followed by bounded process termination. Tests may inject
shorter deadlines. Wire versions use positive i32 counters retained across reopen;
exhaustion forces a new server generation and resets counters before replay.

Review-driven decisions: shutdown cancels older start/restart continuations and
awaits in-flight process stops; the startup deadline includes initialized and
document replay writes. Failed document sends invalidate that generation even
without a transport close event; retained current text reopens fully on restart.
Strict RPC classification separates notifications, unsupported server requests,
and validated responses, rejecting malformed matching responses without leaving
pending timers. Transport protocol closure is separate from actual child-process
exit: errors clear consumers immediately, while shutdown still awaits or terminates
the owned process with a bounded deadline.

Client mapping measurement: rebuilding/scanning coordinates per diagnostic took
237 ms for 1,000 ranges and 908 ms for 2,000. Primary approved an immutable mapper
per valid snapshot with physical line bounds and sparse UTF-16/UTF-8 checkpoints
about every 64 UTF-16 units at scalar boundaries. Binary-search checkpoints and
scan a bounded remainder; reuse the same mapper for diagnostics and related
locations, preserving existing boundary validation and invalid-surrogate recovery.
Post-change reused-mapper measurements (one mapper per snapshot, median of five
passes): 1,000/2,000/4,000 diagnostic ranges took 0.45/0.60/0.96 ms. These measure
mapping, not complete editor latency; checkpoint tests cover accents, emoji, CRLF,
and a shared mapper used across a large diagnostic batch.

- [x] Implement separate framing/RPC, request tracking, snapshot conversion,
      LspClient, and editor adapter with thin activation.
- [x] Launch configured executable; advertise UTF-8, diagnostic versions/related info.
- [x] Initialize before replaying opens; fold startup edits into latest snapshots.
- [x] Convert ranges against retained pre-event snapshots, sort nonoverlapping
      edits descending by original offset, reconstruct/compare final text.
- [x] Ambiguous ordering/reconstruction uses full replacement fallback.
- [x] Unpaired UTF-16 surrogates cause error/diagnostic clearing, no lossy send;
      next valid snapshot is sent as full replacement.
- [x] Monotonic per-URI wire versions survive close/reopen within server session.
- [x] Gate diagnostics by process generation, open URI, exact current wire version;
      convert against matching snapshot; clear immediately on edit/close/exit.
- [x] Bound startup/request/shutdown waits and release pending requests/processes.
- [x] Implement Idle: Restart Language Server, offer restart on server errors;
      new generation replays valid full didOpen snapshots.
- [x] Recovery uses standard messages and explicit actions, no custom notification
      or message-text parsing.
- [x] Verify multicursor, undo/redo, fallback, stale results, surrogates, lifecycle.
- [x] Sol reviews; Luna fixes findings; primary records evidence.

Evidence: Sol accepted Stage 5 after lifecycle, failed-send, RPC classification,
coordinate-mapper, and process-cleanup corrections. Extension build and typecheck
passed, with 38/38 tests. Sol independently reproduced and verified the lifecycle
fixes and ran the final three process-cleanup regressions. Primary independently
verified 28,960 coordinate round trips across accents, emoji, CJK, tabs, checkpoint
boundaries, and CRLF/CR/LF. The editor adapter selects the `idle` language ID,
including manually associated and untitled documents.

Final acceptance audit follow-ups resolved: `publishDiagnostics.versionSupport:
true` is advertised and asserted, the real Extension Host verifies undo/redo,
and the allocation-failure sweep restores allocation and verifies a newer ranged
edit reparses successfully. Sol accepted these follow-ups; updated native Debug
and ReleaseSafe suites both passed 50/50 tests.

### Stage 6: Highlighting and integration

Primary integration decisions: grammar is basic lexical highlighting, with
context-sensitive word/operator roles documented as a limitation. Runtime code
keeps no protocol dependency; TextMate and installed-editor test tooling are
development dependencies. The extension is disabled in untrusted workspaces.
Use isolated, owned test workspace/profile directories. VS Code can retain a text
model after its tab closes, so the host test may use the documented language-change
close/open events to verify document lifecycle deterministically.

- [x] Register idle / Idle / .idl; lexical TextMate grammar for comments, all string
      styles/escapes, numbers/units, booleans/null, operators, annotations, names.
- [x] Configure comments, bracket pairs, single quotes; do not invent schema meaning.
- [x] Reuse kitchen-sink fixture for grammar/editor integration coverage.
- [x] Write package docs and Extension Host debug setup for build/config/tests/restart.
- [x] Update AGENTS navigation for new packages/toolchain.
- [x] Verify actual local extension against native server.
- [x] Sol reviews; Luna fixes findings; primary records evidence.

Evidence: Sol accepted Stage 6 after complete numeric-boundary/exponent matching,
TypeScript source maps, documentation, and style corrections. `pnpm test` passed
41/41 tests (including three TextMate tests), and `pnpm run typecheck` passed.
`pnpm run test:native` passed 2/2 subprocess suites, including UTF-8 offered after
UTF-16, rejection cases, kitchen-sink parsing, Unicode diagnostics/ranged repair,
close/reopen, and restart replay. Installed VS Code 1.141.0 ran the actual
Extension Host suite successfully: language association, fixture with a known
Unicode-adjacent error, exact editor diagnostic coordinates, repair, undo/redo,
diagnostic clearing on language-close, same-URI reopen, and fresh restart replay.
The host test exposed and fixed close-event handling when the event already has
the new language ID; unknown close URIs are safe no-ops in the client.

The harness creates and removes only verified per-run workspace/profile paths.
Primary removed the stale isolated profile from early harness attempts using
approved sandbox escalation; the test-data directory is empty. No normal editor
profile was modified by the integration tests.

## Final acceptance

Primary final native checks: both core and server passed Zig formatting,
Debug/ReleaseSafe test commands (cached), and package builds on Windows. Server
tests remain 50/50 from Stage 4; core source and API remain unchanged.

- [x] Framing: split/coalesced frames, UTF-8 lengths, invalid lengths, limits,
      malformed JSON, truncation, shutdown.
- [x] UTF-8 offered alone/with others accepted; missing/empty/UTF-16/UTF-32 rejected.
- [x] Positions: ASCII, accents, emoji, all newline styles, empty/EOF, zero-width,
      malformed bytes, clamping, scalar boundaries.
- [x] Edits: sequential, multiline strings/comments, rollback, skipped/stale versions,
      full replacements, unsynchronized recovery, close/reopen.
- [x] Allocation/nesting failures clean up and permit ranged recovery.
- [x] Client rejects stale diagnostics after edits/reopen/restart, cleans pending RPC.
- [x] Grammar distinguishes string/comment markers, marked strings, hex/exponent/units.
- [x] Native subprocess protocol tests and Extension Host end-to-end kitchen-sink
      diagnostics with Unicode-adjacent error, fix, restart.
- [x] Core/server Zig fmt and Debug/ReleaseSafe tests pass.
- [x] Extension build/typecheck/unit/integration checks pass.
- [x] Record actual Windows checks and unverified platforms honestly.
- [x] Inspect final diff for artifacts/unrelated changes; record final limitations.

Completion record: all runtime checks above were performed on Windows; Linux and
macOS runtime behavior has not been verified. The server uses incremental text
edits with full reparsing, UTF-8-only negotiation, and syntax-only diagnostics.
The extension requires a separately built local server and has a basic lexical
grammar with the contextual limitations described in its README. No binaries are
bundled or published, and no out-of-scope language features were added.

Primary inspected all 48 new files plus tracked changes for whitespace and the
final file list for artifacts. Caches, compiled output, dependencies, and test
profiles are ignored. Core/spec files remain unchanged, and the user's Node/pnpm
mise pins are preserved. `AGENTS.md` now describes the new package boundaries and
verification workflow. No push or publication occurred.

## Agent workflow

For each stage the primary gives GPT-6 Luna (high) the spec/plan requirements,
allowed files, conventions, acceptance checks, and stopping point. Luna implements
simple readable code following `.agents/alignment.md`. GPT-6.1 Sol (high) reviews
read-only for conformance, ownership, failure handling, maintainability, and evidence.
Neither sub-agent decides language behavior or architecture: gaps return to the
primary. Luna fixes approved findings before the next stage. Primary records
actual results and task completion. Use Conventional Commits when committing;
preserve unrelated user changes and do not push or publish without authorization.
