const std = @import("std");
const assert = std.debug.assert;
const common = @import("common.zig");
const idmap = @import("idmap.zig");
const build_info = @import("build_info");

const mkdtemp = common.mkdtemp;
const extract_file = common.extract_file;

const c = @cImport({
    @cDefine("_GNU_SOURCE", {});
    @cInclude("pwd.h");
    @cInclude("subid.h");
});

extern fn squashfuse_main(argc: c_int, argv: [*:null]const ?[*:0]const u8) c_int;
extern fn overlayfs_main(argc: c_int, argv: [*:null]const ?[*:0]const u8) c_int;

const eql = std.mem.eql;

pub fn helpOutputHasRootFlag(output: []const u8) bool {
    // runc exposes: "--root value" (also shown as "--root string" in some builds)
    // Detecting this lets us pass a writable state dir and avoid /run/runc.
    return std.mem.indexOf(u8, output, "--root") != null;
}

pub fn helpOutputHasRootlessFlag(output: []const u8) bool {
    return std.mem.indexOf(u8, output, "--rootless") != null;
}

pub fn helpOutputHasCgroupManagerFlag(output: []const u8) bool {
    return std.mem.indexOf(u8, output, "--cgroup-manager") != null;
}

pub const MappingTriple = struct {
    container_id: u32,
    host_id: u32,
    size: u32,
};

pub fn computeUsernsIdMap(allocator: std.mem.Allocator, user_id: u32, sub_start: u32, sub_count: u32) !std.ArrayList(MappingTriple) {
    // Goal:
    // - Ensure `user_id` inside the namespace maps to the same host id (so tools like runc
    //   can chown to the invoking user).
    // - Map the rest of [0..sub_count) to subordinate IDs starting at sub_start, without
    //   overlapping the `user_id` mapping.
    //
    // When sub_count==0, callers should fall back to a single mapping.
    var out = try std.ArrayList(MappingTriple).initCapacity(allocator, 3);
    errdefer out.deinit(allocator);

    if (sub_count == 0) {
        try out.append(allocator, .{ .container_id = 0, .host_id = user_id, .size = 1 });
        return out;
    }

    if (user_id >= sub_count) {
        try out.append(allocator, .{ .container_id = 0, .host_id = sub_start, .size = sub_count });
        try out.append(allocator, .{ .container_id = user_id, .host_id = user_id, .size = 1 });
        return out;
    }

    // Split the subordinate range around user_id.
    if (user_id > 0) {
        try out.append(allocator, .{ .container_id = 0, .host_id = sub_start, .size = user_id });
    }
    try out.append(allocator, .{ .container_id = user_id, .host_id = user_id, .size = 1 });
    const after_start = user_id + 1;
    if (after_start < sub_count) {
        try out.append(allocator, .{ .container_id = after_start, .host_id = sub_start + user_id, .size = sub_count - after_start });
    }
    return out;
}

pub fn buildRuntimeRunArgv(
    allocator: std.mem.Allocator,
    runtime_bin_path: []const u8,
    container_id: []const u8,
    state_dir: []const u8,
    supports_root_flag: bool,
    supports_rootless_flag: bool,
    force_rootless: bool,
    supports_cgroup_manager_flag: bool,
    force_cgroupfs: bool,
) !std.ArrayList([]const u8) {
    // For runc (and any runtime that supports it), --root controls the state dir.
    // We must avoid defaulting to /run/runc for rootless portability.
    // Keep this simple: worst-case is 6 args (bin, --root, dir, --rootless=true, run, id).
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 6);
    errdefer argv.deinit(allocator);

    try argv.append(allocator, runtime_bin_path);
    if (supports_root_flag) {
        try argv.append(allocator, "--root");
        try argv.append(allocator, state_dir);
    }
    if (supports_rootless_flag and force_rootless) {
        // runc auto-detection checks for euid==0. In our userns setup we appear as uid 0,
        // so force rootless behavior to avoid privileged filesystem operations.
        try argv.append(allocator, "--rootless=true");
    }

    if (supports_cgroup_manager_flag and force_cgroupfs) {
        // Some runtimes (notably youki) default to systemd cgroup manager, which can fail
        // in rootless/non-session contexts. Force cgroupfs for portability.
        try argv.append(allocator, "--cgroup-manager");
        try argv.append(allocator, "cgroupfs");
    }
    try argv.append(allocator, "run");
    try argv.append(allocator, container_id);
    return argv;
}

