//! The conzig format, see README.md.

pub const Kind = enum {
    @"have-header",
    @"have-function",
    @"have-type",
    @"have-member",
    @"have-decl",
    links,
    sizeof,
    alignof,
    compiles,
    runs,
    exists,
    when,
    select,
    literal,

    /// Whether answering this takes a compiler.
    pub fn needsCompiler(kind: Kind) bool {
        return switch (kind) {
            .@"have-header", .@"have-function", .@"have-type", .@"have-member", .@"have-decl", .links, .compiles, .sizeof, .alignof => true,
            .runs, .exists, .when, .select, .literal => false,
        };
    }

    /// Whether this is true or false rather than having a value, so it needs `? PASS|FAIL`.
    fn isCheck(kind: Kind) bool {
        return switch (kind) {
            .@"have-header", .@"have-function", .@"have-type", .@"have-member", .@"have-decl", .links, .compiles, .runs, .exists, .when => true,
            .sizeof, .alignof, .select, .literal => false,
        };
    }
};

pub const Attrs = struct {
    includes: []const []const u8 = &.{},
    defines: []const []const u8 = &.{},
    libs: []const []const u8 = &.{},
};

pub const Arm = struct {
    value: Value,
    /// Null for the last one, which always matches.
    condition: ?*const Expr,
};

pub const Def = struct {
    name: []const u8,
    line: u32,
    local: bool = false,
    kind: Kind,
    args: []const []const u8 = &.{},
    attrs: Attrs = .{},
    body: []const []const u8 = &.{},
    guard: ?*const Expr = null,
    assume: ?*const Expr = null,
    /// The expression of a `when`.
    expr: ?*const Expr = null,
    /// The lines of a `select`.
    arms: []const Arm = &.{},
    /// This definition's lines from the file, to write it back out if it can't be resolved.
    source: []const u8 = "",
    /// The value of a `literal`.
    value: Value = .undef,
    /// The values from `? PASS|FAIL`, for the kinds that are true or false.
    pass: Value = .undef,
    fail: Value = .undef,
};

pub const Input = struct {
    name: []const u8,
    value: []const u8,
};

pub const File = struct {
    /// The inputs an earlier run was given, its results are only right for these.
    inputs: []const Input = &.{},
    /// The prelude's line from the file.
    prelude_source: []const u8 = "",
    prelude: Attrs = .{},
    defs: []const Def = &.{},
};

pub const Value = union(enum) {
    undef,
    defined,
    false,
    true,
    int: i64,
    string: []const u8,
    ident: []const u8,

    pub fn parse(str: []const u8) ?Value {
        if (std.mem.eql(u8, str, "undef")) return .undef;
        if (std.mem.eql(u8, str, "defined")) return .defined;
        if (std.mem.eql(u8, str, "false")) return .false;
        if (std.mem.eql(u8, str, "true")) return .true;
        if (std.fmt.parseInt(i64, str, 10)) |int| return .{ .int = int } else |_| {}
        if (str.len >= 2 and str[0] == '"' and str[str.len - 1] == '"') return .{ .string = str[1 .. str.len - 1] };
        // strings and idents are passed along verbatim, an ident can have spaces
        if (str.len >= 2 and str[0] == ':') return .{ .ident = str[1..] };
        return null;
    }

    pub fn format(value: Value, w: *std.Io.Writer) error{WriteFailed}!void {
        switch (value) {
            .undef => try w.writeAll("undef"),
            .defined => try w.writeAll("defined"),
            .false => try w.writeAll("false"),
            .true => try w.writeAll("true"),
            .int => |int| try w.print("{}", .{int}),
            .string => |str| try w.print("\"{s}\"", .{str}),
            .ident => |str| try w.print(":{s}", .{str}),
        }
    }
};

pub const Expr = union(enum) {
    boolean: bool,
    int: i64,
    version: std.SemanticVersion,
    literal: []const u8,
    name: []const u8,
    not: *const Expr,
    @"and": [2]*const Expr,
    @"or": [2]*const Expr,
    compare: struct { op: Op, operands: [2]*const Expr },

    pub const Op = enum { eq, ne, lt, le, gt, ge };
};

/// What an expression or an input evaluates to.
pub const Result = union(enum) {
    boolean: bool,
    int: i64,
    version: std.SemanticVersion,
    literal: []const u8,

    /// `true` and `false`, an integer, a version if it has a dot, otherwise an enum literal.
    pub fn parseInput(str: []const u8) Result {
        if (std.mem.eql(u8, str, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, str, "false")) return .{ .boolean = false };
        if (std.fmt.parseInt(i64, str, 10)) |int| return .{ .int = int } else |_| {}
        if (parseVersion(str)) |version| return .{ .version = version };
        return .{ .literal = str };
    }
};

fn parseVersion(str: []const u8) ?std.SemanticVersion {
    var version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };
    var it = std.mem.splitScalar(u8, str, '.');
    version.major = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    version.minor = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    if (it.next()) |patch| version.patch = std.fmt.parseInt(usize, patch, 10) catch return null;
    if (it.next() != null) return null;
    return version;
}

