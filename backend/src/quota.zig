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

// 共享工具模块：流量单位解析（parseTrafficUnit）已迁至 common.zig，此处仅 re-export，
// 对外符号与错误行为保持不变，main.zig 与既有测试无需改动。
pub const common = @import("common.zig");
pub const parseTrafficUnit = common.parseTrafficUnit;

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

/// 查询预算周期内的流量总量（rx + tx 字节）自 SQLite daily_traffic 表。
/// period_start_epoch_day 为周期起始日的 epoch day 号（语义从「自然月 1 号」变为
/// 「滚动窗口周期起始日」，由 computePeriod 计算）。daily_traffic 只记录到「今天」、
/// 无未来数据，故 `WHERE date >= ?1` 即等价于「周期内总流量」，无需上界。
/// 返回 0 若无数据。
pub fn getMonthlyTraffic(conn: *zqlite.Conn, period_start_epoch_day: i64) QuotaError!u64 {
    const row = conn.row(
        \\SELECT COALESCE(SUM(total_rx_bytes + total_tx_bytes), 0)
        \\FROM daily_traffic
        \\WHERE date >= ?1
    , .{period_start_epoch_day}) catch return QuotaError.QueryFailed;
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

/// 预算周期信息：滚动窗口的起始日与起始日所在自然月。
pub const PeriodInfo = struct {
    /// 周期起始日的 epoch day 号
    start_epoch_day: u32,
    /// 周期起始日所在自然年（用于 month_key）
    year: u32,
    /// 周期起始日所在自然月（用于 month_key）
    month: u32,
};

/// 计算滚动预算周期的起始日：重置日到下一个重置日前一天为一个周期（周期起始用量归零）。
/// day >= reset_day → 周期起始于本月 reset_day 号；day < reset_day → 回退到上月 reset_day 号。
pub fn computePeriod(reset_day: u8, year: u32, month: u32, day: u32) PeriodInfo {
    var period_year = year;
    var period_month = month;

    // day 未到重置日，周期起始于上月 reset_day 号
    if (day < reset_day) {
        // u32 无符号运算：month==1 时回退到上年 12 月，避免 month-1 下溢为 0
        if (month == 1) {
            period_year = year - 1;
            period_month = 12;
        } else {
            period_month = month - 1;
        }
    }

    // 周期起始 epoch day = 起始月 1 号 + (reset_day - 1)
    const start_epoch_day = firstDayOfMonthEpochDay(period_year, period_month) + @as(u32, reset_day) - 1;

    return .{
        .start_epoch_day = start_epoch_day,
        .year = period_year,
        .month = period_month,
    };
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

// ── 配额调整 CRUD ──

/// 配额调整记录：对月度配额的手动增减
pub const QuotaAdjustment = struct {
    /// 自增主键 ID
    id: i64,
    /// 调整字节数（正数增加配额，负数减少配额）
    amount_bytes: u64,
    /// 调整原因描述
    reason: []const u8,
    /// 调整来源（如 "manual"、"api"）
    source: []const u8,
    /// 月份键，格式 "YYYY-MM"（如 "2026-08"）
    month_key: []const u8,
    /// 创建时间（epoch 毫秒）
    created_at: i64,
};

/// 添加配额调整记录，返回含自增 id 的完整记录
pub fn addAdjustment(
    _: Allocator,
    conn: *zqlite.Conn,
    amount_bytes: u64,
    reason: []const u8,
    source: []const u8,
    month_key: []const u8,
    created_at: i64,
) QuotaError!QuotaAdjustment {
    conn.exec(
        \\INSERT INTO quota_adjustments (amount_bytes, reason, source, month_key, created_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
    , .{
        @as(i64, @bitCast(amount_bytes)),
        reason,
        source,
        month_key,
        created_at,
    }) catch return QuotaError.QueryFailed;

    // 获取刚插入的记录 id
    const row = conn.row(
        "SELECT last_insert_rowid()",
        .{},
    ) catch return QuotaError.QueryFailed;
    const id: i64 = if (row) |r| blk: {
        defer r.deinit();
        break :blk r.int(0);
    } else 0;

    return .{
        .id = id,
        .amount_bytes = amount_bytes,
        .reason = reason,
        .source = source,
        .month_key = month_key,
        .created_at = created_at,
    };
}

/// 删除指定 id 的配额调整记录
pub fn removeAdjustment(conn: *zqlite.Conn, id: i64) QuotaError!void {
    conn.exec(
        "DELETE FROM quota_adjustments WHERE id = ?1",
        .{id},
    ) catch return QuotaError.QueryFailed;
}

/// 列出指定月份的所有配额调整记录
pub fn listAdjustments(
    allocator: Allocator,
    conn: *zqlite.Conn,
    month_key: []const u8,
) QuotaError![]QuotaAdjustment {
    var result_list: std.ArrayList(QuotaAdjustment) = .empty;
    errdefer result_list.deinit(allocator);

    var rows = conn.rows(
        "SELECT id, amount_bytes, reason, source, month_key, created_at FROM quota_adjustments WHERE month_key = ?1 ORDER BY created_at",
        .{month_key},
    ) catch return QuotaError.QueryFailed;
    defer rows.deinit();

    while (rows.next()) |row| {
        const reason_text = row.text(2);
        const source_text = row.text(3);
        const mk_text = row.text(4);

        result_list.append(allocator, .{
            .id = row.int(0),
            .amount_bytes = @bitCast(row.int(1)),
            .reason = try allocator.dupe(u8, reason_text),
            .source = try allocator.dupe(u8, source_text),
            .month_key = try allocator.dupe(u8, mk_text),
            .created_at = row.int(5),
        }) catch return QuotaError.OutOfMemory;
    }
    if (rows.err) |_| return QuotaError.QueryFailed;

    return result_list.toOwnedSlice(allocator) catch return QuotaError.OutOfMemory;
}

/// 获取指定月份所有调整的字节总和（正数相加，负数相减）
pub fn getAdjustmentTotal(conn: *zqlite.Conn, month_key: []const u8) QuotaError!u64 {
    const row = conn.row(
        "SELECT COALESCE(SUM(amount_bytes), 0) FROM quota_adjustments WHERE month_key = ?1",
        .{month_key},
    ) catch return QuotaError.QueryFailed;
    if (row) |r| {
        defer r.deinit();
        return @intCast(r.int(0));
    }
    return 0;
}

/// 获取当月有效配额 = 基础配额 + 当月所有调整之和
pub fn getEffectiveMonthlyQuota(
    conn: *zqlite.Conn,
    limit_bytes: u64,
    month_key: []const u8,
) QuotaError!u64 {
    const adjustment_total = try getAdjustmentTotal(conn, month_key);
    return std.math.add(u64, limit_bytes, adjustment_total) catch 0;
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

test "computePeriod: day >= reset_day → this month" {
    // reset_day=15，2026-08-20 >= 15 → 周期起始于本月 2026-08-15
    const period = computePeriod(15, 2026, 8, 20);
    try std.testing.expectEqual(firstDayOfMonthEpochDay(2026, 8) + 14, period.start_epoch_day);
    try std.testing.expectEqual(@as(u32, 2026), period.year);
    try std.testing.expectEqual(@as(u32, 8), period.month);
}

test "computePeriod: day < reset_day → last month" {
    // reset_day=15，2026-08-10 < 15 → 回退到上月周期起始 2026-07-15
    const period = computePeriod(15, 2026, 8, 10);
    try std.testing.expectEqual(firstDayOfMonthEpochDay(2026, 7) + 14, period.start_epoch_day);
    try std.testing.expectEqual(@as(u32, 2026), period.year);
    try std.testing.expectEqual(@as(u32, 7), period.month);
}

test "computePeriod: January rollback" {
    // reset_day=5，2026-01-03 < 5 且 month==1 → 跨年回退到上年 12 月周期起始 2025-12-05
    const period = computePeriod(5, 2026, 1, 3);
    try std.testing.expectEqual(firstDayOfMonthEpochDay(2025, 12) + 4, period.start_epoch_day);
    try std.testing.expectEqual(@as(u32, 2025), period.year);
    try std.testing.expectEqual(@as(u32, 12), period.month);
}

test "computePeriod: day == reset_day → this month" {
    // 边界：day 恰好等于 reset_day，归属本月周期（不是回退）
    const period = computePeriod(15, 2026, 8, 15);
    try std.testing.expectEqual(firstDayOfMonthEpochDay(2026, 8) + 14, period.start_epoch_day);
    try std.testing.expectEqual(@as(u32, 2026), period.year);
    try std.testing.expectEqual(@as(u32, 8), period.month);
}

test "computePeriod: reset_day=1 degenerates to natural month" {
    // reset_day=1 时周期起始即自然月 1 号（退化情形）
    const period = computePeriod(1, 2026, 8, 20);
    try std.testing.expectEqual(firstDayOfMonthEpochDay(2026, 8), period.start_epoch_day);
    try std.testing.expectEqual(@as(u32, 2026), period.year);
    try std.testing.expectEqual(@as(u32, 8), period.month);
}

test "computePeriod: February cross-month" {
    // reset_day=28，2026-03-01 < 28 → 回退到 2 月末周期起始 2026-02-28
    const period = computePeriod(28, 2026, 3, 1);
    try std.testing.expectEqual(firstDayOfMonthEpochDay(2026, 2) + 27, period.start_epoch_day);
    try std.testing.expectEqual(@as(u32, 2026), period.year);
    try std.testing.expectEqual(@as(u32, 2), period.month);
}
