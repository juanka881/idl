//! JSON-RPC session lifecycle, document ownership, and LSP notifications.
//!
//! Message slices borrow their frame body only during dispatch. Requests kept
//! pending after dispatch must own their identifiers and payloads. Document
//! URI, text, and line-index storage belongs to the session document store.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const json = std.json;
const mem = std.mem;
const debug = std.debug;
const fmt = std.fmt;
const framing = @import("framing.zig");
const documents = @import("documents.zig");
const diagnostics = @import("diagnostics.zig");
const lsp = @import("lsp.zig");
const rpc = @import("rpc.zig");
const transport = @import("transport.zig");

pub const Session = struct {
    allocator: Allocator,
    output: transport.Output,
    document_store: documents.Store,
    state: State = .pre_initialize,
    initialize_attempted: bool = false,
    related_information_supported: bool = false,
    shutdown_was_requested: bool = false,

    pub const State = enum {
        pre_initialize,
        await_initialized,
        running,
        shutdown,
        exited,
    };

    pub fn init(allocator: Allocator, output: transport.Output) Session {
        const session: Session = .{
            .allocator = allocator,
            .output = output,
            .document_store = documents.Store.init(allocator),
        };

        return session;
    }

    pub fn deinit(self: *Session) void {
        self.document_store.deinit();
    }

    pub fn run(self: *Session, input: transport.Input) anyerror!u8 {
        while (true) {
            const maybe_body = try framing.readFrame(self.allocator, input);
            if (maybe_body == null) {
                return self.exitStatus();
            }

            const body = maybe_body.?;
            {
                defer {
                    self.allocator.free(body);
                }

                try self.handleMessage(body);
            }

            if (self.state == .exited) {
                return self.exitStatus();
            }
        }
    }

    pub fn handleMessage(self: *Session, message_json: []const u8) anyerror!void {
        var arena = ArenaAllocator.init(self.allocator);
        defer {
            arena.deinit();
        }

        const parsed_message = json.parseFromSliceLeaky(
            json.Value,
            arena.allocator(),
            message_json,
            .{},
        ) catch |err| {
            if (err == error.OutOfMemory) {
                return error.OutOfMemory;
            }

            try self.sendError(arena.allocator(), .null, rpc.parse_error, "Parse error", null);
            return;
        };

        if (parsed_message != .object) {
            try self.sendError(
                arena.allocator(),
                .null,
                rpc.invalid_request,
                "Invalid Request",
                null,
            );
            return;
        }

        try self.handleObject(arena.allocator(), parsed_message.object);
    }

    pub fn exitStatus(self: *const Session) u8 {
        if (self.shutdown_was_requested) {
            return 0;
        }

        return 1;
    }

    fn handleObject(self: *Session, allocator: Allocator, object: json.ObjectMap) anyerror!void {
        const is_response_candidate = rpc.isResponseCandidate(object);
        if (is_response_candidate) {
            const is_valid_response = rpc.isValidResponse(object);
            _ = is_valid_response;
            return;
        }

        const version = object.get("jsonrpc") orelse {
            try self.sendInvalidRequest(allocator, object);
            return;
        };
        const is_supported_jsonrpc_version = version == .string and
            mem.eql(u8, version.string, "2.0");
        if (!is_supported_jsonrpc_version) {
            try self.sendInvalidRequest(allocator, object);
            return;
        }

        const method_value = object.get("method");
        if (method_value) |method| {
            if (method != .string) {
                try self.sendInvalidRequest(allocator, object);
                return;
            }

            try self.handleMethod(allocator, object, method.string);
            return;
        }

        try self.sendInvalidRequest(allocator, object);
    }

    fn handleMethod(
        self: *Session,
        allocator: Allocator,
        object: json.ObjectMap,
        method: []const u8,
    ) anyerror!void {
        const request_id = object.get("id");
        const is_notification = request_id == null;

        if (is_notification) {
            const is_initialized_notification = mem.eql(u8, method, "initialized");
            if (is_initialized_notification and !hasObjectOrAbsentParams(object)) {
                return;
            }

            const is_exit_notification = mem.eql(u8, method, "exit");
            if (is_exit_notification and !hasAbsentOrNullParams(object)) {
                return;
            }

            const has_valid_params = rpc.hasValidParams(object);
            if (!has_valid_params) {
                return;
            }

            try self.handleNotification(allocator, object, method);
            return;
        }

        const id = request_id.?;
        const has_valid_request_id = rpc.isValidRequestId(id);
        if (!has_valid_request_id) {
            try self.sendInvalidRequest(allocator, object);
            return;
        }

        const has_valid_params = rpc.hasValidParams(object);
        if (!has_valid_params) {
            try self.sendError(
                allocator,
                id,
                rpc.invalid_params,
                "Invalid params",
                null,
            );
            return;
        }

        try self.handleRequest(allocator, object, method, id);
    }

    fn handleRequest(
        self: *Session,
        allocator: Allocator,
        object: json.ObjectMap,
        method: []const u8,
        id: json.Value,
    ) anyerror!void {
        if (mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(allocator, object, id);
            return;
        }

        if (self.state == .shutdown or self.state == .exited) {
            try self.sendError(allocator, id, rpc.invalid_request, "Invalid Request", null);
            return;
        }

        if (self.state != .running) {
            try self.sendError(
                allocator,
                id,
                rpc.server_not_initialized,
                "Server not initialized",
                null,
            );
            return;
        }

        if (mem.eql(u8, method, "shutdown")) {
            if (!hasAbsentOrNullParams(object)) {
                try self.sendError(allocator, id, rpc.invalid_params, "Invalid params", null);
                return;
            }

            self.state = .shutdown;
            self.shutdown_was_requested = true;
            try self.sendResult(allocator, id, .null);
            return;
        }

        try self.sendError(allocator, id, rpc.method_not_found, "Method not found", null);
    }

    fn handleInitialize(
        self: *Session,
        allocator: Allocator,
        object: json.ObjectMap,
        id: json.Value,
    ) anyerror!void {
        const may_initialize = self.state == .pre_initialize and !self.initialize_attempted;
        if (!may_initialize) {
            try self.sendError(allocator, id, rpc.invalid_request, "Invalid Request", null);
            return;
        }

        self.initialize_attempted = true;

        const params = object.get("params") orelse {
            try self.sendError(allocator, id, rpc.invalid_params, "Invalid params", null);
            return;
        };
        if (params != .object) {
            try self.sendError(allocator, id, rpc.invalid_params, "Invalid params", null);
            return;
        }

        if (!offersUtf8(params.object)) {
            const retry_value: json.Value = .{
                .bool = false,
            };
            const error_data = try makeObject(allocator, &.{.{
                .key = "retry",
                .value = retry_value,
            }});
            try self.sendError(
                allocator,
                id,
                rpc.server_not_initialized,
                "Idle requires UTF-8 position support.",
                error_data,
            );
            return;
        }

        self.related_information_supported = clientSupportsRelatedInformation(params.object);
        const result = try initializationResult(allocator);
        self.state = .await_initialized;
        try self.sendResult(allocator, id, result);
    }

    fn offersUtf8(params: json.ObjectMap) bool {
        const maybe_capabilities = params.get("capabilities");
        if (maybe_capabilities == null) {
            return false;
        }
        const capabilities = maybe_capabilities.?;
        if (capabilities != .object) {
            return false;
        }

        const maybe_general = capabilities.object.get("general");
        if (maybe_general == null) {
            return false;
        }
        const general = maybe_general.?;
        if (general != .object) {
            return false;
        }

        const maybe_position_encodings = general.object.get("positionEncodings");
        if (maybe_position_encodings == null) {
            return false;
        }
        const position_encodings = maybe_position_encodings.?;
        if (position_encodings != .array) {
            return false;
        }

        for (position_encodings.array.items) |position_encoding| {
            const is_utf8 = position_encoding == .string and
                mem.eql(u8, position_encoding.string, "utf-8");
            if (is_utf8) {
                return true;
            }
        }

        return false;
    }

    fn handleNotification(
        self: *Session,
        allocator: Allocator,
        object: json.ObjectMap,
        method: []const u8,
    ) anyerror!void {
        if (mem.eql(u8, method, "exit")) {
            self.state = .exited;
            return;
        }

        if (self.state == .await_initialized and mem.eql(u8, method, "initialized")) {
            self.state = .running;
            return;
        }

        if (self.state != .running) {
            return;
        }

        const maybe_params = object.get("params");
        if (maybe_params == null) {
            return;
        }
        const params = maybe_params.?;

        if (mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(allocator, params);
            return;
        }

        if (mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(allocator, params);
            return;
        }

        if (mem.eql(u8, method, "textDocument/didClose")) {
            try self.handleDidClose(allocator, params);
        }
    }

    fn handleDidOpen(self: *Session, allocator: Allocator, params: json.Value) anyerror!void {
        const uri = lsp.decodeUri(params) catch {
            logIgnoredDocumentNotification("didOpen", "<unknown>");
            return;
        };
        if (self.document_store.get(uri) != null) {
            logIgnoredDocumentNotification("duplicate didOpen", uri);
            return;
        }

        const opened_document = lsp.decodeDidOpen(params) catch {
            try self.sendSynchronizationError(allocator, uri);
            return;
        };
        const open_outcome = self.document_store.open(
            opened_document.uri,
            opened_document.version,
            opened_document.text,
        ) catch {
            try self.sendSynchronizationError(allocator, uri);
            return;
        };

        if (open_outcome == .duplicate) {
            logIgnoredDocumentNotification("duplicate didOpen", uri);
            return;
        }

        try self.parseAndPublishDiagnostics(allocator, uri, opened_document.version);
    }

    fn handleDidChange(self: *Session, allocator: Allocator, params: json.Value) anyerror!void {
        const uri = lsp.decodeUri(params) catch {
            logIgnoredDocumentNotification("didChange", "<unknown>");
            return;
        };
        if (self.document_store.get(uri) == null) {
            logIgnoredDocumentNotification("unknown didChange", uri);
            return;
        }

        const version = lsp.decodeVersion(params) catch {
            const mark_outcome = self.document_store.markUnsynchronized(uri, null);
            if (mark_outcome == .marked_unsynchronized) {
                try self.reportUnsynchronizedDocument(allocator, uri);
            }
            return;
        };
        if (self.document_store.isStale(uri, version)) {
            return;
        }

        const changes = lsp.decodeChanges(allocator, params) catch {
            const mark_outcome = self.document_store.markUnsynchronized(uri, version);
            if (mark_outcome == .marked_unsynchronized) {
                try self.reportUnsynchronizedDocument(allocator, uri);
            }
            return;
        };
        defer {
            allocator.free(changes);
        }

        const update_outcome = self.document_store.applyChanges(uri, version, changes) catch {
            try self.reportUnsynchronizedDocument(allocator, uri);
            return;
        };
        switch (update_outcome) {
            .updated => {
                try self.parseAndPublishDiagnostics(allocator, uri, version);
            },
            .stale, .unknown_uri => {},
            .invalid_update => {
                try self.reportUnsynchronizedDocument(allocator, uri);
            },
        }
    }

    fn handleDidClose(self: *Session, allocator: Allocator, params: json.Value) anyerror!void {
        const uri = lsp.decodeUri(params) catch {
            logIgnoredDocumentNotification("didClose", "<unknown>");
            return;
        };
        const maybe_closed_version = self.document_store.close(uri);
        if (maybe_closed_version == null) {
            return;
        }

        try self.sendEmptyDiagnostics(allocator, uri, null);
    }

    fn reportUnsynchronizedDocument(self: *Session, allocator: Allocator, uri: []const u8) anyerror!void {
        const document = self.document_store.get(uri);
        if (document == null) {
            return;
        }

        const observed_version = document.?.highest_observed_version;
        try self.sendEmptyDiagnostics(allocator, uri, observed_version);
        try self.sendSynchronizationError(allocator, uri);
    }

    fn sendEmptyDiagnostics(
        self: *Session,
        allocator: Allocator,
        uri: []const u8,
        version: ?i32,
    ) anyerror!void {
        try self.sendDiagnostics(allocator, uri, version, &.{});
    }

    fn parseAndPublishDiagnostics(
        self: *Session,
        allocator: Allocator,
        uri: []const u8,
        version: i32,
    ) anyerror!void {
        self.document_store.parseCurrent(uri) catch {
            try self.reportAnalysisFailure(allocator, uri, version);
            return;
        };

        const maybe_document = self.document_store.get(uri);
        if (maybe_document == null) {
            try self.reportAnalysisFailure(allocator, uri, version);
            return;
        }

        const document = maybe_document.?;
        const tree = document.tree;
        if (tree == null) {
            try self.reportAnalysisFailure(allocator, uri, version);
            return;
        }

        const mapped_diagnostics = diagnostics.mapAll(
            allocator,
            uri,
            tree.?,
            document.line_map,
            self.related_information_supported,
        ) catch {
            try self.reportAnalysisFailure(allocator, uri, version);
            return;
        };
        defer {
            allocator.free(mapped_diagnostics);
        }

        try self.sendDiagnostics(allocator, uri, version, mapped_diagnostics);
    }

    fn reportAnalysisFailure(
        self: *Session,
        allocator: Allocator,
        uri: []const u8,
        version: i32,
    ) anyerror!void {
        try self.sendEmptyDiagnostics(allocator, uri, version);

        const message = fmt.allocPrint(
            allocator,
            "Idle could not analyze '{s}'. Edit the document or close and reopen it to retry.",
            .{uri},
        ) catch {
            return error.OutOfMemory;
        };
        defer {
            allocator.free(message);
        }

        try self.sendShowMessage(allocator, 1, message);
    }

    fn sendDiagnostics(
        self: *Session,
        allocator: Allocator,
        uri: []const u8,
        version: ?i32,
        diagnostic_list: []const lsp.Diagnostic,
    ) anyerror!void {
        var diagnostic_values = json.Array.init(allocator);
        defer {
            diagnostic_values.deinit();
        }

        for (diagnostic_list) |diagnostic| {
            const value = try diagnosticValue(allocator, diagnostic);
            diagnostic_values.append(value) catch {
                return error.OutOfMemory;
            };
        }

        var fields: [3]ObjectField = undefined;
        var field_count: usize = 0;
        fields[field_count] = .{
            .key = "uri",
            .value = .{
                .string = uri,
            },
        };
        field_count += 1;

        if (version) |diagnostic_version| {
            fields[field_count] = .{
                .key = "version",
                .value = .{
                    .integer = diagnostic_version,
                },
            };
            field_count += 1;
        }

        const diagnostic_array: json.Value = .{
            .array = diagnostic_values,
        };
        fields[field_count] = .{
            .key = "diagnostics",
            .value = diagnostic_array,
        };
        field_count += 1;

        const params = try makeObject(allocator, fields[0..field_count]);
        try self.sendNotification(allocator, "textDocument/publishDiagnostics", params);
    }

    fn sendShowMessage(
        self: *Session,
        allocator: Allocator,
        message_type: i64,
        message: []const u8,
    ) anyerror!void {
        const params = try makeObject(allocator, &.{
            .{
                .key = "type",
                .value = .{
                    .integer = message_type,
                },
            },
            .{
                .key = "message",
                .value = .{
                    .string = message,
                },
            },
        });
        try self.sendNotification(allocator, "window/showMessage", params);
    }

    fn diagnosticValue(allocator: Allocator, diagnostic: lsp.Diagnostic) anyerror!json.Value {
        const range = try rangeValue(allocator, diagnostic.range);
        var fields: [6]ObjectField = undefined;
        var field_count: usize = 0;
        fields[field_count] = .{
            .key = "range",
            .value = range,
        };
        field_count += 1;

        if (diagnostic.severity) |severity| {
            fields[field_count] = .{
                .key = "severity",
                .value = .{
                    .integer = severity,
                },
            };
            field_count += 1;
        }

        if (diagnostic.code) |code| {
            fields[field_count] = .{
                .key = "code",
                .value = .{
                    .string = code,
                },
            };
            field_count += 1;
        }

        if (diagnostic.source) |source| {
            fields[field_count] = .{
                .key = "source",
                .value = .{
                    .string = source,
                },
            };
            field_count += 1;
        }

        fields[field_count] = .{
            .key = "message",
            .value = .{
                .string = diagnostic.message,
            },
        };
        field_count += 1;

        if (diagnostic.related_information) |related_information| {
            const related_range = try rangeValue(allocator, related_information.range);
            const location = try makeObject(allocator, &.{
                .{
                    .key = "uri",
                    .value = .{
                        .string = related_information.uri,
                    },
                },
                .{
                    .key = "range",
                    .value = related_range,
                },
            });
            const related_value = try makeObject(allocator, &.{
                .{
                    .key = "location",
                    .value = location,
                },
                .{
                    .key = "message",
                    .value = .{
                        .string = related_information.message,
                    },
                },
            });
            var related_values = json.Array.init(allocator);
            related_values.append(related_value) catch {
                return error.OutOfMemory;
            };
            fields[field_count] = .{
                .key = "relatedInformation",
                .value = .{
                    .array = related_values,
                },
            };
            field_count += 1;
        }

        return makeObject(allocator, fields[0..field_count]);
    }

    fn rangeValue(allocator: Allocator, range: lsp.Range) anyerror!json.Value {
        const start = positionValue(allocator, range.start) catch {
            return error.OutOfMemory;
        };
        const end = positionValue(allocator, range.end) catch {
            return error.OutOfMemory;
        };
        const value = try makeObject(allocator, &.{
            .{
                .key = "start",
                .value = start,
            },
            .{
                .key = "end",
                .value = end,
            },
        });

        return value;
    }

    fn positionValue(allocator: Allocator, position: lsp.Position) anyerror!json.Value {
        const value = try makeObject(allocator, &.{
            .{
                .key = "line",
                .value = .{
                    .integer = position.line,
                },
            },
            .{
                .key = "character",
                .value = .{
                    .integer = position.character,
                },
            },
        });

        return value;
    }

    fn sendSynchronizationError(self: *Session, allocator: Allocator, uri: []const u8) anyerror!void {
        const message = fmt.allocPrint(
            allocator,
            "Idle could not synchronize '{s}'. Close and reopen this document or restart the language server.",
            .{uri},
        ) catch {
            return error.OutOfMemory;
        };
        defer {
            allocator.free(message);
        }

        const params = try makeObject(allocator, &.{
            .{
                .key = "type",
                .value = .{
                    .integer = 1,
                },
            },
            .{
                .key = "message",
                .value = .{
                    .string = message,
                },
            },
        });
        try self.sendNotification(allocator, "window/showMessage", params);
    }

    fn sendNotification(
        self: *Session,
        allocator: Allocator,
        method: []const u8,
        params: json.Value,
    ) anyerror!void {
        const notification = try makeObject(allocator, &.{
            .{
                .key = "jsonrpc",
                .value = .{
                    .string = "2.0",
                },
            },
            .{
                .key = "method",
                .value = .{
                    .string = method,
                },
            },
            .{
                .key = "params",
                .value = params,
            },
        });

        try self.sendJson(allocator, notification);
    }

    fn hasObjectOrAbsentParams(object: json.ObjectMap) bool {
        const maybe_params = object.get("params");
        if (maybe_params == null) {
            return true;
        }

        const params = maybe_params.?;
        return params == .object;
    }

    fn hasAbsentOrNullParams(object: json.ObjectMap) bool {
        const maybe_params = object.get("params");
        if (maybe_params == null) {
            return true;
        }

        const params = maybe_params.?;
        return params == .null;
    }

    fn sendInvalidRequest(self: *Session, allocator: Allocator, object: json.ObjectMap) anyerror!void {
        var id: json.Value = .null;
        if (object.get("id")) |candidate_id| {
            if (rpc.isValidRequestId(candidate_id)) {
                id = candidate_id;
            }
        }

        try self.sendError(allocator, id, rpc.invalid_request, "Invalid Request", null);
    }

    fn sendResult(
        self: *Session,
        allocator: Allocator,
        id: json.Value,
        result: json.Value,
    ) anyerror!void {
        const response = try makeObject(allocator, &.{
            .{
                .key = "jsonrpc",
                .value = .{
                    .string = "2.0",
                },
            },
            .{
                .key = "id",
                .value = id,
            },
            .{
                .key = "result",
                .value = result,
            },
        });

        try self.sendJson(allocator, response);
    }

    fn sendError(
        self: *Session,
        allocator: Allocator,
        id: json.Value,
        code: i64,
        message: []const u8,
        data: ?json.Value,
    ) anyerror!void {
        const error_object = try makeErrorObject(allocator, code, message, data);
        const response = try makeObject(allocator, &.{
            .{
                .key = "jsonrpc",
                .value = .{
                    .string = "2.0",
                },
            },
            .{
                .key = "id",
                .value = id,
            },
            .{
                .key = "error",
                .value = error_object,
            },
        });

        try self.sendJson(allocator, response);
    }

    fn sendJson(self: *Session, allocator: Allocator, value: json.Value) anyerror!void {
        const message_json = json.Stringify.valueAlloc(allocator, value, .{}) catch {
            return error.OutOfMemory;
        };
        defer {
            allocator.free(message_json);
        }

        try framing.writeFrame(allocator, self.output, message_json);
    }
};