pub const Diagnostic = struct {
    line: u32 = 0,
    message: []const u8 = "",
};

pub const ParseError = error{ Invalid, OutOfMemory };

fn invalid(arena: std.mem.Allocator, diagnostic: *Diagnostic, line: u32, comptime fmt: []const u8, args: anytype) ParseError {
    diagnostic.* = .{ .line = line, .message = try std.fmt.allocPrint(arena, fmt, args) };
    return error.Invalid;
}

/// Splits on spaces, a double quoted token keeps its spaces and its quotes.
const TokenIterator = struct {
    str: []const u8,
    index: usize = 0,

    fn next(it: *TokenIterator) ?[]const u8 {
        while (it.index < it.str.len and it.str[it.index] == ' ') it.index += 1;
        if (it.index == it.str.len) return null;
        const start = it.index;
        var quoted = false;
        while (it.index < it.str.len) : (it.index += 1) {
            if (it.str[it.index] == '"') quoted = !quoted;
            if (it.str[it.index] == ' ' and !quoted) break;
        }
        return it.str[start..it.index];
    }
};

fn unquote(token: []const u8) []const u8 {
    if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') return token[1 .. token.len - 1];
    return token;
}

const AttrsBuilder = struct {
    includes: std.ArrayList([]const u8) = .empty,
    defines: std.ArrayList([]const u8) = .empty,
    libs: std.ArrayList([]const u8) = .empty,

    /// Returns whether `token` is an attribute.
    fn add(builder: *AttrsBuilder, arena: std.mem.Allocator, token: []const u8) error{OutOfMemory}!bool {
        for ([_]struct { []const u8, *std.ArrayList([]const u8) }{
            .{ "include=", &builder.includes },
            .{ "define=", &builder.defines },
            .{ "lib=", &builder.libs },
        }) |attr| {
            if (std.mem.startsWith(u8, token, attr[0])) {
                var it = std.mem.splitScalar(u8, unquote(token[attr[0].len..]), ',');
                while (it.next()) |item| try attr[1].append(arena, item);
                return true;
            }
        }
        return false;
    }
    fn finish(builder: AttrsBuilder) Attrs {
        return .{ .includes = builder.includes.items, .defines = builder.defines.items, .libs = builder.libs.items };
    }
};

