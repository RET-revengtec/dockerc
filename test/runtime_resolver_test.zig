const std = @import("std");
const runtime_resolver = @import("runtime_resolver");

test "parseRuntimeSpec: auto" {
    const spec = try runtime_resolver.parseRuntimeSpec("runc");
    try std.testing.expectEqualStrings("runc", spec.name);
    try std.testing.expectEqual(runtime_resolver.RuntimeSource.auto, spec.source);
    try std.testing.expect(spec.version == null);
}

test "parseRuntimeSpec: local" {
    const spec = try runtime_resolver.parseRuntimeSpec("runc@local");
    try std.testing.expectEqualStrings("runc", spec.name);
    try std.testing.expectEqual(runtime_resolver.RuntimeSource.local, spec.source);
    try std.testing.expect(spec.version == null);
}

test "parseRuntimeSpec: latest" {
    const spec = try runtime_resolver.parseRuntimeSpec("youki@latest");
    try std.testing.expectEqualStrings("youki", spec.name);
    try std.testing.expectEqual(runtime_resolver.RuntimeSource.latest, spec.source);
    try std.testing.expect(spec.version == null);
}

test "parseRuntimeSpec: pinned semver" {
    const spec = try runtime_resolver.parseRuntimeSpec("runc@1.2.3");
    try std.testing.expectEqualStrings("runc", spec.name);
    try std.testing.expectEqual(runtime_resolver.RuntimeSource.pinned, spec.source);
    try std.testing.expect(spec.version != null);
    try std.testing.expectEqualStrings("1.2.3", spec.version.?);
}

test "parseRuntimeSpec: pinned v-prefixed semver" {
    const spec = try runtime_resolver.parseRuntimeSpec("runc@v1.2.3");
    try std.testing.expectEqualStrings("runc", spec.name);
    try std.testing.expectEqual(runtime_resolver.RuntimeSource.pinned, spec.source);
    try std.testing.expectEqualStrings("v1.2.3", spec.version.?);
}

test "parseRuntimeSpec: rejects invalid" {
    try std.testing.expectError(runtime_resolver.ResolveError.InvalidRuntimeSpec, runtime_resolver.parseRuntimeSpec(""));
    try std.testing.expectError(runtime_resolver.ResolveError.InvalidRuntimeSpec, runtime_resolver.parseRuntimeSpec("@latest"));
    try std.testing.expectError(runtime_resolver.ResolveError.InvalidRuntimeSpec, runtime_resolver.parseRuntimeSpec("runc@"));
    try std.testing.expectError(runtime_resolver.ResolveError.InvalidRuntimeVersion, runtime_resolver.parseRuntimeSpec("runc@1.2"));
    try std.testing.expectError(runtime_resolver.ResolveError.InvalidRuntimeVersion, runtime_resolver.parseRuntimeSpec("runc@nope"));
}
