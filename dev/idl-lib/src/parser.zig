const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const diag = @import("diagnostics.zig");
const scan = @import("scanner.zig");
const syntax = @import("syntax.zig");
const text = @import("text.zig");

pub const Error = error{
    OutOfMemory,
    NestingLimitExceeded,
};

const maximum_nesting = 256;

const Operator = struct {
    value: syntax.BinaryOperator,
    precedence: u8,
};

pub const DocumentSyntax = struct {
    nodes: []const syntax.Node,
    tokens: []const syntax.Token,
    diagnostics: []const diag.Diagnostic,
};

pub const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    scanner: scan.Scanner,
    token_list: ArrayList(syntax.Token) = .empty,
    diagnostic_list: ArrayList(diag.Diagnostic) = .empty,
    scanner_diagnostic_count: usize = 0,
    active_nesting: usize = 0,
    expected_closers: [maximum_nesting]syntax.TokenKind = undefined,
    expected_closer_count: usize = 0,
    name_mode: scan.NameMode = .symbol,

    pub fn init(allocator: Allocator, source: []const u8) Parser {
        const options: scan.Options = .{};

        return initWithOptions(allocator, source, options);
    }

    /// Initializes a parser whose allocations belong to the caller's arena.
    /// The caller must keep that arena alive for every returned syntax view and
    /// must not deinitialize the parser's scanner independently.
    pub fn initWithOptions(allocator: Allocator, source: []const u8, options: scan.Options) Parser {
        const parser: Parser = .{
            .allocator = allocator,
            .source = source,
            .scanner = scan.Scanner.init(allocator, source, options),
        };

        return parser;
    }

    /// Parses one expression and leaves a following delimiter or token unconsumed.
    pub fn parseExpression(self: *Parser) Error!*const syntax.Expression {
        return self.parseExpressionAt(1);
    }

    /// Parses one expression and diagnoses any additional non-EOF syntax.
    pub fn parseFullExpression(self: *Parser) Error!*const syntax.Expression {
        const expression = try self.parseExpression();
        var next = self.peek(.{
            .operand_start = false,
        }) orelse {
            unreachable;
        };
        if (next.kind != .end_of_file) {
            try self.appendDiagnostic(
                diag.expected_operator_code,
                diag.expected_operator_message,
                next.span,
            );
            while (next.kind != .end_of_file) {
                _ = try self.consume(.{
                    .operand_start = false,
                });
                next = self.peek(.{
                    .operand_start = false,
                }) orelse {
                    unreachable;
                };
            }
        }

        _ = try self.consume(.{
            .operand_start = false,
        });

        return expression;
    }

    pub fn parseDocument(self: *Parser) Error!DocumentSyntax {
        const previous_name_mode = self.name_mode;
        self.name_mode = .header;
        defer {
            self.name_mode = previous_name_mode;
        }

        var nodes: ArrayList(syntax.Node) = .empty;
        try self.parseNodeSequence(false, &nodes);

        const owned_nodes = try nodes.toOwnedSlice(self.allocator);
        const owned_tokens = try self.token_list.toOwnedSlice(self.allocator);
        const owned_diagnostics = try self.diagnostic_list.toOwnedSlice(self.allocator);
        const document_syntax: DocumentSyntax = .{
            .nodes = owned_nodes,
            .tokens = owned_tokens,
            .diagnostics = owned_diagnostics,
        };

        return document_syntax;
    }

    fn parseNodeSequence(self: *Parser, in_body: bool, nodes: *ArrayList(syntax.Node)) Error!void {
        var pending_annotations: ArrayList(syntax.Annotation) = .empty;

        while (true) {
            const probe = self.peek(.{
                .operand_start = false,
            }) orelse {
                unreachable;
            };

            if (probe.kind == .end_of_file) {
                try self.reportOrphanAnnotations(&pending_annotations);
                if (!in_body) {
                    _ = try self.consume(.{
                        .operand_start = false,
                    });
                }

                return;
            }

            if (probe.kind == .right_brace) {
                try self.reportOrphanAnnotations(&pending_annotations);
                if (in_body) {
                    return;
                }

                try self.appendDiagnostic(
                    diag.unexpected_closing_brace_code,
                    diag.unexpected_closing_brace_message,
                    probe.span,
                );
                _ = try self.consume(.{
                    .operand_start = false,
                });
                continue;
            }

            if (probe.kind == .semicolon) {
                try self.reportOrphanAnnotations(&pending_annotations);
                _ = try self.consume(.{
                    .operand_start = false,
                });
                continue;
            }

            if (probe.kind == .at_sign) {
                const parsed_annotation = try self.parseAnnotation();
                if (parsed_annotation.terminated_by_newline) {
                    try pending_annotations.append(self.allocator, parsed_annotation.annotation);
                } else {
                    try self.reportOrphanAnnotations(&pending_annotations);
                    try self.reportOrphanAnnotation(parsed_annotation.annotation);
                }

                continue;
            }

            if (probe.kind == .name) {
                var attached_annotations: []const syntax.Annotation = &.{};
                if (pending_annotations.items.len > 0) {
                    attached_annotations = try self.allocator.dupe(syntax.Annotation, pending_annotations.items);
                }

                pending_annotations.clearRetainingCapacity();

                const node = try self.parseNode(attached_annotations);
                try nodes.append(self.allocator, node);
                continue;
            }

            try self.reportOrphanAnnotations(&pending_annotations);
            const is_closing_body_delimiter = in_body and probe.kind == .right_brace;
            if (is_closing_body_delimiter) {
                return;
            }

            try self.appendDiagnostic(
                diag.expected_node_code,
                diag.expected_node_message,
                probe.span,
            );
            _ = try self.consume(.{
                .operand_start = false,
            });
        }
    }

    fn parseNode(self: *Parser, annotations: []const syntax.Annotation) Error!syntax.Node {
        const name_token = try self.consume(.{
            .operand_start = false,
        });
        const name_span = name_token.span;
        var node_end = name_span.end();

        var arguments: ArrayList(*const syntax.Expression) = .empty;
        var properties: ArrayList(syntax.Property) = .empty;
        var saw_property = false;

        try self.parseHeaderEntries(&arguments, &properties, &saw_property, &node_end);

        var body: ?syntax.Body = null;
        var probe = self.peek(.{
            .operand_start = false,
        }) orelse {
            unreachable;
        };
        if (probe.kind == .left_brace) {
            body = try self.parseBody();
            node_end = body.?.close_token.span.end();

            probe = self.peek(.{
                .operand_start = false,
            }) orelse {
                unreachable;
            };
            while (true) {
                const is_same_line_additional_body = probe.kind == .left_brace and !probe.has_logical_newline;
                if (!is_same_line_additional_body) {
                    break;
                }

                try self.appendDiagnostic(diag.multiple_bodies_code, diag.multiple_bodies_message, probe.span);
                const ignored_body = try self.parseBody();
                node_end = ignored_body.close_token.span.end();
                probe = self.peek(.{
                    .operand_start = false,
                }) orelse {
                    unreachable;
                };
            }
        }

        probe = self.peek(.{
            .operand_start = false,
        }) orelse {
            unreachable;
        };
        const is_node_terminator = probe.has_logical_newline or
            probe.kind == .semicolon or
            probe.kind == .right_brace or
            probe.kind == .end_of_file;
        if (!is_node_terminator) {
            try self.appendDiagnostic(
                diag.expected_separator_code,
                diag.expected_separator_message,
                probe.span,
            );
        }

        var node_start = name_span.start;
        if (annotations.len > 0) {
            node_start = annotations[0].span.start;
        }

        const owned_arguments = try arguments.toOwnedSlice(self.allocator);
        const owned_properties = try properties.toOwnedSlice(self.allocator);
        const node: syntax.Node = .{
            .name_span = name_span,
            .span = makeSpan(node_start, node_end),
            .annotations = annotations,
            .arguments = owned_arguments,
            .properties = owned_properties,
            .body = body,
        };

        return node;
    }

    fn parseHeaderEntries(
        self: *Parser,
        arguments: *ArrayList(*const syntax.Expression),
        properties: *ArrayList(syntax.Property),
        saw_property: *bool,
        header_end: *usize,
    ) Error!void {
        while (true) {
            const probe = self.peek(.{
                .operand_start = true,
            }) orelse {
                unreachable;
            };
            const starts_next_logical_entry = probe.has_logical_newline or isHeaderEntryBoundary(probe.kind);
            if (starts_next_logical_entry) {
                return;
            }

            const property_name = self.scanner.probePropertyName();
            const has_property_name = property_name != null;
            const property_name_starts_at_probe = has_property_name and property_name.?.start == probe.span.start;
            const is_spaced_property_entry = probe.has_gap and property_name_starts_at_probe;
            if (is_spaced_property_entry) {
                const property = try self.parseProperty(properties);
                try properties.append(self.allocator, property);
                saw_property.* = true;
                header_end.* = property.span.end();
                continue;
            }

            if (!probe.has_gap) {
                try self.appendDiagnostic(
                    diag.expected_separator_code,
                    diag.expected_separator_message,
                    probe.span,
                );
            }

            const is_unexpected_header_separator = probe.kind == .comma or
                probe.kind == .right_parenthesis or
                probe.kind == .right_bracket;
            if (is_unexpected_header_separator) {
                try self.appendDiagnostic(
                    diag.expected_value_code,
                    diag.expected_value_message,
                    probe.span,
                );
                _ = try self.consume(.{
                    .operand_start = true,
                });
                continue;
            }

            const value = try self.parseHeaderValue(header_end.*);
            if (saw_property.*) {
                try self.appendDiagnostic(
                    diag.argument_after_property_code,
                    diag.argument_after_property_message,
                    value.span,
                );
            }

            try arguments.append(self.allocator, value);
            if (value.span.len > 0) {
                header_end.* = value.span.end();
            }
        }
    }

    fn parseProperty(self: *Parser, previous_properties: *const ArrayList(syntax.Property)) Error!syntax.Property {
        const previous_name_mode = self.name_mode;
        self.name_mode = .header;
        const name_token = try self.consume(.{
            .operand_start = false,
        });
        self.name_mode = .symbol;

        const equals_probe = self.peek(.{
            .operand_start = false,
        }) orelse {
            unreachable;
        };
        if (equals_probe.kind != .equals) {
            self.name_mode = previous_name_mode;
            const equals_token = missingToken(.equals, name_token.span.end());
            const missing_value = try self.makeMissingExpression(name_token.span.end(), true);
            const property: syntax.Property = .{
                .name_span = name_token.span,
                .equals_token = equals_token,
                .value = missing_value,
                .span = name_token.span,
            };

            return property;
        }

        self.name_mode = .header;
        const equals_token = try self.consume(.{
            .operand_start = false,
        });
        self.name_mode = .symbol;

        var value = try self.parseHeaderValue(equals_token.span.end());
        self.name_mode = previous_name_mode;

        for (previous_properties.items) |previous| {
            if (self.spansHaveEqualText(previous.name_span, name_token.span)) {
                try self.appendRelatedDiagnostic(
                    diag.duplicate_property_code,
                    diag.duplicate_property_message,
                    name_token.span,
                    previous.name_span,
                );
                break;
            }
        }

        const property_end = @max(equals_token.span.end(), value.span.end());
        const property: syntax.Property = .{
            .name_span = name_token.span,
            .equals_token = equals_token,
            .value = value,
            .span = makeSpan(name_token.span.start, property_end),
        };

        return property;
    }

    fn parseHeaderValue(self: *Parser, missing_anchor: usize) Error!*const syntax.Expression {
        const previous_name_mode = self.name_mode;
        self.name_mode = .symbol;
        defer {
            self.name_mode = previous_name_mode;
        }

        const probe = self.peek(.{
            .operand_start = true,
        }) orelse {
            unreachable;
        };
        const value_starts_after_header_boundary = probe.has_logical_newline or isHeaderValueBoundary(probe.kind);
        if (value_starts_after_header_boundary) {
            try self.appendDiagnostic(diag.expected_value_code, diag.expected_value_message, insertionSpan(missing_anchor));

            return self.makeMissingExpression(missing_anchor, false);
        }

        if (probe.kind == .operator) {
            const spelling = self.sourceSlice(probe.span);
            if (mem.eql(u8, spelling, "!")) {
                const operator_token = try self.consume(.{
                    .operand_start = false,
                });
                try self.enterNesting();
                defer {
                    self.leaveNesting();
                }

                const operand = try self.parseHeaderValue(operator_token.span.end());
                const expression_span = makeSpan(operator_token.span.start, operand.span.end());
                const unary: syntax.Unary = .{
                    .operator = .logical_not,
                    .operator_span = operator_token.span,
                    .operand = operand,
                };
                const expression_data: syntax.Data = .{
                    .unary = unary,
                };

                return self.allocateExpression(expression_span, expression_data);
            }

            if (mem.eql(u8, spelling, "-")) {
                return self.parseSignedHeaderNumber();
            }

            const operator_token = try self.consume(.{
                .operand_start = false,
            });
            try self.appendDiagnostic(
                diag.invalid_header_value_code,
                diag.invalid_header_value_message,
                operator_token.span,
            );

            var invalid_end = operator_token.span.end();
            const following = self.peek(.{
                .operand_start = true,
            }) orelse {
                unreachable;
            };
            const is_adjacent_number_after_plus = mem.eql(u8, spelling, "+") and
                following.kind == .number and
                following.leading_span.len == 0;
            if (is_adjacent_number_after_plus) {
                const scanned = try self.consumeScanned(.{
                    .operand_start = true,
                });
                invalid_end = scanned.token.span.end();
            }

            const invalid_data: syntax.Data = .{
                .invalid = {},
            };
            const invalid_span = makeSpan(operator_token.span.start, invalid_end);

            return self.allocateExpression(invalid_span, invalid_data);
        }

        return self.parsePrimary();
    }

    fn parseSignedHeaderNumber(self: *Parser) Error!*const syntax.Expression {
        const minus_token = try self.consume(.{
            .operand_start = false,
        });
        const following = self.peek(.{
            .operand_start = true,
        }) orelse {
            unreachable;
        };
        const is_adjacent_number = following.kind == .number and following.leading_span.len == 0;
        if (is_adjacent_number) {
            const scanned = try self.consumeScanned(.{
                .operand_start = true,
            });

            return self.allocateSignedNumber(minus_token.span, scanned);
        }

        const maybe_invalid_number = following.kind == .unknown and following.leading_span.len == 0;
        if (maybe_invalid_number) {
            const scanned = try self.consume(.{
                .operand_start = true,
            });
            const span = makeSpan(minus_token.span.start, scanned.span.end());
            const invalid_data: syntax.Data = .{
                .invalid = {},
            };

            return self.allocateExpression(span, invalid_data);
        }

        try self.appendDiagnostic(
            diag.invalid_header_value_code,
            diag.invalid_header_value_message,
            minus_token.span,
        );
        const invalid_data: syntax.Data = .{
            .invalid = {},
        };

        return self.allocateExpression(minus_token.span, invalid_data);
    }

    fn allocateSignedNumber(self: *Parser, minus_span: text.TextSpan, scanned: scan.ScannedToken) Error!*const syntax.Expression {
        const radix = scanned.radix orelse .decimal;
        const positive_number_span = scanned.number_span orelse scanned.token.span;
        const signed_number_span = makeSpan(minus_span.start, positive_number_span.end());
        const full_span = makeSpan(minus_span.start, scanned.token.span.end());

        if (scanned.unit_span) |unit_span| {
            const number: syntax.NumberWithUnit = .{
                .number_span = signed_number_span,
                .unit_span = unit_span,
                .radix = radix,
            };
            const expression_data: syntax.Data = .{
                .number_with_unit = number,
            };

            return self.allocateExpression(full_span, expression_data);
        }

        const number: syntax.Number = .{
            .number_span = signed_number_span,
            .radix = radix,
        };
        const expression_data: syntax.Data = .{
            .number = number,
        };

        return self.allocateExpression(full_span, expression_data);
    }

    fn parseBody(self: *Parser) Error!syntax.Body {
        const open_token = try self.consume(.{
            .operand_start = false,
        });
        try self.enterContainer(.right_brace);
        defer {
            self.leaveContainer();
        }

        var children: ArrayList(syntax.Node) = .empty;
        try self.parseNodeSequence(true, &children);

        const probe = self.peek(.{
            .operand_start = false,
        }) orelse {
            unreachable;
        };
        var close_token: syntax.Token = undefined;
        if (probe.kind == .right_brace) {
            close_token = try self.consume(.{
                .operand_start = false,
            });
        } else {
            close_token =
                try self.insertMissingClose(.right_brace, probe.span.start);
        }

        const owned_children = try children.toOwnedSlice(self.allocator);
        const body: syntax.Body = .{
            .open_token = open_token,
            .close_token = close_token,
            .children = owned_children,
        };

        return body;
    }

    fn parseAnnotation(self: *Parser) Error!ParsedAnnotation {
        const at_token = try self.consume(.{
            .operand_start = false,
        });
        var arguments: ArrayList(*const syntax.Expression) = .empty;
        var properties: ArrayList(syntax.Property) = .empty;

        var annotation_end = at_token.span.end();
        const name_probe = self.peek(.{
            .operand_start = false,
        }) orelse {
            unreachable;
        };
        var name_span: text.TextSpan = insertionSpan(at_token.span.end());
        const is_adjacent_annotation_name = name_probe.kind == .name and name_probe.leading_span.len == 0;
        if (is_adjacent_annotation_name) {
            const previous_name_mode = self.name_mode;
            self.name_mode = .header;
            const name_token = try self.consume(.{
                .operand_start = false,
            });
            self.name_mode = previous_name_mode;
            name_span = name_token.span;
            annotation_end = name_span.end();
        } else {
            try self.appendDiagnostic(diag.expected_name_code, diag.expected_name_message, insertionSpan(at_token.span.end()));
        }

        var saw_property = false;
        if (name_span.len > 0) {
            try self.parseHeaderEntries(&arguments, &properties, &saw_property, &annotation_end);
        }

        const next = self.peek(.{
            .operand_start = false,
        }) orelse {
            unreachable;
        };
        var terminated_by_newline = next.has_logical_newline;
        const is_same_line_semicolon = next.kind == .semicolon and !next.has_logical_newline;
        if (is_same_line_semicolon) {
            try self.appendDiagnostic(
                diag.invalid_annotation_terminator_code,
                diag.invalid_annotation_terminator_message,
                next.span,
            );
            _ = try self.consume(.{
                .operand_start = false,
            });
            terminated_by_newline = false;
        } else if (!terminated_by_newline) {
            try self.appendDiagnostic(
                diag.invalid_annotation_terminator_code,
                diag.invalid_annotation_terminator_message,
                insertionSpan(annotation_end),
            );
        }

        const owned_arguments = try arguments.toOwnedSlice(self.allocator);
        const owned_properties = try properties.toOwnedSlice(self.allocator);
        const annotation: syntax.Annotation = .{
            .name_span = name_span,
            .span = makeSpan(at_token.span.start, annotation_end),
            .arguments = owned_arguments,
            .properties = owned_properties,
        };
        const parsed_annotation: ParsedAnnotation = .{
            .annotation = annotation,
            .terminated_by_newline = terminated_by_newline,
        };

        return parsed_annotation;
    }

    fn reportOrphanAnnotations(self: *Parser, annotations: *ArrayList(syntax.Annotation)) Error!void {
        for (annotations.items) |annotation| {
            try self.reportOrphanAnnotation(annotation);
        }

        annotations.clearRetainingCapacity();
    }

    fn reportOrphanAnnotation(self: *Parser, annotation: syntax.Annotation) Error!void {
        try self.appendDiagnostic(
            diag.unattached_annotation_code,
            diag.unattached_annotation_message,
            annotation.span,
        );
    }

    pub fn tokens(self: *const Parser) []const syntax.Token {
        return self.token_list.items;
    }

    pub fn diagnostics(self: *const Parser) []const diag.Diagnostic {
        return self.diagnostic_list.items;
    }

    fn parseExpressionAt(self: *Parser, minimum_precedence: u8) Error!*const syntax.Expression {
        var left = try self.parsePrefix();

        while (true) {
            const probe = self.peek(.{
                .operand_start = false,
            }) orelse {
                break;
            };
            const operator = self.binaryOperator(probe) orelse {
                break;
            };
            if (operator.precedence < minimum_precedence) {
                break;
            }

            const operator_token = try self.consume(.{
                .operand_start = false,
            });
            const right = try self.parseExpressionAt(operator.precedence + 1);
            left = try self.makeBinary(operator.value, operator_token.span, left, right);
        }

        return left;
    }

    fn parsePrefix(self: *Parser) Error!*const syntax.Expression {
        const probe = self.peek(.{
            .operand_start = true,
        }) orelse {
            unreachable;
        };
        if (probe.kind == .operator) {
            if (prefixOperator(self.sourceSlice(probe.span))) |operator| {
                const operator_token = try self.consume(.{
                    .operand_start = false,
                });
                try self.enterNesting();
                defer {
                    self.leaveNesting();
                }

                const operand = try self.parsePrefix();
                const span = makeSpan(operator_token.span.start, operand.span.end());
                const unary: syntax.Unary = .{
                    .operator = operator,
                    .operator_span = operator_token.span,
                    .operand = operand,
                };
                const expression_data: syntax.Data = .{
                    .unary = unary,
                };

                return self.allocateExpression(span, expression_data);
            }
        }

        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) Error!*const syntax.Expression {
        const probe = self.peek(.{
            .operand_start = true,
        }) orelse {
            unreachable;
        };

        switch (probe.kind) {
            .number => {
                const scanned = try self.consumeScanned(.{
                    .operand_start = true,
                });
                const radix = scanned.radix orelse .decimal;
                if (scanned.unit_span) |unit_span| {
                    const number: syntax.NumberWithUnit = .{
                        .number_span = scanned.number_span orelse scanned.token.span,
                        .unit_span = unit_span,
                        .radix = radix,
                    };
                    const expression_data: syntax.Data = .{
                        .number_with_unit = number,
                    };

                    return self.allocateExpression(scanned.token.span, expression_data);
                }

                const number: syntax.Number = .{
                    .number_span = scanned.number_span orelse scanned.token.span,
                    .radix = radix,
                };
                const expression_data: syntax.Data = .{
                    .number = number,
                };

                return self.allocateExpression(scanned.token.span, expression_data);
            },
            .string => {
                const scanned = try self.consumeScanned(.{
                    .operand_start = true,
                });
                const string: syntax.String = .{
                    .raw_span = scanned.token.span,
                    .style = scanned.string_style orelse .ordinary,
                    .decoded = scanned.decoded_string,
                };
                const expression_data: syntax.Data = .{
                    .string = string,
                };

                return self.allocateExpression(scanned.token.span, expression_data);
            },
            .symbol, .name => {
                return self.parseSymbolOrCall();
            },
            .left_bracket => {
                return self.parseList();
            },
            .left_parenthesis => {
                return self.parseGroup();
            },
            .left_brace => {
                return self.parseForbiddenBraceRegion();
            },
            .end_of_file,
            .right_parenthesis,
            .right_bracket,
            .right_brace,
            .comma,
            => {
                return self.makeMissingExpression(probe.span.start, true);
            },
            else => {
                const consumed = try self.consume(.{
                    .operand_start = true,
                });
                try self.appendDiagnostic(
                    diag.invalid_expression_code,
                    diag.invalid_expression_message,
                    consumed.span,
                );
                const invalid_data: syntax.Data = .{
                    .invalid = {},
                };

                return self.allocateExpression(consumed.span, invalid_data);
            },
        }
    }

    fn parseSymbolOrCall(self: *Parser) Error!*const syntax.Expression {
        const name_token = try self.consume(.{
            .operand_start = true,
        });
        const name = self.sourceSlice(name_token.span);

        if (mem.eql(u8, name, "true")) {
            const expression_data: syntax.Data = .{
                .boolean = true,
            };

            return self.allocateExpression(name_token.span, expression_data);
        }

        if (mem.eql(u8, name, "false")) {
            const expression_data: syntax.Data = .{
                .boolean = false,
            };

            return self.allocateExpression(name_token.span, expression_data);
        }

        if (mem.eql(u8, name, "null")) {
            const expression_data: syntax.Data = .{
                .null_value = {},
            };

            return self.allocateExpression(name_token.span, expression_data);
        }

        const following = self.peek(.{
            .operand_start = false,
        }) orelse {
            unreachable;
        };
        const is_adjacent_call_opening = following.kind == .left_parenthesis and following.leading_span.len == 0;
        if (is_adjacent_call_opening) {
            const open_token = try self.consume(.{
                .operand_start = false,
            });

            return self.parseCall(name_token.span, open_token);
        }

        const expression_data: syntax.Data = .{
            .symbol = name_token.span,
        };

        return self.allocateExpression(name_token.span, expression_data);
    }

    fn parseList(self: *Parser) Error!*const syntax.Expression {
        const open_token = try self.consume(.{
            .operand_start = true,
        });
        const previous_name_mode = self.name_mode;
        self.name_mode = .symbol;
        defer {
            self.name_mode = previous_name_mode;
        }

        try self.enterContainer(.right_bracket);
        defer {
            self.leaveContainer();
        }

        const elements = try self.parseDelimitedValues(.right_bracket);
        const span = makeSpan(open_token.span.start, elements.close_token.span.end());
        const list: syntax.List = .{
            .open_token = open_token,
            .elements = elements.values,
            .close_token = elements.close_token,
        };
        const expression_data: syntax.Data = .{
            .list = list,
        };

        return self.allocateExpression(span, expression_data);
    }

    fn parseCall(self: *Parser, name_span: text.TextSpan, open_token: syntax.Token) Error!*const syntax.Expression {
        const previous_name_mode = self.name_mode;
        self.name_mode = .symbol;
        defer {
            self.name_mode = previous_name_mode;
        }

        try self.enterContainer(.right_parenthesis);
        defer {
            self.leaveContainer();
        }

        const arguments = try self.parseDelimitedValues(.right_parenthesis);
        const span = makeSpan(name_span.start, arguments.close_token.span.end());
        const call: syntax.Call = .{
            .name_span = name_span,
            .open_token = open_token,
            .arguments = arguments.values,
            .close_token = arguments.close_token,
        };
        const expression_data: syntax.Data = .{
            .call = call,
        };

        return self.allocateExpression(span, expression_data);
    }

    fn parseGroup(self: *Parser) Error!*const syntax.Expression {
        const open_token = try self.consume(.{
            .operand_start = true,
        });
        const previous_name_mode = self.name_mode;
        self.name_mode = .symbol;
        defer {
            self.name_mode = previous_name_mode;
        }

        try self.enterContainer(.right_parenthesis);
        defer {
            self.leaveContainer();
        }

        var value: *const syntax.Expression = undefined;
        const first = self.peek(.{
            .operand_start = true,
        }) orelse {
            unreachable;
        };
        if (first.kind == .right_parenthesis) {
            try self.appendDiagnostic(diag.expected_value_code, diag.expected_value_message, first.span);
            value = try self.makeMissingExpression(first.span.start, false);
        } else if (isMismatchedCloser(first.kind, .right_parenthesis) or first.kind == .end_of_file) {
            try self.appendDiagnostic(diag.expected_value_code, diag.expected_value_message, insertionSpan(first.span.start));
            value = try self.makeMissingExpression(first.span.start, false);
        } else {
            value = try self.parseExpressionAt(1);
        }

        var next = self.peek(.{
            .operand_start = false,
        }) orelse {
            unreachable;
        };
        if (next.kind == .comma) {
            try self.appendDiagnostic(diag.invalid_group_code, diag.invalid_group_message, next.span);
            while (next.kind == .comma) {
                _ = try self.consume(.{
                    .operand_start = false,
                });
                next = self.peek(.{
                    .operand_start = false,
                }) orelse {
                    unreachable;
                };
                const is_group_boundary = isAnyCloser(next.kind) or next.kind == .end_of_file;
                if (is_group_boundary) {
                    break;
                }

                _ = try self.parseExpressionAt(1);
                next = self.peek(.{
                    .operand_start = false,
                }) orelse {
                    unreachable;
                };
            }
        }

        const is_group_boundary = isAnyCloser(next.kind) or next.kind == .end_of_file;
        if (!is_group_boundary) {
            try self.discardUnexpectedGroupValues(&next);
        }

        const close_token = try self.consumeExpectedClose(.right_parenthesis, next);
        const span = makeSpan(open_token.span.start, close_token.span.end());
        const group: syntax.Group = .{
            .open_token = open_token,
            .expression = value,
            .close_token = close_token,
        };
        const expression_data: syntax.Data = .{
            .group = group,
        };

        return self.allocateExpression(span, expression_data);
    }

    fn parseDelimitedValues(self: *Parser, expected_close: syntax.TokenKind) Error!DelimitedValues {
        var values: ArrayList(*const syntax.Expression) = .empty;
        var expect_value = true;

        while (true) {
            const probe = self.peek(.{
                .operand_start = true,
            }) orelse {
                unreachable;
            };
            if (probe.kind == expected_close) {
                const close_token = try self.consume(.{
                    .operand_start = false,
                });
                const owned_values = try values.toOwnedSlice(self.allocator);
                const delimited_values: DelimitedValues = .{
                    .values = owned_values,
                    .close_token = close_token,
                };

                return delimited_values;
            }

            const is_opening_delimited_value_boundary = probe.kind == .end_of_file or
                isMismatchedCloser(probe.kind, expected_close);
            if (is_opening_delimited_value_boundary) {
                const has_values = values.items.len > 0;
                const needs_empty_value = expect_value and !has_values;
                if (needs_empty_value) {
                    try self.appendDiagnostic(diag.expected_value_code, diag.expected_value_message, insertionSpan(probe.span.start));
                    try values.append(self.allocator, try self.makeMissingExpression(probe.span.start, false));
                }

                const close_token = try self.insertMissingClose(expected_close, probe.span.start);
                const owned_values = try values.toOwnedSlice(self.allocator);
                const delimited_values: DelimitedValues = .{
                    .values = owned_values,
                    .close_token = close_token,
                };

                return delimited_values;
            }

            if (probe.kind == .comma) {
                if (expect_value) {
                    try self.appendDiagnostic(diag.expected_value_code, diag.expected_value_message, probe.span);
                    try values.append(self.allocator, try self.makeMissingExpression(probe.span.start, false));
                }

                _ = try self.consume(.{
                    .operand_start = false,
                });
                expect_value = true;
                continue;
            }

            if (!expect_value) {
                try self.appendDiagnostic(diag.expected_comma_code, diag.expected_comma_message, probe.span);
                expect_value = true;
            }

            const before_start = probe.span.start;
            const value = try self.parseExpressionAt(1);
            try values.append(self.allocator, value);
            expect_value = false;

            const after = self.peek(.{
                .operand_start = false,
            }) orelse {
                unreachable;
            };
            if (after.kind == .comma) {
                _ = try self.consume(.{
                    .operand_start = false,
                });
                expect_value = true;
                continue;
            }

            const is_delimited_value_boundary = after.kind == expected_close or
                after.kind == .end_of_file or
                isMismatchedCloser(after.kind, expected_close);
            if (is_delimited_value_boundary) {
                continue;
            }

            if (after.kind == .equals) {
                try self.appendDiagnostic(diag.invalid_expression_code, diag.invalid_expression_message, after.span);
                _ = try self.consume(.{
                    .operand_start = false,
                });
            }

            const parser_made_no_progress = after.span.start == before_start;
            const produced_zero_width_value = value.span.len == 0;
            const needs_progress_recovery = parser_made_no_progress and produced_zero_width_value;
            if (needs_progress_recovery) {
                // Keep malformed streams moving if primary-expression recovery
                // returns a zero-width value without consuming input.
                try self.appendDiagnostic(diag.invalid_expression_code, diag.invalid_expression_message, after.span);
                _ = try self.consume(.{
                    .operand_start = true,
                });
                expect_value = true;
            }
        }
    }

    fn discardUnexpectedGroupValues(self: *Parser, next: *scan.Probe) Error!void {
        while (true) {
            const reached_group_boundary = isAnyCloser(next.kind) or next.kind == .end_of_file;
            if (reached_group_boundary) {
                break;
            }

            try self.appendDiagnostic(
                diag.expected_operator_code,
                diag.expected_operator_message,
                next.span,
            );

            if (next.kind == .comma) {
                _ = try self.consume(.{
                    .operand_start = false,
                });
            } else {
                _ = try self.parseExpressionAt(1);
            }

            next.* = self.peek(.{
                .operand_start = false,
            }) orelse {
                unreachable;
            };
        }
    }

    fn parseForbiddenBraceRegion(self: *Parser) Error!*const syntax.Expression {
        const open_token = try self.consume(.{
            .operand_start = true,
        });
        try self.enterContainer(.right_brace);

        var expected: [maximum_nesting]syntax.TokenKind = undefined;
        expected[0] = .right_brace;
        var expected_count: usize = 1;
        defer {
            while (expected_count > 1) {
                expected_count -= 1;
                self.leaveNesting();
            }

            self.leaveContainer();
        }

        while (true) {
            const probe = self.peek(.{
                .operand_start = true,
            }) orelse {
                unreachable;
            };
            if (probe.kind == .end_of_file) {
                try self.reportMissingForbiddenClosers(expected[0..expected_count], probe.span.start);
                const span = makeSpan(open_token.span.start, probe.span.start);
                try self.appendDiagnostic(diag.invalid_expression_code, diag.invalid_expression_message, span);
                const invalid_data: syntax.Data = .{
                    .invalid = {},
                };

                return self.allocateExpression(span, invalid_data);
            }

            if (isAnyCloser(probe.kind)) {
                if (findCloser(expected[0..expected_count], probe.kind)) |matching_index| {
                    while (expected_count - 1 > matching_index) {
                        expected_count -= 1;
                        _ = try self.insertMissingClose(expected[expected_count], probe.span.start);
                        self.leaveNesting();
                    }

                    const closing_token = try self.consume(.{
                        .operand_start = false,
                    });
                    if (matching_index == 0) {
                        const span = makeSpan(open_token.span.start, closing_token.span.end());
                        try self.appendDiagnostic(diag.invalid_expression_code, diag.invalid_expression_message, span);
                        const invalid_data: syntax.Data = .{
                            .invalid = {},
                        };

                        return self.allocateExpression(span, invalid_data);
                    }

                    expected_count -= 1;
                    self.leaveNesting();
                    continue;
                }

                if (self.isParentCloser(probe.kind)) {
                    try self.reportMissingForbiddenClosers(expected[0..expected_count], probe.span.start);
                    const span = makeSpan(open_token.span.start, probe.span.start);
                    try self.appendDiagnostic(diag.invalid_expression_code, diag.invalid_expression_message, span);
                    const invalid_data: syntax.Data = .{
                        .invalid = {},
                    };

                    return self.allocateExpression(span, invalid_data);
                }

                _ = try self.consume(.{
                    .operand_start = false,
                });
                continue;
            }

            if (openingDelimiter(probe.kind)) |matching_close| {
                const can_add_expected_closer = expected_count < maximum_nesting;
                if (!can_add_expected_closer) {
                    return error.NestingLimitExceeded;
                }

                try self.enterNesting();
                expected[expected_count] = matching_close;
                expected_count += 1;
            }

            _ = try self.consume(.{
                .operand_start = true,
            });
        }
    }

    fn reportMissingForbiddenClosers(self: *Parser, closers: []const syntax.TokenKind, insertion: usize) Error!void {
        var index = closers.len;
        while (index > 0) {
            index -= 1;
            _ = try self.insertMissingClose(closers[index], insertion);
        }
    }

    fn consumeExpectedClose(self: *Parser, expected: syntax.TokenKind, probe: scan.Probe) Error!syntax.Token {
        if (probe.kind == expected) {
            const context: scan.Context = .{
                .operand_start = false,
            };
            const close_token = try self.consume(context);

            return close_token;
        }

        return self.insertMissingClose(expected, probe.span.start);
    }

    fn insertMissingClose(self: *Parser, expected: syntax.TokenKind, insertion: usize) Error!syntax.Token {
        const span = insertionSpan(insertion);
        try self.appendDiagnostic(diag.expected_close_delimiter_code, diag.expected_close_delimiter_message, span);
        const missing_close: syntax.Token = .{
            .kind = expected,
            .span = span,
            .leading_trivia = &.{},
            .missing = true,
        };

        return missing_close;
    }

    fn makeMissingExpression(self: *Parser, insertion: usize, report_diagnostic: bool) Error!*const syntax.Expression {
        const span = insertionSpan(insertion);
        if (report_diagnostic) {
            try self.appendDiagnostic(diag.expected_value_code, diag.expected_value_message, span);
        }

        const missing_data: syntax.Data = .{
            .missing = {},
        };

        return self.allocateExpression(span, missing_data);
    }

    fn makeBinary(
        self: *Parser,
        operator: syntax.BinaryOperator,
        operator_span: text.TextSpan,
        left: *const syntax.Expression,
        right: *const syntax.Expression,
    ) Error!*const syntax.Expression {
        const span = makeSpan(left.span.start, right.span.end());
        const binary: syntax.Binary = .{
            .operator = operator,
            .operator_span = operator_span,
            .left = left,
            .right = right,
        };
        const expression_data: syntax.Data = .{
            .binary = binary,
        };

        return self.allocateExpression(span, expression_data);
    }

    fn allocateExpression(self: *Parser, span: text.TextSpan, data: syntax.Data) Error!*const syntax.Expression {
        const expression = try self.allocator.create(syntax.Expression);
        expression.* = .{
            .span = span,
            .data = data,
        };

        return expression;
    }

    fn enterNesting(self: *Parser) Error!void {
        const is_below_nesting_limit = self.active_nesting < maximum_nesting;
        if (!is_below_nesting_limit) {
            return error.NestingLimitExceeded;
        }

        self.active_nesting += 1;
    }

    fn enterContainer(self: *Parser, expected_close: syntax.TokenKind) Error!void {
        try self.enterNesting();
        self.expected_closers[self.expected_closer_count] = expected_close;
        self.expected_closer_count += 1;
    }

    fn leaveContainer(self: *Parser) void {
        self.expected_closer_count -= 1;
        self.leaveNesting();
    }

    fn leaveNesting(self: *Parser) void {
        self.active_nesting -= 1;
    }

    fn isParentCloser(self: *const Parser, kind: syntax.TokenKind) bool {
        if (!isAnyCloser(kind)) {
            return false;
        }

        var index: usize = 0;
        while (index + 1 < self.expected_closer_count) : (index += 1) {
            if (self.expected_closers[index] == kind) {
                return true;
            }
        }

        return false;
    }

    fn binaryOperator(self: *const Parser, probe: scan.Probe) ?Operator {
        const spelling = self.sourceSlice(probe.span);
        if (probe.kind == .symbol) {
            if (mem.eql(u8, spelling, "and")) {
                const operator: Operator = .{
                    .value = .logical_and,
                    .precedence = 2,
                };

                return operator;
            }

            if (mem.eql(u8, spelling, "or")) {
                const operator: Operator = .{
                    .value = .logical_or,
                    .precedence = 1,
                };

                return operator;
            }

            return null;
        }

        if (probe.kind != .operator) {
            return null;
        }

        if (mem.eql(u8, spelling, "==")) {
            const operator: Operator = .{
                .value = .equal,
                .precedence = 3,
            };

            return operator;
        }

        if (mem.eql(u8, spelling, "!=")) {
            const operator: Operator = .{
                .value = .not_equal,
                .precedence = 3,
            };

            return operator;
        }

        if (mem.eql(u8, spelling, "<")) {
            const operator: Operator = .{
                .value = .less_than,
                .precedence = 4,
            };

            return operator;
        }

        if (mem.eql(u8, spelling, "<=")) {
            const operator: Operator = .{
                .value = .less_than_or_equal,
                .precedence = 4,
            };

            return operator;
        }

        if (mem.eql(u8, spelling, ">")) {
            const operator: Operator = .{
                .value = .greater_than,
                .precedence = 4,
            };

            return operator;
        }

        if (mem.eql(u8, spelling, ">=")) {
            const operator: Operator = .{
                .value = .greater_than_or_equal,
                .precedence = 4,
            };

            return operator;
        }

        if (mem.eql(u8, spelling, "+")) {
            const operator: Operator = .{
                .value = .add,
                .precedence = 5,
            };

            return operator;
        }

        if (mem.eql(u8, spelling, "-")) {
            const operator: Operator = .{
                .value = .subtract,
                .precedence = 5,
            };

            return operator;
        }

        if (mem.eql(u8, spelling, "*")) {
            const operator: Operator = .{
                .value = .multiply,
                .precedence = 6,
            };

            return operator;
        }

        if (mem.eql(u8, spelling, "/")) {
            const operator: Operator = .{
                .value = .divide,
                .precedence = 6,
            };

            return operator;
        }

        if (mem.eql(u8, spelling, "%")) {
            const operator: Operator = .{
                .value = .remainder,
                .precedence = 6,
            };

            return operator;
        }

        return null;
    }

    fn peek(self: *const Parser, context: scan.Context) ?scan.Probe {
        var scanner_context = context;
        scanner_context.name_mode = self.name_mode;

        return self.scanner.probe(scanner_context);
    }

    fn consume(self: *Parser, context: scan.Context) Error!syntax.Token {
        var scanner_context = context;
        scanner_context.name_mode = self.name_mode;
        const scanned = try self.scanner.next(scanner_context);
        try self.token_list.append(self.allocator, scanned.token);
        try self.copyScannerDiagnostics();

        return scanned.token;
    }

    fn consumeScanned(self: *Parser, context: scan.Context) Error!scan.ScannedToken {
        var scanner_context = context;
        scanner_context.name_mode = self.name_mode;
        const scanned = try self.scanner.next(scanner_context);
        try self.token_list.append(self.allocator, scanned.token);
        try self.copyScannerDiagnostics();

        return scanned;
    }

    fn copyScannerDiagnostics(self: *Parser) Error!void {
        const scanner_diagnostics = self.scanner.diagnostics();
        const has_another_scanner_diagnostic = self.scanner_diagnostic_count < scanner_diagnostics.len;
        if (!has_another_scanner_diagnostic) {
            return;
        }

        try self.diagnostic_list.appendSlice(
            self.allocator,
            scanner_diagnostics[self.scanner_diagnostic_count..],
        );
        self.scanner_diagnostic_count = scanner_diagnostics.len;
    }

    fn appendDiagnostic(self: *Parser, code: []const u8, message: []const u8, span: text.TextSpan) Error!void {
        try self.diagnostic_list.append(self.allocator, .{
            .code = code,
            .severity = .err,
            .message = message,
            .span = span,
        });
    }

    fn appendRelatedDiagnostic(
        self: *Parser,
        code: []const u8,
        message: []const u8,
        span: text.TextSpan,
        related_span: text.TextSpan,
    ) Error!void {
        try self.diagnostic_list.append(self.allocator, .{
            .code = code,
            .severity = .err,
            .message = message,
            .span = span,
            .related_span = related_span,
        });
    }

    fn spansHaveEqualText(self: *const Parser, left: text.TextSpan, right: text.TextSpan) bool {
        return mem.eql(u8, self.sourceSlice(left), self.sourceSlice(right));
    }

    fn sourceSlice(self: *const Parser, span: text.TextSpan) []const u8 {
        return self.source[span.start..span.end()];
    }
};