/// Everything is allocated in `arena`, and slices of `content` are kept.
pub fn parse(arena: std.mem.Allocator, content: []const u8, diagnostic: *Diagnostic) ParseError!File {
    var file: File = .{};
    var defs: std.ArrayList(Def) = .empty;
    var body: std.ArrayList([]const u8) = .empty;
    var inputs: std.ArrayList(Input) = .empty;
    var seen_prelude = false;

    var line_it = std.mem.splitScalar(u8, content, '\n');
    var line_num: u32 = 0;
    while (line_it.next()) |line| {
        line_num += 1;
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == ' ') {
            if (defs.items.len == 0) return invalid(arena, diagnostic, line_num, "a body without a definition", .{});
            try body.append(arena, std.mem.trim(u8, line, " "));
            const last = &defs.items[defs.items.len - 1];
            last.source = last.source.ptr[0 .. @intFromPtr(line.ptr) + line.len - @intFromPtr(last.source.ptr)];
            continue;
        }
        if (defs.items.len != 0) {
            try finishDef(arena, &defs.items[defs.items.len - 1], body.items, diagnostic);
            body = .empty;
        }

        var tokens: TokenIterator = .{ .str = line };
        const first = tokens.next().?;
        if (std.mem.eql(u8, first, "input")) {
            if (seen_prelude or defs.items.len != 0) return invalid(arena, diagnostic, line_num, "input has to be before the prelude and the definitions", .{});
            const token = tokens.next() orelse return invalid(arena, diagnostic, line_num, "expected input NAME=VALUE", .{});
            const eq = std.mem.indexOfScalar(u8, token, '=') orelse return invalid(arena, diagnostic, line_num, "expected input NAME=VALUE but got '{s}'", .{token});
            try inputs.append(arena, .{ .name = token[0..eq], .value = token[eq + 1 ..] });
            continue;
        }
        if (std.mem.eql(u8, first, "prelude")) {
            if (seen_prelude or defs.items.len != 0) return invalid(arena, diagnostic, line_num, "prelude has to be a single line before the definitions", .{});
            seen_prelude = true;
            var attrs: AttrsBuilder = .{};
            while (tokens.next()) |token| {
                if (!try attrs.add(arena, token)) return invalid(arena, diagnostic, line_num, "'{s}' isn't an attribute", .{token});
            }
            file.prelude = attrs.finish();
            file.prelude_source = line;
            continue;
        }

        const local = std.mem.eql(u8, first, "local");
        const name = if (local) tokens.next() orelse return invalid(arena, diagnostic, line_num, "local needs a name", .{}) else first;
        for (defs.items) |def| {
            if (std.mem.eql(u8, def.name, name)) return invalid(arena, diagnostic, line_num, "{s} is already defined on line {}", .{ name, def.line });
        }
        const second = tokens.next() orelse return invalid(arena, diagnostic, line_num, "{s} needs a value or a kind", .{name});
        var def: Def = .{ .name = name, .line = line_num, .local = local, .kind = .literal, .source = line };
        if (std.mem.eql(u8, second, "?")) {
            const values = tokens.next() orelse return invalid(arena, diagnostic, line_num, "{s}: expected PASS|FAIL after ?", .{name});
            const pipe = indexOfPipe(values) orelse return invalid(arena, diagnostic, line_num, "{s}: expected PASS|FAIL but got '{s}'", .{ name, values });
            def.pass = Value.parse(values[0..pipe]) orelse return invalid(arena, diagnostic, line_num, "{s}: invalid value '{s}'", .{ name, values[0..pipe] });
            def.fail = Value.parse(values[pipe + 1 ..]) orelse return invalid(arena, diagnostic, line_num, "{s}: invalid value '{s}'", .{ name, values[pipe + 1 ..] });
            const kind_str = tokens.next() orelse return invalid(arena, diagnostic, line_num, "{s} needs a kind after PASS|FAIL", .{name});
            def.kind = std.meta.stringToEnum(Kind, kind_str) orelse return invalid(arena, diagnostic, line_num, "unknown kind '{s}'", .{kind_str});
            if (!def.kind.isCheck()) return invalid(arena, diagnostic, line_num, "{s}: {t} has a value of its own so it can't have ? PASS|FAIL", .{ name, def.kind });
        } else if (std.meta.stringToEnum(Kind, second)) |kind| {
            if (kind.isCheck()) return invalid(arena, diagnostic, line_num, "{s}: {t} needs ? PASS|FAIL before it", .{ name, kind });
            if (kind == .literal) return invalid(arena, diagnostic, line_num, "unknown kind 'literal'", .{});
            def.kind = kind;
        } else {
            // an ident goes to the end of the line
            const value_str = if (second[0] == ':') line[tokens.index - second.len ..] else second;
            def.value = Value.parse(value_str) orelse return invalid(arena, diagnostic, line_num, "{s}: '{s}' isn't a value or a kind", .{ name, value_str });
            if (second[0] != ':' and tokens.next() != null) return invalid(arena, diagnostic, line_num, "{s}: a literal value can't have anything after it", .{name});
        }
        const kind = def.kind;

        if (kind == .when) {
            def.expr = try parseExprString(arena, line[tokens.index..], diagnostic, line_num);
        } else if (kind != .literal) {
            var args: std.ArrayList([]const u8) = .empty;
            var attrs: AttrsBuilder = .{};
            var tail: enum { none, guard, assume } = .none;
            var tail_start: usize = 0;
            while (true) {
                const before = tokens.index;
                const token = tokens.next() orelse break;
                const keyword: @TypeOf(tail) = if (std.mem.eql(u8, token, "if"))
                    .guard
                else if (std.mem.eql(u8, token, "assume"))
                    .assume
                else
                    .none;
                if (keyword != .none) {
                    try finishTail(arena, &def, tail, line[tail_start..before], diagnostic, line_num);
                    tail = keyword;
                    tail_start = tokens.index;
                } else if (tail == .none) {
                    if (!try attrs.add(arena, token)) try args.append(arena, unquote(token));
                }
            }
            try finishTail(arena, &def, tail, line[tail_start..], diagnostic, line_num);
            def.args = args.items;
            def.attrs = attrs.finish();
        }
        try defs.append(arena, def);
    }
    if (defs.items.len != 0) try finishDef(arena, &defs.items[defs.items.len - 1], body.items, diagnostic);

    file.inputs = inputs.items;
    file.defs = defs.items;
    try checkNames(arena, file, diagnostic);
    return file;
}

/// The `|` between PASS and FAIL, one in a string doesn't count.
fn indexOfPipe(values: []const u8) ?usize {
    var quoted = false;
    for (values, 0..) |c, i| {
        if (c == '"') quoted = !quoted;
        if (c == '|' and !quoted) return i;
    }
    return null;
}

fn finishTail(
    arena: std.mem.Allocator,
    def: *Def,
    tail: anytype,
    str: []const u8,
    diagnostic: *Diagnostic,
    line_num: u32,
) ParseError!void {
    switch (tail) {
        .none => {},
        .guard => {
            if (def.guard != null) return invalid(arena, diagnostic, line_num, "{s} has more than one if", .{def.name});
            def.guard = try parseExprString(arena, str, diagnostic, line_num);
        },
        .assume => {
            if (def.assume != null) return invalid(arena, diagnostic, line_num, "{s} has more than one assume", .{def.name});
            def.assume = try parseExprString(arena, str, diagnostic, line_num);
        },
    }
}

