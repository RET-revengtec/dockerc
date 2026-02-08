const std = @import("std");

pub const ResolveError = error{
    RuntimeNotFound,
    InvalidRuntimeSpec,
    InvalidRuntimeVersion,
    UnsupportedTarget,
    HttpError,
    BadReleaseMetadata,
    NoMatchingAsset,
    DownloadTooLarge,
    DownloadFailed,
    ExtractionFailed,
    NotAnExecutable,
};

pub const RuntimeSource = enum {
    /// Backward-compatible behavior: try PATH first, then fall back to downloading latest.
    auto,
    /// Only use a locally available runtime (PATH or absolute path).
    local,
    /// Download the latest available runtime release (cacheable).
    latest,
    /// Download a specific runtime release (by semver).
    pinned,
};

pub const RuntimeSpec = struct {
    /// Runtime binary name (e.g. "runc", "crun", "youki", "custom").
    name: []const u8,
    /// Source selection.
    source: RuntimeSource,
    /// Only set for `.pinned`.
    version: ?[]const u8 = null,
};

pub fn parseRuntimeSpec(runtime_value: []const u8) ResolveError!RuntimeSpec {
    const v = std.mem.trim(u8, runtime_value, " \t\r\n");
    if (v.len == 0) return ResolveError.InvalidRuntimeSpec;

    const at_i = std.mem.indexOfScalar(u8, v, '@') orelse {
        return .{ .name = v, .source = .auto, .version = null };
    };

    if (at_i == 0) return ResolveError.InvalidRuntimeSpec;
    if (at_i + 1 >= v.len) return ResolveError.InvalidRuntimeSpec;

    const name = v[0..at_i];
    const version_part = v[at_i + 1 ..];
    if (name.len == 0 or version_part.len == 0) return ResolveError.InvalidRuntimeSpec;

    if (std.mem.eql(u8, version_part, "local")) {
        return .{ .name = name, .source = .local, .version = null };
    }
    if (std.mem.eql(u8, version_part, "latest")) {
        return .{ .name = name, .source = .latest, .version = null };
    }

    // Semver (optionally prefixed with 'v').
    const semver_str = if (version_part.len > 0 and version_part[0] == 'v') version_part[1..] else version_part;
    _ = std.SemanticVersion.parse(semver_str) catch return ResolveError.InvalidRuntimeVersion;
    return .{ .name = name, .source = .pinned, .version = version_part };
}

fn fileExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn findOnPath(allocator: std.mem.Allocator, exe_name: []const u8) ?[]u8 {
    if (exe_name.len == 0) return null;

    // If the caller already gave an absolute path, accept it.
    if (std.fs.path.isAbsolute(exe_name)) {
        if (!fileExistsAbsolute(exe_name)) return null;
        return allocator.dupe(u8, exe_name) catch null;
    }

    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return null;
    defer allocator.free(path_env);

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, exe_name }) catch continue;
        if (fileExistsAbsolute(candidate)) return candidate;
        allocator.free(candidate);
    }

    return null;
}

fn archAliases(arch: []const u8) []const []const u8 {
    // Map dockerc arch strings to the common names used in release assets.
    if (std.mem.eql(u8, arch, "amd64")) {
        return &[_][]const u8{ "amd64", "x86_64", "x64" };
    }
    if (std.mem.eql(u8, arch, "arm64")) {
        return &[_][]const u8{ "arm64", "aarch64" };
    }
    return &[_][]const u8{arch};
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, haystack, n) != null) return true;
    }
    return false;
}

fn isLikelyBinaryAsset(name: []const u8) bool {
    // Skip obviously-not-binaries.
    return !(std.mem.endsWith(u8, name, ".tar.gz") or
        std.mem.endsWith(u8, name, ".tgz") or
        std.mem.endsWith(u8, name, ".zip") or
        std.mem.endsWith(u8, name, ".sha256") or
        std.mem.endsWith(u8, name, ".sha256sum") or
        std.mem.endsWith(u8, name, ".sig") or
        std.mem.endsWith(u8, name, ".asc") or
        std.mem.endsWith(u8, name, ".txt"));
}

fn runtimeRepo(runtime: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, runtime, "runc")) return "opencontainers/runc";
    if (std.mem.eql(u8, runtime, "crun")) return "containers/crun";
    if (std.mem.eql(u8, runtime, "youki")) return "containers/youki";
    return null;
}

fn getCacheRoot(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |xdg| {
        return xdg;
    } else |_| {}

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return ResolveError.UnsupportedTarget;
    defer allocator.free(home);

    return try std.fmt.allocPrint(allocator, "{s}/.cache", .{home});
}

