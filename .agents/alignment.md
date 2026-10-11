# Alignment

A running log of explicit user corrections for this project. These entries can
later be extracted into skills or reusable context.

Record each correction in the user's intended scope. Include the reason and a
before/after example when provided or useful; distinguish interpretation from
what the user explicitly requested. Preserve earlier entries when a later
correction refines or supersedes them.

## Entry format

- **Area:** Code style, architecture, workflow, communication, or another topic.
- **Correction:** The behavior to follow going forward.
- **Scope:** Where the correction applies.
- **Reason or example:** Optional supporting context.

## Corrections

These corrections apply throughout maintained project code, including source,
tests, build files, and code examples. The examples below are illustrative;
apply the intent rather than mechanically renaming or rearranging expressions.
Generated files and third-party code are excluded.

### 1. Name the meaning of complex conditions

**Issue:** Compound comparisons, arithmetic, and boolean expressions inside a
condition hide its purpose. Understanding a guard should not require tracing its
callers or mentally evaluating several operations.

**Correction:** Extract meaningful intermediate values and predicates before the
condition. More than two or three comparisons or expression parts is a useful
signal to split the expression; also name shorter conditions whose intent is
unclear. Names must describe the domain or safety guarantee, not just the syntax.

**Why:** Readability and clear intent take priority over skipping a few cheap
checks. Optimize measured hot loops separately and explain any resulting
complexity with comments.

Before:

```zig
if (raw_span.start > source.len or raw_span.len > source.len - raw_span.start) {
    return .{ .decoded = null, .diagnostics = &.{} };
}
```

After:

```zig
const is_span_start_in_bounds = raw_span.start <= source.len;
var is_valid_span = false;
if (is_span_start_in_bounds) {
    const remaining_source_len = source.len - raw_span.start;
    is_valid_span = raw_span.len <= remaining_source_len;
}

if (!is_valid_span) {
    const result: DecodeResult = .{
        .decoded = null,
        .diagnostics = &.{},
    };
    return result;
}
```

**Safety clarification:** Zig's `and` and `or` short-circuit. Preserve that safety
when extracting expressions: subtraction, indexing, and optional unwrapping must
remain guarded by their prerequisites. Here, the span start must be in bounds
before subtracting it from the source length. The rejecting branch tests
`!is_valid_span`; testing `is_valid_span` would reverse the intended behavior.

### 2. Construct return objects in named locals

**Issue:** Returning a newly constructed struct directly combines construction
and function exit on one line.

**Correction:** Construct the result in a named, appropriately typed local, then
return that local. Apply this to inline struct/aggregate construction within
return expressions as well. Ordinary delegation to another function does not
need an artificial local unless construction or debugging benefits from it.

**Why:** A separate construction statement is easier to place a breakpoint on,
step through, and inspect before the function returns.

Before:

```zig
return .{ .decoded = null, .diagnostics = finished_diagnostics };
```

After:

```zig
const result: DecodeResult = .{
    .decoded = null,
    .diagnostics = finished_diagnostics,
};
return result;
```

Use `const` for a local that is never reassigned, as Zig requires, and `var` for
one that is mutated. The important correction is the named, inspectable local.

### 3. Use multiline struct and object definitions

**Issue:** Inline field initializers crowd several pieces of state onto one line,
including nested initializers and objects passed to functions.

**Correction:** Put nonempty struct/object fields on separate lines, including
nested constructions. Use trailing commas so Zig formatting preserves the layout.
Empty initializers (`.{}`) and named constants such as `.empty` have no fields to
split; scalar array/list literals are not struct definitions.

**Why:** Each field becomes easy to read, inspect, change, and review independently.

Before:

```zig
const span: text.TextSpan = .{ .start = index, .len = length };
```

After:

```zig
const span: text.TextSpan = .{
    .start = index,
    .len = length,
};
```

### 4. Prefer statements to if/else expressions

**Issue:** Zig's expression-form `if/else` compresses branching into a value
expression and readily grows into a line with high cognitive load.