/// Checks what depends on the kind, now that the body is known.
fn finishDef(arena: std.mem.Allocator, def: *Def, body: []const []const u8, diagnostic: *Diagnostic) ParseError!void {
    const args_needed: usize, const needs_body: bool = switch (def.kind) {
        .@"have-header", .@"have-function", .@"have-type", .@"have-decl", .sizeof, .alignof, .exists => .{ 1, false },
        .@"have-member" => .{ 2, false },
        .links, .compiles, .runs, .select => .{ 0, true },
        .when, .literal => .{ 0, false },
    };
    if (def.args.len != args_needed) return invalid(arena, diagnostic, def.line, "{s}: {t} takes {} arguments but it has {}", .{ def.name, def.kind, args_needed, def.args.len });
    if (needs_body and body.len == 0) return invalid(arena, diagnostic, def.line, "{s}: {t} needs a body", .{ def.name, def.kind });
    if (!needs_body and body.len != 0) return invalid(arena, diagnostic, def.line, "{s}: {t} can't have a body", .{ def.name, def.kind });
    if (def.guard != null and !def.kind.isCheck()) return invalid(arena, diagnostic, def.line, "{s}: {t} has no FAIL value for if to use", .{ def.name, def.kind });
    const needs_assume = def.kind == .runs or def.kind == .exists;
    if (needs_assume and def.assume == null) return invalid(arena, diagnostic, def.line, "{s}: {t} needs assume", .{ def.name, def.kind });
    if (!needs_assume and def.assume != null) return invalid(arena, diagnostic, def.line, "{s}: {t} can't have assume", .{ def.name, def.kind });

    switch (def.kind) {
        .select => {
            var arms: std.ArrayList(Arm) = .empty;
            for (body, 0..) |line, i| {
                const last = i == body.len - 1;
                const value_end = std.mem.indexOf(u8, line, " if ");
                if (last == (value_end != null)) return invalid(arena, diagnostic, def.line, "{s}: only the last line of a select leaves out if: '{s}'", .{ def.name, line });
                const value_str = line[0 .. value_end orelse line.len];
                try arms.append(arena, .{
                    .value = Value.parse(value_str) orelse return invalid(arena, diagnostic, def.line, "{s}: invalid value '{s}'", .{ def.name, value_str }),
                    .condition = if (value_end) |end| try parseExprString(arena, line[end + " if ".len ..], diagnostic, def.line) else null,
                });
            }
            def.arms = arms.items;
        },
        else => def.body = try arena.dupe([]const u8, body),
    }
}

/// A name without a dot has to be a definition that came earlier, otherwise a typo would look like an
/// input that's missing. A name with a dot is an input and that's checked when evaluating.
fn checkNames(arena: std.mem.Allocator, file: File, diagnostic: *Diagnostic) ParseError!void {
    for (file.defs, 0..) |def, i| {
        const earlier = file.defs[0..i];
        if (def.guard) |e| try checkExprNames(arena, e, earlier, def, diagnostic);
        if (def.assume) |e| try checkExprNames(arena, e, earlier, def, diagnostic);
        if (def.expr) |e| try checkExprNames(arena, e, earlier, def, diagnostic);
        for (def.arms) |arm| {
            if (arm.condition) |e| try checkExprNames(arena, e, earlier, def, diagnostic);
        }
    }
}

fn checkExprNames(arena: std.mem.Allocator, expr: *const Expr, earlier: []const Def, def: Def, diagnostic: *Diagnostic) ParseError!void {
    switch (expr.*) {
        .boolean, .int, .version, .literal => {},
        .not => |e| try checkExprNames(arena, e, earlier, def, diagnostic),
        .@"and", .@"or" => |es| for (es) |e| try checkExprNames(arena, e, earlier, def, diagnostic),
        .compare => |c| for (c.operands) |e| try checkExprNames(arena, e, earlier, def, diagnostic),
        .name => |name| {
            if (!isDefinitionName(name)) return;
            for (earlier) |other| {
                if (std.mem.eql(u8, other.name, name)) return;
            }
            return invalid(arena, diagnostic, def.line, "{s} uses '{s}', which isn't defined above it", .{ def.name, name });
        },
    }
}

fn isDefinitionName(name: []const u8) bool {
    return std.mem.indexOfScalar(u8, name, '.') == null;
}