fn ensureDirAbsolute(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        try std.fs.cwd().makePath(path);
        return;
    }

    // POSIX-friendly implementation: open the filesystem root and make the rest
    // of the path as a subpath.
    if (path.len > 0 and path[0] == '/') {
        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();
        const sub = std.mem.trimLeft(u8, path, "/");
        if (sub.len == 0) return;
        try root.makePath(sub);
        return;
    }

    // Fallback: best-effort single directory.
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn httpGetAll(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    const headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = "dockerc" },
        .{ .name = "Accept", .value = "application/vnd.github+json" },
        // Keep the response JSON-readable without needing decompression.
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    var req = try client.request(.GET, uri, .{ .extra_headers = &headers });
    defer req.deinit();

    try req.sendBodiless();
    var redirect_buf: [8 * 1024]u8 = undefined;
    var res = try req.receiveHead(&redirect_buf);

    if (res.head.status.class() != .success) return ResolveError.HttpError;

    var transfer_buf: [16 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const r = res.readerDecompressing(transfer_buf[0..], &decompress, decompress_buf[0..]);
    return r.allocRemaining(allocator, std.Io.Limit.limited(max_bytes)) catch |err| switch (err) {
        error.OutOfMemory => err,
        error.StreamTooLong => return ResolveError.DownloadTooLarge,
        error.ReadFailed => return ResolveError.DownloadFailed,
    };
}