**Correction:** In general, initialize a variable and use explicit braced
`if`/`else` statements to assign it. Preserve evaluation order, types, and safety.
Do not replace an if-expression with an equally dense expression of another kind.

**Why:** The default value and the condition that changes it are visible as
separate steps, making control flow easier to follow and debug.

Before:

```zig
const marker_len: usize = if (style == .ordinary) 0 else 1;
```

After:

```zig
var marker_len: usize = 1;
if (style == .ordinary) {
    marker_len = 0;
}
```

### 5. Give control-flow constructs explicit bodies

**Issue:** Single-line bodies hide actions inside control-flow syntax and make
breakpoints and later edits awkward.

**Correction:** Use braced bodies for `if`, `else`, loops, `defer`, and `errdefer`
and other applicable block-based constructs. Expand nested control flow clearly.

**Why:** Explicit blocks make the condition, action, cleanup, and exit separate
steps and keep the style consistent as the code grows.

Before:

```zig
errdefer if (finished_diagnostics.len > 0) allocator.free(finished_diagnostics);
if (!valid) return .{ .decoded = null, .diagnostics = finished_diagnostics };
```

After:

```zig
errdefer {
    if (finished_diagnostics.len > 0) {
        allocator.free(finished_diagnostics);
    }
}

if (!valid) {
    const result: DecodeResult = .{
        .decoded = null,
        .diagnostics = finished_diagnostics,
    };
    return result;
}
```

### 6. Name the valid state and reject invalid states early

**Issue:** Negative predicate names make a reader reason about an error state or
untangle double negatives. Nesting the main work inside a success branch also
obscures the valid path.

**Correction:** Prefer predicates named for the positive, valid state, such as
`is_valid_span`, `is_in_bounds`, or `has_value`. Negate that predicate in a guard
clause that exits early when the requirement is not met. Eliminate invalid states
first so the rest of the function can operate on validated inputs with less
nesting. This applies to validation predicates, not diagnostic codes or syntax
variants whose purpose is explicitly to represent an error.

**Why:** The code should read as a sequence of questions and prerequisites:
"Is my span valid? If not, return an empty result. Otherwise, continue with a
valid span." Positive names and early exits make that reasoning direct.

Before:

```zig
const is_invalid_span = raw_span.len > remaining_source_len;
if (is_invalid_span) {
    return empty_result;
}
```

After:

```zig
const is_valid_span = raw_span.len <= remaining_source_len;
if (!is_valid_span) {
    return empty_result;
}

// The rest of the function can rely on the span being valid.
```

In this example, `remaining_source_len` is calculated only after validating the
span start, as described in correction 1. Early guards must preserve safety
prerequisites and existing cleanup on every exit path.

### 7. Use blank lines to separate logical steps

**Issue:** Adjacent validation blocks, cleanup declarations, and return statements
can visually run together. Without a pause, the reader has to infer where one
operational step ends and the next begins.

**Correction:** Group related statements into visible steps within a function.
Keep the calculations and positive predicate for a check together with its guard,
then leave a blank line before the next check or task. In general, leave a blank
line after a completed `if`, loop, `defer`, `errdefer`, or similar statement when
another step follows. Give a return visual separation from preceding construction
or computation. Keep related setup and its paired normal `defer` together; the
cleanup registration completes that creation step. An `errdefer` usually stands
apart as an error-cleanup hook, with blank lines around it, though close pairing
can be appropriate in context.

**Why:** Whitespace creates a visual pause and communicates the function's steps.
Validation, resource creation, cleanup registration, and exit are easier to scan
when their visual grouping matches their purpose.

**Scope:** All maintained code and code examples, consistent with the earlier
corrections. This refines the spacing of earlier examples; their original forms
remain in this log to preserve the history of each correction.

Before:

```zig
const finished_diagnostics = try diagnostic_list.toOwnedSlice(allocator);
errdefer {
    if (finished_diagnostics.len > 0) {
        allocator.free(finished_diagnostics);
    }
}
if (!is_valid_content) {
    const result: DecodeResult = .{
        .decoded = null,
        .diagnostics = finished_diagnostics,
    };
    return result;
}
```

