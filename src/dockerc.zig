const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap");
const common = @import("common.zig");
const dockerc_config = @import("dockerc_config.zig");
const build_info = @import("build_info");

const mkdtemp = common.mkdtemp;
const extract_file = common.extract_file;

const debug = std.debug;

const io = std.io;
const StderrWriter = std.io.GenericWriter(std.fs.File, std.fs.File.WriteError, std.fs.File.write);

const skopeo_content = @embedFile("skopeo");
const umoci_content = @embedFile("umoci");

const policy_content = @embedFile("tools/policy.json");

const runtime_resolver = @import("runtime_resolver.zig");

fn get_runtime_content_len_u64(runtime_content: []const u8) [8]u8 {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, runtime_content.len, .big);
    return buf;
}

const runtime_content_x86_64 = @embedFile("runtime_x86_64");
const runtime_content_aarch64 = @embedFile("runtime_aarch64");
const runtime_exec_content_x86_64 = @embedFile("runtime_exec_x86_64");
const runtime_exec_content_aarch64 = @embedFile("runtime_exec_aarch64");

const runtime_content_len_u64_x86_64 = get_runtime_content_len_u64(runtime_content_x86_64);
const runtime_content_len_u64_aarch64 = get_runtime_content_len_u64(runtime_content_aarch64);

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const list = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(list);
    return try allocator.dupeZ(u8, list);
}

extern fn mksquashfs_main(argc: c_int, argv: [*:null]const ?[*:0]const u8) void;

const Config = dockerc_config.Config;

