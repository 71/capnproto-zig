const std = @import("std");

const upstream_url = @import("build.zig.zon").dependencies.capnproto.url;
const upstream_version = upstream_url[(std.mem.findScalarLast(u8, upstream_url, '/') orelse unreachable) + 1 .. std.mem.findScalarLast(u8, upstream_url, '.') orelse unreachable];

pub fn build(b: *std.Build) !void {
    const given_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pic = b.option(bool, "pic", "Produce Position Independent Code");
    const strip = b.option(bool, "strip", "Omit debug information");

    const build_all_step = b.step("all", "Build binaries for multiple architectures");
    const build_all_target_queries: []const std.Target.Query = &.{
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
    };

    var build_all_targets: [1 + build_all_target_queries.len]std.Build.ResolvedTarget = @splat(given_target);
    for (build_all_target_queries, 0..) |query, i| {
        build_all_targets[i + 1] = b.resolveTargetQuery(query);
    }

    const build_all_target_platforms: [build_all_target_queries.len][]const u8 = .{
        // Must match Dotslash.
        "macos-aarch64",
        "linux-aarch64",
        "linux-x86_64",
        "windows-x86_64",
    };

    const upstream = b.dependency("capnproto", .{});
    const upstream_src_dir = upstream.path("c++/src");

    const flags: []const []const u8 = &.{
        "-std=c++23",
    };

    // ---------------------------------------------------------------------------------------------
    // MARK: Dotslash helper

    const to_dotslash = b.addExecutable(.{
        .name = "to_dotslash",
        .root_module = b.createModule(.{
            .target = given_target,
            .optimize = .safe,
            .root_source_file = b.path("create_dotslash.zig"),
        }),
    });
    var tar_zst_paths: [build_all_target_queries.len]std.Build.LazyPath = @splat(.cache_root);

    // ---------------------------------------------------------------------------------------------
    // MARK: Patch capnp.c++

    const capnp_cpp = try patchCapnpCpp(b, upstream_src_dir.path(b, "capnp/compiler/capnp.c++"));

    for (build_all_targets, 0..) |target, i| {
        // -----------------------------------------------------------------------------------------
        // MARK: KJ

        const kj = b.addLibrary(.{
            .name = "kj",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .pic = pic,
                .strip = strip,
                .link_libc = true,
                .link_libcpp = true,
            }),
        });
        const kj_dir = upstream.path("c++/src/kj");

        kj.root_module.addAfterIncludePath(kj_dir);
        kj.root_module.addCSourceFiles(.{
            .language = .cpp,
            .root = kj_dir,
            .flags = flags,
            .files = if (target.result.os.tag == .windows) kj_windows_sources else kj_unix_sources,
        });
        kj.root_module.addIncludePath(upstream_src_dir);
        kj.installHeadersDirectory(kj_dir, "kj", .{});

        if (target.result.os.tag != .windows) kj.root_module.linkSystemLibrary("pthread", .{});

        if (i == 0) b.installArtifact(kj);

        // -----------------------------------------------------------------------------------------
        // MARK: Library

        const capnp = b.addLibrary(.{
            .name = "capnproto",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .pic = pic,
                .strip = strip,
                .link_libc = true,
                .link_libcpp = true,
            }),
        });
        const capnp_dir = upstream.path("c++/src/capnp");

        capnp.root_module.addAfterIncludePath(capnp_dir);
        capnp.root_module.addCSourceFiles(.{
            .language = .cpp,
            .root = capnp_dir,
            .flags = flags,
            .files = capnp_sources,
        });
        capnp.root_module.addIncludePath(upstream_src_dir);
        capnp.root_module.linkLibrary(kj);
        capnp.installHeadersDirectory(capnp_dir, "capnp", .{
            .include_extensions = &.{ ".h", ".capnp" },
        });

        if (i == 0) b.installArtifact(capnp);

        const capnpc = b.addLibrary(.{
            .name = "capnpc",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .pic = pic,
                .strip = strip,
                .link_libc = true,
                .link_libcpp = true,
            }),
        });

        capnpc.root_module.addAfterIncludePath(upstream.path("c++/src/capnp/compiler"));
        capnpc.root_module.addCSourceFiles(.{
            .language = .cpp,
            .root = capnp_dir,
            .flags = flags,
            .files = capnpc_sources,
        });
        capnpc.root_module.addIncludePath(upstream_src_dir);
        capnpc.root_module.linkLibrary(capnp);

        // -----------------------------------------------------------------------------------------
        // MARK: Binaries

        const target_triple = if (i > 0) build_all_target_platforms[i - 1] else "native";
        const tar_run = if (i > 0) b.addSystemCommand(&.{ "tar", "--zstd", "-cf" }) else null;

        for (capnp_binaries) |name| {
            const is_capnp = std.mem.eql(u8, name, "capnp");

            const exe = b.addExecutable(.{
                .name = name,
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .pic = pic,
                    .strip = strip,
                    .link_libc = true,
                    .link_libcpp = true,
                }),
            });

            exe.root_module.addIncludePath(upstream.path("c++/src/capnp/compiler"));
            exe.root_module.addCSourceFile(.{
                .language = .cpp,
                .file = if (is_capnp)
                    capnp_cpp
                else
                    upstream.path(b.fmt("c++/src/capnp/compiler/{s}.c++", .{name})),
                .flags = flags ++ .{"-DVERSION=\"(" ++ upstream_version ++ " via zig)\""},
            });
            exe.root_module.addIncludePath(upstream_src_dir);
            exe.root_module.linkLibrary(capnpc);

            if (tar_run) |tar| {
                // "all" target binary.
                const target_output = b.addInstallArtifact(exe, .{
                    .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/bin", .{target_triple}) } },
                });

                build_all_step.dependOn(&target_output.step);
                tar.step.dependOn(&target_output.step);
                tar.addFileInput(exe.getEmittedBin());
                continue;
            }

            // Native binary.
            b.installArtifact(exe);

            const run = b.addRunArtifact(exe);
            run.addPassthruArgs();
            run.step.dependOn(&exe.step);

            const run_step = b.step(name, b.fmt("Run {s}", .{name}));
            run_step.dependOn(&run.step);
        }

        const tar = tar_run orelse continue;

        // -----------------------------------------------------------------------------------------
        // MARK: .capnp files

        for (capnp_files) |capnp_file| {
            const capnp_file_path = upstream.path(b.fmt("c++/src/capnp/{s}", .{capnp_file}));
            const capnp_file_step = b.addInstallFile(
                capnp_file_path,
                b.fmt("{s}/include/capnp/{s}", .{ target_triple, capnp_file }),
            );

            tar.step.dependOn(&capnp_file_step.step);
            tar.addFileInput(capnp_file_path);
        }

        // -----------------------------------------------------------------------------------------
        // MARK: .tar.zst

        const target_triple_tar_zst = b.fmt("{s}.tar.zst", .{target_triple});
        const tar_output = tar.addOutputFileArg2(target_triple_tar_zst, .{});

        tar.addArg("-C");
        _ = tar.addDirectoryArg2(b.graph.path(.install_prefix, target_triple), .{});
        tar.addArgs(&.{ "bin", "include" });

        tar_zst_paths[i - 1] = tar_output;

        const install_tar_zst = b.addInstallFile(
            tar_output,
            target_triple_tar_zst,
        );
        install_tar_zst.step.dependOn(&tar.step);

        build_all_step.dependOn(&install_tar_zst.step);
    }

    // ---------------------------------------------------------------------------------------------
    // MARK: Dotslash

    for (capnp_binaries) |binary| {
        const run_to_dotslash = b.addRunArtifact(to_dotslash);
        const run_to_dotslash_output = run_to_dotslash.addOutputFileArg2(binary, .{});

        for (tar_zst_paths) |path| _ = run_to_dotslash.addFileArg2(path, .{});

        build_all_step.dependOn(&b.addInstallFile(run_to_dotslash_output, binary).step);
    }
}

