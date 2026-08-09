// backend/tests/test_log.zig
// Independent tests for the log module.
// Tests only public API of src/log.zig.
const std = @import("std");
const log_mod = @import("log_mod");

const LogLevel = log_mod.LogLevel;

test "LogLevel toString" {
    try std.testing.expectEqualStrings("ERROR", LogLevel.err_level.toString());
    try std.testing.expectEqualStrings("WARN", LogLevel.warn_level.toString());
    try std.testing.expectEqualStrings("INFO", LogLevel.info_level.toString());
    try std.testing.expectEqualStrings("DEBUG", LogLevel.debug_level.toString());
}

test "LogLevel fromString" {
    try std.testing.expectEqual(@as(?LogLevel, .err_level), LogLevel.fromString("ERROR"));
    try std.testing.expectEqual(@as(?LogLevel, .warn_level), LogLevel.fromString("WARN"));
    try std.testing.expectEqual(@as(?LogLevel, .info_level), LogLevel.fromString("INFO"));
    try std.testing.expectEqual(@as(?LogLevel, .debug_level), LogLevel.fromString("DEBUG"));
    try std.testing.expectEqual(@as(?LogLevel, null), LogLevel.fromString("INVALID"));
}

test "LogLevel intValue ordering" {
    try std.testing.expect(LogLevel.err_level.intValue() < LogLevel.warn_level.intValue());
    try std.testing.expect(LogLevel.warn_level.intValue() < LogLevel.info_level.intValue());
    try std.testing.expect(LogLevel.info_level.intValue() < LogLevel.debug_level.intValue());
}
