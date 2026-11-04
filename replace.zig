const std = @import("std");

/// Replaces each @NAME@ in `in` with the value from the NAME=VALUE `replacements`.
/// Panics if a variable is undefined or a replacement is unused.
pub fn replace(
    arena: std.mem.Allocator,
    in_path: []const u8,
    in: []const u8,
    replacements: []const []const u8,
) []const u8 {
    var map: std.StringHashMapUnmanaged(MapNode) = .{};
    for (replacements) |r| {
        const eq_index = std.mem.indexOfScalar(u8, r, '=') orelse std.debug.panic(
            "expected NAME=VALUE but got '{s}'",
            .{r},
        );
        map.put(arena, r[0..eq_index], .{ .count = 0, .value = r[eq_index + 1 ..] }) catch @panic("OOM");
    }

    var out: std.ArrayList(u8) = .empty;
    var missing_count: usize = 0;
    var offset: usize = 0;
    while (true) {
        const at_index = std.mem.indexOfScalarPos(u8, in, offset, '@') orelse break;
        out.appendSlice(arena, in[offset..at_index]) catch @panic("OOM");
        const end = std.mem.indexOfScalarPos(u8, in, at_index + 1, '@') orelse std.debug.panic(
            "{s}: unterminated '@' at offset {}",
            .{ in_path, at_index },
        );
        const name = in[at_index + 1 .. end];
        if (map.getEntry(name)) |entry| {
            entry.value_ptr.count += 1;
            out.appendSlice(arena, entry.value_ptr.value) catch @panic("OOM");
        } else {
            std.log.err("{s}: undefined variable '{s}'", .{ in_path, name });
            missing_count += 1;
        }
        offset = end + 1;
    }
    out.appendSlice(arena, in[offset..]) catch @panic("OOM");
    if (missing_count > 0) std.debug.panic("{} missing variable(s) for template '{s}'", .{ missing_count, in_path });

    var unused_count: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.count == 0) {
            std.log.err("{s}: unused variable '{s}'", .{ in_path, entry.key_ptr.* });
            unused_count += 1;
        }
    }
    if (unused_count != 0) std.debug.panic("{} unused variable(s), they did not appear in template '{s}'", .{ unused_count, in_path });

    return out.items;
}

const MapNode = struct {
    count: usize,
    value: []const u8,
};