fn downloadToFile(allocator: std.mem.Allocator, url: []const u8, dest_abs: []const u8) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = "dockerc" },
        // Avoid transparent compression for binary downloads.
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    var current_url = try allocator.dupe(u8, url);
    defer allocator.free(current_url);

    var redirects_left: u8 = 5;
    while (true) {
        const uri = try std.Uri.parse(current_url);

        // Handle redirects ourselves so we work reliably with GitHub release asset URLs.
        var req = try client.request(.GET, uri, .{
            .extra_headers = &headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();

        try req.sendBodiless();
        var res = try req.receiveHead(&.{});

        if (res.head.status.class() == .redirect) {
            if (redirects_left == 0) return ResolveError.HttpError;
            redirects_left -= 1;

            const location = res.head.location orelse return ResolveError.HttpError;
            if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
                allocator.free(current_url);
                current_url = try allocator.dupe(u8, location);
                continue;
            }

            // We only expect absolute redirect URLs for GitHub release assets.
            return ResolveError.HttpError;
        }

        if (res.head.status.class() != .success) return ResolveError.HttpError;

        var file = try std.fs.createFileAbsolute(dest_abs, .{ .truncate = true });
        defer file.close();

        var transfer_buf: [16 * 1024]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
        const r = res.readerDecompressing(transfer_buf[0..], &decompress, decompress_buf[0..]);

        const body = r.allocRemaining(allocator, std.Io.Limit.limited(200 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.StreamTooLong => return ResolveError.DownloadTooLarge,
            error.ReadFailed => return ResolveError.DownloadFailed,
        };
        defer allocator.free(body);
        try file.writeAll(body);
        return;
    }
}

const GithubRelease = struct {
    tag_name: []const u8,
    assets: []GithubAsset,
};

const GithubAsset = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

fn pickAssetUrl(allocator: std.mem.Allocator, runtime: []const u8, arch: []const u8, release_json: []const u8) !struct { tag: []u8, asset_name: []u8, url: []u8 } {
    var parsed = std.json.parseFromSlice(GithubRelease, allocator, release_json, .{ .ignore_unknown_fields = true }) catch return ResolveError.BadReleaseMetadata;
    defer parsed.deinit();

    const tag = parsed.value.tag_name;
    if (tag.len == 0) return ResolveError.BadReleaseMetadata;

    const aliases = archAliases(arch);

    // Heuristics per runtime.
    var best: ?GithubAsset = null;
    var best_score: i32 = -1;
    for (parsed.value.assets) |asset| {
        if (asset.name.len == 0 or asset.browser_download_url.len == 0) continue;

        if (std.mem.eql(u8, runtime, "runc")) {
            // Prefer exact match assets like runc.amd64 / runc.arm64.
            const want = if (std.mem.eql(u8, arch, "amd64")) "runc.amd64" else if (std.mem.eql(u8, arch, "arm64")) "runc.arm64" else "";
            if (want.len != 0 and std.mem.eql(u8, asset.name, want)) {
                best = asset;
                break;
            }
            continue;
        }

        if (std.mem.eql(u8, runtime, "crun")) {
            // crun releases sometimes have source-only assets; prefer a likely binary.
            if (!containsAny(asset.name, aliases)) continue;
            if (std.mem.indexOf(u8, asset.name, "linux") == null) continue;
            if (!isLikelyBinaryAsset(asset.name)) continue;
            if (std.mem.indexOf(u8, asset.name, "crun") == null) continue;
            best = asset;
            break;
        }

        if (std.mem.eql(u8, runtime, "youki")) {
            if (!containsAny(asset.name, aliases)) continue;
            if (std.mem.indexOf(u8, asset.name, "youki") == null) continue;
            // youki release assets are commonly named like:
            //   youki-<ver>-x86_64-musl.tar.gz
            // (no "linux" substring), so match on arch + "youki".
            // Prefer musl tarballs for portability.
            var score: i32 = 0;
            if (std.mem.endsWith(u8, asset.name, ".tar.gz") or std.mem.endsWith(u8, asset.name, ".tgz")) {
                score += 10;
            } else if (isLikelyBinaryAsset(asset.name)) {
                score += 5;
            } else {
                continue;
            }

            if (std.mem.indexOf(u8, asset.name, "musl") != null) score += 3;
            if (std.mem.indexOf(u8, asset.name, "gnu") != null) score += 1;

            if (score > best_score) {
                best = asset;
                best_score = score;
            }
        }
    }

    const chosen = best orelse return ResolveError.NoMatchingAsset;

    return .{
        .tag = try allocator.dupe(u8, tag),
        .asset_name = try allocator.dupe(u8, chosen.name),
        .url = try allocator.dupe(u8, chosen.browser_download_url),
    };
}

fn extractYoukiTarGzTo(allocator: std.mem.Allocator, archive_abs: []const u8, dest_abs: []const u8) !void {
    // Use system tar if available. This avoids depending on std.tar API details.
    // Extracts and writes the `youki` binary to dest_abs.
    // Works with typical release archives that contain a top-level `youki` file.

    const tar_path = findOnPath(allocator, "tar") orelse return ResolveError.ExtractionFailed;
    defer allocator.free(tar_path);

    // We extract into a temporary directory next to dest.
    const dest_dir = std.fs.path.dirname(dest_abs) orelse return ResolveError.ExtractionFailed;
    const tmp_dir_abs = try std.fmt.allocPrint(allocator, "{s}/.tmp-youki-extract", .{dest_dir});
    defer allocator.free(tmp_dir_abs);

    std.fs.deleteTreeAbsolute(tmp_dir_abs) catch {};
    try ensureDirAbsolute(tmp_dir_abs);

    var child = std.process.Child.init(&[_][]const u8{
        tar_path,
        "-xzf",
        archive_abs,
        "-C",
        tmp_dir_abs,
    }, allocator);
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return ResolveError.ExtractionFailed,
        else => return ResolveError.ExtractionFailed,
    }

    // Find `youki` within the extracted tree.
    var found_path: ?[]u8 = null;
    defer if (found_path) |p| allocator.free(p);

    var walk_dir = try std.fs.openDirAbsolute(tmp_dir_abs, .{ .iterate = true });
    defer walk_dir.close();

    var walker = try walk_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const base = std.fs.path.basename(entry.path);
        if (!std.mem.eql(u8, base, "youki")) continue;

        found_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir_abs, entry.path });
        break;
    }

    const src_abs = found_path orelse return ResolveError.ExtractionFailed;

    // Copy into final destination.
    std.fs.deleteFileAbsolute(dest_abs) catch {};
    // Copy into final destination.
    var src = try std.fs.openFileAbsolute(src_abs, .{ .mode = .read_only });
    defer src.close();
    var dst = try std.fs.createFileAbsolute(dest_abs, .{ .truncate = true });
    defer dst.close();
    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dst.writeAll(buf[0..n]);
    }
}