const DelimitedValues = struct {
    values: []const *const syntax.Expression,
    close_token: syntax.Token,
};

const ParsedAnnotation = struct {
    annotation: syntax.Annotation,
    terminated_by_newline: bool,
};

fn prefixOperator(spelling: []const u8) ?syntax.UnaryOperator {
    if (mem.eql(u8, spelling, "+")) {
        return .plus;
    }

    if (mem.eql(u8, spelling, "-")) {
        return .minus;
    }

    if (mem.eql(u8, spelling, "!")) {
        return .logical_not;
    }

    return null;
}

fn isMismatchedCloser(kind: syntax.TokenKind, expected: syntax.TokenKind) bool {
    const is_closer = isAnyCloser(kind);
    if (!is_closer) {
        return false;
    }

    return kind != expected;
}

fn isAnyCloser(kind: syntax.TokenKind) bool {
    return kind == .right_parenthesis or kind == .right_bracket or kind == .right_brace;
}

fn findCloser(closers: []const syntax.TokenKind, requested: syntax.TokenKind) ?usize {
    var index = closers.len;
    while (index > 0) {
        index -= 1;
        if (closers[index] == requested) {
            return index;
        }
    }

    return null;
}

fn openingDelimiter(kind: syntax.TokenKind) ?syntax.TokenKind {
    return switch (kind) {
        .left_parenthesis => .right_parenthesis,
        .left_bracket => .right_bracket,
        .left_brace => .right_brace,
        else => null,
    };
}

