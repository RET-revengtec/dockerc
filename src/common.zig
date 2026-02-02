const std = @import("std");
const builtin = @import("builtin");

const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const native_endian = builtin.target.cpu.arch.endian();

pub const Footer = extern struct {
    offset: u64,
    // TODO: make use of this field, currently ignored
    require_mapped_uids: bool = false,
};

pub fn mkdtemp(in: []u8) !void {
    try std.posix.getrandom(in[in.len - 6 ..]);
    for (in[in.len - 6 ..]) |*v| {
        v.* = letters[v.* % letters.len];
    }

    try std.posix.mkdir(in, 0o700);
}

// TODO: ideally we can use memfd_create
// The problem is that zig doesn't have fexecve support by default so it would
// be a pain to find the location of the file.
pub fn extract_file(tmpDir: []const u8, name: []const u8, data: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmpDir, name });

    const file = try std.fs.createFileAbsolute(path, .{ .mode = 0o700 });
    defer file.close();
    try file.writeAll(data);

    return path;
}

pub fn getFooter(path: []const u8) !Footer {
    var file = try std.fs.cwd().openFile(path, .{});
    try file.seekFromEnd(-@sizeOf(Footer));

    var footer: Footer = undefined;
    std.debug.assert(try file.readAll(std.mem.asBytes(&footer)) == @sizeOf(Footer));

    if (native_endian != std.builtin.Endian.little) {
        std.mem.byteSwapAllFields(Footer, footer[0]);
    }

    return footer;
}

pub fn writeFooter(file: std.fs.File, footer: Footer) !void {
    comptime std.debug.assert(@typeInfo(Footer).@"struct".layout != .auto);

    if (native_endian != std.builtin.Endian.little) {
        std.mem.byteSwapAllFields(Footer, &footer);
    }

    try file.writeAll(std.mem.asBytes(&footer));
}