fn downloadRuntimeReleaseToCache(allocator: std.mem.Allocator, runtime: []const u8, arch: []const u8, api_url: []const u8) ![]u8 {
    const json_body = try httpGetAll(allocator, api_url, 2 * 1024 * 1024);
    defer allocator.free(json_body);

    const picked = try pickAssetUrl(allocator, runtime, arch, json_body);
    defer allocator.free(picked.tag);
    defer allocator.free(picked.asset_name);
    defer allocator.free(picked.url);

    const cache_root = try getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const runtime_dir_abs = try std.fmt.allocPrint(allocator, "{s}/dockerc/runtimes/{s}/{s}", .{ cache_root, runtime, picked.tag });
    defer allocator.free(runtime_dir_abs);

    try ensureDirAbsolute(runtime_dir_abs);

    const is_archive = std.mem.endsWith(u8, picked.asset_name, ".tar.gz") or std.mem.endsWith(u8, picked.asset_name, ".tgz");
    const out_name = if (is_archive) runtime else picked.asset_name;

    const out_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ runtime_dir_abs, out_name });
    errdefer allocator.free(out_abs);

    // If a previous run left an empty file behind, treat it as not downloaded.
    if (fileExistsAbsolute(out_abs)) {
        var delete_empty = false;
        if (std.fs.openFileAbsolute(out_abs, .{})) |f_existing| {
            defer f_existing.close();
            const st_existing = f_existing.stat() catch null;
            if (st_existing) |st| {
                if (st.size == 0) delete_empty = true;
            } else {
                delete_empty = true;
            }
        } else |_| {
            delete_empty = true;
        }

        if (delete_empty) {
            std.fs.deleteFileAbsolute(out_abs) catch {};
        }
    }

    // If already downloaded, reuse.
    if (!fileExistsAbsolute(out_abs)) {
        if (is_archive) {
            const archive_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ runtime_dir_abs, picked.asset_name });
            defer allocator.free(archive_abs);

            try downloadToFile(allocator, picked.url, archive_abs);

            if (std.mem.eql(u8, runtime, "youki")) {
                try extractYoukiTarGzTo(allocator, archive_abs, out_abs);
            } else {
                return ResolveError.NoMatchingAsset;
            }
        } else {
            try downloadToFile(allocator, picked.url, out_abs);
        }

        // chmod +x
        if (std.fs.openFileAbsolute(out_abs, .{ .mode = .read_only })) |fchmod| {
            defer fchmod.close();
            fchmod.chmod(@as(std.fs.File.Mode, 0o755)) catch {};
        } else |_| {}
    }

    // Ensure it is executable-ish.
    var f = std.fs.openFileAbsolute(out_abs, .{}) catch return ResolveError.NotAnExecutable;
    defer f.close();
    const st = f.stat() catch return ResolveError.NotAnExecutable;
    if (st.size == 0) return ResolveError.NotAnExecutable;

    return out_abs;
}

fn downloadLatestRuntimeToCache(allocator: std.mem.Allocator, runtime: []const u8, arch: []const u8) ![]u8 {
    const repo = runtimeRepo(runtime) orelse return ResolveError.RuntimeNotFound;

    const api_url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases/latest", .{repo});
    defer allocator.free(api_url);

    return downloadRuntimeReleaseToCache(allocator, runtime, arch, api_url);
}

fn downloadTaggedRuntimeToCache(allocator: std.mem.Allocator, runtime: []const u8, arch: []const u8, version: []const u8) ![]u8 {
    const repo = runtimeRepo(runtime) orelse return ResolveError.RuntimeNotFound;

    const try_tag = struct {
        fn go(alloc: std.mem.Allocator, rt: []const u8, a: []const u8, r: []const u8, tag: []const u8) ![]u8 {
            const api_url = try std.fmt.allocPrint(alloc, "https://api.github.com/repos/{s}/releases/tags/{s}", .{ r, tag });
            defer alloc.free(api_url);
            return downloadRuntimeReleaseToCache(alloc, rt, a, api_url);
        }
    }.go;

    // Prefer common GitHub tag form with leading 'v', but allow tags without it.
    if (version.len > 0 and version[0] == 'v') {
        return try_tag(allocator, runtime, arch, repo, version);
    }

    const v_tag = try std.fmt.allocPrint(allocator, "v{s}", .{version});
    defer allocator.free(v_tag);

    return try_tag(allocator, runtime, arch, repo, v_tag) catch |err| switch (err) {
        ResolveError.HttpError => try_tag(allocator, runtime, arch, repo, version),
        else => err,
    };
}

pub fn resolveRuntimePath(allocator: std.mem.Allocator, spec: RuntimeSpec, arch: []const u8) ![]u8 {
    switch (spec.source) {
        .local => {
            return findOnPath(allocator, spec.name) orelse ResolveError.RuntimeNotFound;
        },
        .latest => {
            return downloadLatestRuntimeToCache(allocator, spec.name, arch);
        },
        .pinned => {
            const v = spec.version orelse return ResolveError.InvalidRuntimeSpec;
            return downloadTaggedRuntimeToCache(allocator, spec.name, arch, v);
        },
        .auto => {
            // Portability-first: do not consult host PATH implicitly.
            // If the runtime is known, download its latest release to cache.
            // For custom/unknown runtimes, require --runtime-path or @local explicitly.
            return downloadLatestRuntimeToCache(allocator, spec.name, arch);
        },
    }
}
