// backend/tests/test_config_store.zig
// ConfigStore 模块的独立单元测试
// 测试 SQLite 配置存储的 CRUD 操作、类型序列化 round-trip 和 JSON 迁移
const std = @import("std");
const config_store = @import("config_store");

const ConfigStore = config_store.ConfigStore;
const Config = config_store.Config;
const zqlite = @import("zqlite");

/// 创建内存 SQLite 数据库并执行建表语句
fn createTestDb() !zqlite.Conn {
    var conn = try zqlite.open(":memory:", 0);
    errdefer conn.close();
    // 创建 config 表（与生产环境 SCHEMA 一致）
    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS config (
        \\  key TEXT PRIMARY KEY NOT NULL,
        \\  value TEXT NOT NULL
        \\)
    , .{});
    return conn;
}

// ── loadAll 测试 ──

test "loadAll: 空数据库返回默认 Config" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);
    const config = try store.loadAll();

    // 默认值验证
    try std.testing.expectEqual(@as(?[]const u8, null), config.interface);
    try std.testing.expectEqual(@as(u64, 1), config.interval_sec);
    try std.testing.expectEqual(false, config.daemon_mode);
    try std.testing.expectEqual(false, config.foreground);
    try std.testing.expectEqual(false, config.use_sqlite);
    try std.testing.expectEqual(@as(u32, 30), config.retention_days);
    try std.testing.expectEqual(@as(?[]const u8, null), config.log_file);
    try std.testing.expectEqual(@as(?[]const u8, null), config.pid_file);
    try std.testing.expectEqual(false, config.list_only);
    try std.testing.expectEqual(@as(u32, 0), config.day_count);
    try std.testing.expectEqual(@as(u64, 0), config.quota_limit_bytes);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), config.quota_warning_threshold, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), config.quota_disconnect_threshold, 0.001);
    try std.testing.expectEqual(@as(u8, 1), config.reset_day);
    try std.testing.expectEqual(@as(u8, 1), config.reset_day);
    try std.testing.expectEqual(@as(?[]const u8, null), config.webhook_url);
    try std.testing.expectEqual(@as(?[]const u8, null), config.smtp_server);
    try std.testing.expectEqual(@as(?[]const u8, null), config.smtp_port);
    try std.testing.expectEqual(@as(?[]const u8, null), config.smtp_user);
    try std.testing.expectEqual(@as(?[]const u8, null), config.smtp_pass);
    try std.testing.expectEqual(@as(?[]const u8, null), config.smtp_from);
    try std.testing.expectEqual(@as(?[]const u8, null), config.smtp_to);
}

// ── saveAll + loadAll round-trip 测试 ──