fn isHeaderEntryBoundary(kind: syntax.TokenKind) bool {
    return switch (kind) {
        .end_of_file, .semicolon, .right_brace, .left_brace, .at_sign => true,
        else => false,
    };
}

fn isHeaderValueBoundary(kind: syntax.TokenKind) bool {
    return switch (kind) {
        .end_of_file,
        .semicolon,
        .right_brace,
        .left_brace,
        .at_sign,
        .right_parenthesis,
        .right_bracket,
        .comma,
        => true,
        else => false,
    };
}

fn missingToken(kind: syntax.TokenKind, insertion: usize) syntax.Token {
    const token: syntax.Token = .{
        .kind = kind,
        .span = insertionSpan(insertion),
        .leading_trivia = &.{},
        .missing = true,
    };

    return token;
}

fn insertionSpan(offset: usize) text.TextSpan {
    const span: text.TextSpan = .{
        .start = offset,
        .len = 0,
    };

    return span;
}

fn makeSpan(start: usize, end: usize) text.TextSpan {
    const span: text.TextSpan = .{
        .start = start,
        .len = end - start,
    };

    return span;
}

test "precedence, left associativity, and unary nesting produce exact expression shapes" {
    const allocator = testing.allocator;
    var arena = ArenaAllocator.init(allocator);
    defer {
        arena.deinit();
    }

    var parser = Parser.init(arena.allocator(), "a - b - c + d * e < f == g and h or i");
    const expression = try parser.parseFullExpression();

    const disjunction = expression.data.binary;
    try testing.expectEqual(syntax.BinaryOperator.logical_or, disjunction.operator);
    const conjunction = disjunction.left.data.binary;
    try testing.expectEqual(syntax.BinaryOperator.logical_and, conjunction.operator);
    const equality = conjunction.left.data.binary;
    try testing.expectEqual(syntax.BinaryOperator.equal, equality.operator);
    const relational = equality.left.data.binary;
    try testing.expectEqual(syntax.BinaryOperator.less_than, relational.operator);
    const addition = relational.left.data.binary;
    try testing.expectEqual(syntax.BinaryOperator.add, addition.operator);
    const subtraction = addition.left.data.binary;
    try testing.expectEqual(syntax.BinaryOperator.subtract, subtraction.operator);
    try testing.expectEqual(syntax.BinaryOperator.subtract, subtraction.left.data.binary.operator);
    try testing.expectEqual(syntax.BinaryOperator.multiply, addition.right.data.binary.operator);
    try testing.expectEqual(@as(usize, 0), parser.diagnostics().len);

    var unary_parser = Parser.init(arena.allocator(), "!-+value");
    const unary = try unary_parser.parseFullExpression();
    try testing.expectEqual(syntax.UnaryOperator.logical_not, unary.data.unary.operator);
    try testing.expectEqual(syntax.UnaryOperator.minus, unary.data.unary.operand.data.unary.operator);
    try testing.expectEqual(syntax.UnaryOperator.plus, unary.data.unary.operand.data.unary.operand.data.unary.operator);
}

