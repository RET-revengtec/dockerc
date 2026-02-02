const std = @import("std");
const assert = std.debug.assert;
const common = @import("common.zig");
const build_info = @import("build_info");

const mkdtemp = common.mkdtemp;
const extract_file = common.extract_file;

const c = @cImport({
    @cDefine("_GNU_SOURCE", {});
    @cDefine("LIBCRUN_PUBLIC", "");
    @cInclude("pwd.h");
    @cInclude("libcrun/container.h");
    @cInclude("libcrun/custom-handler.h");
    @cInclude("subid.h");
});

extern fn squashfuse_main(argc: c_int, argv: [*:null]const ?[*:0]const u8) c_int;
extern fn overlayfs_main(argc: c_int, argv: [*:null]const ?[*:0]const u8) c_int;

const eql = std.mem.eql;

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const s = try std.fmt.allocPrint(allocator, fmt ++ "\x00", args);
    return s[0 .. s.len - 1 :0];
}

// inspired from std.posix.getenv
fn getEnvFull(key: []const u8) ?[:0]const u8 {
    var ptr = std.c.environ;
    while (ptr[0]) |line| : (ptr += 1) {
        var line_i: usize = 0;
        while (line[line_i] != 0 and line[line_i] != '=') : (line_i += 1) {}
        const this_key = line[0..line_i];

        if (!std.mem.eql(u8, this_key, key)) continue;

        return std.mem.sliceTo(line, 0);
    }
    return null;
}

const IDMapping = struct {
    containerID: i64,
    hostID: i64,
    size: i64,

    fn toValue(self: @This(), allocator: Allocator) !std.json.Value {
        var object = std.json.ObjectMap.init(allocator);
        try object.put("containerID", std.json.Value{
            .integer = self.containerID,
        });
        try object.put("hostID", std.json.Value{
            .integer = self.hostID,
        });
        try object.put("size", std.json.Value{
            .integer = self.size,
        });
        return std.json.Value{ .object = object };
    }
};

const IDMappings = []IDMapping;

fn intToString(allocator: Allocator, v: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{}", .{v});
}

fn newgidmap(allocator: Allocator, pid: i64, gid_mappings: IDMappings) !void {
    return uidgidmap_helper(allocator, "newgidmap", pid, gid_mappings);
}

fn newuidmap(allocator: Allocator, pid: i64, uid_mappings: IDMappings) !void {
    return uidgidmap_helper(allocator, "newuidmap", pid, uid_mappings);
}

fn uidgidmap_helper(child_allocator: Allocator, helper: []const u8, pid: i64, uid_mappings: IDMappings) !void {
    var arena = std.heap.ArenaAllocator.init(child_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 2 + 3 * uid_mappings.len);
    argv.appendAssumeCapacity(helper);
    // TODO: specify pid using fd:N to avoid a TOCTTOU, see newuidmap(1)
    argv.appendAssumeCapacity(try intToString(allocator, pid));

    for (uid_mappings) |uid_mapping| {
        argv.appendAssumeCapacity(try intToString(allocator, uid_mapping.containerID));
        argv.appendAssumeCapacity(try intToString(allocator, uid_mapping.hostID));
        argv.appendAssumeCapacity(try intToString(allocator, uid_mapping.size));
    }

    var newuidmapProcess = std.process.Child.init(argv.items, allocator);
    switch (try newuidmapProcess.spawnAndWait()) {
        .Exited => |status| if (status == 0) {
            return;
        } else {
            std.debug.panic("newuidmap/newgidmap failed with status: {}", .{status});
        },
        else => |term| {
            std.debug.panic("newuidmap/newgidmap terminated abnormally: {}", .{term});
        },
    }
    return error.UidGidMapFailed;
}

const Allocator = std.mem.Allocator;

fn IDMappingsToValue(allocator: Allocator, id_mappings: IDMappings) !std.json.Value {
    var array = try std.json.Array.initCapacity(allocator, id_mappings.len);
    for (id_mappings) |id_mapping| {
        array.appendAssumeCapacity(try id_mapping.toValue(allocator));
    }
    return std.json.Value{ .array = array };
}

