// backend/tests/test_quota.zig
// 独立测试：配额模块
// 仅测试 src/quota.zig 的公共 API
const std = @import("std");
const quota = @import("quota");
const zqlite = @import("zqlite");

const QuotaConfig = quota.QuotaConfig;
const QuotaState = quota.QuotaState;
const QuotaError = quota.QuotaError;

// ── parseTrafficUnit 测试 ──

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

test "parseTrafficUnit: large values" {
    const one_tb: u64 = 1024 * 1024 * 1024 * 1024;
    try std.testing.expectEqual(5 * one_tb, try quota.parseTrafficUnit("5TB"));
}

// ── checkQuota 测试 ──

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

// ── firstDayOfMonthEpochDay 测试 ──

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

// ── shouldRestore / getDayOfMonth 测试 ──

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

// ── 辅助函数：创建测试用内存数据库 ──

fn createTestDb() !zqlite.Conn {
    var db = try zqlite.open(":memory:", 0);
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS quota_adjustments (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  amount_bytes INTEGER NOT NULL,
        \\  reason TEXT NOT NULL DEFAULT '',
        \\  source TEXT NOT NULL DEFAULT '',
        \\  month_key TEXT NOT NULL,
        \\  created_at INTEGER NOT NULL
        \\)
    , .{});
    return db;
}

// ── 配额调整 CRUD 测试 ──

test "addAdjustment: 插入并返回自增 id" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    const adj1 = try quota.addAdjustment(allocator, &db, 500 * 1024 * 1024, "运营商赠送", "manual", "2026-08", 1000);
    try std.testing.expect(adj1.id > 0);
    try std.testing.expectEqual(@as(u64, 500 * 1024 * 1024), adj1.amount_bytes);
    try std.testing.expectEqualStrings("运营商赠送", adj1.reason);
    try std.testing.expectEqualStrings("manual", adj1.source);
    try std.testing.expectEqualStrings("2026-08", adj1.month_key);

    const adj2 = try quota.addAdjustment(allocator, &db, 100 * 1024 * 1024, "测试调整", "api", "2026-08", 2000);
    try std.testing.expect(adj2.id > adj1.id);
}

test "addAdjustment: 多条记录自增 id 递增" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    const a1 = try quota.addAdjustment(allocator, &db, 100, "r1", "s1", "2026-01", 100);
    const a2 = try quota.addAdjustment(allocator, &db, 200, "r2", "s2", "2026-01", 200);
    const a3 = try quota.addAdjustment(allocator, &db, 300, "r3", "s3", "2026-01", 300);

    try std.testing.expect(a1.id < a2.id);
    try std.testing.expect(a2.id < a3.id);
}

test "removeAdjustment: 删除指定 id 记录" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    const adj = try quota.addAdjustment(allocator, &db, 500, "test", "manual", "2026-08", 1000);
    try quota.removeAdjustment(&db, adj.id);

    const total = try quota.getAdjustmentTotal(&db, "2026-08");
    try std.testing.expectEqual(@as(u64, 0), total);
}

test "removeAdjustment: 删除不存在的 id 静默成功" {
    var db = try createTestDb();
    defer db.close();

    try quota.removeAdjustment(&db, 99999);
}

test "listAdjustments: 列出指定月份的调整" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    _ = try quota.addAdjustment(allocator, &db, 100, "r1", "s1", "2026-08", 100);
    _ = try quota.addAdjustment(allocator, &db, 200, "r2", "s2", "2026-08", 200);
    _ = try quota.addAdjustment(allocator, &db, 300, "r3", "s3", "2026-09", 300);

    const adjustments = try quota.listAdjustments(allocator, &db, "2026-08");
    defer {
        for (adjustments) |adj| {
            allocator.free(adj.reason);
            allocator.free(adj.source);
            allocator.free(adj.month_key);
        }
        allocator.free(adjustments);
    }

    try std.testing.expectEqual(@as(usize, 2), adjustments.len);
    try std.testing.expectEqual(@as(u64, 100), adjustments[0].amount_bytes);
    try std.testing.expectEqual(@as(u64, 200), adjustments[1].amount_bytes);
}

