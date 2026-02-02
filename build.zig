const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    b.reference_trace = 64;

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const zstd_dep = b.dependency("zstd", .{});
    const libfuse_dep = b.dependency("libfuse", .{});
    const fuse_overlayfs_dep = b.dependency("fuse_overlayfs", .{});
    const squashfuse_dep = b.dependency("squashfuse", .{});
    const crun_dep = b.dependency("crun", .{});
    const argp_dep = b.dependency("argp_standalone", .{});
    const umoci_dep = b.dependency("umoci", .{});
    const skopeo_dep = b.dependency("skopeo", .{});
    const squashfs_tools_dep = b.dependency("squashfs_tools", .{});
    const libocispec_dep = b.dependency("libocispec", .{});
    const yajl_dep = b.dependency("yajl", .{});
    const runtime_spec_dep = b.dependency("runtime_spec", .{});
    const image_spec_dep = b.dependency("image_spec", .{});

    const skip_crun_build = b.option(bool, "skip_crun_build", "Skip crun build") orelse false;
    const dockerc_version = b.option([]const u8, "dockerc_version", "Set dockerc version") orelse "HEAD";

    const build_info = b.addOptions();
    build_info.addOption([]const u8, "dockerc_version", dockerc_version);

    const zstd = b.createModule(.{});
    zstd.addAssemblyFile(zstd_dep.path("lib/decompress/huf_decompress_amd64.S"));
    zstd.addCSourceFiles(.{
        .root = zstd_dep.path("lib"),
        .files = &[_][]const u8{
            "common/debug.c",
            "common/entropy_common.c",
            "common/error_private.c",
            "common/fse_decompress.c",
            "common/pool.c",
            "common/threading.c",
            "common/xxhash.c",
            "common/zstd_common.c",

            "compress/fse_compress.c",
            "compress/hist.c",
            "compress/huf_compress.c",
            "compress/zstd_compress.c",
            "compress/zstd_compress_literals.c",
            "compress/zstd_compress_sequences.c",
            "compress/zstd_compress_superblock.c",
            "compress/zstd_double_fast.c",
            "compress/zstd_fast.c",
            "compress/zstd_lazy.c",
            "compress/zstd_ldm.c",
            "compress/zstdmt_compress.c",
            "compress/zstd_opt.c",
            "compress/zstd_preSplit.c",

            "decompress/huf_decompress.c",
            "decompress/zstd_ddict.c",
            "decompress/zstd_decompress_block.c",
            "decompress/zstd_decompress.c",
        },
    });

    const libfuse_config = b.addWriteFiles();
    const libfuse_config_h =
        \\#ifndef LIBFUSE_CONFIG_H
        \\#define LIBFUSE_CONFIG_H
        \\
        \\#define HAVE_COPY_FILE_RANGE 1
        \\#define HAVE_FALLOCATE 1
        \\#define HAVE_FDATASYNC 1
        \\#define HAVE_FORK 1
        \\#define HAVE_FSTATAT 1
        \\#define HAVE_ICONV 1
        \\#define HAVE_MEMORY_H 1
        \\#define HAVE_OPENAT 1
        \\#define HAVE_PIPE2 1
        \\#define HAVE_POSIX_FALLOCATE 1
        \\#define HAVE_READLINKAT 1
        \\#define HAVE_SETXATTR 1
        \\#define HAVE_SPLICE 1
        \\#define HAVE_STDINT_H 1
        \\#define HAVE_STDLIB_H 1
        \\#define HAVE_STRINGS_H 1
        \\#define HAVE_STRING_H 1
        \\#define HAVE_STRUCT_STAT_ST_ATIM 1
        \\#define HAVE_SYS_STAT_H 1
        \\#define HAVE_SYS_TYPES_H 1
        \\#define HAVE_UNISTD_H 1
        \\#define HAVE_UTIMENSAT 1
        \\#define HAVE_VMSPLICE 1
        \\
        \\#ifndef PACKAGE_VERSION
        \\#define PACKAGE_VERSION "3.10.5"
        \\#endif
        \\
        \\#define FUSE_MAJOR_VERSION 3
        \\#define FUSE_MINOR_VERSION 10
        \\#define FUSE_HOTFIX_VERSION 5
        \\#endif
    ;
    _ = libfuse_config.add("libfuse_config.h", libfuse_config_h);
    _ = libfuse_config.add("fuse_config.h", "#include \"libfuse_config.h\"\n");

    const mk_deps_initial = b.addSystemCommand(&[_][]const u8{ "mkdir", "-p", "deps" });

    // --- Squashfuse ---
    const build_sf_dir = "deps/squashfuse";
    const clean_sf = b.addSystemCommand(&[_][]const u8{ "rm", "-rf", build_sf_dir });
    const cp_sf = b.addSystemCommand(&[_][]const u8{ "cp", "-rT" });
    cp_sf.addFileArg(squashfuse_dep.path(""));
    cp_sf.addArg(build_sf_dir);
    cp_sf.step.dependOn(&clean_sf.step);
    cp_sf.step.dependOn(&mk_deps_initial.step);

    const sf_autogen = b.addSystemCommand(&[_][]const u8{ "autoreconf", "-vfi" });
    sf_autogen.setCwd(b.path(build_sf_dir));
    sf_autogen.step.dependOn(&cp_sf.step);

    const sf_configure = b.addSystemCommand(&[_][]const u8{
        "./configure",
        "--without-zlib",
        "--without-xz",
        "--without-lzo",
        "--without-lz4",
        "--with-zstd",
    });
    sf_configure.setCwd(b.path(build_sf_dir));
    sf_configure.step.dependOn(&sf_autogen.step);

    const sf_make_swap = b.addSystemCommand(&[_][]const u8{
        "make",
        "swap.h.inc",
        "swap.c.inc",
    });
    sf_make_swap.setCwd(b.path(build_sf_dir));
    sf_make_swap.step.dependOn(&sf_configure.step);

    // --- Fuse Overlayfs ---
    const build_fov_dir = "deps/fuse-overlayfs";
    const clean_fov = b.addSystemCommand(&[_][]const u8{ "rm", "-rf", build_fov_dir });
    const cp_fov = b.addSystemCommand(&[_][]const u8{ "cp", "-rT" });
    cp_fov.addFileArg(fuse_overlayfs_dep.path(""));
    cp_fov.addArg(build_fov_dir);
    cp_fov.step.dependOn(&clean_fov.step);
    cp_fov.step.dependOn(&mk_deps_initial.step);

    const fov_autogen = b.addSystemCommand(&[_][]const u8{ "autoreconf", "-vfi" });
    fov_autogen.setCwd(b.path(build_fov_dir));
    fov_autogen.step.dependOn(&cp_fov.step);

    const fov_configure = b.addSystemCommand(&[_][]const u8{"./configure"});
    fov_configure.setCwd(b.path(build_fov_dir));
    fov_configure.step.dependOn(&fov_autogen.step);

    const fuse_fss = b.createModule(.{});
    fuse_fss.addIncludePath(zstd_dep.path("lib"));

    fuse_fss.addIncludePath(libfuse_dep.path("include"));
    fuse_fss.addIncludePath(libfuse_config.getDirectory());

    fuse_fss.addCSourceFiles(.{
        .root = libfuse_dep.path("lib"),
        .files = &[_][]const u8{
            "fuse_opt.c",
            "helper.c",
            "fuse_log.c",
            "fuse_lowlevel.c",
            "mount_util.c",
            "fuse.c",
            "fuse_signals.c",
            "fuse_loop_mt.c",
            "buffer.c",
            "mount.c",
            "fuse_loop.c",
            "modules/subdir.c",
            "modules/iconv.c",
            "cuse_lowlevel.c",
            "util.c",
        },
        .flags = &[_][]const u8{
            // TODO: figure out where to get this value from
            "-DFUSE_USE_VERSION=317",
            // TODO: make sure this is correct value as well, or maybe we're supposed to dynamically link
            "-DFUSERMOUNT_DIR=\"/usr/local/bin\"",
        },
    });

    fuse_fss.addIncludePath(b.path(build_fov_dir));
    fuse_fss.addIncludePath(b.path(build_fov_dir ++ "/lib"));
    fuse_fss.addCSourceFiles(.{
        .root = b.path(build_fov_dir),
        .files = &[_][]const u8{
            "main.c",
            "lib/hash.c",
            "lib/bitrotate.c",
            "utils.c",
            "plugin-manager.c",
            "direct.c",
        },
        .flags = &[_][]const u8{
            "-Dmain=overlayfs_main",
            // collision with libcrun
            "-Dsafe_openat=overlayfs_safe_openat",
            "-DPKGLIBEXECDIR=\"\"",
            "-Wno-format",
            "-Wno-switch",
            "-DFUSE_USE_VERSION=317",
        },
    });
    fuse_fss.addCSourceFiles(.{
        .root = b.path(build_sf_dir),
        .files = &[_][]const u8{
            "ll_main.c",
            "ll.c",
            "ll_inode.c",
            "fs.c",
            "fuseprivate.c",
            "stat.c",
            "dir.c",
            "file.c",
            "xattr.c",
            "nonstd-enoattr.c",
            "nonstd-makedev.c",
            "util.c",
            "nonstd-daemon.c",
            "nonstd-pread.c",
            "swap.c",
            "table.c",
            "cache_mt.c",
            "decompress.c",
            "nonstd-stat.c",
        },
        .flags = &[_][]const u8{
            "-Dmain=squashfuse_main",
            "-D_FILE_OFFSET_BITS=64",
            "-DFUSE_USE_VERSION=317",
        },
    });

    const clap = b.dependency("clap", .{
        .optimize = optimize,
        .target = target,
    });

    var triple = target.result.zigTriple(b.allocator) catch @panic("OOM");
    if (std.mem.indexOf(u8, triple, "...") != null) {
        triple = std.fmt.allocPrint(b.allocator, "{s}-{s}-{s}", .{
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
            @tagName(target.result.abi),
        }) catch @panic("OOM");
    }

    const cc = std.fmt.allocPrint(
        b.allocator,
        "{s} cc --target={s}",
        .{
            b.graph.zig_exe,
            triple,
        },
    ) catch @panic("OOM");

    const build_crun_dir = "deps/crun";
    const clean_crun = b.addSystemCommand(&[_][]const u8{ "rm", "-rf", build_crun_dir });

    const cp_crun = b.addSystemCommand(&[_][]const u8{ "cp", "-rT" });
    cp_crun.addFileArg(crun_dep.path(""));
    cp_crun.addArg(build_crun_dir);
    cp_crun.step.dependOn(&mk_deps_initial.step);
    cp_crun.step.dependOn(&clean_crun.step);

    const cp_libocispec = b.addSystemCommand(&[_][]const u8{ "cp", "-rT" });
    cp_libocispec.addFileArg(libocispec_dep.path(""));
    cp_libocispec.addArg(build_crun_dir ++ "/libocispec");
    cp_libocispec.step.dependOn(&cp_crun.step);

    const cp_yajl = b.addSystemCommand(&[_][]const u8{ "cp", "-rT" });
    cp_yajl.addFileArg(yajl_dep.path(""));
    cp_yajl.addArg(build_crun_dir ++ "/libocispec/yajl");
    cp_yajl.step.dependOn(&cp_libocispec.step);

    const cp_runtime_spec = b.addSystemCommand(&[_][]const u8{ "cp", "-rT" });
    cp_runtime_spec.addFileArg(runtime_spec_dep.path(""));
    cp_runtime_spec.addArg(build_crun_dir ++ "/libocispec/runtime-spec");
    cp_runtime_spec.step.dependOn(&cp_libocispec.step);

    const cp_image_spec = b.addSystemCommand(&[_][]const u8{ "cp", "-rT" });
    cp_image_spec.addFileArg(image_spec_dep.path(""));
    cp_image_spec.addArg(build_crun_dir ++ "/libocispec/image-spec");
    cp_image_spec.step.dependOn(&cp_libocispec.step);

    const gen_git_version_crun = b.addSystemCommand(&[_][]const u8{ "sh", "-c", "echo '#define GIT_VERSION \"0.17\"' > git-version.h" });
    gen_git_version_crun.setCwd(b.path(build_crun_dir));
    gen_git_version_crun.step.dependOn(&cp_crun.step);

    const crun_src_root = b.path(build_crun_dir);
    const libocispec_src_root = b.path(build_crun_dir ++ "/libocispec");

    const prepare_crun_step = &gen_git_version_crun.step;
    prepare_crun_step.dependOn(&cp_yajl.step);
    prepare_crun_step.dependOn(&cp_runtime_spec.step);
    prepare_crun_step.dependOn(&cp_image_spec.step);

    // --- Prepare shadow build directory ---
    const build_shadow_dir = "deps/shadow";
    const shadow_dep = b.dependency("shadow", .{});

    const clean_build_shadow = b.addSystemCommand(&[_][]const u8{
        "rm", "-rf", build_shadow_dir,
    });

    const mk_build_shadow = b.addSystemCommand(&[_][]const u8{
        "mkdir", "-p", build_shadow_dir,
    });
    mk_build_shadow.step.dependOn(&clean_build_shadow.step);

    const cp_shadow = b.addSystemCommand(&[_][]const u8{
        "cp", "-rT",
    });
    cp_shadow.addFileArg(shadow_dep.path(""));
    cp_shadow.addArg(build_shadow_dir);
    cp_shadow.step.dependOn(&mk_build_shadow.step);

    const shadow_autogen = b.addSystemCommand(&[_][]const u8{
        "autoreconf", "-vfi",
    });
    shadow_autogen.setCwd(b.path(build_shadow_dir));
    // shadow_autogen.step.dependOn(&cp_shadow.step);
    shadow_autogen.step.dependOn(&cp_shadow.step);

    const shadow_configure = b.addSystemCommand(&[_][]const u8{
        "./configure",
        "--disable-nls",
        "--disable-man",
        "--disable-shared",
        "--enable-static",
        "--enable-subids",
        "--without-selinux",
        "--without-acl",
        "--without-attr",
        "--without-audit",
        "--without-nscd",
    });
    // shadow_configure.setEnvironmentVariable("CC", cc); // Use native gcc to avoid environment issues in subdir
    shadow_configure.setEnvironmentVariable("CFLAGS", "-isystem /usr/include/bsd -DLIBBSD_OVERLAY");
    // shadow_configure.setEnvironmentVariable("LDFLAGS", "-L/usr/lib -L/usr/lib/x86_64-linux-gnu");
    shadow_configure.setCwd(b.path(build_shadow_dir));
    shadow_configure.step.dependOn(&shadow_autogen.step);

    // We also need to build it? Or just configure?
    // We are compiling sources manually below. Configure should generate config.h and Makefiles.
    // That should be enough for headers.

    const prepare_shadow_step = &shadow_configure.step;

    const runtime = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .link_libc = true,
    });

    runtime.addOptions("build_info", build_info);

    runtime.addImport("zstd", zstd);
    runtime.addImport("fuse-overlayfs", fuse_fss);

    runtime.addIncludePath(crun_src_root);
    runtime.addIncludePath(b.path(build_crun_dir ++ "/src"));
    runtime.addIncludePath(b.path(build_crun_dir ++ "/libocispec/src"));

    runtime.addIncludePath(argp_dep.path(""));

    runtime.addCSourceFiles(.{
        .root = b.path(build_crun_dir ++ "/src/libcrun"),
        .files = &[_][]const u8{
            "container.c",
            "status.c",
            "linux.c",
            "utils.c",
            "cgroup-utils.c",
            "cgroup.c",
            "intelrdt.c",
            "cgroup-resources.c",
            "ebpf.c",
            "cgroup-cgroupfs.c",
            "chroot_realpath.c",
            "cloned_binary.c",
            "custom-handler.c",
            "terminal.c",
            "cgroup-systemd.c",
            "error.c",
            "mount_flags.c",
            "seccomp.c",
            "seccomp_notify.c",
            "scheduler.c",
            "io_priority.c",
            "cgroup-setup.c",
            "signals.c",
            "criu.c",

            "blake3/blake3.c",
            "blake3/blake3_portable.c",
        },
        .flags = &[_][]const u8{
            "-DPACKAGE_VERSION=\"0.17\"",
        },
    });

    runtime.addCSourceFiles(.{
        .root = libocispec_src_root,
        .files = &[_][]const u8{
            "src/ocispec/read-file.c",
            "src/ocispec/json_common.c",
            "src/ocispec/runtime_spec_schema_config_schema.c",
            "src/ocispec/runtime_spec_schema_config_zos.c",
            "src/ocispec/runtime_spec_schema_config_vm.c",
            "src/ocispec/runtime_spec_schema_config_windows.c",
            "src/ocispec/runtime_spec_schema_config_solaris.c",
            "src/ocispec/runtime_spec_schema_config_linux.c",
            "src/ocispec/runtime_spec_schema_defs.c",
            "src/ocispec/runtime_spec_schema_defs_linux.c",
            "src/ocispec/runtime_spec_schema_defs_windows.c",
            "src/ocispec/runtime_spec_schema_defs_zos.c",
        },
    });

    runtime.addCSourceFiles(.{
        .root = b.path(build_crun_dir ++ "/libocispec/yajl/src"),
        .files = &[_][]const u8{
            "yajl.c",
            "yajl_gen.c",
            "yajl_buf.c",
            "yajl_alloc.c",
            "yajl_encode.c",
            "yajl_tree.c",
            "yajl_parser.c",
            "yajl_lex.c",
        },
    });

    runtime.addIncludePath(b.path(build_shadow_dir ++ "/libsubid"));
    runtime.addIncludePath(b.path(build_shadow_dir ++ "/lib"));
    runtime.addIncludePath(b.path(build_shadow_dir));

    runtime.addCSourceFiles(.{
        .root = b.path(build_shadow_dir),
        .files = &[_][]const u8{
            "libsubid/api.c",
            "lib/shadowlog.c",
            "lib/subordinateio.c",
            "lib/commonio.c",
            "lib/write_full.c",
            "lib/nss.c",
            "lib/get_pid.c",
            "lib/memzero.c",
            "lib/alloc.c",
            "lib/atoi/str2i.c",
            "lib/atoi/a2i.c",
            "lib/atoi/strtou_noneg.c",
            "lib/atoi/strtoi.c",
            "lib/string/sprintf.c",
        },
        .flags = &[_][]const u8{
            "-DENABLE_SUBIDS",
            // duplicate symbol with crun
            "-Dxasprintf=shadow_xasprintf",
        },
    });

    const aarch64_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .abi = target.result.abi,
        .os_tag = .linux,
    });

    const x86_64_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .abi = target.result.abi,
        .os_tag = .linux,
    });

    const runtime_x86_64 = b.addExecutable(.{
        .name = "runtime_x86-64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entry.zig"),
            .target = x86_64_target,
            .optimize = optimize,
        }),
    });

    const runtime_aarch64 = b.addExecutable(.{
        .name = "runtime_aarch64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entry.zig"),
            .target = aarch64_target,
            // FIXME: When compiled with ReleaseSafe reading files in the overlayfs
            // will give EINVAL (Invalid Argument)
            .optimize = .Debug,
        }),
    });

    runtime_x86_64.root_module.addImport("runtime_lib", runtime);
    runtime_aarch64.root_module.addImport("runtime_lib", runtime);

    const crun_mkdir_m4 = b.addSystemCommand(&[_][]const u8{ "mkdir", "-p", "m4" });
    crun_mkdir_m4.setCwd(crun_src_root);
    crun_mkdir_m4.step.dependOn(prepare_crun_step);

    const crun_autogen = b.addSystemCommand(&[_][]const u8{ "autoreconf", "-fi" });
    crun_autogen.setCwd(crun_src_root);
    crun_autogen.step.dependOn(&crun_mkdir_m4.step);

    const crun_configure = b.addSystemCommand(&[_][]const u8{
        "./configure",
        "--enable-embedded-yajl",
        "--disable-systemd",
        "--disable-caps",
        "--disable-seccomp",
        "--disable-criu",
    });
    crun_configure.setEnvironmentVariable(
        "CC",
        cc,
    );
    crun_configure.setCwd(crun_src_root);
    crun_configure.step.dependOn(&crun_autogen.step);

    const libocspec_generate_files = b.addSystemCommand(&[_][]const u8{
        "make",
        "src/ocispec/runtime_spec_schema_config_schema.c",
        "src/ocispec/runtime_spec_schema_config_zos.c",
        "src/ocispec/runtime_spec_schema_config_vm.c",
        "src/ocispec/runtime_spec_schema_config_windows.c",
        "src/ocispec/runtime_spec_schema_config_solaris.c",
        "src/ocispec/runtime_spec_schema_config_linux.c",
        "src/ocispec/runtime_spec_schema_defs.c",
        "src/ocispec/runtime_spec_schema_defs_linux.c",
        "src/ocispec/runtime_spec_schema_defs_windows.c",
        "src/ocispec/runtime_spec_schema_defs_zos.c",
    });
    libocspec_generate_files.setCwd(libocispec_src_root);
    libocspec_generate_files.step.dependOn(&crun_configure.step);

    const prepare_headers = b.addSystemCommand(&[_][]const u8{ "sh", "-c", "ln -snf libocispec/src/ocispec ocispec && ln -snf libocispec/yajl/src/api yajl" });
    prepare_headers.setCwd(crun_src_root);
    prepare_headers.step.dependOn(&libocspec_generate_files.step);

    if (!skip_crun_build) {
        runtime_x86_64.step.dependOn(&sf_make_swap.step);
        runtime_x86_64.step.dependOn(&fov_configure.step);
        runtime_x86_64.step.dependOn(&prepare_headers.step);
        runtime_x86_64.step.dependOn(prepare_shadow_step);

        runtime_aarch64.step.dependOn(&sf_make_swap.step);
        runtime_aarch64.step.dependOn(&fov_configure.step);
        runtime_aarch64.step.dependOn(&prepare_headers.step);
        runtime_aarch64.step.dependOn(prepare_shadow_step);
    }

    const go_cpu_arch = switch (target.query.cpu_arch orelse target.result.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => @panic("unimplemented"),
    };

    const build_umoci_dir = "deps/umoci";
    const clean_umoci = b.addSystemCommand(&[_][]const u8{ "rm", "-rf", build_umoci_dir });
    const cp_umoci = b.addSystemCommand(&[_][]const u8{ "cp", "-rT" });
    cp_umoci.addFileArg(umoci_dep.path(""));
    cp_umoci.addArg(build_umoci_dir);
    cp_umoci.step.dependOn(&clean_umoci.step);
    cp_umoci.step.dependOn(&mk_deps_initial.step);

    const umoci = b.addSystemCommand(&[_][]const u8{
        "go",
        "build",
        "-tags",
        "",
        "-ldflags",
        "-s -extldflags '-static'",
        "-o",
    });
    umoci.setCwd(b.path(build_umoci_dir));
    const umoci_output = umoci.addOutputFileArg(
        std.fmt.allocPrint(
            b.allocator,
            "umoci_{s}",
            .{go_cpu_arch},
        ) catch @panic("OOM"),
    );
    umoci.addArg("github.com/opencontainers/umoci/cmd/umoci");
    umoci.step.dependOn(&cp_umoci.step);

    umoci.setEnvironmentVariable(
        "CGO_ENABLED",
        "0",
    );

    umoci.setEnvironmentVariable("GOARCH", go_cpu_arch);

    const build_skopeo_dir = "deps/skopeo";
    const clean_skopeo = b.addSystemCommand(&[_][]const u8{ "rm", "-rf", build_skopeo_dir });
    const cp_skopeo = b.addSystemCommand(&[_][]const u8{ "cp", "-rT" });
    cp_skopeo.addFileArg(skopeo_dep.path(""));
    cp_skopeo.addArg(build_skopeo_dir);
    cp_skopeo.step.dependOn(&clean_skopeo.step);
    cp_skopeo.step.dependOn(&mk_deps_initial.step);

    const skopeo = b.addSystemCommand(&[_][]const u8{
        "go",
        "build",
        "-gcflags",
        "",
        "-tags",
        "containers_image_openpgp",
        "-o",
    });
    skopeo.setCwd(b.path(build_skopeo_dir));
    const skopeo_output = skopeo.addOutputFileArg(
        std.fmt.allocPrint(
            b.allocator,
            "skopeo_{s}",
            .{go_cpu_arch},
        ) catch @panic("OOM"),
    );
    skopeo.addArg("./cmd/skopeo");
    skopeo.step.dependOn(&cp_skopeo.step);

    skopeo.setEnvironmentVariable(
        "CGO_ENABLED",
        "0",
    );
    skopeo.setEnvironmentVariable("GOARCH", go_cpu_arch);
    skopeo.setEnvironmentVariable("DISABLE_DOCS", "1");

    const dockerc = b.addExecutable(.{
        .name = "dockerc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dockerc.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    dockerc.root_module.addOptions("build_info", build_info);

    dockerc.addIncludePath(zstd_dep.path("lib"));
    dockerc.root_module.addImport("zstd", zstd);
    dockerc.addCSourceFiles(.{
        .root = squashfs_tools_dep.path("squashfs-tools"),
        .files = &[_][]const u8{
            "mksquashfs.c",
            "progressbar.c",
            "caches-queues-lists.c",
            "date.c",
            "pseudo.c",
            "action.c",
            "sort.c",
            "restore.c",
            "info.c",
            "mksquashfs_help.c",
            "print_pager.c",
            "compressor.c",
            "tar.c",
            "reader.c",
            "read_fs.c",
            "memory.c",
            "process_fragments.c",
            "zstd_wrapper.c",
            "virt_disk_pos.c",
            "thread.c",
            "symbolic_mode.c",
            "limit.c",
            "nprocessors_compat.c",
            "xattr.c",
            "read_xattrs.c",
            "tar_xattr.c",
            "pseudo_xattr.c",
            "xattr_system.c",
        },
        .flags = &[_][]const u8{
            // avoid collision of main function
            "-Dmain=mksquashfs_main",
            "-DZSTD_SUPPORT",
            "-D_GNU_SOURCE",
            "-DVERSION=\"dockerc\"",
            "-DDATE=\"2024/07/21\"",
            "-DYEAR=\"2024\"",
            "-DCOMP_DEFAULT=\"zstd\"",
            "-DCOMPRESSORS=\"zstd\"",
            "-DXATTR_SUPPORT",
            "-DXATTR_OS_SUPPORT",
            "-DXATTR_DEFAULT",
            // There's UB in squashfs. This deals with it.
            "-fno-sanitize=undefined",
            "-DMAX_READER_THREADS=1024",
            "-DSMALL_READER_THREADS=8",
            "-DBLOCK_READER_THREADS=3",
        },
    });

    dockerc.root_module.addAnonymousImport(
        "runtime_x86_64",
        .{ .root_source_file = runtime_x86_64.getEmittedBin() },
    );

    dockerc.root_module.addAnonymousImport(
        "runtime_aarch64",
        .{ .root_source_file = runtime_aarch64.getEmittedBin() },
    );

    dockerc.root_module.addAnonymousImport(
        "umoci",
        .{ .root_source_file = umoci_output },
    );
    dockerc.root_module.addAnonymousImport(
        "skopeo",
        .{ .root_source_file = skopeo_output },
    );

    dockerc.root_module.addImport("clap", clap.module("clap"));

    b.installArtifact(dockerc);

    const replace_bin = b.addExecutable(.{
        .name = "replace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/replace.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    replace_bin.root_module.addAnonymousImport(
        "runtime_x86_64",
        .{ .root_source_file = runtime_x86_64.getEmittedBin() },
    );

    replace_bin.root_module.addAnonymousImport(
        "runtime_aarch64",
        .{ .root_source_file = runtime_aarch64.getEmittedBin() },
    );

    b.installArtifact(replace_bin);

    const extract_bin = b.addExecutable(.{
        .name = "extract",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/extract_squashfs.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(extract_bin);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    // b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    // const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    // run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    // if (b.args) |args| {
    //     run_cmd.addArgs(args);
    // }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    // const run_step = b.step("run", "Run the app");
    // run_step.dependOn(&run_cmd.step);
}