const IdMapParser = struct {
    bytes: []const u8,
    index: usize = 0,

    fn nextNumber(self: *IdMapParser) ?i64 {
        while (self.index < self.bytes.len and (self.bytes[self.index] < '0' or self.bytes[self.index] > '9')) {
            self.index += 1;
        }

        if (self.index == self.bytes.len) {
            return null;
        }

        const intStart = self.index;

        while (self.bytes[self.index] >= '0' and self.bytes[self.index] <= '9') {
            self.index += 1;

            if (self.index == self.bytes.len) {
                break;
            }
        }

        return std.fmt.parseInt(i64, self.bytes[intStart..self.index], 10) catch |err| {
            std.debug.panic("unexpected error parsing uid_map/gid_map: {}\n", .{err});
        };
    }
};

fn parseIdmap(allocator: Allocator, bytes: []const u8) !IDMappings {
    var idmap_parser = IdMapParser{ .bytes = bytes };
    var id_mappings = try std.ArrayList(IDMapping).initCapacity(allocator, 0);

    while (idmap_parser.nextNumber()) |containerID| {
        try id_mappings.append(allocator, IDMapping{
            .containerID = containerID,
            .hostID = idmap_parser.nextNumber() orelse std.debug.panic("must have 3 numbers\n", .{}),
            .size = idmap_parser.nextNumber() orelse std.debug.panic("must have 3 numbers\n", .{}),
        });
    }

    return id_mappings.toOwnedSlice(allocator);
}

fn updateIdMap(id_mappings: IDMappings) void {
    var runningId: i64 = 0;

    for (id_mappings) |*id_mapping| {
        id_mapping.*.hostID = id_mapping.*.containerID;
        id_mapping.*.containerID = runningId;
        runningId += id_mapping.*.size;
    }
}