test "every symbolic operator maps to its specified syntax node" {
    const OperatorCase = struct {
        spelling: []const u8,
        expected: syntax.BinaryOperator,
    };
    const cases = [_]OperatorCase{
        .{
            .spelling = "*",
            .expected = .multiply,
        },
        .{
            .spelling = "/",
            .expected = .divide,
        },
        .{
            .spelling = "%",
            .expected = .remainder,
        },
        .{
            .spelling = "+",
            .expected = .add,
        },
        .{
            .spelling = "-",
            .expected = .subtract,
        },
        .{
            .spelling = "<",
            .expected = .less_than,
        },
        .{
            .spelling = "<=",
            .expected = .less_than_or_equal,
        },
        .{
            .spelling = ">",
            .expected = .greater_than,
        },
        .{
            .spelling = ">=",
            .expected = .greater_than_or_equal,
        },
        .{
            .spelling = "==",
            .expected = .equal,
        },
        .{
            .spelling = "!=",
            .expected = .not_equal,
        },
        .{
            .spelling = "and",
            .expected = .logical_and,
        },
        .{
            .spelling = "or",
            .expected = .logical_or,
        },
    };

    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    for (cases) |operator_case| {
        const source = try mem.concat(
            arena.allocator(),
            u8,
            &.{ "left ", operator_case.spelling, " right" },
        );
        var parser = Parser.init(arena.allocator(), source);
        const expression = try parser.parseFullExpression();
        try testing.expectEqual(operator_case.expected, expression.data.binary.operator);
        try testing.expectEqual(@as(usize, 0), parser.diagnostics().len);
    }
}

