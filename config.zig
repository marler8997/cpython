//! The format of config.txt, which holds the pyconfig.h values for every combination of inputs that
//! has been tested. See "Generating static config" in README.md.
//!
//!     verified absent
//!     verified zig=0.16.0 python=3.11.13,3.12.11 os=linux arch=x86_64 abi=gnu glibc=2.30,2.31 yes
//!     verified zig=0.16.0 python=3.11.13,3.12.11 os=linux arch=x86_64 abi=musl glibc=none yes
//!     verified zig=0.16.0 python=3.11.13,3.12.11 os=linux arch=hexagon abi=musl glibc=none failed
//!     HAVE_CRYPT_H undef
//!     HAVE_CRYPT_H abi=musl 1
//!
//! Each line is `NAME [INPUT=VALUE,...]... VALUE`. The first line for a name is its default and the
//! lines after it are for the combinations that differ from it, no combination matches more than
//! one. The `verified` lines come first and always list every input, a value only means something
//! for a combination that `verified` lists as yes. Every list and line is sorted by its bytes.

/// The inputs we know affect config, in their canonical order. To add one, append it here and
/// enumerate it in updateconfig.zig. The combinations already in config.txt don't have the new input
/// so they get tested again.
pub const input_names = [_][]const u8{ "zig", "python", "os", "arch", "abi", "glibc" };

pub const glibc_input = 5;

/// The value of the glibc input for a target that doesn't use glibc.
pub const no_glibc = "none";

pub const Inputs = [input_names.len][]const u8;

pub const verified_name = "verified";

pub const File = struct {
    verified: Entry = .{ .name = verified_name, .value = .absent },
    values: []const Entry = &.{},
};

pub const Entry = struct {
    name: []const u8,
    value: Value,
    when: []const When = &.{},

    pub fn eval(entry: Entry, inputs: Inputs) Value {
        for (entry.when) |when| {
            if (when.matches(inputs)) return when.value;
        }
        return entry.value;
    }
};

pub const When = struct {
    /// Indexes correspond to `input_names`, null means this doesn't depend on that input.
    lists: [input_names.len]?[]const []const u8,
    value: Value,

    pub fn matches(when: When, inputs: Inputs) bool {
        for (when.lists, inputs) |maybe_list, input| {
            const list = maybe_list orelse continue;
            for (list) |item| {
                if (std.mem.eql(u8, item, input)) break;
            } else return false;
        }
        return true;
    }
};

pub const Value = union(enum) {
    /// The name doesn't exist for these inputs, for example it's not in this version of Python.
    absent,
    undef,
    defined,
    int: i64,
    string: []const u8,
    ident: []const u8,

    pub fn parse(str: []const u8) ?Value {
        if (std.mem.eql(u8, str, "absent")) return .absent;
        if (std.mem.eql(u8, str, "undef")) return .undef;
        if (std.mem.eql(u8, str, "defined")) return .defined;
        if (std.fmt.parseInt(i64, str, 10)) |int| return .{ .int = int } else |_| {}
        if (str.len >= 2 and str[0] == '"' and str[str.len - 1] == '"') {
            const inner = str[1 .. str.len - 1];
            if (std.mem.indexOfAny(u8, inner, "\"\\") != null) return null;
            return .{ .string = inner };
        }
        if (str.len == 0) return null;
        for (str) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
            else => return null,
        };
        return .{ .ident = str };
    }

    pub fn format(value: Value, w: *std.Io.Writer) error{WriteFailed}!void {
        return value.write(w);
    }

    pub fn write(value: Value, w: *std.Io.Writer) error{WriteFailed}!void {
        switch (value) {
            .absent => try w.writeAll("absent"),
            .undef => try w.writeAll("undef"),
            .defined => try w.writeAll("defined"),
            .int => |int| try w.print("{}", .{int}),
            .string => |str| try w.print("\"{s}\"", .{str}),
            .ident => |str| try w.writeAll(str),
        }
    }

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .absent => b == .absent,
            .undef => b == .undef,
            .defined => b == .defined,
            .int => |x| b == .int and x == b.int,
            .string => |x| b == .string and std.mem.eql(u8, x, b.string),
            .ident => |x| b == .ident and std.mem.eql(u8, x, b.ident),
        };
    }
};

