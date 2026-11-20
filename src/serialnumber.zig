const std = @import("std");

/// Get an integer from the representation exposed by the driver:
/// the 6 bytes of the serial number read from the EEPROM, printed like a MAC address (aa:bb:cc:dd:ee:ff).
/// Each byte is expected to be an ASCII digit
pub fn parseSerialNumber(raw: []const u8) error{ InvalidFormat, InvalidCharacter }!u32 {
    var bytes: [6]u8 = undefined;
    var count: usize = 0;
    var pairs = std.mem.splitScalar(u8, raw, ':');
    while (pairs.next()) |pair| : (count += 1) {
        if (count == bytes.len or pair.len != 2 or !std.ascii.isHex(pair[0]) or !std.ascii.isHex(pair[1]))
            return error.InvalidFormat;
        bytes[count] = std.fmt.parseUnsigned(u8, pair, 16) catch unreachable;
    }
    if (count != bytes.len)
        return error.InvalidFormat;

    var result: u32 = 0;
    for (bytes) |byte| {
        result *= 10;
        result += try std.fmt.charToDigit(byte, 10);
    }
    return result;
}

test parseSerialNumber {
    try std.testing.expectEqual(123456, try parseSerialNumber("31:32:33:34:35:36"));
    try std.testing.expectEqual(230541, try parseSerialNumber("32:33:30:35:34:31"));
    // Well formed, but with bytes that aren't ASCII digits
    try std.testing.expectError(error.InvalidCharacter, parseSerialNumber("00:00:00:00:00:00"));
    try std.testing.expectError(error.InvalidCharacter, parseSerialNumber("ff:ff:ff:ff:ff:ff"));
    try std.testing.expectError(error.InvalidCharacter, parseSerialNumber("12:85:31:32:33:34"));
    // Not what the driver is supposed to print
    try std.testing.expectError(error.InvalidFormat, parseSerialNumber(""));
    try std.testing.expectError(error.InvalidFormat, parseSerialNumber("31:32:33:34:35"));
    try std.testing.expectError(error.InvalidFormat, parseSerialNumber("31:32:33:34:35:36:37"));
    try std.testing.expectError(error.InvalidFormat, parseSerialNumber("31:32::34:35:36"));
    try std.testing.expectError(error.InvalidFormat, parseSerialNumber("3:32:33:34:35:36"));
    try std.testing.expectError(error.InvalidFormat, parseSerialNumber("+1:32:33:34:35:36"));
    try std.testing.expectError(error.InvalidFormat, parseSerialNumber("31:32:33:34:35:36\n"));
    try std.testing.expectError(error.InvalidFormat, parseSerialNumber("00:00:00:00:00:zz"));
}
