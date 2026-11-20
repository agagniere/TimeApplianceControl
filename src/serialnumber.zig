const std = @import("std");

const Dir = std.Io.Dir;

/// Read the attribute exposed by the driver
pub fn readSerialNumber(io: std.Io, root: Dir) !u32 {
    var buffer: [6 * 2 + 5]u8 = undefined;
    const raw = try root.readFile(io, "serialnum", &buffer);
    std.debug.assert(raw.len == buffer.len);
    return parseSerialNumber(raw);
}

/// Get an integer from the mac-address-like representation
/// Each byte is interpreted as an ASCII digit
/// The serial number is given in the form aa:bb:cc:dd:ee:ff
fn parseSerialNumber(raw: []const u8) !u32 {
    var result: u32 = 0;
    var pairs = std.mem.tokenizeScalar(u8, raw, ':');
    while (pairs.next()) |pair| {
        const chr = try std.fmt.parseUnsigned(u8, pair, 16);
        result *= 10;
        result += try std.fmt.charToDigit(chr, 10);
    }
    return result;
}

test parseSerialNumber {
    try std.testing.expectEqual(123456, try parseSerialNumber("31:32:33:34:35:36"));
    try std.testing.expectEqual(230541, try parseSerialNumber("32:33:30:35:34:31"));
}
