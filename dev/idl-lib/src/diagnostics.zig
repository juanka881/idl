const text = @import("text.zig");

pub const Severity = enum {
    information,
    warning,
    err,
};

pub const Diagnostic = struct {
    code: []const u8,
    severity: Severity,
    message: []const u8,
    span: text.TextSpan,
    related_span: ?text.TextSpan = null,
};

pub const invalid_utf8_code = "invalid_utf8";
pub const invalid_utf8_message = "Invalid UTF-8 byte.";
pub const invalid_number_code = "invalid_number";
pub const invalid_number_message = "Invalid number spelling.";
pub const invalid_escape_code = "invalid_escape";
pub const invalid_escape_message = "Invalid string escape.";
pub const unterminated_string_code = "unterminated_string";
pub const unterminated_string_message = "Unterminated string literal.";
pub const unterminated_comment_code = "unterminated_comment";
pub const unterminated_comment_message = "Unterminated block comment.";
pub const invalid_control_code = "invalid_control";
pub const invalid_control_message = "Control character is not allowed here.";
pub const invalid_character_code = "invalid_character";
pub const invalid_character_message = "Character is not allowed in this context.";
pub const invalid_operator_code = "invalid_operator";
pub const invalid_operator_message = "Operator is not supported.";
pub const expected_value_code = "expected_value";
pub const expected_value_message = "Expected a value expression.";
pub const expected_comma_code = "expected_comma";
pub const expected_comma_message = "Expected a comma between expressions.";
pub const expected_close_delimiter_code = "expected_close_delimiter";
pub const expected_close_delimiter_message = "Expected a closing delimiter.";
pub const expected_operator_code = "expected_operator";
pub const expected_operator_message = "Expected an operator between expressions.";
pub const invalid_group_code = "invalid_group";
pub const invalid_group_message = "A group must contain exactly one expression.";
pub const invalid_expression_code = "invalid_expression";
pub const invalid_expression_message = "Invalid expression syntax.";
pub const expected_name_code = "expected_name";
pub const expected_name_message = "Expected a name here.";
pub const expected_node_code = "expected_node";
pub const expected_node_message = "Expected a node declaration here.";
pub const expected_separator_code = "expected_separator";
pub const expected_separator_message = "Expected a node separator before this entry.";
pub const argument_after_property_code = "argument_after_property";
pub const argument_after_property_message = "Positional arguments must precede properties.";
pub const duplicate_property_code = "duplicate_property";
pub const duplicate_property_message = "Property is repeated in this header.";
pub const multiple_bodies_code = "multiple_bodies";
pub const multiple_bodies_message = "A node can have only one body.";
pub const unattached_annotation_code = "unattached_annotation";
pub const unattached_annotation_message = "Annotation is not attached to a node.";
pub const invalid_annotation_terminator_code = "invalid_annotation_terminator";
pub const invalid_annotation_terminator_message = "Annotation must end at a logical newline.";
pub const unexpected_closing_brace_code = "unexpected_closing_brace";
pub const unexpected_closing_brace_message = "Closing brace has no matching body.";
pub const invalid_header_value_code = "invalid_header_value";
pub const invalid_header_value_message = "Operator is not valid as a bare header value.";
pub const invalid_continuation_code = "invalid_continuation";
pub const invalid_continuation_message = "Line continuation must end with a newline.";