test "keywords are symbols in operand positions and infix operators only between operands" {
    const allocator = testing.allocator;
    var arena = ArenaAllocator.init(allocator);
    defer {
        arena.deinit();
    }

    var list_parser = Parser.init(arena.allocator(), "[and, or]");
    const list_expression = try list_parser.parseFullExpression();
    const list = list_expression.data.list;
    try testing.expectEqual(@as(usize, 2), list.elements.len);
    try testing.expectEqualStrings("and", list_parser.sourceSlice(list.elements[0].data.symbol));
    try testing.expectEqualStrings("or", list_parser.sourceSlice(list.elements[1].data.symbol));

    var binary_parser = Parser.init(arena.allocator(), "(a and or)");
    const grouped = try binary_parser.parseFullExpression();
    const group = grouped.data.group;
    const conjunction = group.expression.data.binary;
    try testing.expectEqual(syntax.BinaryOperator.logical_and, conjunction.operator);
    try testing.expectEqualStrings("or", binary_parser.sourceSlice(conjunction.right.data.symbol));
}

test "numbers retain units and radix while signs remain unary expressions" {
    const allocator = testing.allocator;
    var arena = ArenaAllocator.init(allocator);
    defer {
        arena.deinit();
    }

    var parser = Parser.init(arena.allocator(), "(-0xFF + 1e3ms)");
    const grouped = try parser.parseFullExpression();
    const group = grouped.data.group;
    const addition = group.expression.data.binary;
    try testing.expectEqual(syntax.UnaryOperator.minus, addition.left.data.unary.operator);
    try testing.expectEqual(syntax.Radix.hexadecimal, addition.left.data.unary.operand.data.number.radix);
    const unit_number = addition.right.data.number_with_unit;
    try testing.expectEqual(syntax.Radix.decimal, unit_number.radix);
    try testing.expectEqual(@as(usize, 2), unit_number.unit_span.len);
    try testing.expectEqual(@as(usize, 0), parser.diagnostics().len);
}

