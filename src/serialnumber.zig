const std = @import("std");

/// Get an integer from the mac-address-like representation exposed by the driver
/// Each byte is interpreted as an ASCII digit
/// The serial number is given in the form aa:bb:cc:dd:ee:ff
pub fn parseSerialNumber(raw: []const u8) !u32 {
    var result: u32 = 0;
    var count: usize = 0;
    var pairs = std.mem.splitScalar(u8, raw, ':');
    while (pairs.next()) |pair| : (count += 1) {
        if (count == 6)
            return error.InvalidFormat;
        const chr = try std.fmt.parseUnsigned(u8, pair, 16);
        result *= 10;
        result += try std.fmt.charToDigit(chr, 10);
    }
    if (count != 6)
        return error.InvalidFormat;
    return result;
}

test parseSerialNumber {
    try std.testing.expectEqual(123456, try parseSerialNumber("31:32:33:34:35:36"));
    try std.testing.expectEqual(230541, try parseSerialNumber("32:33:30:35:34:31"));
    // Unflashed EEPROM
    try std.testing.expectError(error.InvalidCharacter, parseSerialNumber("00:00:00:00:00:00"));
    try std.testing.expectError(error.InvalidFormat, parseSerialNumber("31:32:33:34:35"));
    try std.testing.expectError(error.InvalidFormat, parseSerialNumber("31:32:33:34:35:36:37"));
    try std.testing.expectError(error.InvalidCharacter, parseSerialNumber("31:32::34:35:36"));
    try std.testing.expectError(error.InvalidCharacter, parseSerialNumber(""));
}