fn getContainerFromArgs(file: std.fs.File, rootfs_absolute_path: []const u8, parentAllocator: std.mem.Allocator) ![*c]c.libcrun_container_t {
    var arena = std.heap.ArenaAllocator.init(parentAllocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file_contents = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, file_contents, .{ .max_value_len = 99999999 });
    var root_value = parsed.value;

    var args_json: *std.json.Array = undefined;
    var env_json: *std.json.Array = undefined;
    var mounts_json: *std.json.Array = undefined;

    switch (root_value) {
        .object => |*object| {
            const processVal = object.getPtr("process") orelse @panic("no process key");
            switch (processVal.*) {
                .object => |*process| {
                    const argsVal = process.getPtr("args") orelse @panic("no args key");
                    switch (argsVal.*) {
                        .array => |*argsArr| {
                            args_json = argsArr;
                        },
                        else => return error.InvalidJSON,
                    }

                    if (process.getPtr("env")) |envVal| {
                        switch (envVal.*) {
                            .array => |*envArr| {
                                env_json = envArr;
                            },
                            else => return error.InvalidJSON,
                        }
                    } else {
                        var array = std.json.Array.init(allocator);
                        env_json = &array;
                        try process.put("env", std.json.Value{ .array = array });
                    }
                },
                else => return error.InvalidJSON,
            }

            if (object.getPtr("mounts")) |mountsVal| {
                switch (mountsVal.*) {
                    .array => |*mountsArr| {
                        mounts_json = mountsArr;
                    },
                    else => return error.InvalidJSON,
                }
            } else {
                var array = std.json.Array.init(allocator);
                mounts_json = &array;
                try object.put("mounts", std.json.Value{ .array = array });
            }

            const rootVal = object.getPtr("root") orelse @panic("no root key");
            switch (rootVal.*) {
                .object => |*root| {
                    try root.put("path", std.json.Value{ .string = rootfs_absolute_path });
                },
                else => return error.InvalidJSON,
            }

            const linuxVal = object.getPtr("linux") orelse @panic("no linux key");
            switch (linuxVal.*) {
                .object => |*linux| {
                    // In rootfull containers uidMappings is not set
                    if (linux.getPtr("uidMappings")) |uidMappingsVal| {
                        const uid_map = try std.fs.cwd().readFileAlloc(allocator, "/proc/self/uid_map", 1000000);
                        const uidMappings = try parseIdmap(allocator, uid_map);

                        updateIdMap(uidMappings);

                        uidMappingsVal.* = try IDMappingsToValue(allocator, uidMappings);
                    }

                    // In rootfull containers gidMappings is not set
                    if (linux.getPtr("gidMappings")) |gidMappingsVal| {
                        const gid_map = try std.fs.cwd().readFileAlloc(allocator, "/proc/self/gid_map", 1000000);
                        const gidMappings = try parseIdmap(allocator, gid_map);

                        updateIdMap(gidMappings);

                        gidMappingsVal.* = try IDMappingsToValue(allocator, gidMappings);
                    }
                },
                else => return error.InvalidJSON,
            }
        },
        else => return error.InvalidJSON,
    }

    var args = std.process.args();
    _ = args.next() orelse @panic("there should be an executable");

    while (args.next()) |arg| {
        if (eql(u8, arg, "-e") or eql(u8, arg, "--env")) {
            const environment_variable = args.next() orelse @panic("expected environment variable");
            if (std.mem.indexOfScalar(u8, environment_variable, '=')) |_| {
                try env_json.append(std.json.Value{ .string = environment_variable });
            } else {
                try env_json.append(std.json.Value{ .string = getEnvFull(environment_variable) orelse @panic("environment variable does not exist") });
            }
        } else if (eql(u8, arg, "-v") or eql(u8, arg, "--volume")) {
            const volume_syntax = args.next() orelse @panic("expected volume syntax");

            var mount = std.json.ObjectMap.init(allocator);

            var options = std.json.Array.init(allocator);
            try options.append(std.json.Value{ .string = "rw" });
            try options.append(std.json.Value{ .string = "rbind" });
            try mount.put("options", std.json.Value{ .array = options });

            const separator = std.mem.indexOfScalar(u8, volume_syntax, ':') orelse @panic("no volume destination specified");

            if (volume_syntax[0] == '/') {
                try mount.put("source", std.json.Value{ .string = volume_syntax[0..separator] });
            } else {
                try mount.put("source", std.json.Value{ .string = try std.fs.cwd().realpathAlloc(allocator, volume_syntax[0..separator]) });
            }
            try mount.put("destination", std.json.Value{ .string = volume_syntax[separator + 1 ..] });

            try mounts_json.append(std.json.Value{ .object = mount });
        } else if (eql(u8, arg, "--")) {
            while (args.next()) |arg_inner| {
                try args_json.append(std.json.Value{ .string = arg_inner });
            }
        } else {
            try args_json.append(std.json.Value{ .string = arg });
        }
    }

    const stringified_config = stringified_config: {
        var list = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer list.deinit(allocator);
        try list.writer(allocator).print("{f}", .{std.json.fmt(root_value, .{})});
        break :stringified_config try list.toOwnedSliceSentinel(allocator, 0);
    };

    var err: c.libcrun_error_t = null;
    const container = c.libcrun_container_load_from_memory(stringified_config, &err);
    if (container == null) {
        std.debug.panic("failed to load config: {s}\n", .{err.*.msg});
    }

    return container;
}

fn check_unprivileged_userns_permissions() void {
    var sysctl_paths = [_]struct { path: []const u8, expected_value: u8, expected_value_is_set: bool }{
        .{ .path = "/proc/sys/kernel/unprivileged_userns_clone", .expected_value = '1', .expected_value_is_set = true },
        .{ .path = "/proc/sys/kernel/apparmor_restrict_unprivileged_userns", .expected_value = '0', .expected_value_is_set = true },
    };

    for (&sysctl_paths) |*sysctl_path| {
        if (std.fs.openFileAbsolute(sysctl_path.path, .{ .mode = .read_only })) |file| {
            defer file.close();

            var buffer: [1]u8 = undefined;
            const bytes_read = file.readAll(&buffer) catch |err| std.debug.panic("failed reading {s}: {}", .{ sysctl_path.path, err });
            assert(bytes_read == 1);

            if (buffer[0] != sysctl_path.expected_value) {
                sysctl_path.expected_value_is_set = false;
            }
        } else |err| {
            if (err != std.fs.File.OpenError.FileNotFound) {
                std.debug.panic("error: {}\n", .{err});
            }
        }
    }

    if (!(sysctl_paths[0].expected_value_is_set and sysctl_paths[1].expected_value_is_set)) {
        std.debug.print("error: User namespace creation restricted. Run as root or disable restrictions using:\n", .{});
        if (!sysctl_paths[0].expected_value_is_set) {
            std.debug.print("sudo sysctl -w kernel.unprivileged_userns_clone=1\n", .{});
        }

        if (!sysctl_paths[1].expected_value_is_set) {
            std.debug.print("sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0\n", .{});
        }

        std.posix.exit(1);
    }
}

