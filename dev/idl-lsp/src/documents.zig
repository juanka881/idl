//! Session-owned document snapshots and transactional content changes.
//!
//! URI, text, and line-index slices belong to the store allocator. Incoming
//! changes borrow text from the dispatch arena only while a proposal is built.
//! The optional core tree is owned by the document and destroyed on change or
//! close. No protocol output is produced by this module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const math = std.math;
const mem = std.mem;
const unicode = std.unicode;
const idl = @import("idl");
const lsp = @import("lsp.zig");
const positions = @import("positions.zig");
const FailingAllocator = std.testing.FailingAllocator;
const testing = std.testing;

pub const ParseTree = *idl.Document;

pub const OpenOutcome = enum {
    opened,
    duplicate,
};

pub const UpdateOutcome = enum {
    updated,
    stale,
    unknown_uri,
    invalid_update,
};

pub const MarkOutcome = enum {
    marked_unsynchronized,
    stale,
    unknown_uri,
};

pub const Document = struct {
    uri: []u8,
    text: []u8,
    line_map: []positions.Line,
    committed_version: i32,
    highest_observed_version: i32,
    is_synchronized: bool,
    tree: ?ParseTree = null,

    fn deinit(self: *Document, allocator: Allocator) void {
        destroyTree(self);
        allocator.free(self.uri);
        allocator.free(self.text);
        allocator.free(self.line_map);
    }
};

