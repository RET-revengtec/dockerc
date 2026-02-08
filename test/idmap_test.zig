const std = @import("std");
const idmap = @import("idmap");

test "parse parses multiple lines" {
    const allocator = std.testing.allocator;

    const input = "0 1000 1\n1 2000 2\n";
    const mappings = try idmap.parse(allocator, input);
    defer allocator.free(mappings);

    try std.testing.expectEqual(@as(usize, 2), mappings.len);
    try std.testing.expectEqual(@as(i64, 0), mappings[0].containerID);
    try std.testing.expectEqual(@as(i64, 1000), mappings[0].hostID);
    try std.testing.expectEqual(@as(i64, 1), mappings[0].size);

    try std.testing.expectEqual(@as(i64, 1), mappings[1].containerID);
    try std.testing.expectEqual(@as(i64, 2000), mappings[1].hostID);
    try std.testing.expectEqual(@as(i64, 2), mappings[1].size);
}

test "parse skips non-numeric noise" {
    const allocator = std.testing.allocator;

    const input = "foo 0 1000 1 bar\n# comment\n1 2000 2 baz";
    const mappings = try idmap.parse(allocator, input);
    defer allocator.free(mappings);

    try std.testing.expectEqual(@as(usize, 2), mappings.len);
}

test "updateInPlace rewrites ids sequentially" {
    var mappings = [_]idmap.IDMapping{
        .{ .containerID = 1000, .hostID = 0, .size = 1 },
        .{ .containerID = 2000, .hostID = 0, .size = 2 },
        .{ .containerID = 3000, .hostID = 0, .size = 3 },
    };

    idmap.updateInPlace(mappings[0..]);

    try std.testing.expectEqual(@as(i64, 0), mappings[0].containerID);
    try std.testing.expectEqual(@as(i64, 1000), mappings[0].hostID);

    try std.testing.expectEqual(@as(i64, 1), mappings[1].containerID);
    try std.testing.expectEqual(@as(i64, 2000), mappings[1].hostID);

    try std.testing.expectEqual(@as(i64, 3), mappings[2].containerID);
    try std.testing.expectEqual(@as(i64, 3000), mappings[2].hostID);
}
