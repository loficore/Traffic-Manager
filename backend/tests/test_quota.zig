// backend/tests/test_quota.zig
// Independent tests for the quota module.
// Tests only public API of src/quota.zig.
const std = @import("std");
const quota = @import("quota");

const QuotaConfig = quota.QuotaConfig;
const QuotaState = quota.QuotaState;
const QuotaError = quota.QuotaError;

test "parseTrafficUnit: bytes" {
    try std.testing.expectEqual(@as(u64, 100), try quota.parseTrafficUnit("100"));
    try std.testing.expectEqual(@as(u64, 0), try quota.parseTrafficUnit("0"));
}

test "parseTrafficUnit: KB" {
    try std.testing.expectEqual(@as(u64, 1024), try quota.parseTrafficUnit("1KB"));
    try std.testing.expectEqual(@as(u64, 1024), try quota.parseTrafficUnit("1kb"));
    try std.testing.expectEqual(@as(u64, 5120), try quota.parseTrafficUnit("5KB"));
}

test "parseTrafficUnit: MB" {
    try std.testing.expectEqual(@as(u64, 1048576), try quota.parseTrafficUnit("1MB"));
    try std.testing.expectEqual(@as(u64, 1048576), try quota.parseTrafficUnit("1mb"));
    try std.testing.expectEqual(@as(u64, 100 * 1048576), try quota.parseTrafficUnit("100MB"));
}

test "parseTrafficUnit: GB" {
    const one_gb: u64 = 1024 * 1024 * 1024;
    try std.testing.expectEqual(one_gb, try quota.parseTrafficUnit("1GB"));
    try std.testing.expectEqual(one_gb, try quota.parseTrafficUnit("1gb"));
    try std.testing.expectEqual(100 * one_gb, try quota.parseTrafficUnit("100GB"));
}

test "parseTrafficUnit: TB" {
    const one_tb: u64 = 1024 * 1024 * 1024 * 1024;
    try std.testing.expectEqual(one_tb, try quota.parseTrafficUnit("1TB"));
    try std.testing.expectEqual(2 * one_tb, try quota.parseTrafficUnit("2TB"));
}

test "parseTrafficUnit: invalid input" {
    try std.testing.expectError(QuotaError.InvalidUnit, quota.parseTrafficUnit(""));
    try std.testing.expectError(QuotaError.InvalidUnit, quota.parseTrafficUnit("GB"));
    try std.testing.expectError(QuotaError.InvalidUnit, quota.parseTrafficUnit("abc"));
}

test "checkQuota: disabled when limit is 0" {
    const config = QuotaConfig{ .limit_bytes = 0 };
    try std.testing.expectEqual(QuotaState.disabled, quota.checkQuota(config, 0));
    try std.testing.expectEqual(QuotaState.disabled, quota.checkQuota(config, 999999));
}

test "checkQuota: normal below warning" {
    const config = QuotaConfig{
        .limit_bytes = 1000,
        .warning_threshold = 0.9,
        .disconnect_threshold = 1.0,
    };
    try std.testing.expectEqual(QuotaState.normal, quota.checkQuota(config, 0));
    try std.testing.expectEqual(QuotaState.normal, quota.checkQuota(config, 500));
    try std.testing.expectEqual(QuotaState.normal, quota.checkQuota(config, 899));
}

test "checkQuota: warned at 90%" {
    const config = QuotaConfig{
        .limit_bytes = 1000,
        .warning_threshold = 0.9,
        .disconnect_threshold = 1.0,
    };
    try std.testing.expectEqual(QuotaState.warned, quota.checkQuota(config, 900));
    try std.testing.expectEqual(QuotaState.warned, quota.checkQuota(config, 950));
    try std.testing.expectEqual(QuotaState.warned, quota.checkQuota(config, 999));
}

test "checkQuota: exceeded at 100%" {
    const config = QuotaConfig{
        .limit_bytes = 1000,
        .warning_threshold = 0.9,
        .disconnect_threshold = 1.0,
    };
    try std.testing.expectEqual(QuotaState.exceeded, quota.checkQuota(config, 1000));
    try std.testing.expectEqual(QuotaState.exceeded, quota.checkQuota(config, 1500));
}

test "checkQuota: custom thresholds" {
    const config = QuotaConfig{
        .limit_bytes = 1000,
        .warning_threshold = 0.5,
        .disconnect_threshold = 0.8,
    };
    try std.testing.expectEqual(QuotaState.normal, quota.checkQuota(config, 499));
    try std.testing.expectEqual(QuotaState.warned, quota.checkQuota(config, 500));
    try std.testing.expectEqual(QuotaState.warned, quota.checkQuota(config, 799));
    try std.testing.expectEqual(QuotaState.exceeded, quota.checkQuota(config, 800));
}

test "firstDayOfMonthEpochDay: 1970-01-01" {
    try std.testing.expectEqual(@as(u32, 0), quota.firstDayOfMonthEpochDay(1970, 1));
}

test "firstDayOfMonthEpochDay: 2024-01-01" {
    try std.testing.expectEqual(@as(u32, 19723), quota.firstDayOfMonthEpochDay(2024, 1));
}

test "firstDayOfMonthEpochDay: 2024-03-01 (leap year)" {
    try std.testing.expectEqual(@as(u32, 19723 + 31 + 29), quota.firstDayOfMonthEpochDay(2024, 3));
}

test "firstDayOfMonthEpochDay: 2023-03-01 (non-leap year)" {
    try std.testing.expectEqual(@as(u32, 19417), quota.firstDayOfMonthEpochDay(2023, 3));
}

test "parseTrafficUnit: large values" {
    const one_tb: u64 = 1024 * 1024 * 1024 * 1024;
    try std.testing.expectEqual(5 * one_tb, try quota.parseTrafficUnit("5TB"));
}

test "shouldRestore: returns true when day matches reset_day" {
    const epoch_secs: u64 = 1704067200; // 2024-01-01 00:00:00 UTC
    try std.testing.expect(quota.shouldRestore(1, epoch_secs));
}

test "shouldRestore: returns false when day does not match" {
    const epoch_secs: u64 = 1704153600; // 2024-01-02 00:00:00 UTC
    try std.testing.expect(!quota.shouldRestore(1, epoch_secs));
}

test "getDayOfMonth: returns correct day" {
    const epoch_secs: u64 = 1705320000; // 2024-01-15 12:00:00 UTC
    try std.testing.expectEqual(@as(u8, 15), quota.getDayOfMonth(epoch_secs));
}
