/// Add config values to a ConfigHeader from a lazy path.
/// The lazy path should contain lines in the format: NAME VALUE
/// TODO: upstream into ConfigHeader.zig
pub fn addLazy(config_header: *ConfigHeader, config_results: std.Build.LazyPath) void {
    const b = config_header.step.owner;
    // This ApplyConfigStep is just a HACK which *should work* but the proper solution is to
    // add LazyPath support in ConfigHeader itself.
    const apply = b.allocator.create(ApplyConfigStep) catch @panic("OOM");
    apply.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = "add configuration from lazy path",
            .owner = b,
            .makeFn = ApplyConfigStep.make,
        }),
        .config_header = config_header,
        .config_results = config_results,
    };
    config_results.addStepDependencies(&apply.step);
    config_header.step.dependOn(&apply.step);
}

pub const Entry = struct {
    name: []const u8,
    value: ConfigHeader.Value,

    pub const ParseError = error{
        MissingValue,
        InvalidValue,
    };

    pub fn parse(raw_line: []const u8) ParseError!Entry {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.MissingValue;
        const name = line[0..first_space];
        const raw_value = std.mem.trimStart(u8, line[first_space + 1 ..], " ");
        const value, const end = parseValue(raw_value) orelse return error.InvalidValue;
        if (end != raw_value.len) return error.InvalidValue;
        return .{ .name = name, .value = value };
    }
};

pub fn parseValue(str: []const u8) ?struct { ConfigHeader.Value, usize } {
    if (str.len == 0) return null;
    if (matchKeyword(str, "undef")) |end| return .{ .undef, end };
    if (matchKeyword(str, "defined")) |end| return .{ .defined, end };
    if (matchKeyword(str, "true")) |end| return .{ .{ .boolean = true }, end };
    if (matchKeyword(str, "false")) |end| return .{ .{ .boolean = false }, end };
    if (str[0] == '.') {
        if (str.len >= 3 and str[1] == '@' and str[2] == '"') {
            const close = std.mem.indexOfScalarPos(u8, str, 3, '"') orelse return null;
            return .{ .{ .ident = str[3..close] }, close + 1 };
        }
        if (str.len < 2 or !isIdentStart(str[1])) return null;
        var end: usize = 2;
        while (end < str.len and isIdentChar(str[end])) : (end += 1) {}
        return .{ .{ .ident = str[1..end] }, end };
    }
    if (str[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, str, 1, '"') orelse return null;
        return .{ .{ .string = str[1..close] }, close + 1 };
    }
    // integer: scan digits (with optional leading -)
    {
        var end: usize = if (str[0] == '-') 1 else 0;
        if (end >= str.len or str[end] < '0' or str[end] > '9') return null;
        while (end < str.len and str[end] >= '0' and str[end] <= '9') : (end += 1) {}
        if (std.fmt.parseInt(i64, str[0..end], 10)) |int_val| return .{ .{ .int = int_val }, end } else |_| return null;
    }
}

fn matchKeyword(str: []const u8, keyword: []const u8) ?usize {
    if (str.len < keyword.len) return null;
    if (!std.mem.eql(u8, str[0..keyword.len], keyword)) return null;
    if (str.len == keyword.len) return keyword.len;
    if (!isIdentChar(str[keyword.len])) return keyword.len;
    return null;
}

const ApplyConfigStep = struct {
    step: std.Build.Step,
    config_header: *ConfigHeader,
    config_results: std.Build.LazyPath,

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const self: *ApplyConfigStep = @fieldParentPtr("step", step);
        const b = step.owner;
        const results_path = self.config_results.getPath2(b, step);
        const content = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, results_path, b.allocator, .unlimited);
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const entry = Entry.parse(line) catch |err| return step.fail(
                "failed to parse config '{s}' with {t}",
                .{ line, err },
            );
            self.config_header.values.put(b.allocator, entry.name, entry.value) catch @panic("OOM");
        }
    }
};

fn isIdentStart(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '_' => true,
        else => false,
    };
}

fn isIdentChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '_', '0'...'9' => true,
        else => false,
    };
}

test matchKeyword {
    // exact match
    try std.testing.expectEqual(5, matchKeyword("undef", "undef").?);
    try std.testing.expectEqual(7, matchKeyword("defined", "defined").?);
    // followed by non-ident char
    try std.testing.expectEqual(5, matchKeyword("undef ", "undef").?);
    try std.testing.expectEqual(5, matchKeyword("undef|foo", "undef").?);
    try std.testing.expectEqual(4, matchKeyword("true.", "true").?);
    // should NOT match when followed by ident chars
    try std.testing.expectEqual(null, matchKeyword("undefined", "undef"));
    try std.testing.expectEqual(null, matchKeyword("trueish", "true"));
    try std.testing.expectEqual(null, matchKeyword("false0", "false"));
    // too short
    try std.testing.expectEqual(null, matchKeyword("und", "undef"));
    try std.testing.expectEqual(null, matchKeyword("", "undef"));
}

fn expectValue(str: []const u8, expected: ConfigHeader.Value, expected_end: usize) !void {
    const value, const end = parseValue(str) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(expected, value);
    try std.testing.expectEqual(expected_end, end);
}

test parseValue {
    // undef
    try expectValue("undef", .undef, 5);
    try expectValue("undef rest", .undef, 5);
    // defined
    try expectValue("defined", .defined, 7);
    // bool
    try expectValue("true", .{ .boolean = true }, 4);
    try expectValue("false", .{ .boolean = false }, 5);
    // int
    try expectValue("4", .{ .int = 4 }, 1);
    try expectValue("-1", .{ .int = -1 }, 2);
    try expectValue("0", .{ .int = 0 }, 1);
    try expectValue("42 rest", .{ .int = 42 }, 2);
    // ident (.IDENT syntax)
    try expectValue(".void", .{ .ident = "void" }, 5);
    try expectValue(".some_value", .{ .ident = "some_value" }, 11);
    try expectValue(".void rest", .{ .ident = "void" }, 5);
    // ident (.@"..." syntax)
    try expectValue(".@\"linux-gnu\"", .{ .ident = "linux-gnu" }, 13);
    try expectValue(".@\"has spaces\"", .{ .ident = "has spaces" }, 14);
    try expectValue(".@\"\"", .{ .ident = "" }, 4);
    try expectValue(".@\"x\" rest", .{ .ident = "x" }, 5);
    // string
    try expectValue("\"md5,sha1\"", .{ .string = "md5,sha1" }, 10);
    try expectValue("\"\"", .{ .string = "" }, 2);
    try expectValue("\"hello world\"", .{ .string = "hello world" }, 13);
    try expectValue("\"x\" rest", .{ .string = "x" }, 3);
    // null for invalid
    try std.testing.expectEqual(null, parseValue(""));
    try std.testing.expectEqual(null, parseValue("notavalue"));
    try std.testing.expectEqual(null, parseValue("\"unclosed"));
    try std.testing.expectEqual(null, parseValue("."));
    try std.testing.expectEqual(null, parseValue(".0bad"));
    try std.testing.expectEqual(null, parseValue(".@\"unclosed"));
}

const std = @import("std");
const ConfigHeader = std.Build.Step.ConfigHeader;