test "calls require adjacent symbolic names and preserve delimiters" {
    const allocator = testing.allocator;
    var arena = ArenaAllocator.init(allocator);
    defer {
        arena.deinit();
    }

    var call_parser = Parser.init(arena.allocator(), "math.clamp(1, base + 2,)");
    const call_expression = try call_parser.parseFullExpression();
    const call = call_expression.data.call;
    try testing.expectEqual(@as(usize, 2), call.arguments.len);
    try testing.expectEqualStrings("math.clamp", call_parser.sourceSlice(call.name_span));
    try testing.expect(!call.open_token.missing);
    try testing.expect(!call.close_token.missing);

    var spaced_parser = Parser.init(arena.allocator(), "foo (1)");
    _ = try spaced_parser.parseFullExpression();
    try testing.expectEqualStrings("expected_operator", spaced_parser.diagnostics()[0].code);

    var keyword_parser = Parser.init(arena.allocator(), "true(1)");
    _ = try keyword_parser.parseFullExpression();
    try testing.expectEqualStrings("expected_operator", keyword_parser.diagnostics()[0].code);

    var chained_parser = Parser.init(arena.allocator(), "foo(1)(2)");
    _ = try chained_parser.parseFullExpression();
    try testing.expectEqualStrings("expected_operator", chained_parser.diagnostics()[0].code);
}

