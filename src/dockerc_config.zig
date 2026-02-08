const std = @import("std");

pub const Config = struct {
    image: ?[]const u8 = null,
    output: ?[]const u8 = null,
    arch: ?[]const u8 = null,
    rootfull: bool = false,
    runtime: []const u8 = "crun",
    runtime_path: ?[]const u8 = null,

    _owned_image: ?[]u8 = null,
    _owned_output: ?[]u8 = null,
    _owned_arch: ?[]u8 = null,
    _owned_runtime: ?[]u8 = null,
    _owned_runtime_path: ?[]u8 = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self._owned_image) |buf| allocator.free(buf);
        if (self._owned_output) |buf| allocator.free(buf);
        if (self._owned_arch) |buf| allocator.free(buf);
        if (self._owned_runtime) |buf| allocator.free(buf);
        if (self._owned_runtime_path) |buf| allocator.free(buf);

        self._owned_image = null;
        self._owned_output = null;
        self._owned_arch = null;
        self._owned_runtime = null;
        self._owned_runtime_path = null;
    }
};

fn trim(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn replaceOwnedOpt(
    allocator: std.mem.Allocator,
    owned_slot: *?[]u8,
    field: *?[]const u8,
    value: []const u8,
) !void {
    if (owned_slot.*) |old| allocator.free(old);
    const duped = try allocator.dupe(u8, value);
    owned_slot.* = duped;
    field.* = duped;
}

fn replaceOwnedReq(
    allocator: std.mem.Allocator,
    owned_slot: *?[]u8,
    field: *[]const u8,
    value: []const u8,
) !void {
    if (owned_slot.*) |old| allocator.free(old);
    const duped = try allocator.dupe(u8, value);
    owned_slot.* = duped;
    field.* = duped;
}

fn parseTomlOwned(allocator: std.mem.Allocator, content: []const u8) !Config {
    var cfg = Config{};

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line_raw| {
        var line = line_raw;
        if (std.mem.indexOfScalar(u8, line, '#')) |hash_i| {
            line = line[0..hash_i];
        }
        line = trim(line);
        if (line.len == 0) continue;

        const eq_i = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key_raw = trim(line[0..eq_i]);
        const value_raw = trim(line[eq_i + 1 ..]);
        if (key_raw.len == 0 or value_raw.len == 0) continue;

        const key = key_raw;

        const value = blk: {
            if (value_raw.len >= 2 and value_raw[0] == '"') {
                const end = std.mem.indexOfScalarPos(u8, value_raw, 1, '"') orelse return error.InvalidToml;
                break :blk value_raw[1..end];
            }
            break :blk value_raw;
        };

        if (std.mem.eql(u8, key, "image")) {
            try replaceOwnedOpt(allocator, &cfg._owned_image, &cfg.image, value);
        } else if (std.mem.eql(u8, key, "output")) {
            try replaceOwnedOpt(allocator, &cfg._owned_output, &cfg.output, value);
        } else if (std.mem.eql(u8, key, "arch")) {
            try replaceOwnedOpt(allocator, &cfg._owned_arch, &cfg.arch, value);
        } else if (std.mem.eql(u8, key, "runtime")) {
            try replaceOwnedReq(allocator, &cfg._owned_runtime, &cfg.runtime, value);
        } else if (std.mem.eql(u8, key, "runtime_path") or std.mem.eql(u8, key, "runtime-path")) {
            try replaceOwnedOpt(allocator, &cfg._owned_runtime_path, &cfg.runtime_path, value);
        } else if (std.mem.eql(u8, key, "rootfull")) {
            if (std.mem.eql(u8, value, "true")) {
                cfg.rootfull = true;
            } else if (std.mem.eql(u8, value, "false")) {
                cfg.rootfull = false;
            } else {
                return error.InvalidToml;
            }
        }
    }

    return cfg;
}

fn makeOwnedFromParsed(allocator: std.mem.Allocator, parsed: Config) !Config {
    var cfg = Config{};
    cfg.rootfull = parsed.rootfull;

    if (parsed.image) |v| try replaceOwnedOpt(allocator, &cfg._owned_image, &cfg.image, v);
    if (parsed.output) |v| try replaceOwnedOpt(allocator, &cfg._owned_output, &cfg.output, v);
    if (parsed.arch) |v| try replaceOwnedOpt(allocator, &cfg._owned_arch, &cfg.arch, v);
    if (parsed.runtime_path) |v| try replaceOwnedOpt(allocator, &cfg._owned_runtime_path, &cfg.runtime_path, v);
    try replaceOwnedReq(allocator, &cfg._owned_runtime, &cfg.runtime, parsed.runtime);

    return cfg;
}

pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".toml")) {
        return parseTomlOwned(allocator, content);
    }

    var parsed = try std.json.parseFromSlice(Config, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return makeOwnedFromParsed(allocator, parsed.value);
}
