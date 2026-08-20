// backend/tests/test_integration.zig
// 集成测试：覆盖配置存储层（ConfigStore）与配额调整层（quota）。
// 这两层在 test_http_server.zig 的纯 HTTP 测试之外，需要直接的 SQLite round-trip 验证，
// 包括 ConfigStore 的 save/load 完整还原、单键读写，以及从 JSON 配置文件迁移到 SQLite；
// 以及 quota 模块的增加/列举/累计/有效配额计算与删除。
const std = @import("std");
const zqlite = @import("zqlite");
const config_store = @import("config_store");
const quota = @import("quota");

const Io = std.Io;

const CONFIG_SCHEMA =
    \\CREATE TABLE IF NOT EXISTS config (
    \\    key TEXT PRIMARY KEY,
    \\    value TEXT NOT NULL
    \\);
;

const ADJ_SCHEMA =
    \\CREATE TABLE IF NOT EXISTS quota_adjustments (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    amount_bytes INTEGER NOT NULL,
    \\    reason TEXT NOT NULL DEFAULT '',
    \\    source TEXT NOT NULL DEFAULT '',
    \\    month_key TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL
    \\);
;

test "ConfigStore.saveAll 后 loadAll 可完整还原配置" {
    const alloc = std.testing.allocator;
    var conn = try zqlite.open(":memory:", 0);
    defer conn.close();
    try conn.execNoArgs(CONFIG_SCHEMA);

    const store = config_store.ConfigStore.init(&conn, alloc);
    var cfg = config_store.Config{};
    cfg.interface = try alloc.dupe(u8, "eth0");
    defer alloc.free(cfg.interface.?);
    cfg.interval_sec = 5;
    cfg.retention_days = 60;
    cfg.quota_limit_bytes = 1024 * 1024 * 1024;
    cfg.quota_warning_threshold = 0.85;
    cfg.quota_disconnect_threshold = 1.0;
    // smtp_port 保持 null，避免 deinitConfig 未覆盖的字段泄漏
    try store.saveAll(cfg);

    const loaded = try store.loadAll();
    defer config_store.deinitConfig(alloc, &loaded);
    try std.testing.expectEqualStrings("eth0", loaded.interface.?);
    try std.testing.expectEqual(@as(u64, 5), loaded.interval_sec);
    try std.testing.expectEqual(@as(u32, 60), loaded.retention_days);
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), loaded.quota_limit_bytes);
    try std.testing.expectApproxEqAbs(@as(f64, 0.85), loaded.quota_warning_threshold, 1e-9);
}

test "ConfigStore.set/get 单键读写" {
    const alloc = std.testing.allocator;
    var conn = try zqlite.open(":memory:", 0);
    defer conn.close();
    try conn.execNoArgs(CONFIG_SCHEMA);

    const store = config_store.ConfigStore.init(&conn, alloc);
    try store.set("interval_sec", "30");
    const v = try store.get("interval_sec");
    defer if (v) |s| alloc.free(s);
    try std.testing.expectEqualStrings("30", v.?);
}

test "quota 调整 CRUD 与有效配额累计" {
    const alloc = std.testing.allocator;
    var conn = try zqlite.open(":memory:", 0);
    defer conn.close();
    try conn.execNoArgs(ADJ_SCHEMA);

    const mk = "2026-08";
    const a1 = try quota.addAdjustment(alloc, &conn, 500 * 1024 * 1024, "奖励", "api", mk, 1000);
    try std.testing.expect(a1.id > 0);
    try std.testing.expectEqual(@as(u64, 500 * 1024 * 1024), a1.amount_bytes);

    _ = try quota.addAdjustment(alloc, &conn, 200 * 1024 * 1024, "补偿", "api", mk, 2000);

    const total = try quota.getAdjustmentTotal(&conn, mk);
    try std.testing.expectEqual(@as(u64, 700 * 1024 * 1024), total);

    const effective = try quota.getEffectiveMonthlyQuota(&conn, 1024 * 1024 * 1024, mk);
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024 + 700 * 1024 * 1024), effective);

    const list = try quota.listAdjustments(alloc, &conn, mk);
    defer {
        for (list) |it| {
            alloc.free(it.reason);
            alloc.free(it.source);
            alloc.free(it.month_key);
        }
        alloc.free(list);
    }
    try std.testing.expectEqual(@as(usize, 2), list.len);

    try quota.removeAdjustment(&conn, a1.id);
    const total2 = try quota.getAdjustmentTotal(&conn, mk);
    try std.testing.expectEqual(@as(u64, 200 * 1024 * 1024), total2);
}

test "ConfigStore 从 JSON 配置迁移到 SQLite" {
    const alloc = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    var conn = try zqlite.open(":memory:", 0);
    defer conn.close();
    try conn.execNoArgs(CONFIG_SCHEMA);

    const store = config_store.ConfigStore.init(&conn, alloc);

    // 构造临时绝对 home 目录：std.testing.tmpDir 返回真实打开的目录句柄，
    // 对其 .dir 调用 realPath 即可得到绝对路径（cwd 句柄在部分环境下不支持 realpath）。
    // defaultConfigPath 会拼成 home/.config/traffic-manager/config.json，
    // 且 openFileAbsolute 要求绝对路径，故 home 必须为绝对路径。
    var tmp = try std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_buf: [4096]u8 = undefined;
    const home_len = try tmp.dir.realPath(io, &home_buf);
    const home = home_buf[0..home_len];

    // 递归创建 home/.config/traffic-manager 目录（已存在则忽略）
    if (tmp.dir.createDirPathOpen(io, ".config/traffic-manager", .{})) |cfg_dir_handle| {
        cfg_dir_handle.close(io);
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    }

    const json =
        \\{ "interface": "wlan0", "interval_sec": 7, "retention_days": 45, "quota_limit_bytes": 2000000000 }
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = ".config/traffic-manager/config.json", .data = json });

    store.migrateFromJson(io, home);

    const loaded = try store.loadAll();
    defer config_store.deinitConfig(alloc, &loaded);
    try std.testing.expectEqualStrings("wlan0", loaded.interface.?);
    try std.testing.expectEqual(@as(u64, 7), loaded.interval_sec);
    try std.testing.expectEqual(@as(u32, 45), loaded.retention_days);
    try std.testing.expectEqual(@as(u64, 2000000000), loaded.quota_limit_bytes);
}
