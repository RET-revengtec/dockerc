const std = @import("std");
const dockerc_config = @import("dockerc_config");

test "loadFromFile parses config and ignores unknown fields" {
    const testing_allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json =
        \\{
        \\  "image": "docker.io/library/alpine:latest",
        \\  "output": "out.sqfs",
        \\  "arch": "amd64",
        \\  "unknown": 123
        \\}
    ;

    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = json });

    const config_path = try tmp.dir.realpathAlloc(testing_allocator, "config.json");
    defer testing_allocator.free(config_path);

    const cfg = try dockerc_config.loadFromFile(allocator, config_path);
    try std.testing.expect(cfg.image != null);
    try std.testing.expect(cfg.output != null);
    try std.testing.expect(cfg.arch != null);
    try std.testing.expect(!cfg.rootfull);
    try std.testing.expectEqualStrings("crun", cfg.runtime);
    try std.testing.expect(cfg.runtime_path == null);
}

test "loadFromFile reads runtime settings" {
    const testing_allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json =
        \\{
        \\  "image": "img",
        \\  "output": "out",
        \\  "runtime": "runc",
        \\  "runtime_path": "/usr/bin/runc",
        \\  "rootfull": true
        \\}
    ;

    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = json });

    const config_path = try tmp.dir.realpathAlloc(testing_allocator, "config.json");
    defer testing_allocator.free(config_path);

    const cfg = try dockerc_config.loadFromFile(allocator, config_path);
    try std.testing.expectEqualStrings("runc", cfg.runtime);
    try std.testing.expect(cfg.runtime_path != null);
    try std.testing.expectEqualStrings("/usr/bin/runc", cfg.runtime_path.?);
    try std.testing.expect(cfg.rootfull);
}

test "loadFromFile parses toml" {
    const testing_allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const toml =
        \\image = "img"
        \\output = "out"
        \\arch = "arm64"
        \\runtime = "runc"
        \\runtime_path = "/usr/bin/runc"
        \\rootfull = true
    ;

    try tmp.dir.writeFile(.{ .sub_path = "config.toml", .data = toml });

    const config_path = try tmp.dir.realpathAlloc(testing_allocator, "config.toml");
    defer testing_allocator.free(config_path);

    const cfg = try dockerc_config.loadFromFile(allocator, config_path);
    try std.testing.expectEqualStrings("img", cfg.image.?);
    try std.testing.expectEqualStrings("out", cfg.output.?);
    try std.testing.expectEqualStrings("arm64", cfg.arch.?);
    try std.testing.expectEqualStrings("runc", cfg.runtime);
    try std.testing.expectEqualStrings("/usr/bin/runc", cfg.runtime_path.?);
    try std.testing.expect(cfg.rootfull);
}