const ExprParser = struct {
    arena: std.mem.Allocator,
    str: []const u8,
    index: usize = 0,
    diagnostic: *Diagnostic,
    line: u32,

    fn skip(p: *ExprParser) void {
        while (p.index < p.str.len and p.str[p.index] == ' ') p.index += 1;
    }
    fn eat(p: *ExprParser, token: []const u8) bool {
        p.skip();
        if (!std.mem.startsWith(u8, p.str[p.index..], token)) return false;
        p.index += token.len;
        return true;
    }
    fn fail(p: *ExprParser, comptime fmt: []const u8, args: anytype) ParseError {
        return invalid(p.arena, p.diagnostic, p.line, "in expression '{s}': " ++ fmt, .{p.str} ++ args);
    }
    fn new(p: *ExprParser, expr: Expr) ParseError!*const Expr {
        const result = try p.arena.create(Expr);
        result.* = expr;
        return result;
    }

    fn parseOr(p: *ExprParser) ParseError!*const Expr {
        var left = try p.parseAnd();
        while (p.eat("||")) left = try p.new(.{ .@"or" = .{ left, try p.parseAnd() } });
        return left;
    }
    fn parseAnd(p: *ExprParser) ParseError!*const Expr {
        var left = try p.parseUnary();
        while (p.eat("&&")) left = try p.new(.{ .@"and" = .{ left, try p.parseUnary() } });
        return left;
    }
    fn parseUnary(p: *ExprParser) ParseError!*const Expr {
        // has to be before the comparison operators so that it doesn't take the start of a !=
        if (p.eat("!")) return p.new(.{ .not = try p.parseUnary() });
        if (p.eat("(")) {
            const inner = try p.parseOr();
            if (!p.eat(")")) return p.fail("expected )", .{});
            return inner;
        }
        const left = try p.parseOperand();
        for ([_]struct { []const u8, Expr.Op }{
            .{ "==", .eq },
            .{ "!=", .ne },
            .{ "<=", .le },
            .{ ">=", .ge },
            .{ "<", .lt },
            .{ ">", .gt },
        }) |op| {
            if (p.eat(op[0])) return p.new(.{ .compare = .{ .op = op[1], .operands = .{ left, try p.parseOperand() } } });
        }
        return left;
    }
    fn parseOperand(p: *ExprParser) ParseError!*const Expr {
        p.skip();
        const start = p.index;
        while (p.index < p.str.len) : (p.index += 1) switch (p.str[p.index]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.' => {},
            else => break,
        };
        const token = p.str[start..p.index];
        if (token.len == 0) return p.fail("expected an operand at offset {}", .{start});
        if (std.mem.eql(u8, token, "true")) return p.new(.{ .boolean = true });
        if (std.mem.eql(u8, token, "false")) return p.new(.{ .boolean = false });
        if (token[0] == '.') return p.new(.{ .literal = token[1..] });
        if (std.ascii.isDigit(token[0])) {
            if (std.fmt.parseInt(i64, token, 10)) |int| return p.new(.{ .int = int }) else |_| {}
            return p.new(.{ .version = parseVersion(token) orelse return p.fail("invalid number '{s}'", .{token}) });
        }
        return p.new(.{ .name = token });
    }
};

fn parseExprString(arena: std.mem.Allocator, str: []const u8, diagnostic: *Diagnostic, line: u32) ParseError!*const Expr {
    var p: ExprParser = .{ .arena = arena, .str = std.mem.trim(u8, str, " "), .diagnostic = diagnostic, .line = line };
    const expr = try p.parseOr();
    p.skip();
    if (p.index != p.str.len) return p.fail("unexpected '{s}'", .{p.str[p.index..]});
    return expr;
}

pub const CheckError = error{ CheckFailed, OutOfMemory };
pub const EvalError = error{ Invalid, OutOfMemory, CheckFailed };

/// Answers the definitions that need a compiler.
pub const Check = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, def: Def) CheckError!Value,
};

/// Why a definition isn't resolved.
pub const Reason = union(enum) {
    /// It needs this input, which wasn't given.
    input: []const u8,
    /// It uses this definition, which isn't resolved.
    def: []const u8,
    /// It needs a compiler, which wasn't given.
    check: Kind,

    pub fn format(reason: Reason, w: *std.Io.Writer) error{WriteFailed}!void {
        switch (reason) {
            .input => |name| try w.print("needs the input '{s}'", .{name}),
            .def => |name| try w.print("uses {s}, which isn't resolved", .{name}),
            .check => |kind| try w.print("needs a compiler for its {t} check", .{kind}),
        }
    }
};

pub const Resolution = union(enum) {
    resolved: Value,
    unresolved: Reason,
};