const ObjectField = struct {
    key: []const u8,
    value: json.Value,
};

fn logIgnoredDocumentNotification(event: []const u8, uri: []const u8) void {
    debug.print("idl-lsp: ignored {s} for URI '{s}'\n", .{ event, uri });
}

fn makeObject(allocator: Allocator, fields: []const ObjectField) error{OutOfMemory}!json.Value {
    var object: json.ObjectMap = .empty;
    for (fields) |field| {
        object.put(allocator, field.key, field.value) catch {
            return error.OutOfMemory;
        };
    }

    const value = json.Value{
        .object = object,
    };

    return value;
}

fn makeErrorObject(
    allocator: Allocator,
    code: i64,
    message: []const u8,
    data: ?json.Value,
) error{OutOfMemory}!json.Value {
    var error_object: json.ObjectMap = .empty;
    error_object.put(allocator, "code", .{
        .integer = code,
    }) catch {
        return error.OutOfMemory;
    };
    error_object.put(allocator, "message", .{
        .string = message,
    }) catch {
        return error.OutOfMemory;
    };

    if (data) |error_data| {
        error_object.put(allocator, "data", error_data) catch {
            return error.OutOfMemory;
        };
    }

    const value = json.Value{
        .object = error_object,
    };

    return value;
}

fn initializationResult(allocator: Allocator) error{OutOfMemory}!json.Value {
    const sync_options = try makeObject(allocator, &.{
        .{
            .key = "openClose",
            .value = .{
                .bool = true,
            },
        },
        .{
            .key = "change",
            .value = .{
                .integer = 2,
            },
        },
    });
    const capabilities = try makeObject(allocator, &.{
        .{
            .key = "positionEncoding",
            .value = .{
                .string = "utf-8",
            },
        },
        .{
            .key = "textDocumentSync",
            .value = sync_options,
        },
    });
    const result = try makeObject(allocator, &.{.{
        .key = "capabilities",
        .value = capabilities,
    }});

    return result;
}

fn clientSupportsRelatedInformation(initialize_params: json.ObjectMap) bool {
    const maybe_client_capabilities = initialize_params.get("capabilities");
    if (maybe_client_capabilities == null) {
        return false;
    }
    const client_capabilities = maybe_client_capabilities.?;
    if (client_capabilities != .object) {
        return false;
    }

    const maybe_text_document = client_capabilities.object.get("textDocument");
    if (maybe_text_document == null) {
        return false;
    }
    const text_document = maybe_text_document.?;
    if (text_document != .object) {
        return false;
    }

    const maybe_publish_diagnostics = text_document.object.get("publishDiagnostics");
    if (maybe_publish_diagnostics == null) {
        return false;
    }
    const publish_diagnostics = maybe_publish_diagnostics.?;
    if (publish_diagnostics != .object) {
        return false;
    }

    const maybe_related_information = publish_diagnostics.object.get("relatedInformation");
    if (maybe_related_information == null) {
        return false;
    }
    const related_information = maybe_related_information.?;
    return related_information == .bool and related_information.bool;
}
