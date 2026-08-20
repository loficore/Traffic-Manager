// backend/src/config_store.zig
// SQLite-backed configuration storage with typed serialization.
//
// 从 config 表读写键值对，支持 Config 结构体的完整 round-trip。
// 类型序列化格式：bool->"true"/"false"，整数->十进制字符串，
// 浮点->十进制字符串，?[]const u8->null 存 ""，非 null 存原值。
const std = @import("std");
const zqlite = @import("zqlite");
const cfg = @import("config.zig");

// 导出 Config 类型与释放函数，供测试模块统一通过 config_store 访问
pub const Config = cfg.Config;
pub const deinitConfig = cfg.deinitConfig;
const Allocator = std.mem.Allocator;

pub const ConfigError = error{
    QueryFailed,
    InsertFailed,
    OutOfMemory,
};

pub const ConfigStore = struct {
    conn: *zqlite.Conn,
    allocator: Allocator,

    /// 创建 ConfigStore 实例
    pub fn init(conn: *zqlite.Conn, allocator: Allocator) ConfigStore {
        return .{ .conn = conn, .allocator = allocator };
    }

    /// 从 config 表读取所有键值对，填充 Config 结构体
    pub fn loadAll(self: ConfigStore) ConfigError!cfg.Config {
        var config = cfg.Config{};
        // 记录 reset_day 是否已加载：旧键 quota_reset_day 仅在该字段尚未置位时生效
        var reset_day_seen = false;
        var rows = self.conn.rows(
            "SELECT key, value FROM config",
            .{},
        ) catch return ConfigError.QueryFailed;
        defer rows.deinit();
        while (rows.next()) |row| {
            const key = row.text(0);
            const val = row.text(1);
            if (std.mem.eql(u8, key, "reset_day")) reset_day_seen = true;
            self.applyKV(&config, key, val, reset_day_seen) catch {};
        }
        if (rows.err) |_| return ConfigError.QueryFailed;
        return config;
    }

    /// 应用单个键值对到 Config
    fn applyKV(self: ConfigStore, config: *cfg.Config, key: []const u8, val: []const u8, reset_day_seen: bool) !void {
        if (std.mem.eql(u8, key, "interface")) {
            if (val.len == 0) {
                config.interface = null;
            } else {
                config.interface = try self.allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, key, "interval_sec")) {
            config.interval_sec = std.fmt.parseInt(u64, val, 10) catch return;
        } else if (std.mem.eql(u8, key, "daemon_mode")) {
            config.daemon_mode = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "foreground")) {
            config.foreground = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "use_sqlite")) {
            config.use_sqlite = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "retention_days")) {
            config.retention_days = std.fmt.parseInt(u32, val, 10) catch return;
        } else if (std.mem.eql(u8, key, "log_file")) {
            if (val.len == 0) {
                config.log_file = null;
            } else {
                config.log_file = try self.allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, key, "pid_file")) {
            if (val.len == 0) {
                config.pid_file = null;
            } else {
                config.pid_file = try self.allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, key, "list_only")) {
            config.list_only = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "day_count")) {
            config.day_count = std.fmt.parseInt(u32, val, 10) catch return;
        } else if (std.mem.eql(u8, key, "quota_limit_bytes")) {
            config.quota_limit_bytes = std.fmt.parseInt(u64, val, 10) catch return;
        } else if (std.mem.eql(u8, key, "quota_warning_threshold")) {
            config.quota_warning_threshold = std.fmt.parseFloat(f64, val) catch return;
        } else if (std.mem.eql(u8, key, "quota_disconnect_threshold")) {
            config.quota_disconnect_threshold = std.fmt.parseFloat(f64, val) catch return;
        } else if (std.mem.eql(u8, key, "quota_reset_day")) {
            // 旧键兼容：仅当 reset_day 尚未加载时写入，显式 reset_day 永远优先（与行序无关）
            if (!reset_day_seen) {
                config.reset_day = std.fmt.parseInt(u8, val, 10) catch return;
            }
        } else if (std.mem.eql(u8, key, "reset_day")) {
            config.reset_day = std.fmt.parseInt(u8, val, 10) catch return;
        } else if (std.mem.eql(u8, key, "webhook_url")) {
            if (val.len == 0) {
                config.webhook_url = null;
            } else {
                config.webhook_url = try self.allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, key, "smtp_server")) {
            if (val.len == 0) {
                config.smtp_server = null;
            } else {
                config.smtp_server = try self.allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, key, "smtp_port")) {
            if (val.len == 0) {
                config.smtp_port = null;
            } else {
                config.smtp_port = try self.allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, key, "smtp_user")) {
            if (val.len == 0) {
                config.smtp_user = null;
            } else {
                config.smtp_user = try self.allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, key, "smtp_pass")) {
            if (val.len == 0) {
                config.smtp_pass = null;
            } else {
                config.smtp_pass = try self.allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, key, "smtp_from")) {
            if (val.len == 0) {
                config.smtp_from = null;
            } else {
                config.smtp_from = try self.allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, key, "smtp_to")) {
            if (val.len == 0) {
                config.smtp_to = null;
            } else {
                config.smtp_to = try self.allocator.dupe(u8, val);
            }
        }
        // 忽略未知键（前向兼容）
    }

    /// 将 Config 所有字段序列化写入 config 表
    pub fn saveAll(self: ConfigStore, config: cfg.Config) ConfigError!void {
        self.conn.transaction() catch return ConfigError.InsertFailed;
        errdefer self.conn.rollback();

        // 清空现有配置后重新写入
        self.conn.exec("DELETE FROM config", .{}) catch return ConfigError.InsertFailed;

        try self.putKV("interface", if (config.interface) |v| v else "");
        try self.putU64("interval_sec", config.interval_sec);
        try self.putBool("daemon_mode", config.daemon_mode);
        try self.putBool("foreground", config.foreground);
        try self.putBool("use_sqlite", config.use_sqlite);
        try self.putU32("retention_days", config.retention_days);
        try self.putKV("log_file", if (config.log_file) |v| v else "");
        try self.putKV("pid_file", if (config.pid_file) |v| v else "");
        try self.putBool("list_only", config.list_only);
        try self.putU32("day_count", config.day_count);
        try self.putU64("quota_limit_bytes", config.quota_limit_bytes);
        try self.putF64("quota_warning_threshold", config.quota_warning_threshold);
        try self.putF64("quota_disconnect_threshold", config.quota_disconnect_threshold);
        try self.putU8("reset_day", config.reset_day);
        try self.putKV("webhook_url", if (config.webhook_url) |v| v else "");
        try self.putKV("smtp_server", if (config.smtp_server) |v| v else "");
        try self.putKV("smtp_port", if (config.smtp_port) |v| v else "");
        try self.putKV("smtp_user", if (config.smtp_user) |v| v else "");
        try self.putKV("smtp_pass", if (config.smtp_pass) |v| v else "");
        try self.putKV("smtp_from", if (config.smtp_from) |v| v else "");
        try self.putKV("smtp_to", if (config.smtp_to) |v| v else "");

        self.conn.commit() catch return ConfigError.InsertFailed;
    }

    /// 读取单个配置项
    pub fn get(self: ConfigStore, key: []const u8) ConfigError!?[]const u8 {
        const row = self.conn.row(
            "SELECT value FROM config WHERE key = ?1",
            .{key},
        ) catch return ConfigError.QueryFailed;
        if (row) |r| {
            defer r.deinit();
            const val = r.text(0);
            return try self.allocator.dupe(u8, val);
        }
        return null;
    }

    /// 设置单个配置项（INSERT OR REPLACE）
    pub fn set(self: ConfigStore, key: []const u8, value: []const u8) ConfigError!void {
        self.conn.exec(
            "INSERT OR REPLACE INTO config (key, value) VALUES (?1, ?2)",
            .{ key, value },
        ) catch return ConfigError.InsertFailed;
    }

    /// 写入键值对到 config 表
    fn putKV(self: ConfigStore, key: []const u8, value: []const u8) ConfigError!void {
        self.conn.exec(
            "INSERT INTO config (key, value) VALUES (?1, ?2)",
            .{ key, value },
        ) catch return ConfigError.InsertFailed;
    }

    /// 写入 bool 值
    fn putBool(self: ConfigStore, key: []const u8, value: bool) ConfigError!void {
        try self.putKV(key, if (value) "true" else "false");
    }

    /// 写入 u64 值
    fn putU64(self: ConfigStore, key: []const u8, value: u64) ConfigError!void {
        var buf: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return ConfigError.InsertFailed;
        try self.putKV(key, s);
    }

    /// 写入 u32 值
    fn putU32(self: ConfigStore, key: []const u8, value: u32) ConfigError!void {
        var buf: [10]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return ConfigError.InsertFailed;
        try self.putKV(key, s);
    }

    /// 写入 u8 值
    fn putU8(self: ConfigStore, key: []const u8, value: u8) ConfigError!void {
        var buf: [3]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return ConfigError.InsertFailed;
        try self.putKV(key, s);
    }

    /// 写入 f64 值
    fn putF64(self: ConfigStore, key: []const u8, value: f64) ConfigError!void {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return ConfigError.InsertFailed;
        try self.putKV(key, s);
    }

    /// 从 JSON 配置文件迁移到 SQLite。
    /// 如果 JSON 文件不存在，静默返回；如果存在则解析并写入 SQLite，
    /// 成功后将 JSON 重命名为 .bak 作为备份。
    pub fn migrateFromJson(
        self: ConfigStore,
        io: std.Io,
        home_dir: ?[]const u8,
    ) void {
        const home = home_dir orelse return;
        const json_path = cfg.defaultConfigPath(self.allocator, home) catch return;
        defer self.allocator.free(json_path);

        // 尝试解析 JSON 配置文件
        const parsed = cfg.parseConfigFile(io, self.allocator, json_path) catch {
            // 文件不存在或解析失败，静默跳过
            return;
        };
        defer cfg.deinitConfig(self.allocator, &parsed.config);

        // 将解析结果写入 SQLite
        self.saveAll(parsed.config) catch return;

        // 重命名为 .bak 作为备份（使用 Zig 0.16 std.Io.Dir.renameAbsolute）
        const bak_path = std.fmt.allocPrint(self.allocator, "{s}.bak", .{json_path}) catch return;
        defer self.allocator.free(bak_path);
        std.Io.Dir.renameAbsolute(json_path, bak_path, io) catch {};
    }
};