fn umount(path: [*:0]const u8) void {
    const umountRet: i64 = @bitCast(std.os.linux.umount(path));
    if (umountRet != 0) {
        assert(umountRet < 0 and umountRet > -4096);
        const errno: std.posix.E = @enumFromInt(-umountRet);
        std.debug.panic("Failed to unmount {s}. Errno: {}\n", .{ path, errno });
    }
}

pub fn main() !u8 {
    var args = std.process.args();
    const executable_path = args.next() orelse @panic("unreachable: there must be a executable name");

    while (args.next()) |arg| {
        if (eql(u8, arg, "--dockerc-version")) {
            std.debug.print("dockerc version: {s}\n", .{build_info.dockerc_version});
            return 0;
        }
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // TODO: consider the case where a user can mount the filesystem but isn't root
    // We might only need to check for CAP_SYS_ADMIN
    // Also in the case where fusermount3 is present this is unnecessary
    const euid = std.os.linux.geteuid();
    if (euid != 0) {
        // So that fuse filesystems can be mounted without needing fusermount3

        const egid = std.os.linux.getegid();

        const username = try allocator.dupeZ(u8, std.mem.span(blk: {
            const pw = c.getpwuid(@as(c.uid_t, euid));
            if (pw == null) @panic("couldn't get username");
            break :blk pw.*.pw_name;
        }));
        defer allocator.free(username);

        var subuid_ranges: [*]c.subid_range = undefined;
        var subgid_ranges: [*]c.subid_range = undefined;

        var uid_mappings = try std.ArrayList(IDMapping).initCapacity(allocator, 0);
        defer uid_mappings.deinit(allocator);

        try uid_mappings.append(allocator, IDMapping{
            .containerID = 0,
            .hostID = euid,
            .size = 1,
        });

        var gid_mappings = try std.ArrayList(IDMapping).initCapacity(allocator, 0);
        defer gid_mappings.deinit(allocator);

        try gid_mappings.append(allocator, IDMapping{
            .containerID = 0,
            .hostID = egid,
            .size = 1,
        });

        const subuid_ranges_len = c.subid_get_uid_ranges(username, @ptrCast(&subuid_ranges));
        const subgid_ranges_len = c.subid_get_gid_ranges(username, @ptrCast(&subgid_ranges));

        if (subuid_ranges_len > 0) {
            for (0..@intCast(subuid_ranges_len)) |i| {
                try uid_mappings.append(allocator, IDMapping{
                    .containerID = @intCast(subuid_ranges[i].start),
                    .hostID = @intCast(subuid_ranges[i].start),
                    .size = @intCast(subuid_ranges[i].count),
                });
            }
        }

        if (subgid_ranges_len > 0) {
            for (0..@intCast(subgid_ranges_len)) |i| {
                try gid_mappings.append(allocator, IDMapping{
                    .containerID = @intCast(subgid_ranges[i].start),
                    .hostID = @intCast(subgid_ranges[i].start),
                    .size = @intCast(subgid_ranges[i].count),
                });
            }
        }

        const pipe = try std.posix.pipe();
        const read_fd = pipe[0];
        const write_fd = pipe[1];

        const pid: i64 = @bitCast(std.os.linux.clone2(std.os.linux.CLONE.NEWUSER | std.os.linux.CLONE.NEWNS | std.os.linux.SIG.CHLD, 0));
        if (pid < 0) {
            std.debug.panic("failed to clone process: {}\n", .{std.posix.errno(pid)});
        }

        if (pid > 0) {
            std.posix.close(read_fd);
            // inside parent process

            const set_groups_file = try std.fmt.allocPrint(allocator, "/proc/{}/setgroups", .{pid});
            defer allocator.free(set_groups_file);

            newuidmap(allocator, pid, uid_mappings.items) catch {
                std.debug.print("newuidmap failed, falling back to single user mapping\n", .{});
                const uid_map_path = try std.fmt.allocPrint(allocator, "/proc/{}/uid_map", .{pid});
                defer allocator.free(uid_map_path);

                const uid_map_content = try std.fmt.allocPrint(allocator, "0 {} 1", .{euid});
                defer allocator.free(uid_map_content);
                std.fs.cwd().writeFile(.{ .sub_path = uid_map_path, .data = uid_map_content }) catch |err| {
                    if (err == std.posix.WriteError.AccessDenied) {
                        // TODO: when using newuidmap this may not get hit until
                        // trying to mount file system
                        check_unprivileged_userns_permissions();
                    }
                    std.debug.panic("error: {}\n", .{err});
                };
            };

            newgidmap(allocator, pid, gid_mappings.items) catch {
                std.debug.print("newgidmap failed, falling back to single group mapping\n", .{});

                // must be set for writing to gid_map to succeed (see user_namespaces(7))
                // otherwise we want to leave it untouched so that setgroups can be used in the container
                try std.fs.cwd().writeFile(.{ .sub_path = set_groups_file, .data = "deny" });

                const gid_map_path = try std.fmt.allocPrint(allocator, "/proc/{}/gid_map", .{pid});
                defer allocator.free(gid_map_path);

                const gid_map_content = try std.fmt.allocPrint(allocator, "0 {} 1", .{egid});
                defer allocator.free(gid_map_content);
                std.fs.cwd().writeFile(.{ .sub_path = gid_map_path, .data = gid_map_content }) catch |err| {
                    if (err == std.posix.WriteError.AccessDenied) {
                        check_unprivileged_userns_permissions();
                    }
                    std.debug.panic("error: {}\n", .{err});
                };
            };

            std.posix.close(write_fd);
            const wait_result = std.posix.waitpid(@intCast(pid), 0);
            if (std.os.linux.W.IFEXITED(wait_result.status)) {
                return std.os.linux.W.EXITSTATUS(wait_result.status);
            }
            std.debug.panic("did not exit normally status: {}\n", .{wait_result.status});
        }

        std.posix.close(write_fd);

        var buf: [1]u8 = undefined;
        const bytes_read = try std.posix.read(read_fd, &buf);
        assert(bytes_read == 0);
        std.posix.close(read_fd);
    }

    var temp_dir_path = "/tmp/dockerc-XXXXXX".*;
    try mkdtemp(&temp_dir_path);

    const filesystem_bundle_dir_null = try allocPrintZ(allocator, "{s}/{s}", .{ temp_dir_path, "bundle.squashfs" });
    defer allocator.free(filesystem_bundle_dir_null);

    try std.fs.makeDirAbsolute(filesystem_bundle_dir_null);

    const mount_dir_path = try allocPrintZ(allocator, "{s}/mount", .{temp_dir_path});
    defer allocator.free(mount_dir_path);

    const footer = try common.getFooter(executable_path);
    const offsetArg = try allocPrintZ(allocator, "offset={}", .{footer.offset});
    defer allocator.free(offsetArg);

    const args_buf = [_:null]?[*:0]const u8{ "squashfuse", "-o", offsetArg, executable_path, filesystem_bundle_dir_null };

    {
        const pid = try std.posix.fork();
        if (pid == 0) {
            std.process.exit(@intCast(squashfuse_main(args_buf.len, &args_buf)));
        }

        const wait_pid_result = std.posix.waitpid(pid, 0);
        if (wait_pid_result.status != 0) {
            // TODO: extract instead of failing
            std.debug.panic("failed to run squashfuse", .{});
        }
    }

    const overlayfs_options = try allocPrintZ(allocator, "lowerdir={s},upperdir={s}/upper,workdir={s}/work", .{
        filesystem_bundle_dir_null,
        temp_dir_path,
        temp_dir_path,
    });
    defer allocator.free(overlayfs_options);

    const container = container: {
        // Indent so that handles to files in mounted dir are closed by the end
        // to avoid umounting from being blocked.
        var tmpDir = try std.fs.openDirAbsolute(&temp_dir_path, .{});
        defer tmpDir.close();
        try tmpDir.makeDir("upper");
        try tmpDir.makeDir("work");
        try tmpDir.makeDir("mount");

        const overlayfs_args = [_:null]?[*:0]const u8{ "fuse-overlayfs", "-o", overlayfs_options, mount_dir_path };

        // reap the child of fuse-overlayfs so that we can be sure fuse-overlayfs
        // has exited before unmounting squashfuse
        assert(try std.posix.prctl(std.posix.PR.SET_CHILD_SUBREAPER, .{1}) == 0);
        const pid = try std.posix.fork();
        if (pid == 0) {
            _ = overlayfs_main(overlayfs_args.len, &overlayfs_args);
            std.debug.panic("unreachable", .{});
        }

        const wait_pid_result = std.posix.waitpid(pid, 0);
        assert(try std.posix.prctl(std.posix.PR.SET_CHILD_SUBREAPER, .{0}) == 0);

        if (wait_pid_result.status != 0) {
            std.debug.panic("failed to run overlayfs", .{});
        }

        const rootfs_absolute_path = try std.fmt.allocPrint(allocator, "{s}/mount/rootfs", .{temp_dir_path});
        defer allocator.free(rootfs_absolute_path);

        const file = try tmpDir.openFile("mount/config.json", .{ .mode = .read_only });
        defer file.close();

        break :container try getContainerFromArgs(file, rootfs_absolute_path, allocator);
    };
    defer c.libcrun_container_free(container);

    var crun_context = c.libcrun_context_t{
        .bundle = mount_dir_path,
        .id = temp_dir_path[13..],
        .fifo_exec_wait_fd = -1,
        .preserve_fds = 0,
        .listen_fds = 0,
    };

    var err: c.libcrun_error_t = null;
    if (c.libcrun_init_logging(&crun_context.output_handler, &crun_context.output_handler_arg, crun_context.id, null, &err) < 0) {
        std.debug.panic("unreachable but not using the unreachable keyword for forward compatibility", .{});
    }

    crun_context.handler_manager = c.libcrun_handler_manager_create(&err);
    if (crun_context.handler_manager == null) {
        std.debug.panic("failed to create handler manager ({d}): {s}\n", .{ err.*.status, err.*.msg });
    }

    // if XDG_RUNTIME_DIR is not set then /run/crun is used as the default which
    // fails because most users do not have write permission there
    assert(c.setenv("XDG_RUNTIME_DIR", "/tmp", 0) == 0);

    const pid = try std.posix.fork();
    assert(pid >= 0);
    if (pid == 0) {
        // Run container in a separate process because crun will try to reap
        // every child including the fuse-overlayfs process still running
        const ret = c.libcrun_container_run(&crun_context, container, 0, &err);

        if (err != null) {
            std.debug.panic("failed to run container (status/errno: {}) ({d}): {s}\n", .{ err.*.status, ret, err.*.msg });
        }

        return @intCast(ret);
    }

    const retStatus = std.posix.waitpid(pid, 0);
    if (!std.posix.W.IFEXITED(retStatus.status)) {
        std.debug.panic("container didn't exist normally : {}\n", .{retStatus.status});
    }

    umount(mount_dir_path);

    // wait for overlayfs process to finish so that device is not busy to unmount squashfuse
    const overlayfs_status = std.posix.waitpid(-1, 0);
    if (!std.posix.W.IFEXITED(overlayfs_status.status) or std.posix.W.EXITSTATUS(overlayfs_status.status) != 0) {
        std.debug.panic("overlayfs failed to exit successfully, status: {}\n", .{overlayfs_status.status});
    }

    umount(filesystem_bundle_dir_null);

    try std.fs.deleteTreeAbsolute(&temp_dir_path);

    return std.posix.W.EXITSTATUS(retStatus.status);
}
