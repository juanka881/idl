const text = @import("text.zig");

pub const TextSpan = text.TextSpan;

pub const TriviaKind = enum {
    horizontal_whitespace,
    newline,
    line_comment,
    block_comment,
    continuation,
    skipped,
};

pub const Trivia = struct {
    kind: TriviaKind,
    span: TextSpan,
};

pub const TokenKind = enum {
    name,
    symbol,
    number,
    string,
    at_sign,
    equals,
    comma,
    semicolon,
    left_parenthesis,
    right_parenthesis,
    left_bracket,
    right_bracket,
    left_brace,
    right_brace,
    operator,
    unknown,
    end_of_file,
};

pub const Token = struct {
    kind: TokenKind,
    span: TextSpan,
    leading_trivia: []const Trivia,
    missing: bool = false,
};

pub const Radix = enum {
    decimal,
    hexadecimal,
};

pub const Number = struct {
    number_span: TextSpan,
    radix: Radix,
};

pub const NumberWithUnit = struct {
    number_span: TextSpan,
    unit_span: TextSpan,
    radix: Radix,
};

pub const StringStyle = enum {
    ordinary,
    dedented,
    folded,
};

pub const String = struct {
    raw_span: TextSpan,
    style: StringStyle,
    decoded: ?[]const u8,
};

pub const UnaryOperator = enum {
    plus,
    minus,
    logical_not,
};

pub const BinaryOperator = enum {
    add,
    subtract,
    multiply,
    divide,
    remainder,
    less_than,
    less_than_or_equal,
    greater_than,
    greater_than_or_equal,
    equal,
    not_equal,
    logical_and,
    logical_or,
};

pub const Expression = struct {
    span: TextSpan,
    data: Data,
};

pub const Data = union(enum) {
    number: Number,
    number_with_unit: NumberWithUnit,
    string: String,
    boolean: bool,
    null_value: void,
    symbol: TextSpan,
    list: List,
    call: Call,
    group: Group,
    unary: Unary,
    binary: Binary,
    missing: void,
    invalid: void,
};

pub const List = struct {
    open_token: Token,
    elements: []const *const Expression,
    close_token: Token,
};

pub const Call = struct {
    name_span: TextSpan,
    open_token: Token,
    arguments: []const *const Expression,
    close_token: Token,
};

pub const Group = struct {
    open_token: Token,
    expression: *const Expression,
    close_token: Token,
};

pub const Unary = struct {
    operator: UnaryOperator,
    operator_span: TextSpan,
    operand: *const Expression,
};

pub const Binary = struct {
    operator: BinaryOperator,
    operator_span: TextSpan,
    left: *const Expression,
    right: *const Expression,
};

pub const Property = struct {
    name_span: TextSpan,
    equals_token: Token,
    value: *const Expression,
    span: TextSpan,
};

pub const Annotation = struct {
    name_span: TextSpan,
    span: TextSpan,
    arguments: []const *const Expression,
    properties: []const Property,
};

pub const Body = struct {
    open_token: Token,
    close_token: Token,
    children: []const Node,
};

pub const Node = struct {
    name_span: TextSpan,
    span: TextSpan,
    annotations: []const Annotation,
    arguments: []const *const Expression,
    properties: []const Property,
    body: ?Body,
};
