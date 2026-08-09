// backend/src/quota.zig
// Traffic quota management: monthly traffic limits with threshold-based state machine.
//
// Supports parsing human-readable traffic units (100GB, 500MB, 1TB) and querying
// monthly totals from the SQLite daily_traffic table. Thresholds trigger state
// transitions: normal → warned (90%) → exceeded (100%).
const std = @import("std");
const zqlite = @import("zqlite");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const QuotaError = error{
    InvalidUnit,
    Overflow,
    QueryFailed,
    OutOfMemory,
};

/// Quota configuration: limit in bytes, threshold fractions, reset day.
pub const QuotaConfig = struct {
    /// Monthly traffic limit in bytes. 0 = quota disabled.
    limit_bytes: u64 = 0,
    /// Warning threshold as fraction of limit (e.g. 0.9 = 90%).
    warning_threshold: f64 = 0.9,
    /// Disconnect/exceed threshold as fraction of limit (e.g. 1.0 = 100%).
    disconnect_threshold: f64 = 1.0,
    /// Day of month to reset the counter (1-28).
    reset_day: u8 = 1,
};

/// Current quota state based on usage vs thresholds.
pub const QuotaState = enum {
    /// Quota disabled (limit_bytes == 0).
    disabled,
    /// Usage below warning threshold.
    normal,
    /// Usage at or above warning threshold but below disconnect threshold.
    warned,
    /// Usage at or above disconnect threshold.
    exceeded,
};

/// Parse a human-readable traffic unit string into bytes.
/// Supports: B, KB, MB, GB, TB (case-insensitive).
/// Bare numbers are interpreted as bytes.
pub fn parseTrafficUnit(input: []const u8) QuotaError!u64 {
    if (input.len == 0) return QuotaError.InvalidUnit;

    // Find where digits end and unit begins
    var digit_end: usize = 0;
    while (digit_end < input.len and isDigit(input[digit_end])) : (digit_end += 1) {}

    if (digit_end == 0) return QuotaError.InvalidUnit;

    const num_str = input[0..digit_end];
    const unit_str = input[digit_end..];

    const num = std.fmt.parseInt(u64, num_str, 10) catch return QuotaError.InvalidUnit;

    const multiplier: u64 = if (unit_str.len == 0)
        1
    else
        unitToMultiplier(unit_str) orelse return QuotaError.InvalidUnit;

    // Check for overflow
    const result = std.math.mul(u64, num, multiplier) catch return QuotaError.Overflow;
    return result;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn unitToMultiplier(unit: []const u8) ?u64 {
    // Normalize to uppercase for case-insensitive matching
    if (unit.len == 0) return null;

    const multipliers = [_]struct { suffix: []const u8, value: u64 }{
        .{ .suffix = "B", .value = 1 },
        .{ .suffix = "KB", .value = 1024 },
        .{ .suffix = "MB", .value = 1024 * 1024 },
        .{ .suffix = "GB", .value = 1024 * 1024 * 1024 },
        .{ .suffix = "TB", .value = 1024 * 1024 * 1024 * 1024 },
    };

    for (multipliers) |m| {
        if (std.ascii.eqlIgnoreCase(unit, m.suffix)) return m.value;
    }
    return null;
}

/// Query the monthly traffic total (rx + tx bytes) from the SQLite daily_traffic table.
/// first_day_of_month is the epoch day number for the first day of the target month.
/// Returns 0 if no data found.
pub fn getMonthlyTraffic(conn: *zqlite.Conn, first_day_of_month: i64) QuotaError!u64 {
    const row = conn.row(
        \\SELECT COALESCE(SUM(total_rx_bytes + total_tx_bytes), 0)
        \\FROM daily_traffic
        \\WHERE date >= ?1
    , .{first_day_of_month}) catch return QuotaError.QueryFailed;
    if (row) |r| {
        defer r.deinit();
        return @intCast(r.int(0));
    }
    return 0;
}

/// Check quota state given config and current usage in bytes.
pub fn checkQuota(config: QuotaConfig, current_usage: u64) QuotaState {
    if (config.limit_bytes == 0) return .disabled;

    const limit = config.limit_bytes;

    // Check disconnect threshold first (more severe)
    const disconnect_point = @as(f64, @floatFromInt(limit)) * config.disconnect_threshold;
    if (current_usage >= @as(u64, @intFromFloat(disconnect_point))) return .exceeded;

    // Check warning threshold
    const warning_point = @as(f64, @floatFromInt(limit)) * config.warning_threshold;
    if (current_usage >= @as(u64, @intFromFloat(warning_point))) return .warned;

    return .normal;
}

/// Compute the first day of a given month as epoch day number.
/// year: 4-digit year (e.g. 2026), month: 1-12.
pub fn firstDayOfMonthEpochDay(year: u32, month: u32) u32 {
    // Days in each month (non-leap year)
    const days_in_month = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var total_days: u32 = 0;

    // Days from epoch (1970-01-01) to start of year
    // Years from 1970 to year-1
    var y: u32 = 1970;
    while (y < year) : (y += 1) {
        total_days += if (isLeapYear(y)) 366 else 365;
    }

    // Days from start of year to start of month
    var m: u32 = 1;
    while (m < month) : (m += 1) {
        total_days += days_in_month[m - 1];
        // Add leap day for February in leap years
        if (m == 2 and isLeapYear(year)) total_days += 1;
    }

    return total_days;
}

/// Get current day of month (1-31) from epoch seconds.
pub fn getDayOfMonth(epoch_secs: u64) u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const epoch_day = es.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return month_day.day_index + 1; // Convert to 1-based
}