test "objects and named call arguments remain invalid syntax while retaining real tokens" {
    const allocator = testing.allocator;
    var arena = ArenaAllocator.init(allocator);
    defer {
        arena.deinit();
    }

    var object_parser = Parser.init(arena.allocator(), "{attempts=3}");
    _ = try object_parser.parseFullExpression();
    try testing.expect(object_parser.diagnostics().len > 0);
    try testing.expectEqual(syntax.TokenKind.left_brace, object_parser.tokens()[0].kind);

    var named_call_parser = Parser.init(arena.allocator(), "foo(attempts=3)");
    _ = try named_call_parser.parseFullExpression();
    try testing.expect(named_call_parser.diagnostics().len > 0);
    try testing.expectEqual(syntax.TokenKind.equals, named_call_parser.tokens()[3].kind);
}

test "group adjacency recovery keeps the group close and later list siblings" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    var parser = Parser.init(arena.allocator(), "[(a b), 3]");
    const expression = try parser.parseFullExpression();
    const list = expression.data.list;
    try testing.expectEqual(@as(usize, 2), list.elements.len);
    const group = list.elements[0].data.group;
    try testing.expectEqualStrings("a", parser.sourceSlice(group.expression.data.symbol));
    try testing.expect(!group.close_token.missing);
    try testing.expectEqualStrings("3", parser.sourceSlice(list.elements[1].span));
    try testing.expectEqualStrings("expected_operator", parser.diagnostics()[0].code);
}

test "forbidden braced regions stay one invalid list element and preserve parent closers" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const source = "[{a=1}, 2]";
    var parser = Parser.init(arena.allocator(), source);
    const expression = try parser.parseFullExpression();
    const list = expression.data.list;
    try testing.expectEqual(@as(usize, 2), list.elements.len);
    try testing.expectEqual(syntax.Data.invalid, meta.activeTag(list.elements[0].data));
    try testing.expectEqualStrings("{a=1}", parser.sourceSlice(list.elements[0].span));
    try testing.expectEqualStrings("2", parser.sourceSlice(list.elements[1].span));
    try testing.expect(!list.close_token.missing);
    try testing.expectEqual(syntax.TokenKind.right_bracket, parser.tokens()[parser.tokens().len - 2].kind);

    var parent_close_parser = Parser.init(arena.allocator(), "[{a=1, 2]");
    const parent_close_expression = try parent_close_parser.parseFullExpression();
    try testing.expectEqual(@as(usize, 1), parent_close_expression.data.list.elements.len);
    try testing.expectEqual(syntax.Data.invalid, meta.activeTag(parent_close_expression.data.list.elements[0].data));
    try testing.expect(!parent_close_expression.data.list.close_token.missing);
    try testing.expectEqualStrings("expected_close_delimiter", parent_close_parser.diagnostics()[0].code);
}

test "containers recover missing elements commas and closers without stealing outer closers" {
    const allocator = testing.allocator;
    var arena = ArenaAllocator.init(allocator);
    defer {
        arena.deinit();
    }

    var missing_element_parser = Parser.init(arena.allocator(), "[1,,2]");
    const missing_element = try missing_element_parser.parseFullExpression();
    try testing.expectEqual(@as(usize, 3), missing_element.data.list.elements.len);
    try testing.expectEqual(syntax.Data.missing, meta.activeTag(missing_element.data.list.elements[1].data));
    try testing.expectEqualStrings("expected_value", missing_element_parser.diagnostics()[0].code);

    var missing_comma_parser = Parser.init(arena.allocator(), "[1 2]");
    const missing_comma = try missing_comma_parser.parseFullExpression();
    try testing.expectEqual(@as(usize, 2), missing_comma.data.list.elements.len);
    try testing.expectEqualStrings("expected_comma", missing_comma_parser.diagnostics()[0].code);

    var outer_close_parser = Parser.init(arena.allocator(), "([1)");
    const outer_group = try outer_close_parser.parseFullExpression();
    try testing.expect(outer_group.data.group.close_token.missing == false);
    try testing.expect(outer_group.data.group.expression.data.list.close_token.missing);
    try testing.expectEqual(@as(usize, 5), outer_close_parser.tokens().len);

    var nested_tuple_parser = Parser.init(arena.allocator(), "[(1, foo(2)), 3]");
    const nested_tuple = try nested_tuple_parser.parseFullExpression();
    try testing.expectEqual(@as(usize, 2), nested_tuple.data.list.elements.len);
    try testing.expectEqualStrings("3", nested_tuple_parser.sourceSlice(nested_tuple.data.list.elements[1].span));
    try testing.expectEqualStrings("invalid_group", nested_tuple_parser.diagnostics()[0].code);
}