/// Resolves what it can with the inputs it has.
pub const Evaluator = struct {
    arena: std.mem.Allocator,
    inputs: *const std.StringHashMapUnmanaged(Result),
    values: std.StringHashMapUnmanaged(?Value) = .empty,
    diagnostic: *Diagnostic,
    /// Without this, the definitions that need a compiler aren't resolved.
    check: ?Check = null,
    line: u32 = 0,
    /// Why the current definition came out unresolved, the first thing it ran into.
    reason: ?Reason = null,

    fn fail(e: *Evaluator, comptime fmt: []const u8, args: anytype) EvalError {
        return invalid(e.arena, e.diagnostic, e.line, fmt, args);
    }

    /// Returns the results in the order of `file.defs`, so a definition can use the ones before it.
    pub fn run(e: *Evaluator, file: File) EvalError![]const Resolution {
        const results = try e.arena.alloc(Resolution, file.defs.len);
        for (file.defs, results) |def, *result| {
            e.line = def.line;
            e.reason = null;
            const value = try e.evalDef(def);
            try e.values.put(e.arena, def.name, value);
            result.* = if (value) |v| .{ .resolved = v } else .{ .unresolved = e.reason.? };
        }
        return results;
    }

    fn setReason(e: *Evaluator, reason: Reason) void {
        if (e.reason == null) e.reason = reason;
    }

    fn evalDef(e: *Evaluator, def: Def) EvalError!?Value {
        if (def.guard) |guard| {
            const passed = (try e.evalBool(guard)) orelse return null;
            if (!passed) return def.fail;
        }
        switch (def.kind) {
            .@"have-header", .@"have-function", .@"have-type", .@"have-member", .@"have-decl", .links, .sizeof, .alignof, .compiles => {
                if (e.check) |check| return try check.run(check.context, def);
                e.setReason(.{ .check = def.kind });
                return null;
            },
            .literal => return def.value,
            .when => return checkValue(def, (try e.evalBool(def.expr.?)) orelse return null),
            // these describe where the program runs, so outside of a real run this is the answer
            .runs, .exists => return checkValue(def, (try e.evalBool(def.assume.?)) orelse return null),
            .select => {
                for (def.arms) |arm| {
                    const condition = arm.condition orelse return arm.value;
                    // an arm that might match means the answer isn't known yet
                    if ((try e.evalBool(condition)) orelse return null) return arm.value;
                }
                unreachable;
            },
        }
    }

    fn checkValue(def: Def, passed: bool) Value {
        return if (passed) def.pass else def.fail;
    }

    fn evalBool(e: *Evaluator, expr: *const Expr) EvalError!?bool {
        const result = (try e.eval(expr)) orelse return null;
        return switch (result) {
            .boolean => |value| value,
            .int => |value| value != 0,
            else => e.fail("expected a boolean but got {t}", .{result}),
        };
    }

    fn eval(e: *Evaluator, expr: *const Expr) EvalError!?Result {
        switch (expr.*) {
            .boolean => |value| return .{ .boolean = value },
            .int => |value| return .{ .int = value },
            .version => |value| return .{ .version = value },
            .literal => |value| return .{ .literal = value },
            .name => |name| {
                if (e.values.get(name)) |maybe_value| {
                    const value = maybe_value orelse {
                        e.setReason(.{ .def = name });
                        return null;
                    };
                    return switch (value) {
                        .undef, .false => .{ .boolean = false },
                        .defined, .true => .{ .boolean = true },
                        .int => |int| .{ .int = int },
                        .string, .ident => |str| .{ .literal = str },
                    };
                }
                return e.inputs.get(name) orelse {
                    e.setReason(.{ .input = name });
                    return null;
                };
            },
            .not => |inner| return .{ .boolean = !((try e.evalBool(inner)) orelse return null) },
            // false && unknown is false, and true || unknown is true, whichever side is unknown
            .@"and" => |sides| {
                const left = try e.evalBool(sides[0]);
                if (left == false) return .{ .boolean = false };
                const right = try e.evalBool(sides[1]);
                if (right == false) return .{ .boolean = false };
                if (left == null or right == null) return null;
                return .{ .boolean = true };
            },
            .@"or" => |sides| {
                const left = try e.evalBool(sides[0]);
                if (left == true) return .{ .boolean = true };
                const right = try e.evalBool(sides[1]);
                if (right == true) return .{ .boolean = true };
                if (left == null or right == null) return null;
                return .{ .boolean = false };
            },
            .compare => |compare| {
                const left = (try e.eval(compare.operands[0])) orelse return null;
                const right = (try e.eval(compare.operands[1])) orelse return null;
                return .{ .boolean = try e.evalCompare(compare.op, left, right) };
            },
        }
    }

    fn evalCompare(e: *Evaluator, op: Expr.Op, left: Result, right: Result) EvalError!bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return e.fail("can't compare {t} with {t}", .{ left, right });
        const order: std.math.Order = switch (left) {
            .int => |x| std.math.order(x, right.int),
            .version => |x| x.order(right.version),
            .boolean => |x| if (x == right.boolean) .eq else .lt,
            .literal => |x| if (std.mem.eql(u8, x, right.literal)) .eq else .lt,
        };
        if ((left == .boolean or left == .literal) and op != .eq and op != .ne) return e.fail("can't order a {t}", .{left});
        return switch (op) {
            .eq => order == .eq,
            .ne => order != .eq,
            .lt => order == .lt,
            .le => order != .gt,
            .gt => order == .gt,
            .ge => order != .lt,
        };
    }
};

/// Writes what's resolved as a ConfigHeader config file: `NAME VALUE`. A local name isn't in it.
pub fn writeResolved(w: *std.Io.Writer, file: File, results: []const Resolution) error{WriteFailed}!void {
    for (file.defs, results) |def, result| {
        if (def.local or result != .resolved) continue;
        try w.print("{s} {f}\n", .{ def.name, result.resolved });
    }
}

/// Writes what isn't resolved so that another run can continue from here. That also needs the
/// inputs, and the resolved values the rest use, which are local so they aren't written twice.
pub fn writeUnresolved(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    file: File,
    results: []const Resolution,
    inputs: []const Input,
) error{ WriteFailed, OutOfMemory }!void {
    var used: std.StringHashMapUnmanaged(void) = .empty;
    for (file.defs, results) |def, result| {
        if (result != .unresolved) continue;
        try addDefNames(arena, &used, def);
    }

    for (inputs) |input| try w.print("input {s}={s}\n", .{ input.name, input.value });
    if (file.prelude_source.len != 0) try w.print("{s}\n", .{file.prelude_source});
    for (file.defs, results) |def, result| switch (result) {
        .unresolved => try w.print("{s}\n", .{def.source}),
        .resolved => |value| if (used.contains(def.name)) try w.print("local {s} {f}\n", .{ def.name, value }),
    };
}

