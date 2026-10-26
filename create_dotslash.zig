const std = @import("std");

/// Internal tool used by `build.zig` to generate the Dotslash file output by the CI job.
pub fn main(init: std.process.Init) !void {
    const cwd = std.Io.Dir.cwd();

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    const output_path = args.next() orelse return error.InvalidArguments;
    const output_name = std.Io.Dir.path.basename(output_path);

    // ---------------------------------------------------------------------------------------------
    // Read inputs concurrently.

    var results = try init.arena.allocator().alloc(FileHash, init.minimal.args.vector.len - 2);
    var result_i: usize = 0;

    var group: std.Io.Group = .init;
    errdefer group.cancel(init.io);

    while (args.next()) |input_path| {
        const file = try cwd.openFile(init.io, input_path, .{});
        const result = &results[result_i];

        const input_name = std.Io.Dir.path.basename(input_path);
        const platform = input_name[0 .. std.mem.findScalar(u8, input_name, '.') orelse return error.InvalidInput];

        result.* = .{ .platform = platform };
        group.async(init.io, hashFile, .{ init.io, file, result });
        result_i += 1;
    }

    try group.await(init.io);

    for (results) |result| if (result.err) |err| return err;

    // ---------------------------------------------------------------------------------------------
    // Build output file.

    var output_file = try cwd.createFile(init.io, output_path, .{
        .permissions = .executable_file,
    });
    defer output_file.close(init.io);

    var output_buf: [1024]u8 = undefined;
    var output = output_file.writer(init.io, &output_buf);

    try output.interface.print(
        \\#!/usr/bin/env dotslash
        \\{{
        \\  "name": "{s}",
        \\  "platforms": {{
        \\
    ,
        .{output_name},
    );

    for (results, 0..) |*result, i| {
        const repo = "71/capnproto-zig";
        const release = "v" ++ @import("build.zig.zon").version;

        var digest: [256 / 8]u8 = undefined;
        result.digest.final(&digest);

        try output.interface.print(
            \\    "{s}": {{
            \\      "size": {d},
            \\      "hash": "blake3",
            \\      "digest": "{x}",
            \\      "format": "tar.zst",
            \\      "path": "bin/{s}{s}",
            \\      "providers": [
            \\        {{
            \\          "url": "https://github.com/{s}/releases/download/{s}/{s}.tar.zst"
            \\        }},
            \\        {{
            \\          "type": "github-release",
            \\          "repo": "{s}",
            \\          "tag": "{s}",
            \\          "name": "{s}.tar.zst"
            \\        }}
            \\      ]
            \\    }}{s}
            \\
        , .{
            result.platform,
            result.size,
            digest,
            output_name,
            if (std.mem.startsWith(u8, result.platform, "windows-")) ".exe" else "",
            repo,
            release,
            result.platform,
            repo,
            release,
            result.platform,
            if (i == results.len - 1) "" else ",",
        });
    }

    try output.interface.writeAll(
        \\  }
        \\}
    );

    try output.flush();
}

/// The hash of an input file, plus input and error, output by `hashFile()`.
const FileHash = struct {
    platform: []const u8 = "",
    size: u64 = 0,
    digest: std.crypto.hash.Blake3 = .init(.{}),
    err: ?anyerror = null,
};

/// Hashes `file` into `result`. `result` is a parameter (rather than the result type of this
/// function) so `hashFile()` can be called with `std.Io.Group.async()`.
fn hashFile(
    io: std.Io,
    file: std.Io.File,
    result: *FileHash,
) std.Io.Cancelable!void {
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    while (true) {
        try io.checkCancel();

        reader.interface.fillMore() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |other| {
                result.err = other;
                return;
            },
        };

        result.size += reader.interface.bufferedLen();
        result.digest.update(reader.interface.buffered());

        reader.interface.tossBuffered();
    }
}