fn debugDumpBeforeExec(allocator: std.mem.Allocator, temp_dir: []const u8) void {
    // Debug-only diagnostics to understand rootless/userns behavior.
    // Keep output compact but useful.
    const euid = std.os.linux.geteuid();
    const egid = std.os.linux.getegid();
    std.debug.print("debug: euid={} egid={}\n", .{ euid, egid });

    const maybe_print = struct {
        fn go(alloc: std.mem.Allocator, path: []const u8, label: []const u8) void {
            const data = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch {
                std.debug.print("debug: {s}: <unreadable>\n", .{label});
                return;
            };
            defer alloc.free(data);
            std.debug.print("debug: {s}:\n{s}\n", .{ label, data });
        }
    }.go;

    maybe_print(allocator, "/proc/self/uid_map", "uid_map");
    maybe_print(allocator, "/proc/self/gid_map", "gid_map");
    maybe_print(allocator, "/proc/self/setgroups", "setgroups");

    const mountinfo = std.fs.cwd().readFileAlloc(allocator, "/proc/self/mountinfo", 512 * 1024) catch {
        std.debug.print("debug: mountinfo: <unreadable>\n", .{});
        return;
    };
    defer allocator.free(mountinfo);

    std.debug.print("debug: mounts containing '{s}':\n", .{temp_dir});
    var it = std.mem.splitScalar(u8, mountinfo, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, temp_dir) != null) {
            std.debug.print("debug: {s}\n", .{line});
        }
    }
}

fn maybeDisableTerminalInBundle(allocator: std.mem.Allocator, bundle_dir_abs: []const u8) void {
    if (std.posix.isatty(std.posix.STDIN_FILENO)) return;

    const config_abs = std.fmt.allocPrint(allocator, "{s}/config.json", .{bundle_dir_abs}) catch return;
    defer allocator.free(config_abs);

    const data = std.fs.openFileAbsolute(config_abs, .{ .mode = .read_only }) catch return;
    defer data.close();

    const json_bytes = data.readToEndAlloc(allocator, 100 * 1024 * 1024) catch return;
    defer allocator.free(json_bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{ .max_value_len = 99999999 }) catch return;
    defer parsed.deinit();

    switch (parsed.value) {
        .object => |*root| {
            if (root.getPtr("process")) |processVal| {
                if (processVal.* == .object) {
                    _ = processVal.object.put("terminal", std.json.Value{ .bool = false }) catch return;
                }
            }
        },
        else => return,
    }

    var list = std.ArrayList(u8).initCapacity(allocator, 0) catch return;
    defer list.deinit(allocator);
    list.writer(allocator).print("{f}", .{std.json.fmt(parsed.value, .{})}) catch return;
    const out = list.items;

    var out_file = std.fs.createFileAbsolute(config_abs, .{ .truncate = true }) catch return;
    defer out_file.close();
    out_file.writeAll(out) catch return;
}

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const s = try std.fmt.allocPrint(allocator, fmt ++ "\x00", args);
    return s[0 .. s.len - 1 :0];
}

fn ensureDirAbsolute(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn runtimeSupportsRootFlag(allocator: std.mem.Allocator, runtime_bin_path: []const u8, cwd: []const u8) bool {
    const probes = [_][]const []const u8{
        &[_][]const u8{ runtime_bin_path, "--help" },
        &[_][]const u8{ runtime_bin_path, "help" },
    };

    for (probes) |argv| {
        const res = std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv,
            .cwd = cwd,
            .max_output_bytes = 64 * 1024,
        }) catch continue;
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);

        if (helpOutputHasRootFlag(res.stdout) or helpOutputHasRootFlag(res.stderr)) return true;
    }
    return false;
}

fn runtimeSupportsRootlessFlag(allocator: std.mem.Allocator, runtime_bin_path: []const u8, cwd: []const u8) bool {
    const probes = [_][]const []const u8{
        &[_][]const u8{ runtime_bin_path, "--help" },
        &[_][]const u8{ runtime_bin_path, "help" },
    };

    for (probes) |argv| {
        const res = std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv,
            .cwd = cwd,
            .max_output_bytes = 64 * 1024,
        }) catch continue;
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);

        if (helpOutputHasRootlessFlag(res.stdout) or helpOutputHasRootlessFlag(res.stderr)) return true;
    }
    return false;
}

fn runtimeSupportsCgroupManagerFlag(allocator: std.mem.Allocator, runtime_bin_path: []const u8, cwd: []const u8) bool {
    const probes = [_][]const []const u8{
        &[_][]const u8{ runtime_bin_path, "--help" },
        &[_][]const u8{ runtime_bin_path, "help" },
    };

    for (probes) |argv| {
        const res = std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv,
            .cwd = cwd,
            .max_output_bytes = 64 * 1024,
        }) catch continue;
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);

        if (helpOutputHasCgroupManagerFlag(res.stdout) or helpOutputHasCgroupManagerFlag(res.stderr)) return true;
    }
    return false;
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