/// Check if current day matches the quota reset day.
/// Returns true if the current day of month equals reset_day (1-28).
pub fn shouldRestore(reset_day: u8, current_epoch_secs: u64) bool {
    const current_day = getDayOfMonth(current_epoch_secs);
    return current_day == reset_day;
}

/// Reset quota state after monthly reset.
/// This is a placeholder for quota state persistence - in a real implementation,
/// this would update the quota state file or database.
pub fn resetQuotaState(allocator: Allocator) void {
    // In a full implementation, this would:
    // 1. Clear the monthly traffic counter
    // 2. Reset the quota state to normal
    // 3. Log the reset event
    _ = allocator;
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

// =============================================================================
// Tests
// =============================================================================

test "parseTrafficUnit: bytes" {
    try std.testing.expectEqual(@as(u64, 100), try parseTrafficUnit("100"));
    try std.testing.expectEqual(@as(u64, 0), try parseTrafficUnit("0"));
}

test "parseTrafficUnit: KB" {
    try std.testing.expectEqual(@as(u64, 1024), try parseTrafficUnit("1KB"));
    try std.testing.expectEqual(@as(u64, 1024), try parseTrafficUnit("1kb"));
    try std.testing.expectEqual(@as(u64, 5120), try parseTrafficUnit("5KB"));
}

test "parseTrafficUnit: MB" {
    try std.testing.expectEqual(@as(u64, 1048576), try parseTrafficUnit("1MB"));
    try std.testing.expectEqual(@as(u64, 1048576), try parseTrafficUnit("1mb"));
    try std.testing.expectEqual(@as(u64, 100 * 1048576), try parseTrafficUnit("100MB"));
}

test "parseTrafficUnit: GB" {
    const one_gb: u64 = 1024 * 1024 * 1024;
    try std.testing.expectEqual(one_gb, try parseTrafficUnit("1GB"));
    try std.testing.expectEqual(one_gb, try parseTrafficUnit("1gb"));
    try std.testing.expectEqual(100 * one_gb, try parseTrafficUnit("100GB"));
}

test "parseTrafficUnit: TB" {
    const one_tb: u64 = 1024 * 1024 * 1024 * 1024;
    try std.testing.expectEqual(one_tb, try parseTrafficUnit("1TB"));
    try std.testing.expectEqual(2 * one_tb, try parseTrafficUnit("2TB"));
}

test "parseTrafficUnit: invalid input" {
    try std.testing.expectError(QuotaError.InvalidUnit, parseTrafficUnit(""));
    try std.testing.expectError(QuotaError.InvalidUnit, parseTrafficUnit("GB"));
    try std.testing.expectError(QuotaError.InvalidUnit, parseTrafficUnit("abc"));
}

test "checkQuota: disabled when limit is 0" {
    const config = QuotaConfig{ .limit_bytes = 0 };
    try std.testing.expectEqual(QuotaState.disabled, checkQuota(config, 0));
    try std.testing.expectEqual(QuotaState.disabled, checkQuota(config, 999999));
}

test "checkQuota: normal below warning" {
    const config = QuotaConfig{
        .limit_bytes = 1000,
        .warning_threshold = 0.9,
        .disconnect_threshold = 1.0,
    };
    try std.testing.expectEqual(QuotaState.normal, checkQuota(config, 0));
    try std.testing.expectEqual(QuotaState.normal, checkQuota(config, 500));
    try std.testing.expectEqual(QuotaState.normal, checkQuota(config, 899));
}

test "checkQuota: warned at 90%" {
    const config = QuotaConfig{
        .limit_bytes = 1000,
        .warning_threshold = 0.9,
        .disconnect_threshold = 1.0,
    };
    try std.testing.expectEqual(QuotaState.warned, checkQuota(config, 900));
    try std.testing.expectEqual(QuotaState.warned, checkQuota(config, 950));
    try std.testing.expectEqual(QuotaState.warned, checkQuota(config, 999));
}

test "checkQuota: exceeded at 100%" {
    const config = QuotaConfig{
        .limit_bytes = 1000,
        .warning_threshold = 0.9,
        .disconnect_threshold = 1.0,
    };
    try std.testing.expectEqual(QuotaState.exceeded, checkQuota(config, 1000));
    try std.testing.expectEqual(QuotaState.exceeded, checkQuota(config, 1500));
}

test "checkQuota: custom thresholds" {
    const config = QuotaConfig{
        .limit_bytes = 1000,
        .warning_threshold = 0.5,
        .disconnect_threshold = 0.8,
    };
    try std.testing.expectEqual(QuotaState.normal, checkQuota(config, 499));
    try std.testing.expectEqual(QuotaState.warned, checkQuota(config, 500));
    try std.testing.expectEqual(QuotaState.warned, checkQuota(config, 799));
    try std.testing.expectEqual(QuotaState.exceeded, checkQuota(config, 800));
}

test "firstDayOfMonthEpochDay: 1970-01-01" {
    try std.testing.expectEqual(@as(u32, 0), firstDayOfMonthEpochDay(1970, 1));
}

test "firstDayOfMonthEpochDay: 2024-01-01" {
    // 54 years: 13 leap years (1972,76,80,84,88,92,96,2000,04,08,12,16,20)
    // 41 non-leap: 41*365 + 13*366 = 14965 + 4758 = 19723
    try std.testing.expectEqual(@as(u32, 19723), firstDayOfMonthEpochDay(2024, 1));
}

test "firstDayOfMonthEpochDay: 2024-03-01 (leap year)" {
    // 2024-01-01 = 19723, Jan=31, Feb=29 (leap)
    try std.testing.expectEqual(@as(u32, 19723 + 31 + 29), firstDayOfMonthEpochDay(2024, 3));
}

test "firstDayOfMonthEpochDay: 2023-03-01 (non-leap year)" {
    // 2023-01-01 = 19723 - 366 + 365 = 19722 (2024 is leap, so 2023 is 365 days)
    // Actually let me compute: 2024-01-01 = 19723, 2023-01-01 = 19723 - 366 = 19357 (2024 is leap year)
    // Wait, 2024 is a leap year, so the days from 2023-01-01 to 2024-01-01 is 365
    // 2023-01-01 = 19723 - 365 = 19358
    // 2023-03-01 = 19358 + 31 + 28 = 19417
    try std.testing.expectEqual(@as(u32, 19417), firstDayOfMonthEpochDay(2023, 3));
}

test "parseTrafficUnit: large values" {
    const one_tb: u64 = 1024 * 1024 * 1024 * 1024;
    try std.testing.expectEqual(5 * one_tb, try parseTrafficUnit("5TB"));
}

test "shouldRestore: returns true when day matches reset_day" {
    // 2024-01-01 00:00:00 UTC = 1704067200 seconds
    const epoch_secs: u64 = 1704067200;
    try std.testing.expect(shouldRestore(1, epoch_secs));
}

test "shouldRestore: returns false when day does not match" {
    // 2024-01-02 00:00:00 UTC = 1704153600 seconds
    const epoch_secs: u64 = 1704153600;
    try std.testing.expect(!shouldRestore(1, epoch_secs));
}

test "getDayOfMonth: returns correct day" {
    // 2024-01-15 12:00:00 UTC
    const epoch_secs: u64 = 1705320000;
    try std.testing.expectEqual(@as(u8, 15), getDayOfMonth(epoch_secs));
}