test "empty delimiters and malformed groups retain syntax with diagnostics" {
    const allocator = testing.allocator;
    var arena = ArenaAllocator.init(allocator);
    defer {
        arena.deinit();
    }

    var list_parser = Parser.init(arena.allocator(), "[]");
    const empty_list = try list_parser.parseFullExpression();
    try testing.expectEqual(@as(usize, 0), empty_list.data.list.elements.len);

    var empty_call_parser = Parser.init(arena.allocator(), "foo()");
    const empty_call = try empty_call_parser.parseFullExpression();
    try testing.expectEqual(@as(usize, 0), empty_call.data.call.arguments.len);

    var empty_group_parser = Parser.init(arena.allocator(), "()");
    const empty_group = try empty_group_parser.parseFullExpression();
    try testing.expectEqual(syntax.Data.missing, meta.activeTag(empty_group.data.group.expression.data));
    try testing.expectEqualStrings("expected_value", empty_group_parser.diagnostics()[0].code);

    var tuple_parser = Parser.init(arena.allocator(), "(1, 2)");
    _ = try tuple_parser.parseFullExpression();
    try testing.expectEqualStrings("invalid_group", tuple_parser.diagnostics()[0].code);
}

test "marked strings are recognized at operand starts after comparison operators" {
    const allocator = testing.allocator;
    var arena = ArenaAllocator.init(allocator);
    defer {
        arena.deinit();
    }

    var ordinary_parser = Parser.init(arena.allocator(), "left>'right'");
    const ordinary_comparison = try ordinary_parser.parseFullExpression();
    try testing.expectEqual(syntax.BinaryOperator.greater_than, ordinary_comparison.data.binary.operator);
    try testing.expectEqual(syntax.StringStyle.ordinary, ordinary_comparison.data.binary.right.data.string.style);

    var folded_parser = Parser.init(arena.allocator(), "left > >'fold'");
    const folded_comparison = try folded_parser.parseFullExpression();
    try testing.expectEqual(syntax.BinaryOperator.greater_than, folded_comparison.data.binary.operator);
    try testing.expectEqual(syntax.StringStyle.folded, folded_comparison.data.binary.right.data.string.style);
}

test "active nesting limit counts containers and prefix operators but not flat values" {
    const allocator = testing.allocator;
    var arena = ArenaAllocator.init(allocator);
    defer {
        arena.deinit();
    }

    const accepted = try allocator.alloc(u8, maximum_nesting * 2 + 1);
    defer {
        allocator.free(accepted);
    }

    for (0..maximum_nesting) |index| {
        accepted[index] = '(';
    }

    accepted[maximum_nesting] = 'x';
    for (0..maximum_nesting) |index| {
        accepted[maximum_nesting + 1 + index] = ')';
    }

    var accepted_parser = Parser.init(arena.allocator(), accepted);
    _ = try accepted_parser.parseFullExpression();

    const rejected = try allocator.alloc(u8, (maximum_nesting + 1) * 2 + 1);
    defer {
        allocator.free(rejected);
    }

    for (0..maximum_nesting + 1) |index| {
        rejected[index] = '(';
    }

    rejected[maximum_nesting + 1] = 'x';
    for (0..maximum_nesting + 1) |index| {
        rejected[maximum_nesting + 2 + index] = ')';
    }

    var rejected_parser = Parser.init(arena.allocator(), rejected);
    try testing.expectError(error.NestingLimitExceeded, rejected_parser.parseFullExpression());

    const prefix_source = try allocator.alloc(u8, maximum_nesting + 1);
    defer {
        allocator.free(prefix_source);
    }

    @memset(prefix_source[0..maximum_nesting], '!');
    prefix_source[maximum_nesting] = 'x';
    var prefix_parser = Parser.init(arena.allocator(), prefix_source);
    _ = try prefix_parser.parseFullExpression();

    const rejected_prefix = try allocator.alloc(u8, maximum_nesting + 2);
    defer {
        allocator.free(rejected_prefix);
    }

    @memset(rejected_prefix[0 .. maximum_nesting + 1], '!');
    rejected_prefix[maximum_nesting + 1] = 'x';
    var rejected_prefix_parser = Parser.init(arena.allocator(), rejected_prefix);
    try testing.expectError(error.NestingLimitExceeded, rejected_prefix_parser.parseFullExpression());

    const combined_accepted = try allocator.alloc(u8, maximum_nesting * 2);
    defer {
        allocator.free(combined_accepted);
    }

    for (0..maximum_nesting - 1) |index| {
        combined_accepted[index] = '(';
    }

    combined_accepted[maximum_nesting - 1] = '!';
    combined_accepted[maximum_nesting] = 'x';
    for (0..maximum_nesting - 1) |index| {
        combined_accepted[maximum_nesting + 1 + index] = ')';
    }

    var combined_accepted_parser = Parser.init(arena.allocator(), combined_accepted);
    _ = try combined_accepted_parser.parseFullExpression();

    const combined_rejected = try allocator.alloc(u8, maximum_nesting * 2 + 2);
    defer {
        allocator.free(combined_rejected);
    }

    for (0..maximum_nesting) |index| {
        combined_rejected[index] = '(';
    }

    combined_rejected[maximum_nesting] = '!';
    combined_rejected[maximum_nesting + 1] = 'x';
    for (0..maximum_nesting) |index| {
        combined_rejected[maximum_nesting + 2 + index] = ')';
    }

    var combined_rejected_parser = Parser.init(arena.allocator(), combined_rejected);
    try testing.expectError(error.NestingLimitExceeded, combined_rejected_parser.parseFullExpression());

    const flat_source = try allocator.alloc(u8, 2001);
    defer {
        allocator.free(flat_source);
    }

    for (0..1000) |index| {
        flat_source[index * 2] = 'x';
        flat_source[index * 2 + 1] = '+';
    }

    flat_source[2000] = 'x';
    var flat_parser = Parser.init(arena.allocator(), flat_source);
    _ = try flat_parser.parseFullExpression();
    try testing.expectEqual(@as(usize, 0), flat_parser.diagnostics().len);

    const flat_list_source = try allocator.alloc(u8, 2001);
    defer {
        allocator.free(flat_list_source);
    }

    flat_list_source[0] = '[';
    for (0..999) |index| {
        flat_list_source[index * 2 + 1] = 'x';
        flat_list_source[index * 2 + 2] = ',';
    }

    flat_list_source[1999] = 'x';
    flat_list_source[2000] = ']';
    var flat_list_parser = Parser.init(arena.allocator(), flat_list_source);
    const flat_list = try flat_list_parser.parseFullExpression();
    try testing.expectEqual(@as(usize, 1000), flat_list.data.list.elements.len);
}

test "scanner tokens retain committed trivia and EOF without eager tokenization" {
    const allocator = testing.allocator;
    var arena = ArenaAllocator.init(allocator);
    defer {
        arena.deinit();
    }

    var parser = Parser.init(arena.allocator(), "a + b // tail\n");
    const expression = try parser.parseFullExpression();
    try testing.expectEqual(syntax.BinaryOperator.add, expression.data.binary.operator);
    try testing.expectEqual(syntax.TokenKind.end_of_file, parser.tokens()[parser.tokens().len - 1].kind);
    try testing.expectEqual(syntax.TriviaKind.horizontal_whitespace, parser.tokens()[1].leading_trivia[0].kind);
    try testing.expectEqual(syntax.TriviaKind.line_comment, parser.tokens()[parser.tokens().len - 1].leading_trivia[1].kind);
}