/// Every name that the definitions refer to. An input is one with a dot in it.
pub fn usedNames(arena: std.mem.Allocator, file: File) error{OutOfMemory}!std.StringHashMapUnmanaged(void) {
    var used: std.StringHashMapUnmanaged(void) = .empty;
    for (file.defs) |def| try addDefNames(arena, &used, def);
    return used;
}

/// Writes what another run would have to be given to finish, one per line: the name of each input,
/// and `compiler` if there's a check left to run.
pub fn writeNeeded(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    file: File,
    results: []const Resolution,
    inputs: []const Input,
) error{ WriteFailed, OutOfMemory }!void {
    var used: std.StringHashMapUnmanaged(void) = .empty;
    var needs_compiler = false;
    for (file.defs, results) |def, result| {
        if (result != .unresolved) continue;
        try addDefNames(arena, &used, def);
        if (def.kind.needsCompiler()) needs_compiler = true;
    }
    var names: std.ArrayList([]const u8) = .empty;
    var it = used.keyIterator();
    next: while (it.next()) |name| {
        if (std.mem.indexOfScalar(u8, name.*, '.') == null) continue;
        for (inputs) |input| {
            if (std.mem.eql(u8, input.name, name.*)) continue :next;
        }
        try names.append(arena, name.*);
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    if (needs_compiler) try w.writeAll("compiler\n");
    for (names.items) |name| try w.print("{s}\n", .{name});
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn addDefNames(arena: std.mem.Allocator, used: *std.StringHashMapUnmanaged(void), def: Def) error{OutOfMemory}!void {
    if (def.guard) |e| try addNames(arena, used, e);
    if (def.assume) |e| try addNames(arena, used, e);
    if (def.expr) |e| try addNames(arena, used, e);
    for (def.arms) |arm| {
        if (arm.condition) |e| try addNames(arena, used, e);
    }
}

fn addNames(arena: std.mem.Allocator, used: *std.StringHashMapUnmanaged(void), expr: *const Expr) error{OutOfMemory}!void {
    switch (expr.*) {
        .boolean, .int, .version, .literal => {},
        .name => |name| try used.put(arena, name, {}),
        .not => |e| try addNames(arena, used, e),
        .@"and", .@"or" => |es| for (es) |e| try addNames(arena, used, e),
        .compare => |c| for (c.operands) |e| try addNames(arena, used, e),
    }
}

test "evaluating" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var diagnostic: Diagnostic = .{};
    const file = try parse(arena,
        \\IS_WINDOWS ? 1|undef when os.tag == .windows
        \\HAVE_FOO_H ? 1|undef have-header foo.h
        \\NEEDS_FOO ? 1|undef when HAVE_FOO_H && IS_WINDOWS
        \\NEW_GLIBC ? 1|undef when libc.tag == .glibc && libc.version >= 2.34
        \\local works_at_runtime ? 1|undef runs assume os.tag == .linux
        \\    int main(void) { return 0; }
        \\BROKEN ? 1|undef when !works_at_runtime
        \\GUARDED ? 1|false have-header bar.h if IS_WINDOWS
        \\TIER select
        \\    1 if os.tag == .macos
        \\    0
        \\NAME "a b"
        \\RET :an ident value
        \\FLAG false
        \\FLAG_USER ? 1|undef when !FLAG
        \\NEGATIVE -100
        \\OTHER ? 2|3 when os.tag == .windows
        \\SIZE sizeof "long long"
    , &diagnostic);
    try std.testing.expectEqual(@as(usize, 15), file.defs.len);

    var inputs: std.StringHashMapUnmanaged(Result) = .empty;
    try inputs.put(arena, "os.tag", .{ .literal = "linux" });
    try inputs.put(arena, "libc.tag", .{ .literal = "musl" });
    var evaluator: Evaluator = .{ .arena = arena, .inputs = &inputs, .diagnostic = &diagnostic };
    const values = try evaluator.run(file);
    try std.testing.expectEqual(Value.undef, values[0].resolved);
    // not known, a header has to be checked
    try std.testing.expectEqual(Kind.@"have-header", values[1].unresolved.check);
    // known anyway, because the other side of the && is false
    try std.testing.expectEqual(Value.undef, values[2].resolved);
    // libc.version wasn't given, which is fine because it's not used for musl
    try std.testing.expectEqual(Value.undef, values[3].resolved);
    try std.testing.expectEqual(@as(i64, 1), values[4].resolved.int);
    try std.testing.expectEqual(Value.undef, values[5].resolved);
    // a false if gives the FAIL value without checking
    try std.testing.expectEqual(Value.false, values[6].resolved);
    try std.testing.expectEqual(@as(i64, 0), values[7].resolved.int);
    try std.testing.expectEqualStrings("a b", values[8].resolved.string);
    try std.testing.expectEqualStrings("an ident value", values[9].resolved.ident);
    try std.testing.expectEqual(Value.false, values[10].resolved);
    try std.testing.expectEqual(@as(i64, 1), values[11].resolved.int);
    try std.testing.expectEqual(@as(i64, -100), values[12].resolved.int);
    try std.testing.expectEqual(@as(i64, 3), values[13].resolved.int);
    try std.testing.expectEqual(Kind.sizeof, values[14].unresolved.check);
}

test "resolving in stages gives the same result as all at once" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const content =
        \\prelude define=_GNU_SOURCE
        \\A ? 1|undef when os.tag == .linux
        \\local B 8
        \\C ? 1|undef when A && B == 8 && cpu.arch == .x86_64
        \\D ? 1|undef when cpu.arch == .x86_64
        \\E select
        \\    0 if os.tag == .macos
        \\    :an ident if D
        \\    undef
        \\F ? 1|undef compiles if A
        \\    int x;
        \\
    ;
    const resolve = struct {
        fn run(a: std.mem.Allocator, source: []const u8, given: []const Input) !struct { []const u8, []const u8, []const Resolution } {
            var diagnostic: Diagnostic = .{};
            const file = try parse(a, source, &diagnostic);
            var inputs: std.StringHashMapUnmanaged(Result) = .empty;
            var all: std.ArrayList(Input) = .empty;
            try all.appendSlice(a, file.inputs);
            try all.appendSlice(a, given);
            for (all.items) |input| try inputs.put(a, input.name, .parseInput(input.value));
            var evaluator: Evaluator = .{ .arena = a, .inputs = &inputs, .diagnostic = &diagnostic };
            const results = try evaluator.run(file);
            var resolved: std.Io.Writer.Allocating = .init(a);
            try writeResolved(&resolved.writer, file, results);
            var unresolved: std.Io.Writer.Allocating = .init(a);
            try writeUnresolved(a, &unresolved.writer, file, results, all.items);
            return .{ resolved.written(), unresolved.written(), results };
        }
    }.run;

    const once = try resolve(arena, content, &.{ .{ .name = "os.tag", .value = "linux" }, .{ .name = "cpu.arch", .value = "x86_64" } });
    try std.testing.expectEqualStrings(
        \\A 1
        \\C 1
        \\D 1
        \\E :an ident
        \\
    , once[0]);

    const first = try resolve(arena, content, &.{.{ .name = "os.tag", .value = "linux" }});
    try std.testing.expectEqualStrings(
        \\A 1
        \\
    , first[0]);
    try std.testing.expectEqualStrings(
        \\input os.tag=linux
        \\prelude define=_GNU_SOURCE
        \\local A 1
        \\local B 8
        \\C ? 1|undef when A && B == 8 && cpu.arch == .x86_64
        \\D ? 1|undef when cpu.arch == .x86_64
        \\E select
        \\    0 if os.tag == .macos
        \\    :an ident if D
        \\    undef
        \\F ? 1|undef compiles if A
        \\    int x;
        \\
    , first[1]);
    const second = try resolve(arena, first[1], &.{.{ .name = "cpu.arch", .value = "x86_64" }});
    try std.testing.expectEqualStrings(
        \\C 1
        \\D 1
        \\E :an ident
        \\
    , second[0]);
    // only a compile check is left, and it's the same one in both
    try std.testing.expectEqual(Kind.compiles, once[2][once[2].len - 1].unresolved.check);
    try std.testing.expectEqual(Kind.compiles, second[2][second[2].len - 1].unresolved.check);
}