pub const Store = struct {
    allocator: Allocator,
    entries: ArrayList(Document) = .empty,

    pub fn init(allocator: Allocator) Store {
        const store: Store = .{
            .allocator = allocator,
        };

        return store;
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |*document| {
            document.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn open(
        self: *Store,
        uri: []const u8,
        version: i32,
        text: []const u8,
    ) OpenError!OpenOutcome {
        if (self.findIndex(uri) != null) {
            return .duplicate;
        }

        const snapshot = try buildSnapshot(self.allocator, text);
        errdefer {
            self.allocator.free(snapshot.text);
            self.allocator.free(snapshot.line_map);
        }

        const owned_uri = self.allocator.dupe(u8, uri) catch {
            return error.OutOfMemory;
        };
        errdefer {
            self.allocator.free(owned_uri);
        }

        const document: Document = .{
            .uri = owned_uri,
            .text = snapshot.text,
            .line_map = snapshot.line_map,
            .committed_version = version,
            .highest_observed_version = version,
            .is_synchronized = true,
        };
        self.entries.append(self.allocator, document) catch {
            return error.OutOfMemory;
        };

        return .opened;
    }

    pub fn parseCurrent(self: *Store, uri: []const u8) ParseCurrentError!void {
        const maybe_document = self.get(uri);
        if (maybe_document == null) {
            return error.UnknownUri;
        }

        const document = maybe_document.?;
        destroyTree(document);
        const tree = try idl.parse(self.allocator, document.text);
        document.tree = tree;
    }

    pub fn applyChanges(
        self: *Store,
        uri: []const u8,
        version: i32,
        changes: []const lsp.Change,
    ) Allocator.Error!UpdateOutcome {
        const maybe_index = self.findIndex(uri);
        if (maybe_index == null) {
            return .unknown_uri;
        }

        const index = maybe_index.?;
        const document = &self.entries.items[index];
        if (version <= document.highest_observed_version) {
            return .stale;
        }

        const must_recover_with_full_replace = !document.is_synchronized;
        if (must_recover_with_full_replace and !startsWithFullReplacement(changes)) {
            advanceAndUnsynchronize(document, version);
            return .invalid_update;
        }

        const proposal = buildProposal(self.allocator, document.text, changes) catch |err| {
            advanceAndUnsynchronize(document, version);
            if (err == error.InvalidUpdate) {
                return .invalid_update;
            }

            return error.OutOfMemory;
        };

        self.allocator.free(document.text);
        self.allocator.free(document.line_map);
        destroyTree(document);
        document.text = proposal.text;
        document.line_map = proposal.line_map;
        document.committed_version = version;
        document.highest_observed_version = version;
        document.is_synchronized = true;

        return .updated;
    }

    pub fn markUnsynchronized(self: *Store, uri: []const u8, version: ?i32) MarkOutcome {
        const maybe_index = self.findIndex(uri);
        if (maybe_index == null) {
            return .unknown_uri;
        }

        const index = maybe_index.?;
        const document = &self.entries.items[index];
        if (version) |observed_version| {
            if (observed_version <= document.highest_observed_version) {
                return .stale;
            }

            document.highest_observed_version = observed_version;
        }

        document.is_synchronized = false;
        destroyTree(document);

        return .marked_unsynchronized;
    }

    pub fn isStale(self: *const Store, uri: []const u8, version: i32) bool {
        const maybe_index = self.findIndex(uri);
        if (maybe_index == null) {
            return false;
        }

        const document = self.entries.items[maybe_index.?];
        return version <= document.highest_observed_version;
    }

    pub fn get(self: *Store, uri: []const u8) ?*Document {
        const maybe_index = self.findIndex(uri);
        if (maybe_index == null) {
            return null;
        }

        return &self.entries.items[maybe_index.?];
    }

    pub fn close(self: *Store, uri: []const u8) ?i32 {
        const maybe_index = self.findIndex(uri);
        if (maybe_index == null) {
            return null;
        }

        const index = maybe_index.?;
        var document = self.entries.orderedRemove(index);
        const closed_version = document.highest_observed_version;
        document.deinit(self.allocator);

        return closed_version;
    }

    fn findIndex(self: *const Store, uri: []const u8) ?usize {
        for (self.entries.items, 0..) |document, index| {
            if (mem.eql(u8, document.uri, uri)) {
                return index;
            }
        }

        return null;
    }
};

pub const OpenError = error{
    OutOfMemory,
    InvalidText,
};

pub const ParseCurrentError = error{
    UnknownUri,
    OutOfMemory,
    SourceTooLarge,
    NestingLimitExceeded,
};

const Snapshot = struct {
    text: []u8,
    line_map: []positions.Line,
};

fn buildSnapshot(allocator: Allocator, text: []const u8) OpenError!Snapshot {
    if (!unicode.utf8ValidateSlice(text)) {
        return error.InvalidText;
    }

    const owned_text = allocator.dupe(u8, text) catch {
        return error.OutOfMemory;
    };
    errdefer {
        allocator.free(owned_text);
    }

    const line_map = positions.buildLineMap(allocator, owned_text) catch {
        return error.OutOfMemory;
    };
    errdefer {
        allocator.free(line_map);
    }

    const snapshot: Snapshot = .{
        .text = owned_text,
        .line_map = line_map,
    };

    return snapshot;
}

fn buildProposal(
    allocator: Allocator,
    committed_text: []const u8,
    changes: []const lsp.Change,
) error{ OutOfMemory, InvalidUpdate }!Snapshot {
    var working_text = allocator.dupe(u8, committed_text) catch {
        return error.OutOfMemory;
    };
    errdefer {
        allocator.free(working_text);
    }

    for (changes) |change| {
        if (!unicode.utf8ValidateSlice(change.text)) {
            return error.InvalidUpdate;
        }

        if (change.range) |range| {
            const line_map = positions.buildLineMap(allocator, working_text) catch {
                return error.OutOfMemory;
            };

            const offsets = positions.rangeToOffsets(working_text, line_map, range) catch |err| {
                allocator.free(line_map);
                if (err == error.OutOfMemory) {
                    return error.OutOfMemory;
                }

                return error.InvalidUpdate;
            };
            allocator.free(line_map);

            const prefix_length = offsets.start;
            const suffix_length = working_text.len - offsets.end;
            const length_with_replacement = math.add(usize, prefix_length, change.text.len) catch {
                return error.OutOfMemory;
            };
            const proposed_length = math.add(usize, length_with_replacement, suffix_length) catch {
                return error.OutOfMemory;
            };
            const proposed_text = allocator.alloc(u8, proposed_length) catch {
                return error.OutOfMemory;
            };

            @memcpy(proposed_text[0..prefix_length], working_text[0..offsets.start]);
            @memcpy(
                proposed_text[prefix_length..length_with_replacement],
                change.text,
            );
            @memcpy(
                proposed_text[length_with_replacement..],
                working_text[offsets.end..],
            );

            allocator.free(working_text);
            working_text = proposed_text;
            continue;
        }

        const replacement_text = allocator.dupe(u8, change.text) catch {
            return error.OutOfMemory;
        };
        allocator.free(working_text);
        working_text = replacement_text;
    }

    const line_map = positions.buildLineMap(allocator, working_text) catch {
        return error.OutOfMemory;
    };
    const proposal: Snapshot = .{
        .text = working_text,
        .line_map = line_map,
    };

    return proposal;
}

fn startsWithFullReplacement(changes: []const lsp.Change) bool {
    if (changes.len == 0) {
        return false;
    }

    return changes[0].range == null;
}

fn advanceAndUnsynchronize(document: *Document, version: i32) void {
    document.highest_observed_version = version;
    document.is_synchronized = false;
    destroyTree(document);
}

fn destroyTree(document: *Document) void {
    if (document.tree) |tree| {
        tree.destroy();
        document.tree = null;
    }
}

test "store owns opened snapshots and close removes all URI state" {
    const allocator = testing.allocator;
    var store = Store.init(allocator);
    defer {
        store.deinit();
    }

    const source = try allocator.dupe(u8, "one\r\ntwo");
    defer {
        allocator.free(source);
    }
    try testing.expectEqual(OpenOutcome.opened, try store.open("file:///a.idl", 1, source));
    source[0] = 'X';

    const document = store.get("file:///a.idl").?;
    try testing.expectEqualStrings("one\r\ntwo", document.text);
    try testing.expectEqual(@as(usize, 2), document.line_map.len);
    try testing.expectEqual(@as(i32, 1), document.committed_version);
    document.tree = try idl.parse(allocator, "tree to destroy");

    try testing.expectEqual(@as(?i32, 1), store.close("file:///a.idl"));
    try testing.expect(store.get("file:///a.idl") == null);
    try testing.expect(store.close("file:///a.idl") == null);
}

test "change batches commit sequential ranges and full replacements atomically" {
    const allocator = testing.allocator;
    var store = Store.init(allocator);
    defer {
        store.deinit();
    }
    try testing.expectEqual(OpenOutcome.opened, try store.open("file:///a.idl", 2, "abc\ndef"));
    store.get("file:///a.idl").?.tree = try idl.parse(allocator, "old tree");

    const first_change: lsp.Change = .{
        .range = .{
            .start = .{
                .line = 0,
                .character = 1,
            },
            .end = .{
                .line = 0,
                .character = 2,
            },
        },
        .text = "XYZ",
    };
    const second_change: lsp.Change = .{
        .range = .{
            .start = .{
                .line = 0,
                .character = 4,
            },
            .end = .{
                .line = 0,
                .character = 5,
            },
        },
        .text = "!",
    };
    const changes = [_]lsp.Change{ first_change, second_change };

    try testing.expectEqual(UpdateOutcome.updated, try store.applyChanges("file:///a.idl", 8, &changes));
    const document = store.get("file:///a.idl").?;
    try testing.expectEqualStrings("aXYZ!\ndef", document.text);
    try testing.expectEqual(@as(i32, 8), document.committed_version);
    try testing.expect(document.tree == null);

    const replacement: lsp.Change = .{
        .range = null,
        .text = "fresh\rtext",
    };
    const replace_after_full: lsp.Change = .{
        .range = .{
            .start = .{
                .line = 0,
                .character = 1,
            },
            .end = .{
                .line = 0,
                .character = 2,
            },
        },
        .text = "R",
    };
    const replacement_batch = [_]lsp.Change{ replacement, replace_after_full };
    try testing.expectEqual(UpdateOutcome.updated, try store.applyChanges("file:///a.idl", 12, &replacement_batch));
    try testing.expectEqualStrings("fResh\rtext", store.get("file:///a.idl").?.text);
}

test "sequential physical-line changes edit multiline strings and block comments" {
    const allocator = testing.allocator;
    var store = Store.init(allocator);
    defer {
        store.deinit();
    }

    const initial_text = "server title='first\némoji 😀\nlast' /*\ncomment café\nnext\n*/ port=8080";
    try testing.expectEqual(OpenOutcome.opened, try store.open("file:///multiline.idl", 1, initial_text));

    const string_edit: lsp.Change = .{
        .range = .{
            .start = .{
                .line = 1,
                .character = 7,
            },
            .end = .{
                .line = 1,
                .character = 11,
            },
        },
        .text = "🌎",
    };
    const comment_edit: lsp.Change = .{
        .range = .{
            .start = .{
                .line = 3,
                .character = 8,
            },
            .end = .{
                .line = 3,
                .character = 13,
            },
        },
        .text = "crème",
    };
    const changes = [_]lsp.Change{
        string_edit,
        comment_edit,
    };

    try testing.expectEqual(UpdateOutcome.updated, try store.applyChanges("file:///multiline.idl", 2, &changes));
    const document = store.get("file:///multiline.idl").?;
    try testing.expectEqualStrings("server title='first\némoji 🌎\nlast' /*\ncomment crème\nnext\n*/ port=8080", document.text);
    try testing.expectEqual(@as(i32, 2), document.committed_version);
}

test "empty, skipped, and stale versions follow the observed watermark" {
    const allocator = testing.allocator;
    var store = Store.init(allocator);
    defer {
        store.deinit();
    }
    try testing.expectEqual(OpenOutcome.opened, try store.open("file:///a.idl", 1, "text"));

    try testing.expectEqual(UpdateOutcome.updated, try store.applyChanges("file:///a.idl", 4, &.{}));
    try testing.expectEqual(UpdateOutcome.stale, try store.applyChanges("file:///a.idl", 4, &.{}));
    try testing.expectEqual(UpdateOutcome.updated, try store.applyChanges("file:///a.idl", 9, &.{}));
    const document = store.get("file:///a.idl").?;
    try testing.expectEqualStrings("text", document.text);
    try testing.expectEqual(@as(i32, 9), document.highest_observed_version);
}

test "invalid batches roll back and unsynchronized documents require a full replace" {
    const allocator = testing.allocator;
    var store = Store.init(allocator);
    defer {
        store.deinit();
    }
    try testing.expectEqual(OpenOutcome.opened, try store.open("file:///a.idl", 1, "abc"));
    store.get("file:///a.idl").?.tree = try idl.parse(allocator, "old tree");

    const good_change: lsp.Change = .{
        .range = .{
            .start = .{
                .line = 0,
                .character = 0,
            },
            .end = .{
                .line = 0,
                .character = 1,
            },
        },
        .text = "A",
    };
    const bad_change: lsp.Change = .{
        .range = .{
            .start = .{
                .line = 4,
                .character = 0,
            },
            .end = .{
                .line = 4,
                .character = 1,
            },
        },
        .text = "B",
    };
    const invalid_batch = [_]lsp.Change{ good_change, bad_change };

    try testing.expectEqual(UpdateOutcome.invalid_update, try store.applyChanges("file:///a.idl", 3, &invalid_batch));
    var document = store.get("file:///a.idl").?;
    try testing.expect(document.tree == null);
    try testing.expectEqualStrings("abc", document.text);
    try testing.expectEqual(@as(i32, 1), document.committed_version);
    try testing.expectEqual(@as(i32, 3), document.highest_observed_version);
    try testing.expect(!document.is_synchronized);

    const ranged_change: lsp.Change = .{
        .range = .{
            .start = .{
                .line = 0,
                .character = 0,
            },
            .end = .{
                .line = 0,
                .character = 1,
            },
        },
        .text = "A",
    };
    try testing.expectEqual(UpdateOutcome.invalid_update, try store.applyChanges("file:///a.idl", 4, &.{ranged_change}));
    try testing.expectEqualStrings("abc", document.text);
    try testing.expectEqual(@as(i32, 4), document.highest_observed_version);

    const full_change: lsp.Change = .{
        .range = null,
        .text = "replacement",
    };
    try testing.expectEqual(UpdateOutcome.updated, try store.applyChanges("file:///a.idl", 5, &.{full_change}));
    document = store.get("file:///a.idl").?;
    try testing.expectEqualStrings("replacement", document.text);
    try testing.expect(document.is_synchronized);
}

test "reversed normalized ranges and split UTF-8 scalars are invalid" {
    const allocator = testing.allocator;
    var store = Store.init(allocator);
    defer {
        store.deinit();
    }
    try testing.expectEqual(OpenOutcome.opened, try store.open("file:///a.idl", 1, "aé😀z"));

    const split_scalar: lsp.Change = .{
        .range = .{
            .start = .{
                .line = 0,
                .character = 2,
            },
            .end = .{
                .line = 0,
                .character = 4,
            },
        },
        .text = "x",
    };
    try testing.expectEqual(UpdateOutcome.invalid_update, try store.applyChanges("file:///a.idl", 2, &.{split_scalar}));
    try testing.expectEqualStrings("aé😀z", store.get("file:///a.idl").?.text);

    const clamped_reversed: lsp.Change = .{
        .range = .{
            .start = .{
                .line = 0,
                .character = 100,
            },
            .end = .{
                .line = 0,
                .character = 1,
            },
        },
        .text = "x",
    };
    try testing.expectEqual(UpdateOutcome.invalid_update, try store.applyChanges("file:///a.idl", 3, &.{clamped_reversed}));
}

test "malformed notification invalidation preserves text and stale malformed updates do nothing" {
    const allocator = testing.allocator;
    var store = Store.init(allocator);
    defer {
        store.deinit();
    }
    try testing.expectEqual(OpenOutcome.opened, try store.open("file:///a.idl", 5, "before"));

    try testing.expectEqual(MarkOutcome.marked_unsynchronized, store.markUnsynchronized("file:///a.idl", null));
    const document = store.get("file:///a.idl").?;
    try testing.expectEqual(@as(i32, 5), document.highest_observed_version);
    try testing.expect(!document.is_synchronized);
    try testing.expectEqual(MarkOutcome.stale, store.markUnsynchronized("file:///a.idl", 5));
    try testing.expectEqual(MarkOutcome.marked_unsynchronized, store.markUnsynchronized("file:///a.idl", 7));
    try testing.expectEqualStrings("before", document.text);
    try testing.expectEqual(@as(i32, 7), document.highest_observed_version);
    try testing.expect(!document.is_synchronized);

    try testing.expectEqual(MarkOutcome.stale, store.markUnsynchronized("file:///a.idl", 6));
    try testing.expectEqual(MarkOutcome.marked_unsynchronized, store.markUnsynchronized("file:///a.idl", null));
    try testing.expectEqual(@as(i32, 7), document.highest_observed_version);

    try testing.expectEqual(@as(?i32, 7), store.close("file:///a.idl"));
    try testing.expectEqual(OpenOutcome.opened, try store.open("file:///a.idl", -2, "reopened"));
    const reopened_document = store.get("file:///a.idl").?;
    try testing.expect(reopened_document.is_synchronized);
    try testing.expectEqual(@as(i32, -2), reopened_document.committed_version);
    try testing.expectEqual(@as(i32, -2), reopened_document.highest_observed_version);
}

test "invalid UTF-8 opens never add a partial document" {
    const allocator = testing.allocator;
    var store = Store.init(allocator);
    defer {
        store.deinit();
    }

    try testing.expectError(error.InvalidText, store.open("file:///invalid.idl", 1, "bad\xff"));
    try testing.expect(store.get("file:///invalid.idl") == null);
}

test "duplicate opens and unknown updates are harmless" {
    const allocator = testing.allocator;
    var store = Store.init(allocator);
    defer {
        store.deinit();
    }

    try testing.expectEqual(OpenOutcome.opened, try store.open("file:///a.idl", 1, "one"));
    try testing.expectEqual(OpenOutcome.duplicate, try store.open("file:///a.idl", 2, "two"));
    try testing.expectEqual(UpdateOutcome.unknown_uri, try store.applyChanges("file:///missing.idl", 2, &.{}));
    try testing.expectEqualStrings("one", store.get("file:///a.idl").?.text);
}

test "open allocation failures leave no partial entry or leaked storage" {
    const input_text = "first\r\nsecond";
    var successful_allocator = FailingAllocator.init(testing.allocator, .{});
    var successful_store = Store.init(successful_allocator.allocator());
    try testing.expectEqual(OpenOutcome.opened, try successful_store.open("file:///a.idl", 1, input_text));
    const allocation_count = successful_allocator.alloc_index;
    successful_store.deinit();
    try testing.expectEqual(successful_allocator.allocations, successful_allocator.deallocations);

    for (0..allocation_count) |fail_index| {
        var failing_allocator = FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var store = Store.init(failing_allocator.allocator());
        const result = store.open("file:///a.idl", 1, input_text);
        if (result) |outcome| {
            try testing.expectEqual(OpenOutcome.opened, outcome);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(store.get("file:///a.idl") == null);
        }

        store.deinit();
        try testing.expectEqual(failing_allocator.allocations, failing_allocator.deallocations);
    }
}

test "proposal allocation failures preserve committed text and invalidate synchronization" {
    const allocator = testing.allocator;
    const change: lsp.Change = .{
        .range = .{
            .start = .{
                .line = 0,
                .character = 1,
            },
            .end = .{
                .line = 0,
                .character = 2,
            },
        },
        .text = "replacement",
    };
    const changes = [_]lsp.Change{change};

    var successful_allocator = FailingAllocator.init(allocator, .{});
    var successful_store = Store.init(successful_allocator.allocator());
    try testing.expectEqual(OpenOutcome.opened, try successful_store.open("file:///a.idl", 1, "abc"));
    const first_proposal_allocation = successful_allocator.alloc_index;
    try testing.expectEqual(UpdateOutcome.updated, try successful_store.applyChanges("file:///a.idl", 4, &changes));
    const allocation_count = successful_allocator.alloc_index;
    successful_store.deinit();
    try testing.expectEqual(successful_allocator.allocations, successful_allocator.deallocations);

    for (first_proposal_allocation..allocation_count) |fail_index| {
        var failing_allocator = FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
        });
        var store = Store.init(failing_allocator.allocator());
        try testing.expectEqual(OpenOutcome.opened, try store.open("file:///a.idl", 1, "abc"));
        const result = store.applyChanges("file:///a.idl", 4, &changes);
        if (result) |outcome| {
            try testing.expectEqual(UpdateOutcome.updated, outcome);
            try testing.expect(!failing_allocator.has_induced_failure);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing_allocator.has_induced_failure);
            const document = store.get("file:///a.idl").?;
            try testing.expectEqualStrings("abc", document.text);
            try testing.expectEqual(@as(i32, 1), document.committed_version);
            try testing.expectEqual(@as(i32, 4), document.highest_observed_version);
            try testing.expect(!document.is_synchronized);
        }

        store.deinit();
        try testing.expectEqual(failing_allocator.allocations, failing_allocator.deallocations);
    }
}

