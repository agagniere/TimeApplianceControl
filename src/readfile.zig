const std = @import("std");
const log = @import("log.zig").config.scoped(.timecard);
const Allocator = std.mem.Allocator;

/// Read the whole file into `buffer`, failing instead of silently truncating a file that doesn't fit.
/// The file has to be strictly smaller than `buffer`
pub fn readFileFitting(io: std.Io, dir: std.Io.Dir, filename: []const u8, buffer: []u8) ![]u8 {
    const content = try dir.readFile(io, filename, buffer);
    // A full buffer is ambiguous: it may hold a truncated file
    if (content.len == buffer.len)
        return error.FileTooBig;
    return content;
}

/// Interpret the contents of the file as an integer
pub fn readIntegerFromFile(
    /// Used in logs to describe where a file is expected
    comptime location: []const u8,
    T: type,
    io: std.Io,
    dir: std.Io.Dir,
    filename: []const u8,
) !T {
    var buffer: [64]u8 = undefined;
    const content = readFileFitting(io, dir, filename, &buffer) catch |err| {
        switch (err) {
            error.FileTooBig => log.errAt(@src(), "The file '{s}' in " ++ location ++ " is larger than expected", .{filename}),
            else => log.errAt(@src(), location ++ " is expected to contain a file called '{s}': {t}", .{ filename, err }),
        }
        return err;
    };
    return std.fmt.parseInt(T, std.mem.trim(u8, content, "\n"), 0) catch |err| {
        log.errAt(@src(), "The file '{s}' in " ++ location ++ " is expected to contain an integer: {t}", .{ filename, err });
        return err;
    };
}

const readListFromFileOptions = struct {
    /// Used in logs to describe where a file is expected
    location: []const u8,
    /// Emit an error if not found
    mandatory: bool = true,
};

/// Interpret the content of the file as a sequence of space-separated words
pub fn readListFromFile(
    alloc: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    filename: []const u8,
    comptime log_options: readListFromFileOptions,
) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var buffer: [512]u8 = undefined;
    const content = readFileFitting(io, dir, filename, &buffer) catch |err| {
        switch (err) {
            error.FileTooBig => log.errAt(@src(), "The file '{s}' in " ++ log_options.location ++ " is larger than expected", .{filename}),
            else => if (log_options.mandatory)
                log.errAt(@src(), "A file called '{s}' is expected in " ++ log_options.location ++ ": {t}", .{ filename, err }),
        }
        return err;
    };
    var words = std.mem.tokenizeAny(u8, content, " \n");
    while (words.next()) |word| {
        try result.append(alloc, try alloc.dupe(u8, word));
    }
    return result.toOwnedSlice(alloc);
}

test readFileFitting {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "fits", .data = "123456\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fills", .data = "12345678" });
    try tmp.dir.writeFile(io, .{ .sub_path = "overflows", .data = "123456789\n" });

    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("123456\n", try readFileFitting(io, tmp.dir, "fits", &buffer));
    try std.testing.expectError(error.FileTooBig, readFileFitting(io, tmp.dir, "fills", &buffer));
    try std.testing.expectError(error.FileTooBig, readFileFitting(io, tmp.dir, "overflows", &buffer));
}
