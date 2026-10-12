# VS Code TypeScript alignment

Status: complete. Follow the user's TypeScript corrections and
`.agents/alignment.md` entries 11–14. Preserve the completed LSP behavior and all
unrelated work. Luna (high) implements, Sol (high) reviews, primary owns decisions.

- [x] Upgrade to verified latest stable TypeScript (registry reports 7.0.2),
      replace legacy Node resolution, remove redundant activation events.
- [x] Rename maintained TypeScript files to dash-case and update references.
- [x] Move unit tests/helpers to sibling `tests/`, mirroring `src/`; put native
      subprocess tests under `tests/integration/` and VS Code host tests in `e2e/`.
- [x] Replace custom fake classes with focused `node:test` mocks, preserving
      lifecycle/failure coverage and avoiding a configurable fake framework.
- [x] Verify build/typecheck, unit/grammar tests, native subprocess tests, and
      actual installed VS Code Extension Host activation/integration.
- [x] Finish independent review, update navigation/docs, inspect final changes.

## Decisions and verification

Scope is `dev/idl-vscode` and its editor build/debug references. No Zig or language
changes. Each correction is implemented and reviewed before the next. Use modern
Node16 module and resolution settings while preserving CommonJS runtime behavior;
do not suppress deprecations. Registry version verification used
https://registry.npmjs.org/typescript/latest on 2026-10-11.

Record actual results below as work completes.

Stage 1 accepted by Sol: exact TypeScript 7.0.2 installed and locked, Node16 module
and resolution settings, explicit CommonJS package type, and redundant activation
events removed. Compiler version, frozen install, build, typecheck, and all 41
existing unit/grammar tests passed. Source behavior remained unchanged. Final
real Extension Host checks will verify contribution-derived activation.

Stage 2 accepted by Sol: all maintained TypeScript basenames and the configurable
TextMate grammar filename use dash-case; imports, manifest, scripts, grammar
loader, and host-runner references agree. Verified package-local generated output
was removed before rebuilding. Clean build/typecheck and all 41 unit/grammar tests
passed; searches found no stale filename references. No behavior or layout change.

Layout decision: one TypeScript configuration includes `src/`, `tests/`, and
`e2e/`, with package-root `rootDir` and output under `out/`. The extension entry
becomes `out/src/extension.js`; unit, native, and editor scripts explicitly select
their respective output trees. Tests for the external grammar live in
`tests/syntaxes/`; no custom test runner is needed for unit discovery.

Stage 3 accepted by Sol: directory moves and all compiled entry, import, script,
fixture, grammar, server, and debug paths agree. Production remains only in
`src/`. Clean build/typecheck, 41 unit/grammar tests, and 2 native subprocess tests
passed. Actual editor execution is deferred to the final mock-refactor check.

Mock-refactor scope: replace the custom transport and child-process fakes with
test-context mock functions and focused event/deferred helpers. Keep per-scenario
behavior in the tests instead of a configurable fake framework. Remove the two
tests of the deleted in-memory fake itself; preserve all production-behavior
regressions. This can reduce the fast test count from 41 to 39 without losing
production coverage.

Stage 4 and final task accepted by Sol: test-context mock functions replace the
fake classes and counters. Shared helpers only wire subscriptions; failure and
deferred-response behavior is configured in individual tests. Stdio tests use
real EventEmitter/PassThrough instances with a mocked kill function. Named return
objects and visual spacing were also corrected in the rewritten tests.

Final verification on Windows: TypeScript reports 7.0.2; build/typecheck and
39/39 fast tests pass. The moved native suite passed 2/2 tests in Stage 3. Actual
installed VS Code 1.141.0 successfully ran the relocated `e2e/` suite against
the new CommonJS entry point and contribution-derived activation. Initial
sandboxed process launch returned EPERM; the same test passed with approved
escalation. The harness cleaned its isolated per-run profiles and workspaces.
Linux and macOS execution was not reverified in this correction task.

Primary compared test-name catalogs: only the two authorized fake self-tests were
removed. A maintained-TypeScript scan found no old fake classes/references or
inline object-return constructions. Whitespace checks passed across 47 new files
and existing tracked changes; generated artifacts remain ignored. Alignment
entries 11–14, AGENTS navigation/conventions, and the README document the result.
No Zig, language specification, or mise changes were made by this follow-up.
Existing unrelated work was preserved. No push or publication occurred.