test "fatal parsing retains synchronized text and ranged edits can recover" {
    const allocator = testing.allocator;
    const source = try makeNestedSource(allocator, 257);
    defer {
        allocator.free(source);
    }

    var store = Store.init(allocator);
    defer {
        store.deinit();
    }
    try testing.expectEqual(OpenOutcome.opened, try store.open("file:///nested.idl", 1, source));
    try testing.expectError(error.NestingLimitExceeded, store.parseCurrent("file:///nested.idl"));

    const fatal_document = store.get("file:///nested.idl").?;
    try testing.expect(fatal_document.is_synchronized);
    try testing.expectEqual(@as(i32, 1), fatal_document.committed_version);
    try testing.expect(fatal_document.tree == null);

    const remove_outer_body: lsp.Change = .{
        .range = .{
            .start = .{
                .line = 0,
                .character = 0,
            },
            .end = .{
                .line = 0,
                .character = 6,
            },
        },
        .text = "",
    };
    try testing.expectEqual(UpdateOutcome.updated, try store.applyChanges("file:///nested.idl", 2, &.{remove_outer_body}));
    try testing.expect(fatal_document.tree == null);
    try testing.expect(fatal_document.is_synchronized);
    try store.parseCurrent("file:///nested.idl");

    const recovered_document = store.get("file:///nested.idl").?;
    try testing.expect(recovered_document.tree != null);
    try testing.expect(recovered_document.is_synchronized);
    try testing.expectEqual(@as(i32, 2), recovered_document.committed_version);
}

