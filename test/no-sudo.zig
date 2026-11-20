//! Generate the fake root of a user forgetting sudo: the sysfs of a fixture,
//! with a PTP device that only root can open.
//! Git doesn't store such permissions, hence generating it at build time.
//! Usage: no-sudo <fixture root> <PTP device name> <output root>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4)
        return error.InvalidUsage;
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, args[3]);
    var output = try cwd.openDir(io, args[3], .{});
    defer output.close(io);

    const fixture = try cwd.realPathFileAlloc(io, args[1], arena);
    try output.symLink(io, try std.Io.Dir.path.join(arena, &.{ fixture, "sys" }), "sys", .{ .is_directory = true });
    try output.createDirPath(io, "dev");
    // Never read: opening it fails first
    const device = try output.createFile(io, try std.Io.Dir.path.join(arena, &.{ "dev", args[2] }), .{ .permissions = .fromMode(0) });
    device.close(io);
}