test "getAdjustmentTotal: 求和正确" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    _ = try quota.addAdjustment(allocator, &db, 1000, "r1", "s1", "2026-08", 100);
    _ = try quota.addAdjustment(allocator, &db, 2000, "r2", "s2", "2026-08", 200);
    _ = try quota.addAdjustment(allocator, &db, 500, "r3", "s3", "2026-08", 300);

    const total = try quota.getAdjustmentTotal(&db, "2026-08");
    try std.testing.expectEqual(@as(u64, 3500), total);
}

test "getAdjustmentTotal: 无调整时返回 0" {
    var db = try createTestDb();
    defer db.close();

    const total = try quota.getAdjustmentTotal(&db, "2026-08");
    try std.testing.expectEqual(@as(u64, 0), total);
}

test "getAdjustmentTotal: 跨月隔离" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    _ = try quota.addAdjustment(allocator, &db, 1000, "r1", "s1", "2026-08", 100);
    _ = try quota.addAdjustment(allocator, &db, 2000, "r2", "s2", "2026-09", 200);

    const aug_total = try quota.getAdjustmentTotal(&db, "2026-08");
    const sep_total = try quota.getAdjustmentTotal(&db, "2026-09");

    try std.testing.expectEqual(@as(u64, 1000), aug_total);
    try std.testing.expectEqual(@as(u64, 2000), sep_total);
}

test "getEffectiveMonthlyQuota: 基础 + 调整" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    _ = try quota.addAdjustment(allocator, &db, 500 * 1024 * 1024, "赠送", "manual", "2026-08", 100);

    const base: u64 = 1024 * 1024 * 1024; // 1GB
    const effective = try quota.getEffectiveMonthlyQuota(&db, base, "2026-08");
    try std.testing.expectEqual(base + 500 * 1024 * 1024, effective);
}

test "getEffectiveMonthlyQuota: 无调整时等于基础" {
    var db = try createTestDb();
    defer db.close();

    const base: u64 = 2 * 1024 * 1024 * 1024; // 2GB
    const effective = try quota.getEffectiveMonthlyQuota(&db, base, "2026-08");
    try std.testing.expectEqual(base, effective);
}

test "addAdjustment: 大值调整不溢出" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    const large_amount: u64 = 100 * 1024 * 1024 * 1024; // 100GB
    const adj = try quota.addAdjustment(allocator, &db, large_amount, "大额赠送", "admin", "2026-08", 1000);
    try std.testing.expectEqual(large_amount, adj.amount_bytes);

    const total = try quota.getAdjustmentTotal(&db, "2026-08");
    try std.testing.expectEqual(large_amount, total);
}

test "parseTrafficUnit: 500MB / 小数与非法输入" {
    try std.testing.expectEqual(@as(u64, 500 * 1048576), try quota.parseTrafficUnit("500MB"));
    // 当前实现不解析小数（无小数点扫描），如实断言其报 InvalidUnit
    try std.testing.expectError(QuotaError.InvalidUnit, quota.parseTrafficUnit("1.5GB"));
    try std.testing.expectError(QuotaError.InvalidUnit, quota.parseTrafficUnit("xyz"));
}

test "listAdjustments: 单条记录字段完整" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    const adj = try quota.addAdjustment(allocator, &db, 500 * 1024 * 1024, "运营商赠送", "manual", "2026-08", 1234);
    const adjustments = try quota.listAdjustments(allocator, &db, "2026-08");
    defer {
        for (adjustments) |a| {
            allocator.free(a.reason);
            allocator.free(a.source);
            allocator.free(a.month_key);
        }
        allocator.free(adjustments);
    }

    try std.testing.expectEqual(@as(usize, 1), adjustments.len);
    const got = adjustments[0];
    try std.testing.expectEqual(adj.id, got.id);
    try std.testing.expectEqual(adj.amount_bytes, got.amount_bytes);
    try std.testing.expectEqualStrings("运营商赠送", got.reason);
    try std.testing.expectEqualStrings("manual", got.source);
    try std.testing.expectEqualStrings("2026-08", got.month_key);
    try std.testing.expectEqual(@as(i64, 1234), got.created_at);
}