test "parse allocation failures leave no tree and release all allocations" {
    const allocator = testing.allocator;
    const uri = "file:///parse.idl";
    const source = "node key=1";

    var successful_allocator = FailingAllocator.init(allocator, .{});
    var successful_store = Store.init(successful_allocator.allocator());
    try testing.expectEqual(OpenOutcome.opened, try successful_store.open(uri, 3, source));
    const first_parse_allocation = successful_allocator.alloc_index;
    try successful_store.parseCurrent(uri);
    const allocation_count = successful_allocator.alloc_index;
    successful_store.deinit();
    try testing.expectEqual(successful_allocator.allocations, successful_allocator.deallocations);

    for (first_parse_allocation..allocation_count) |fail_index| {
        var failing_allocator = FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
        });
        var store = Store.init(failing_allocator.allocator());
        try testing.expectEqual(OpenOutcome.opened, try store.open(uri, 3, source));
        const result = store.parseCurrent(uri);
        if (result) {
            try testing.expect(!failing_allocator.has_induced_failure);
            try testing.expect(store.get(uri).?.tree != null);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing_allocator.has_induced_failure);
            const document = store.get(uri).?;
            try testing.expect(document.tree == null);
            try testing.expectEqualStrings(source, document.text);
            try testing.expect(document.is_synchronized);

            failing_allocator.fail_index = math.maxInt(usize);
            const ranged_repair: lsp.Change = .{
                .range = .{
                    .start = .{
                        .line = 0,
                        .character = 9,
                    },
                    .end = .{
                        .line = 0,
                        .character = 10,
                    },
                },
                .text = "2",
            };
            try testing.expectEqual(
                UpdateOutcome.updated,
                try store.applyChanges(uri, 4, &.{ranged_repair}),
            );
            try store.parseCurrent(uri);

            const recovered_document = store.get(uri).?;
            try testing.expectEqualStrings("node key=2", recovered_document.text);
            try testing.expectEqual(@as(i32, 4), recovered_document.committed_version);
            try testing.expect(recovered_document.is_synchronized);
            try testing.expect(recovered_document.tree != null);
        }

        store.deinit();
        try testing.expectEqual(failing_allocator.allocations, failing_allocator.deallocations);
    }
}

