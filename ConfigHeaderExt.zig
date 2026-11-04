/// Parses a config value in the format used by configquery templates.
pub fn parseValue(str: []const u8) ?ConfigHeader.Value {
    if (std.mem.eql(u8, str, "undef")) return .undef;
    if (std.mem.eql(u8, str, "defined")) return .defined;
    if (std.mem.eql(u8, str, "false")) return .{ .boolean = false };
    if (std.mem.eql(u8, str, "true")) return .{ .boolean = true };
    if (std.fmt.parseInt(i64, str, 10)) |int| return .{ .int = int } else |_| {}
    if (std.mem.startsWith(u8, str, ":")) return .{ .ident = str[1..] };
    if (str.len >= 2 and str[0] == '"' and str[str.len - 1] == '"') return .{ .string = str[1 .. str.len - 1] };
    return null;
}

const std = @import("std");
const ConfigHeader = std.Build.Step.ConfigHeader;