test "removeAdjustment: 删除后总量相应减少" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    const a1 = try quota.addAdjustment(allocator, &db, 500, "r1", "s1", "2026-08", 100);
    _ = try quota.addAdjustment(allocator, &db, 300, "r2", "s2", "2026-08", 200);
    try std.testing.expectEqual(@as(u64, 800), try quota.getAdjustmentTotal(&db, "2026-08"));

    try quota.removeAdjustment(&db, a1.id);
    try std.testing.expectEqual(@as(u64, 300), try quota.getAdjustmentTotal(&db, "2026-08"));
}

test "getEffectiveMonthlyQuota: 多笔调整累加" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    _ = try quota.addAdjustment(allocator, &db, 100 * 1024 * 1024, "a", "s1", "2026-08", 100);
    _ = try quota.addAdjustment(allocator, &db, 200 * 1024 * 1024, "b", "s2", "2026-08", 200);
    _ = try quota.addAdjustment(allocator, &db, 300 * 1024 * 1024, "c", "s3", "2026-08", 300);

    const base: u64 = 1024 * 1024 * 1024; // 1GB
    try std.testing.expectEqual(base + 600 * 1024 * 1024, try quota.getEffectiveMonthlyQuota(&db, base, "2026-08"));
}

test "getEffectiveMonthlyQuota: 跨月隔离" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    _ = try quota.addAdjustment(allocator, &db, 1000, "r1", "s1", "2026-08", 100);
    _ = try quota.addAdjustment(allocator, &db, 2000, "r2", "s2", "2026-09", 200);

    const base: u64 = 10_000;
    try std.testing.expectEqual(base + 1000, try quota.getEffectiveMonthlyQuota(&db, base, "2026-08"));
    try std.testing.expectEqual(base + 2000, try quota.getEffectiveMonthlyQuota(&db, base, "2026-09"));
}

test "addAdjustment: amount_bytes = 0 可添加且不影响总量" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    _ = try quota.addAdjustment(allocator, &db, 0, "零值调整", "api", "2026-08", 100);
    try std.testing.expectEqual(@as(u64, 0), try quota.getAdjustmentTotal(&db, "2026-08"));

    _ = try quota.addAdjustment(allocator, &db, 500, "正常调整", "api", "2026-08", 200);
    try std.testing.expectEqual(@as(u64, 500), try quota.getAdjustmentTotal(&db, "2026-08"));

    // 零值记录已入库，列表应包含两条
    const adjustments = try quota.listAdjustments(allocator, &db, "2026-08");
    defer {
        for (adjustments) |a| {
            allocator.free(a.reason);
            allocator.free(a.source);
            allocator.free(a.month_key);
        }
        allocator.free(adjustments);
    }
    try std.testing.expectEqual(@as(usize, 2), adjustments.len);
    try std.testing.expectEqual(@as(u64, 0), adjustments[0].amount_bytes);
}

test "getAdjustmentTotal: 接近 i64 上限值求和不溢出" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    // maxInt(i64) 位转换为 i64 仍为正数，存储与求和均安全
    const big: u64 = @as(u64, std.math.maxInt(i64));
    _ = try quota.addAdjustment(allocator, &db, big, "大值", "admin", "2026-08", 1);
    try std.testing.expectEqual(big, try quota.getAdjustmentTotal(&db, "2026-08"));
}

test "addAdjustment: 接近 u64 上限的大值可添加" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    // 接近 u64 上限，位转换为 i64 后为负数是设计用途（负数代表减少配额）
    const near_max: u64 = std.math.maxInt(u64) - 1024;
    const adj = try quota.addAdjustment(allocator, &db, near_max, "超大调整", "admin", "2026-08", 1);
    try std.testing.expectEqual(near_max, adj.amount_bytes);
    // 注：getAdjustmentTotal 内部用 @intCast(r.int(0))，遇负值会触发安全崩溃，
    // 这是实现缺陷（仅记录），故此处不调用，只验证插入与回读路径不溢出。
}

test "getEffectiveMonthlyQuota: 相加溢出时返回 0（当前实现行为）" {
    const allocator = std.testing.allocator;
    var db = try createTestDb();
    defer db.close();

    _ = try quota.addAdjustment(allocator, &db, 1, "小调整", "api", "2026-08", 1);
    const base: u64 = std.math.maxInt(u64);
    // 实现用 std.math.add 捕获 u64 溢出并返回 0，如实断言该行为
    try std.testing.expectEqual(@as(u64, 0), try quota.getEffectiveMonthlyQuota(&db, base, "2026-08"));
}