test "parsing a snapshot twice destroys the previous tree" {
    const allocator = testing.allocator;
    var store = Store.init(allocator);
    defer {
        store.deinit();
    }

    try testing.expectEqual(OpenOutcome.opened, try store.open("file:///reparse.idl", 1, "node key=1 key=2"));
    try store.parseCurrent("file:///reparse.idl");
    try testing.expect(store.get("file:///reparse.idl").?.tree != null);
    try store.parseCurrent("file:///reparse.idl");

    const document = store.get("file:///reparse.idl").?;
    try testing.expect(document.tree != null);
    try testing.expect(document.is_synchronized);
    try testing.expectEqual(@as(i32, 1), document.committed_version);
}

fn makeNestedSource(allocator: Allocator, level_count: usize) Allocator.Error![]u8 {
    var source: ArrayList(u8) = .empty;
    defer {
        source.deinit(allocator);
    }

    for (0..level_count) |_| {
        source.appendSlice(allocator, "node {\n") catch {
            return error.OutOfMemory;
        };
    }
    for (0..level_count) |_| {
        source.appendSlice(allocator, "}\n") catch {
            return error.OutOfMemory;
        };
    }

    const owned_source = source.toOwnedSlice(allocator) catch {
        return error.OutOfMemory;
    };

    return owned_source;
}