After:

```zig
const finished_diagnostics = try diagnostic_list.toOwnedSlice(allocator);

errdefer {
    if (finished_diagnostics.len > 0) {
        allocator.free(finished_diagnostics);
    }
}

if (!is_valid_content) {
    const result: DecodeResult = .{
        .decoded = null,
        .diagnostics = finished_diagnostics,
    };

    return result;
}
```

Separate successive validation steps while keeping each predicate with its guard:

```zig
const brace = next + 1;
const is_brace_position_in_bounds = brace < end;
if (!is_brace_position_in_bounds) {
    const result: EscapeValidation = .{
        .valid = false,
        .next = brace,
    };

    return result;
}

const has_opening_brace = source[brace] == '{';
if (!has_opening_brace) {
    const result: EscapeValidation = .{
        .valid = false,
        .next = brace,
    };

    return result;
}
```

Keep resource creation and its normal cleanup registration in the same group:

```zig
const layout = try buildLayout(allocator, source, content_start, content_end, style);
defer {
    allocator.free(layout);
}

const decoded = try decodeValidContent(allocator, layout);
```

**Application guidance:** Use the meaning of the statements to choose groups;
do not insert a blank line after every statement or every closing brace. Avoid
padding the start or end of a block, splitting `if` from its `else`, or separating
a predicate from its guard. Blank lines do not change scope or cleanup order.

### 8. Declare file-level aliases for imported types and namespaces

**Issue:** Repeating fully qualified names such as `std.mem.Allocator`,
`std.ArrayList`, and `std.testing.expectEqual` throughout a file adds visual noise.
The reader repeatedly encounters the import path instead of the operation or type.

**Correction:** Treat the types and utility namespaces a file uses as imports:
declare descriptive top-level `const` aliases, then use those aliases throughout
the file. Keep the dependency paths in the import section instead of repeating
them in signatures, local declarations, and call sites.

**Why:** Shorter, recognizable names make the actual work easier to scan, while
the file-level declarations keep the dependencies explicit and easy to find.

**Scope:** Maintained source, tests, build files, and code examples. Preserve public
API declarations and existing short project-module aliases; this is a readability
change, not an API redesign.

Before:

```zig
const std = @import("std");

fn checkBuffer(allocator: std.mem.Allocator) !void {
    var bytes: std.ArrayList(u8) = .empty;
    defer {
        bytes.deinit(allocator);
    }

    try bytes.append(allocator, 'a');
    try std.testing.expectEqual(@as(usize, 1), bytes.items.len);
}
```

After:

```zig
const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing = std.testing;

fn checkBuffer(allocator: Allocator) !void {
    var bytes: ArrayList(u8) = .empty;
    defer {
        bytes.deinit(allocator);
    }

    try bytes.append(allocator, 'a');
    try testing.expectEqual(@as(usize, 1), bytes.items.len);
}
```

**Application used here:** Alias types and generic types directly (`Allocator`,
`ArenaAllocator`, `ArrayList`, `Build`), and utility namespaces at their useful
level (`testing`, `mem`, `math`, `unicode`, `meta`, `debug`). Keep related utility
calls recognizable as `testing.expectEqual` or `mem.eql`; there is no need to
flatten every function into a separate import. Declare only aliases actually used
by that file, use private aliases unless an existing public export requires
otherwise, and check for shadowing. Keep `std` available for the alias declarations.

### 9. Use Conventional Commits

**Issue:** Free-form commit subjects make the purpose and category of a change
harder to scan consistently in the project history.

**Correction:** Use Conventional Commits for project commits:
`type(scope): concise description`, with an optional scope. Choose the type and
scope for the actual change. Use the body for context and verification when useful.

**Why:** A consistent commit structure makes changes easier to understand and
provides a useful history for future work and tooling.

**Scope:** All future project commits. The repository's `AGENTS.md` also documents
this convention alongside the established implementation and review workflow.

Before:

```text
finish parser work and docs
```

After:

```text
feat(core): implement the Idle configuration language
```
