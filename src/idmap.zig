const std = @import("std");

pub const IDMapping = struct {
    containerID: i64,
    hostID: i64,
    size: i64,
};

pub const IDMappings = []IDMapping;

const IdMapParser = struct {
    bytes: []const u8,
    index: usize = 0,

    fn nextNumber(self: *IdMapParser) ?i64 {
        while (self.index < self.bytes.len and (self.bytes[self.index] < '0' or self.bytes[self.index] > '9')) {
            self.index += 1;
        }

        if (self.index == self.bytes.len) return null;

        const int_start = self.index;
        while (self.bytes[self.index] >= '0' and self.bytes[self.index] <= '9') {
            self.index += 1;
            if (self.index == self.bytes.len) break;
        }

        return std.fmt.parseInt(i64, self.bytes[int_start..self.index], 10) catch |err| {
            std.debug.panic("unexpected error parsing uid_map/gid_map: {}\n", .{err});
        };
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !IDMappings {
    var parser = IdMapParser{ .bytes = bytes };
    var mappings = try std.ArrayList(IDMapping).initCapacity(allocator, 0);

    while (parser.nextNumber()) |container_id| {
        try mappings.append(allocator, .{
            .containerID = container_id,
            .hostID = parser.nextNumber() orelse std.debug.panic("must have 3 numbers\n", .{}),
            .size = parser.nextNumber() orelse std.debug.panic("must have 3 numbers\n", .{}),
        });
    }

    return mappings.toOwnedSlice(allocator);
}

pub fn updateInPlace(mappings: IDMappings) void {
    var running_id: i64 = 0;
    for (mappings) |*mapping| {
        mapping.hostID = mapping.containerID;
        mapping.containerID = running_id;
        running_id += mapping.size;
    }
}