const IDMapping = idmap.IDMapping;
const IDMappings = idmap.IDMappings;

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
        .Exited => |status| {
            if (status == 0) return;
            return error.UidGidMapFailed;
        },
        else => {
            return error.UidGidMapFailed;
        },
    }
}

const Allocator = std.mem.Allocator;

// NOTE: idmap parsing/update helpers moved to src/idmap.zig

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
        // Best-effort cleanup: on failure paths, the runtime (or its children) may still
        // have references into the mount. Prefer a lazy detach over crashing and leaving
        // behind orphaned temp dirs / mounts.
        if (errno == .BUSY) {
            const MNT_DETACH: u32 = 2;
            const umount2_ret: i64 = @bitCast(std.os.linux.umount2(path, MNT_DETACH));
            if (umount2_ret == 0) return;
        }

        if (std.posix.getenv("DOCKERC_DEBUG_RUNTIME") != null) {
            std.debug.print("warn: failed to unmount {s}: {}\n", .{ path, errno });
        }
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

    const host_euid = std.os.linux.geteuid();
    const host_egid = std.os.linux.getegid();
    const started_unprivileged = (host_euid != 0);

    // TODO: consider the case where a user can mount the filesystem but isn't root
    // We might only need to check for CAP_SYS_ADMIN
    // Also in the case where fusermount3 is present this is unnecessary
    const euid = host_euid;
    if (started_unprivileged) {
        // So that fuse filesystems can be mounted without needing fusermount3

        const egid = host_egid;

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

        var gid_mappings = try std.ArrayList(IDMapping).initCapacity(allocator, 0);
        defer gid_mappings.deinit(allocator);

        const subuid_ranges_len = c.subid_get_uid_ranges(username, @ptrCast(&subuid_ranges));
        const subgid_ranges_len = c.subid_get_gid_ranges(username, @ptrCast(&subgid_ranges));

        if (subuid_ranges_len > 0) {
            const r = subuid_ranges[0];
            var triples = try computeUsernsIdMap(allocator, @intCast(euid), @intCast(r.start), @intCast(r.count));
            defer triples.deinit(allocator);
            for (triples.items) |t| {
                try uid_mappings.append(allocator, IDMapping{
                    .containerID = t.container_id,
                    .hostID = t.host_id,
                    .size = t.size,
                });
            }
        } else {
            // Best-effort single mapping: makes us uid 0 in the namespace (mapped to the host user).
            // Note: some runtimes (like runc) may fail later if they attempt to chown to the real host uid.
            try uid_mappings.append(allocator, IDMapping{
                .containerID = 0,
                .hostID = euid,
                .size = 1,
            });
        }

        if (subgid_ranges_len > 0) {
            const r = subgid_ranges[0];
            var triples = try computeUsernsIdMap(allocator, @intCast(egid), @intCast(r.start), @intCast(r.count));
            defer triples.deinit(allocator);
            for (triples.items) |t| {
                try gid_mappings.append(allocator, IDMapping{
                    .containerID = t.container_id,
                    .hostID = t.host_id,
                    .size = t.size,
                });
            }
        } else {
            try gid_mappings.append(allocator, IDMapping{
                .containerID = 0,
                .hostID = egid,
                .size = 1,
            });
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
    // Rootless user namespaces commonly do not map host uid/gid 0. If we expose the squashfs
    // ownership as 0:0, those inodes become unmapped (often 65534) inside the namespace and
    // paths like /etc become effectively non-writable.
    // Force ownership to the invoking user so container prep (and runtimes like runc) can
    // create/overwrite files in the merged rootfs (e.g. /etc/resolv.conf).
    const squashfuse_opts = try allocPrintZ(allocator, "offset={},uid={},gid={}", .{ footer.offset, host_euid, host_egid });
    defer allocator.free(squashfuse_opts);

    const args_buf = [_:null]?[*:0]const u8{ "squashfuse", "-o", squashfuse_opts, executable_path, filesystem_bundle_dir_null };

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

    const container_pid = container: {
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

        const runtime_bin_path = try allocPrintZ(allocator, "{s}/runtime", .{mount_dir_path});
        defer allocator.free(runtime_bin_path);

        // Check if runtime binary exists in the mount
        std.fs.accessAbsolute(runtime_bin_path, .{}) catch {
            std.debug.panic("runtime binary not found at {s}", .{runtime_bin_path});
        };

        const pid_runtime = try std.posix.fork();
        assert(pid_runtime >= 0);
        if (pid_runtime == 0) {
            // Child process: execute runtime
            const temp_dir_slice = std.mem.sliceTo(&temp_dir_path, 0);
            const container_id_z = try allocPrintZ(allocator, "{s}", .{temp_dir_path[13..]});
            defer allocator.free(container_id_z);

            const state_dir_z = try allocPrintZ(allocator, "{s}/runtime-state", .{temp_dir_path});
            defer allocator.free(state_dir_z);
            try ensureDirAbsolute(state_dir_z);

            // If the runtime supports it (runc does), force a writable state dir
            // so we never attempt to create /run/runc as an unprivileged user.
            const supports_root_flag = runtimeSupportsRootFlag(allocator, runtime_bin_path, mount_dir_path);
            const supports_rootless_flag = runtimeSupportsRootlessFlag(allocator, runtime_bin_path, mount_dir_path);
            const supports_cgroup_manager_flag = runtimeSupportsCgroupManagerFlag(allocator, runtime_bin_path, mount_dir_path);

            var argv_list = try buildRuntimeRunArgv(
                allocator,
                runtime_bin_path,
                container_id_z,
                state_dir_z,
                supports_root_flag,
                supports_rootless_flag,
                started_unprivileged,
                supports_cgroup_manager_flag,
                started_unprivileged,
            );
            defer argv_list.deinit(allocator);

            if (std.posix.getenv("DOCKERC_DEBUG_RUNTIME") != null) {
                std.debug.print("runtime supports --root: {}\n", .{supports_root_flag});
                std.debug.print("runtime supports --rootless: {}\n", .{supports_rootless_flag});
                std.debug.print("runtime supports --cgroup-manager: {}\n", .{supports_cgroup_manager_flag});
                std.debug.print("runtime argv:", .{});
                for (argv_list.items) |a| {
                    std.debug.print(" {s}", .{a});
                }
                std.debug.print("\n", .{});

                debugDumpBeforeExec(allocator, temp_dir_slice);
            }

            // Convert argv_list to NUL-terminated strings for execveZ.
            var argv_z = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, argv_list.items.len + 1);
            defer argv_z.deinit(allocator);
            var argv_storage = try std.ArrayList([:0]u8).initCapacity(allocator, argv_list.items.len);
            defer {
                for (argv_storage.items) |s| allocator.free(s);
                argv_storage.deinit(allocator);
            }

            for (argv_list.items) |arg| {
                const z = try allocator.dupeZ(u8, arg);
                try argv_storage.append(allocator, z);
                try argv_z.append(allocator, z.ptr);
            }
            try argv_z.append(allocator, null);

            const argv_sentinel: [:null]?[*:0]const u8 = argv_z.items[0 .. argv_z.items.len - 1 :null];

            // Minimal environment for the runtime, but keep user-session variables
            // that some runtimes (notably youki) may need for systemd/dbus integration.
            var envp_z = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, 4);
            defer envp_z.deinit(allocator);
            try envp_z.append(allocator, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
            if (getEnvFull("DBUS_SESSION_BUS_ADDRESS")) |v| {
                try envp_z.append(allocator, v.ptr);
            }
            if (getEnvFull("XDG_RUNTIME_DIR")) |v| {
                try envp_z.append(allocator, v.ptr);
            }
            try envp_z.append(allocator, null);

            const envp_sentinel: [:null]?[*:0]const u8 = envp_z.items[0 .. envp_z.items.len - 1 :null];

            // Change CWD to bundle root (mount_dir_path)
            std.posix.chdir(mount_dir_path) catch @panic("failed to chdir to bundle");

            // If not attached to a TTY, disable terminal allocation in config.json.
            // This avoids runtime failures like tcgetattr when stdin is redirected.
            maybeDisableTerminalInBundle(allocator, mount_dir_path);

            std.debug.print("Executing runtime: {s}\n", .{runtime_bin_path});
            const err_exec = std.posix.execveZ(runtime_bin_path, argv_sentinel.ptr, envp_sentinel.ptr);
            std.debug.panic("failed to execve: {}\n", .{err_exec});
        }

        break :container pid_runtime;
    };

    // Parent process (runtime host) waits for runtime child
    const retStatus = std.posix.waitpid(container_pid, 0);
    if (!std.posix.W.IFEXITED(retStatus.status)) {
        std.debug.print("container didn't exist normally : {}\n", .{retStatus.status});
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