/// Panics with the location of anything invalid, this file is generated so that's a bug.
pub fn parse(arena: std.mem.Allocator, path: []const u8, content: []const u8) File {
    var file: File = .{};
    var values: std.ArrayList(Entry) = .empty;
    var current: ?Entry = null;
    var whens: std.ArrayList(When) = .empty;
    var previous_line: ?[]const u8 = null;
    var seen_entry = false;

    var line_it = std.mem.splitScalar(u8, content, '\n');
    var line_num: u32 = 0;
    while (line_it.next()) |line| {
        line_num += 1;
        if (line.len == 0 or line[0] == '#') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse invalid(path, line_num, line);
        const name = line[0..space];

        var remaining = line[space + 1 ..];
        var lists: [input_names.len]?[]const []const u8 = @splat(null);
        var has_condition = false;
        while (std.mem.indexOfScalar(u8, remaining, ' ')) |end| {
            const token = remaining[0..end];
            if (token[0] == '"') break;
            const eq = std.mem.indexOfScalar(u8, token, '=') orelse invalid(path, line_num, line);
            const input_index = for (input_names, 0..) |input_name, i| {
                if (std.mem.eql(u8, input_name, token[0..eq])) break i;
            } else invalid(path, line_num, line);
            if (lists[input_index] != null) invalid(path, line_num, line);
            var list: std.ArrayList([]const u8) = .empty;
            var item_it = std.mem.splitScalar(u8, token[eq + 1 ..], ',');
            while (item_it.next()) |item| {
                if (item.len == 0) invalid(path, line_num, line);
                list.append(arena, item) catch @panic("OOM");
            }
            lists[input_index] = list.items;
            has_condition = true;
            remaining = remaining[end + 1 ..];
        }
        const value = Value.parse(remaining) orelse invalid(path, line_num, line);

        if (has_condition) {
            const entry_name = if (current) |entry| entry.name else invalid(path, line_num, line);
            if (!std.mem.eql(u8, entry_name, name)) invalid(path, line_num, line);
            if (previous_line) |previous| {
                if (!std.mem.lessThan(u8, previous, line)) invalid(path, line_num, line);
            }
            previous_line = line;
            whens.append(arena, .{ .lists = lists, .value = value }) catch @panic("OOM");
        } else {
            if (current) |entry| {
                const finished: Entry = .{ .name = entry.name, .value = entry.value, .when = whens.items };
                if (std.mem.eql(u8, entry.name, verified_name)) {
                    file.verified = finished;
                } else {
                    if (std.mem.eql(u8, name, verified_name)) invalid(path, line_num, line);
                    if (!std.mem.lessThan(u8, entry.name, name)) invalid(path, line_num, line);
                    values.append(arena, finished) catch @panic("OOM");
                }
            } else if (!std.mem.eql(u8, name, verified_name)) invalid(path, line_num, line);
            seen_entry = true;
            current = .{ .name = name, .value = value };
            whens = .empty;
            previous_line = null;
        }
    }
    if (current) |entry| {
        const finished: Entry = .{ .name = entry.name, .value = entry.value, .when = whens.items };
        if (std.mem.eql(u8, entry.name, verified_name)) {
            file.verified = finished;
        } else {
            values.append(arena, finished) catch @panic("OOM");
        }
    }
    file.values = values.items;
    return file;
}

fn invalid(path: []const u8, line_num: u32, line: []const u8) noreturn {
    std.debug.panic("{s}:{}: invalid line '{s}'", .{ path, line_num, line });
}

const std = @import("std");