test "attributes can be comma separated" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var diagnostic: Diagnostic = .{};
    const file = try parse(arena, "A ? 1|undef have-header a.h include=b.h,c.h include=d.h", &diagnostic);
    try std.testing.expectEqual(@as(usize, 3), file.defs[0].attrs.includes.len);
    try std.testing.expectEqualStrings("c.h", file.defs[0].attrs.includes[1]);
}

test "invalid files are errors" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    for ([_][]const u8{
        "A nonsense x",
        "A ? 1|undef header a.h",
        "A ? 1|undef links accept",
        "A ? 1|undef have-member a",
        "input",
        "input os.tag",
        "A 1\ninput os.tag=linux",
        "A have-header a.h",
        "A ? 1|undef nonsense",
        "A ?",
        "A ? 1 have-header a.h",
        "A ? 1|bad have-header a.h",
        "A ? 1|undef",
        "A ? 1|undef sizeof long",
        "A literal",
        "A undef extra",
        "A absent",
        "A .void",
        "A :",
        "A sizeof long if x.y",
        "A ? 1|undef have-header",
        "A ? 1|undef have-header a.h\nA ? 1|undef have-header b.h",
        "A ? 1|undef compiles",
        "A ? 1|undef runs\n    int x;",
        "A ? 1|undef when B_UNDEFINED",
        "A ? 1|undef when (x.y",
        "A select\n    1\n    2",
        "A select\n    1 if x.y == .z",
        "A ? 1|undef have-header a.h\n    a body",
    }) |content| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.Invalid, parse(arena, content, &diagnostic));
        try std.testing.expect(diagnostic.message.len != 0);
    }
}

pub const Checker = @import("Checker.zig");

const std = @import("std");