// -------------------------------------------------------------------------------------------------
// MARK: capnp.c++ patcher

fn patchCapnpCpp(b: *std.Build, source: std.Build.LazyPath) !std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ "patch", "-o" });
    const output = run.addOutputFileArg2("capnp.c++", .{});

    _ = run.addFileArg2(source, .{});
    _ = run.addFileArg2(b.path("capnp.patch"), .{});

    return output;
}

// -------------------------------------------------------------------------------------------------
// MARK: Sources

const kj_common_sources: []const []const u8 = &.{
    "arena.c++",
    "array.c++",
    "async-io.c++",
    "async.c++",
    "cidr.c++",
    "common.c++",
    "debug.c++",
    "encoding.c++",
    "exception.c++",
    "filesystem.c++",
    "glob-filter.c++",
    "hash.c++",
    "io.c++",
    "list.c++",
    "main.c++",
    "memory.c++",
    "mutex.c++",
    "parse/char.c++",
    "refcount.c++",
    "source-location.c++",
    "sticky-flag.c++",
    "string-tree.c++",
    "string.c++",
    "table.c++",
    "thread.c++",
    "time.c++",
    "timer.c++",
    "units.c++",
};

const kj_unix_sources: []const []const u8 = kj_common_sources ++ &[_][]const u8{
    "async-io-unix.c++",
    "async-unix.c++",
    "filesystem-disk-unix.c++",
};

const kj_windows_sources: []const []const u8 = kj_common_sources ++ &[_][]const u8{
    "async-io-win32.c++",
    "async-win32.c++",
    "filesystem-disk-win32.c++",
};

const capnp_sources: []const []const u8 = &.{
    "any.c++",
    "arena.c++",
    "blob.c++",
    "c++.capnp.c++",
    "compat/json.c++",
    "compat/json.capnp.c++",
    "capability.c++",
    "dynamic-capability.c++",
    "dynamic.c++",
    "layout.c++",
    "list.c++",
    "membrane.c++",
    "message.c++",
    "persistent.capnp.c++",
    "reconnect.c++",
    "rpc-twoparty.c++",
    "rpc-twoparty.capnp.c++",
    "rpc.c++",
    "rpc.capnp.c++",
    "schema-loader.c++",
    "schema-parser.c++",
    "schema.c++",
    "schema.capnp.c++",
    "serialize-async.c++",
    "serialize-packed.c++",
    "serialize-text.c++",
    "serialize.c++",
    "stream.capnp.c++",
    "stringify.c++",
};

const capnpc_sources: []const []const u8 = &.{
    "compiler/compiler.c++",
    "compiler/error-reporter.c++",
    "compiler/generics.c++",
    "compiler/grammar.capnp.c++",
    "compiler/lexer.c++",
    "compiler/lexer.capnp.c++",
    "compiler/module-loader.c++",
    "compiler/node-translator.c++",
    "compiler/parser.c++",
    "compiler/type-id.c++",
};

const capnp_files: []const []const u8 = &.{
    "c++.capnp",
    "persistent.capnp",
    "rpc-twoparty.capnp",
    "rpc.capnp",
    "schema.capnp",
};

const capnp_binaries: []const []const u8 = &.{
    "capnp",
    "capnpc-c++",
    "capnpc-capnp",
};