test "saveAll + loadAll: round-trip 保持配置一致" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    // 构造非默认配置
    var original = Config{};
    original.interface = try std.testing.allocator.dupe(u8, "eth0");
    defer std.testing.allocator.free(original.interface.?);
    original.interval_sec = 5;
    original.daemon_mode = true;
    original.foreground = false;
    original.use_sqlite = true;
    original.retention_days = 60;
    original.log_file = try std.testing.allocator.dupe(u8, "/var/log/test.log");
    defer std.testing.allocator.free(original.log_file.?);
    original.pid_file = try std.testing.allocator.dupe(u8, "/var/run/test.pid");
    defer std.testing.allocator.free(original.pid_file.?);
    original.list_only = true;
    original.day_count = 7;
    original.quota_limit_bytes = 107374182400; // 100GB
    original.quota_warning_threshold = 0.8;
    original.quota_disconnect_threshold = 0.95;
    original.reset_day = 15;
    original.webhook_url = try std.testing.allocator.dupe(u8, "https://hooks.example.com/test");
    defer std.testing.allocator.free(original.webhook_url.?);
    original.smtp_server = try std.testing.allocator.dupe(u8, "smtp.example.com");
    defer std.testing.allocator.free(original.smtp_server.?);
    original.smtp_port = try std.testing.allocator.dupe(u8, "587");
    defer std.testing.allocator.free(original.smtp_port.?);
    original.smtp_user = try std.testing.allocator.dupe(u8, "user@example.com");
    defer std.testing.allocator.free(original.smtp_user.?);
    original.smtp_pass = try std.testing.allocator.dupe(u8, "secret");
    defer std.testing.allocator.free(original.smtp_pass.?);
    original.smtp_from = try std.testing.allocator.dupe(u8, "from@example.com");
    defer std.testing.allocator.free(original.smtp_from.?);
    original.smtp_to = try std.testing.allocator.dupe(u8, "to@example.com");
    defer std.testing.allocator.free(original.smtp_to.?);

    // 保存
    try store.saveAll(original);

    // 加载并验证
    const loaded = try store.loadAll();
    defer std.testing.allocator.free(loaded.interface.?);
    defer std.testing.allocator.free(loaded.log_file.?);
    defer std.testing.allocator.free(loaded.pid_file.?);
    defer std.testing.allocator.free(loaded.webhook_url.?);
    defer std.testing.allocator.free(loaded.smtp_server.?);
    defer std.testing.allocator.free(loaded.smtp_port.?);
    defer std.testing.allocator.free(loaded.smtp_user.?);
    defer std.testing.allocator.free(loaded.smtp_pass.?);
    defer std.testing.allocator.free(loaded.smtp_from.?);
    defer std.testing.allocator.free(loaded.smtp_to.?);
    try std.testing.expectEqual(@as(u64, 5), loaded.interval_sec);
    try std.testing.expectEqual(true, loaded.daemon_mode);
    try std.testing.expectEqual(true, loaded.use_sqlite);
    try std.testing.expectEqual(@as(u32, 60), loaded.retention_days);
    try std.testing.expectEqual(true, loaded.list_only);
    try std.testing.expectEqual(@as(u32, 7), loaded.day_count);
    try std.testing.expectEqual(@as(u64, 107374182400), loaded.quota_limit_bytes);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), loaded.quota_warning_threshold, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), loaded.quota_disconnect_threshold, 0.001);
    try std.testing.expectEqual(@as(u8, 15), loaded.reset_day);
    try std.testing.expectEqual(@as(u8, 15), loaded.reset_day);

    // 字符串字段比较
    try std.testing.expectEqualStrings("eth0", loaded.interface.?);
    try std.testing.expectEqualStrings("/var/log/test.log", loaded.log_file.?);
    try std.testing.expectEqualStrings("/var/run/test.pid", loaded.pid_file.?);
    try std.testing.expectEqualStrings("https://hooks.example.com/test", loaded.webhook_url.?);
    try std.testing.expectEqualStrings("smtp.example.com", loaded.smtp_server.?);
    try std.testing.expectEqualStrings("587", loaded.smtp_port.?);
    try std.testing.expectEqualStrings("user@example.com", loaded.smtp_user.?);
    try std.testing.expectEqualStrings("secret", loaded.smtp_pass.?);
    try std.testing.expectEqualStrings("from@example.com", loaded.smtp_from.?);
    try std.testing.expectEqualStrings("to@example.com", loaded.smtp_to.?);
}

// ── get/set 单个配置项测试 ──

test "get/set: 单个配置项读写" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    // set 一个值
    try store.set("interval_sec", "10");

    // get 验证
    const val = try store.get("interval_sec");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("10", val.?);
    std.testing.allocator.free(val.?);

    // get 不存在的键
    const missing = try store.get("nonexistent");
    try std.testing.expectEqual(@as(?[]const u8, null), missing);
}

test "get/set: INSERT OR REPLACE 覆盖已有值" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    try store.set("interval_sec", "5");
    try store.set("interval_sec", "15");

    const val = try store.get("interval_sec");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("15", val.?);
    std.testing.allocator.free(val.?);
}

// ── 类型序列化 round-trip 测试 ──

test "类型序列化: bool round-trip" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    // 保存一个包含各种 bool 的配置
    var config = Config{};
    config.daemon_mode = true;
    config.foreground = false;
    config.use_sqlite = true;
    config.list_only = false;

    try store.saveAll(config);

    const loaded = try store.loadAll();
    try std.testing.expectEqual(true, loaded.daemon_mode);
    try std.testing.expectEqual(false, loaded.foreground);
    try std.testing.expectEqual(true, loaded.use_sqlite);
    try std.testing.expectEqual(false, loaded.list_only);
}

