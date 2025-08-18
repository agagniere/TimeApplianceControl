const std = @import("std");
const log = @import("log.zig").config.scoped(.timecard);
const Allocator = std.mem.Allocator;

/// Interpret the contents of the file as an integer
pub fn readIntegerFromFile(
    /// Used in logs to describe where a file is expected
    comptime location: []const u8,
    T: type,
    dir: std.fs.Dir,
    filename: []const u8,
) !T {
    var buffer: [64]u8 = undefined;
    const content = dir.readFile(filename, &buffer) catch |err| {
        log.errAt(@src(), location ++ " is expected to contain a file called '{s}': {t}", .{ filename, err });
        return err;
    };
    return std.fmt.parseInt(T, std.mem.trim(u8, content, "\n"), 0) catch |err| {
        log.errAt(@src(), "The file '{s}' in " ++ location ++ " is expected to contain an integer: {t}", .{ filename, err });
        return err;
    };
}

/// Interpret the content of the file as a sequence of space-separated words
pub fn readListFromFile(
    /// Used in logs to describe where a file is expected
    comptime location: []const u8,
    alloc: Allocator,
    dir: std.fs.Dir,
    filename: []const u8,
) ![][]const u8 {
    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    var buffer: [512]u8 = undefined;
    const content = dir.readFile(filename, &buffer) catch |err| {
        log.errAt(@src(), "A file called '{s}' is expected in " ++ location ++ ": {t}", .{ filename, err });
        return err;
    };
    var words = std.mem.tokenizeAny(u8, content, " \n");
    while (words.next()) |word| {
        try result.append(alloc, try alloc.dupe(u8, word));
    }
    return result.toOwnedSlice(alloc);
}
