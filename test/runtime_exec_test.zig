const std = @import("std");
const runtime_exec = @import("runtime_exec");

test "helpOutputHasRootFlag detects --root" {
    try std.testing.expect(runtime_exec.helpOutputHasRootFlag("Usage: runc [global options]\n  --root value\n"));
    try std.testing.expect(runtime_exec.helpOutputHasRootFlag("--root string\n"));
    try std.testing.expect(!runtime_exec.helpOutputHasRootFlag("Usage: youki run ...\n"));
}

test "helpOutputHasRootlessFlag detects --rootless" {
    try std.testing.expect(runtime_exec.helpOutputHasRootlessFlag("--rootless value\n"));
    try std.testing.expect(!runtime_exec.helpOutputHasRootlessFlag("--something-else\n"));
}

test "helpOutputHasCgroupManagerFlag detects --cgroup-manager" {
    try std.testing.expect(runtime_exec.helpOutputHasCgroupManagerFlag("--cgroup-manager value\n"));
    try std.testing.expect(!runtime_exec.helpOutputHasCgroupManagerFlag("--cgroup foo\n"));
}

test "buildRuntimeRunArgv includes --root when supported" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var argv = try runtime_exec.buildRuntimeRunArgv(allocator, "/tmp/runtime", "abc123", "/tmp/state", true, false, false, false, false);
    defer argv.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), argv.items.len);
    try std.testing.expectEqualStrings("/tmp/runtime", argv.items[0]);
    try std.testing.expectEqualStrings("--root", argv.items[1]);
    try std.testing.expectEqualStrings("/tmp/state", argv.items[2]);
    try std.testing.expectEqualStrings("run", argv.items[3]);
    try std.testing.expectEqualStrings("abc123", argv.items[4]);
}

test "buildRuntimeRunArgv omits --root when unsupported" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var argv = try runtime_exec.buildRuntimeRunArgv(allocator, "/tmp/runtime", "abc123", "/tmp/state", false, false, false, false, false);
    defer argv.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("/tmp/runtime", argv.items[0]);
    try std.testing.expectEqualStrings("run", argv.items[1]);
    try std.testing.expectEqualStrings("abc123", argv.items[2]);
}

test "buildRuntimeRunArgv includes --rootless when forced and supported" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var argv = try runtime_exec.buildRuntimeRunArgv(allocator, "/tmp/runtime", "abc123", "/tmp/state", true, true, true, false, false);
    defer argv.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 6), argv.items.len);
    try std.testing.expectEqualStrings("/tmp/runtime", argv.items[0]);
    try std.testing.expectEqualStrings("--root", argv.items[1]);
    try std.testing.expectEqualStrings("/tmp/state", argv.items[2]);
    try std.testing.expectEqualStrings("--rootless=true", argv.items[3]);
    try std.testing.expectEqualStrings("run", argv.items[4]);
    try std.testing.expectEqualStrings("abc123", argv.items[5]);
}

test "buildRuntimeRunArgv includes --cgroup-manager cgroupfs when forced and supported" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var argv = try runtime_exec.buildRuntimeRunArgv(allocator, "/tmp/runtime", "abc123", "/tmp/state", true, false, false, true, true);
    defer argv.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 7), argv.items.len);
    try std.testing.expectEqualStrings("/tmp/runtime", argv.items[0]);
    try std.testing.expectEqualStrings("--root", argv.items[1]);
    try std.testing.expectEqualStrings("/tmp/state", argv.items[2]);
    try std.testing.expectEqualStrings("--cgroup-manager", argv.items[3]);
    try std.testing.expectEqualStrings("cgroupfs", argv.items[4]);
    try std.testing.expectEqualStrings("run", argv.items[5]);
    try std.testing.expectEqualStrings("abc123", argv.items[6]);
}

test "computeUsernsIdMap splits around user id" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // user_id within the subordinate range => should split into 0..user, user, user+1..end.
    var triples = try runtime_exec.computeUsernsIdMap(allocator, 1000, 100000, 65536);
    defer triples.deinit(allocator);

    try std.testing.expect(triples.items.len >= 2);

    var saw_user: bool = false;
    for (triples.items) |t| {
        if (t.container_id == 1000 and t.host_id == 1000 and t.size == 1) saw_user = true;
    }
    try std.testing.expect(saw_user);
}

test "computeUsernsIdMap no-overlap when user outside range" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var triples = try runtime_exec.computeUsernsIdMap(allocator, 1000, 100000, 100);
    defer triples.deinit(allocator);

    // Should include full sub range and separate user mapping.
    try std.testing.expectEqual(@as(usize, 2), triples.items.len);
    try std.testing.expectEqual(@as(u32, 0), triples.items[0].container_id);
    try std.testing.expectEqual(@as(u32, 100000), triples.items[0].host_id);
    try std.testing.expectEqual(@as(u32, 100), triples.items[0].size);
    try std.testing.expectEqual(@as(u32, 1000), triples.items[1].container_id);
    try std.testing.expectEqual(@as(u32, 1000), triples.items[1].host_id);
    try std.testing.expectEqual(@as(u32, 1), triples.items[1].size);
}