fn copyFileAbsolute(src_abs: []const u8, dst_abs: []const u8) !void {
    var src = try std.fs.openFileAbsolute(src_abs, .{ .mode = .read_only });
    defer src.close();

    var dst = try std.fs.createFileAbsolute(dst_abs, .{ .truncate = true });
    defer dst.close();

    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dst.writeAll(buf[0..n]);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var temp_dir_path = "/tmp/dockerc-XXXXXX".*;
    try mkdtemp(&temp_dir_path);

    const allocator = gpa.allocator();
    const skopeo_path = try extract_file(&temp_dir_path, "skopeo", skopeo_content, allocator);
    defer allocator.free(skopeo_path);

    const umoci_path = try extract_file(&temp_dir_path, "umoci", umoci_content, allocator);
    defer allocator.free(umoci_path);

    const policy_path = try extract_file(&temp_dir_path, "policy.json", policy_content, allocator);
    defer allocator.free(policy_path);

    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display this help and exit.
        \\--version                Display dockerc version.
        \\-c, --config <str>       Path to config file.
        \\-i, --image <str>        Image to pull.
        \\-o, --output <str>       Output file.
        \\--arch <str>             Architecture (amd64, arm64).
        \\--rootfull               Do not use rootless container.
        \\--runtime <str>          Runtime to use (e.g. crun, runc, youki, custom). Supports name@{local|latest|<semver>}.
        \\--runtime-path <str>     Path to runtime binary (overrides runtime auto-resolution).
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit
        // diag.report(StderrWriter{ .context = std.fs.File.stderr() }, err) catch {};
        std.debug.print("Error parsing arguments: {s}\n", .{@errorName(err)});
        return err;
    };
    defer res.deinit();

    if (res.args.version != 0) {
        std.debug.print("dockerc version: {s}\n", .{build_info.dockerc_version});
        return;
    }

    if (res.args.help != 0) {
        // try clap.help(StderrWriter{ .context = std.fs.File.stderr() }, clap.Help, &params, .{});
        std.debug.print("Usage: dockerc [options]\n", .{});
        return;
    }

    var config = Config{};
    defer config.deinit(allocator);
    if (res.args.config) |config_path| {
        config = dockerc_config.loadFromFile(allocator, config_path) catch |err| {
            std.debug.print("Failed to load config file: {s}\n", .{@errorName(err)});
            return err;
        };
    }

    // Overlay CLI args
    if (res.args.image) |i| config.image = i;
    if (res.args.output) |o| config.output = o;
    if (res.args.arch) |a| config.arch = a;
    if (res.args.rootfull != 0) config.rootfull = true;
    if (res.args.runtime) |r| config.runtime = r;
    if (res.args.@"runtime-path") |rp| config.runtime_path = rp;

    var missing_args = false;
    if (config.image == null) {
        debug.print("no --image specified\n", .{});
        missing_args = true;
    }

    if (config.output == null) {
        debug.print("no --output specified\n", .{});
        missing_args = true;
    }

    if (missing_args) {
        debug.print("--help for usage\n", .{});
        return;
    }

    // safe to assert because checked above
    const image = config.image.?;
    const output_path = try allocator.dupeZ(u8, config.output.?);
    defer allocator.free(output_path);

    const destination_arg = try std.fmt.allocPrint(allocator, "oci:{s}/image:latest", .{temp_dir_path});
    defer allocator.free(destination_arg);

    var skopeo_args = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer skopeo_args.deinit(allocator);

    try skopeo_args.appendSlice(allocator, &[_][]const u8{
        skopeo_path,
        "copy",
        "--policy",
        policy_path,
    });

    var runtime_content: []const u8 = undefined;
    var use_exec_runtime = false;
    var resolved_runtime_path: ?[]u8 = null;
    defer if (resolved_runtime_path) |p| allocator.free(p);

    // Determine runtime and arch
    const arch = config.arch orelse switch (builtin.target.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => "unknown",
    };

    if (config.arch != null) {
        try skopeo_args.append(allocator, "--override-arch");
        try skopeo_args.append(allocator, arch);
    }

    const runtime_spec = runtime_resolver.parseRuntimeSpec(config.runtime) catch |err| {
        std.debug.print("error: invalid runtime '{s}': {s}\n", .{ config.runtime, @errorName(err) });
        return err;
    };

    // Backward compatibility: plain "crun" means the embedded runtime.
    const use_embedded_crun = std.mem.eql(u8, runtime_spec.name, "crun") and runtime_spec.source == .auto;

    if (use_embedded_crun) {
        // Use embedded libcrun headers
        if (std.mem.eql(u8, arch, "amd64")) {
            runtime_content = runtime_content_x86_64;
        } else if (std.mem.eql(u8, arch, "arm64")) {
            runtime_content = runtime_content_aarch64;
        } else {
            std.debug.panic("unsupported arch for crun: {s}\n", .{arch});
        }
    } else {
        // Using Generic Exec Runtime
        use_exec_runtime = true;
        if (std.mem.eql(u8, arch, "amd64")) {
            runtime_content = runtime_exec_content_x86_64;
        } else if (std.mem.eql(u8, arch, "arm64")) {
            runtime_content = runtime_exec_content_aarch64;
        } else {
            std.debug.panic("unsupported arch for exec runtime: {s}\n", .{arch});
        }

        if (config.runtime_path == null) {
            resolved_runtime_path = runtime_resolver.resolveRuntimePath(allocator, runtime_spec, arch) catch |err| {
                std.debug.print(
                    "error: runtime '{s}' selected but no runtime_path provided; failed to locate/download it: {s}\n",
                    .{ config.runtime, @errorName(err) },
                );
                return err;
            };
            config.runtime_path = resolved_runtime_path.?;
        }
    }

    try skopeo_args.append(allocator, image);
    try skopeo_args.append(allocator, destination_arg);

    var skopeoProcess = std.process.Child.init(skopeo_args.items, gpa.allocator());
    _ = try skopeoProcess.spawnAndWait();

    const umoci_image_layout_path = try std.fmt.allocPrint(allocator, "{s}/image:latest", .{temp_dir_path});
    defer allocator.free(umoci_image_layout_path);

    const bundle_destination = try allocPrintZ(allocator, "{s}/bundle", .{temp_dir_path});
    defer allocator.free(bundle_destination);

    const umoci_args = [_][]const u8{
        umoci_path,
        "unpack",
        "--image",
        umoci_image_layout_path,
        bundle_destination,
        "--rootless",
    };
    var umociProcess = std.process.Child.init(if (!config.rootfull) &umoci_args else umoci_args[0 .. umoci_args.len - 1], gpa.allocator());
    _ = try umociProcess.spawnAndWait();

    // Copy custom runtime if needed
    if (use_exec_runtime) {
        const runtime_src = config.runtime_path.?;
        const runtime_dst = try std.fmt.allocPrint(allocator, "{s}/runtime", .{bundle_destination});
        defer allocator.free(runtime_dst);

        try copyFileAbsolute(runtime_src, runtime_dst);
        if (std.fs.openFileAbsolute(runtime_dst, .{})) |dst_file| {
            defer dst_file.close();
            dst_file.chmod(0o755) catch {};
        } else |_| {}
    }

    const offset_arg = try allocPrintZ(allocator, "{}", .{runtime_content.len});
    defer allocator.free(offset_arg);

    var mksquashfs_args = [_:null]?[*:0]const u8{
        "mksquashfs",
        bundle_destination,
        output_path,
        "-comp",
        "zstd",
        "-offset",
        offset_arg,
        "-noappend",
        "-force-uid",
        "0",
        "-force-gid",
        "0",
    };

    mksquashfs_main(
        // in rootfull, do not force uid/gid to 0,0
        if (config.rootfull)
            mksquashfs_args.len - 4
        else
            mksquashfs_args.len,
        &mksquashfs_args,
    );

    const file = try std.fs.cwd().openFile(output_path, .{
        .mode = .write_only,
    });
    defer file.close();

    try file.writeAll(runtime_content);
    try file.seekFromEnd(0);

    try common.writeFooter(file, common.Footer{
        .offset = runtime_content.len,
        .require_mapped_uids = false,
    });

    try file.chmod(0o755);
}