test "类型序列化: u64 round-trip" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    var config = Config{};
    config.interval_sec = 42;
    config.quota_limit_bytes = 107374182400; // 100GB

    try store.saveAll(config);

    const loaded = try store.loadAll();
    try std.testing.expectEqual(@as(u64, 42), loaded.interval_sec);
    try std.testing.expectEqual(@as(u64, 107374182400), loaded.quota_limit_bytes);
}

test "类型序列化: f64 round-trip" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    var config = Config{};
    config.quota_warning_threshold = 0.85;
    config.quota_disconnect_threshold = 0.95;

    try store.saveAll(config);

    const loaded = try store.loadAll();
    try std.testing.expectApproxEqAbs(@as(f64, 0.85), loaded.quota_warning_threshold, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), loaded.quota_disconnect_threshold, 0.001);
}

test "类型序列化: null 字符串 round-trip（null → 空字符串 → null）" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    // 默认配置的字符串字段均为 null
    const config = Config{};
    try store.saveAll(config);

    const loaded = try store.loadAll();
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.interface);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.log_file);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.pid_file);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.webhook_url);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.smtp_server);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.smtp_port);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.smtp_user);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.smtp_pass);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.smtp_from);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.smtp_to);
}

test "类型序列化: 非 null 字符串 round-trip" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    var config = Config{};
    config.interface = try std.testing.allocator.dupe(u8, "wlan0");
    defer std.testing.allocator.free(config.interface.?);
    config.log_file = try std.testing.allocator.dupe(u8, "/tmp/log.txt");
    defer std.testing.allocator.free(config.log_file.?);

    try store.saveAll(config);

    const loaded = try store.loadAll();
    defer std.testing.allocator.free(loaded.interface.?);
    defer std.testing.allocator.free(loaded.log_file.?);
    try std.testing.expect(loaded.interface != null);
    try std.testing.expectEqualStrings("wlan0", loaded.interface.?);
    try std.testing.expect(loaded.log_file != null);
    try std.testing.expectEqualStrings("/tmp/log.txt", loaded.log_file.?);
}

// ── u32/u8 类型序列化 ──

test "类型序列化: u32 round-trip" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    var config = Config{};
    config.retention_days = 90;
    config.day_count = 3;

    try store.saveAll(config);

    const loaded = try store.loadAll();
    try std.testing.expectEqual(@as(u32, 90), loaded.retention_days);
    try std.testing.expectEqual(@as(u32, 3), loaded.day_count);
}

test "类型序列化: u8 round-trip" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    var config = Config{};
    config.reset_day = 14;

    try store.saveAll(config);

    const loaded = try store.loadAll();
    try std.testing.expectEqual(@as(u8, 14), loaded.reset_day);
}

// ── saveAll 覆盖行为测试 ──

test "saveAll: 覆盖已有配置" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    // 第一次保存
    var config1 = Config{};
    config1.interval_sec = 5;
    try store.saveAll(config1);

    // 第二次保存（覆盖）
    var config2 = Config{};
    config2.interval_sec = 10;
    config2.retention_days = 60;
    try store.saveAll(config2);

    const loaded = try store.loadAll();
    try std.testing.expectEqual(@as(u64, 10), loaded.interval_sec);
    try std.testing.expectEqual(@as(u32, 60), loaded.retention_days);
}

// ── 特殊字符键值测试 ──

test "get/set: 特殊字符值" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    // 包含中文、空格、特殊字符
    const test_value = "运营商赠送 500MB 🎉";
    try store.set("reason", test_value);

    const val = try store.get("reason");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings(test_value, val.?);
    std.testing.allocator.free(val.?);
}

// ── 忽略未知键（前向兼容） ──

test "loadAll: 忽略未知键不影响已知配置" {
    var conn = try createTestDb();
    defer conn.close();

    const store = ConfigStore.init(&conn, std.testing.allocator);

    // 手动插入一个未知键
    try conn.exec(
        "INSERT INTO config (key, value) VALUES (?1, ?2)",
        .{ "future_feature", "some_value" },
    );
    // 同时插入一个已知键
    try conn.exec(
        "INSERT INTO config (key, value) VALUES (?1, ?2)",
        .{ "interval_sec", "25" },
    );

    const loaded = try store.loadAll();
    // 已知键正常加载
    try std.testing.expectEqual(@as(u64, 25), loaded.interval_sec);
    // 默认值不受未知键影响
    try std.testing.expectEqual(false, loaded.daemon_mode);
}
