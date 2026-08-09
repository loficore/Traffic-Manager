// backend/src/config.zig
// Configuration file parsing for TrafficManager
//
// Supports JSON configuration files with the following format:
// {
//     "interface": "eth0",
//     "interval_sec": 5,
//     "daemon_mode": false,
//     "use_sqlite": true,
//     "retention_days": 60,
//     "log_file": "/var/log/traffic-manager.log",
//     "pid_file": "/var/run/traffic-manager.pid"
// }

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Configuration file format
pub const Config = struct {
    /// Network interface to monitor (null = auto-detect)
    interface: ?[]const u8 = null,
    /// Sampling interval in seconds
    interval_sec: u64 = 1,
    /// Run as daemon in background
    daemon_mode: bool = false,
    /// Force foreground mode (mutually exclusive with daemon_mode)
    foreground: bool = false,
    /// Use SQLite storage backend
    use_sqlite: bool = false,
    /// Days to retain sample data
    retention_days: u32 = 30,
    /// Path to log file (null = no logging)
    log_file: ?[]const u8 = null,
    /// Path to PID file (null = no PID file)
    pid_file: ?[]const u8 = null,
    /// List interfaces and exit
    list_only: bool = false,
    /// Show last N days of history (0 = disabled)
    day_count: u32 = 0,
    // ── Quota 配置 ──
    /// Monthly traffic limit in bytes (0 = disabled)
    quota_limit_bytes: u64 = 0,
    /// Warning threshold fraction (0.0-1.0, default 0.9)
    quota_warning_threshold: f64 = 0.9,
    /// Disconnect threshold fraction (0.0-1.0, default 1.0)
    quota_disconnect_threshold: f64 = 1.0,
    /// Day of month to reset quota (1-28)
    quota_reset_day: u8 = 1,
    // ── 通知配置 ──
    /// Webhook URL for notifications
    webhook_url: ?[]const u8 = null,
    /// SMTP server hostname
    smtp_server: ?[]const u8 = null,
    /// SMTP port
    smtp_port: ?[]const u8 = null,
    /// SMTP auth username
    smtp_user: ?[]const u8 = null,
    /// SMTP auth password
    smtp_pass: ?[]const u8 = null,
    /// SMTP from address
    smtp_from: ?[]const u8 = null,
    /// SMTP to address
    smtp_to: ?[]const u8 = null,
    // ── 运行时控制 ──
    /// Restore network and reset quota state
    restore_network: bool = false,
    /// Quota reset day (alias for quota_reset_day)
    reset_day: u8 = 1,
};

/// Track which fields were explicitly set in the config file
pub const ConfigSource = struct {
    interface: bool = false,
    interval_sec: bool = false,
    daemon_mode: bool = false,
    foreground: bool = false,
    use_sqlite: bool = false,
    retention_days: bool = false,
    log_file: bool = false,
    pid_file: bool = false,
    list_only: bool = false,
    day_count: bool = false,
    quota_limit_bytes: bool = false,
    quota_warning_threshold: bool = false,
    quota_disconnect_threshold: bool = false,
    quota_reset_day: bool = false,
    webhook_url: bool = false,
    smtp_server: bool = false,
    smtp_port: bool = false,
    smtp_user: bool = false,
    smtp_pass: bool = false,
    smtp_from: bool = false,
    smtp_to: bool = false,
    restore_network: bool = false,
    reset_day: bool = false,
};

/// Result of parsing a config file
pub const ParseResult = struct {
    config: Config,
    source: ConfigSource,
};

/// Error types for configuration parsing
pub const ConfigError = error{
    /// Failed to open or read the config file
    FileReadError,
    /// Invalid JSON syntax
    InvalidJson,
    /// Invalid field type in config
    InvalidFieldType,
    /// Unknown field in config
    UnknownField,
    /// Value out of valid range
    ValueOutOfRange,
    /// Conflicting options (e.g., daemon + foreground)
    ConflictingOptions,
    /// Missing required value
    MissingRequiredValue,
};

/// Parse a JSON configuration file
///
/// The JSON file can contain any subset of the Config fields.
/// Only fields present in the JSON will be marked as "set" in ConfigSource.
pub fn parseConfigFile(io: Io, allocator: Allocator, file_path: []const u8) !ParseResult {
    // Read the file using Zig 0.16 Io API
    const file = Io.Dir.openFileAbsolute(io, file_path, .{
        .mode = .read_only,
    }) catch {
        return error.FileReadError;
    };
    defer file.close(io);

    // Read file content
    var buf: [1024 * 1024]u8 = undefined; // 1MB limit
    const bytes_read = file.readPositionalAll(io, &buf, 0) catch {
        return error.FileReadError;
    };
    const content = buf[0..bytes_read];

    return parseConfigJson(allocator, content);
}

/// Parse JSON content directly (for testing and inline config)
pub fn parseConfigJson(allocator: Allocator, json_content: []const u8) !ParseResult {
    var config = Config{};
    var source = ConfigSource{};

    // Parse JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_content, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Ensure root is an object
    if (root != .object) {
        return error.InvalidJson;
    }

    const object = root.object;

    // Parse each field
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        if (std.mem.eql(u8, key, "interface")) {
            if (value == .null) {
                // null means auto-detect, which is the default
                source.interface = true;
            } else if (value != .string) {
                return error.InvalidFieldType;
            } else {
                // Free previous value if set (shouldn't happen, but be safe)
                if (config.interface) |old| allocator.free(old);
                config.interface = try allocator.dupe(u8, value.string);
                source.interface = true;
            }
        } else if (std.mem.eql(u8, key, "interval_sec")) {
            if (value != .integer) return error.InvalidFieldType;
            const val = value.integer;
            if (val < 1 or val > 86400) return error.ValueOutOfRange;
            config.interval_sec = @intCast(val);
            source.interval_sec = true;
        } else if (std.mem.eql(u8, key, "daemon_mode")) {
            if (value != .bool) return error.InvalidFieldType;
            config.daemon_mode = value.bool;
            source.daemon_mode = true;
        } else if (std.mem.eql(u8, key, "foreground")) {
            if (value != .bool) return error.InvalidFieldType;
            config.foreground = value.bool;
            source.foreground = true;
        } else if (std.mem.eql(u8, key, "use_sqlite")) {
            if (value != .bool) return error.InvalidFieldType;
            config.use_sqlite = value.bool;
            source.use_sqlite = true;
        } else if (std.mem.eql(u8, key, "retention_days")) {
            if (value != .integer) return error.InvalidFieldType;
            const val = value.integer;
            if (val < 1 or val > 3650) return error.ValueOutOfRange;
            config.retention_days = @intCast(val);
            source.retention_days = true;
        } else if (std.mem.eql(u8, key, "log_file")) {
            if (value == .null) {
                // null means no log file
                source.log_file = true;
            } else if (value != .string) {
                return error.InvalidFieldType;
            } else {
                if (config.log_file) |old| allocator.free(old);
                config.log_file = try allocator.dupe(u8, value.string);
                source.log_file = true;
            }
        } else if (std.mem.eql(u8, key, "pid_file")) {
            if (value == .null) {
                // null means no pid file
                source.pid_file = true;
            } else if (value != .string) {
                return error.InvalidFieldType;
            } else {
                if (config.pid_file) |old| allocator.free(old);
                config.pid_file = try allocator.dupe(u8, value.string);
                source.pid_file = true;
            }
        } else if (std.mem.eql(u8, key, "list_only")) {
            if (value != .bool) return error.InvalidFieldType;
            config.list_only = value.bool;
            source.list_only = true;
        } else if (std.mem.eql(u8, key, "day_count")) {
            if (value != .integer) return error.InvalidFieldType;
            const val = value.integer;
            if (val < 0 or val > 365) return error.ValueOutOfRange;
            config.day_count = @intCast(val);
            source.day_count = true;
        }
        // ── Quota 配置 ──
        else if (std.mem.eql(u8, key, "quota_limit_bytes")) {
            if (value != .integer) return error.InvalidFieldType;
            const val = value.integer;
            if (val < 0) return error.ValueOutOfRange;
            config.quota_limit_bytes = @intCast(val);
            source.quota_limit_bytes = true;
        } else if (std.mem.eql(u8, key, "quota_warning_threshold")) {
            if (value != .float) return error.InvalidFieldType;
            const val = value.float;
            if (val < 0.0 or val > 1.0) return error.ValueOutOfRange;
            config.quota_warning_threshold = val;
            source.quota_warning_threshold = true;
        } else if (std.mem.eql(u8, key, "quota_disconnect_threshold")) {
            if (value != .float) return error.InvalidFieldType;
            const val = value.float;
            if (val < 0.0 or val > 1.0) return error.ValueOutOfRange;
            config.quota_disconnect_threshold = val;
            source.quota_disconnect_threshold = true;
        } else if (std.mem.eql(u8, key, "quota_reset_day")) {
            if (value != .integer) return error.InvalidFieldType;
            const val = value.integer;
            if (val < 1 or val > 28) return error.ValueOutOfRange;
            config.quota_reset_day = @intCast(val);
            source.quota_reset_day = true;
        } else if (std.mem.eql(u8, key, "reset_day")) {
            if (value != .integer) return error.InvalidFieldType;
            const val = value.integer;
            if (val < 1 or val > 28) return error.ValueOutOfRange;
            config.reset_day = @intCast(val);
            source.reset_day = true;
        }
        // ── 通知配置 ──
        else if (std.mem.eql(u8, key, "webhook_url")) {
            if (value == .null) {
                source.webhook_url = true;
            } else if (value != .string) {
                return error.InvalidFieldType;
            } else {
                if (config.webhook_url) |old| allocator.free(old);
                config.webhook_url = try allocator.dupe(u8, value.string);
                source.webhook_url = true;
            }
        } else if (std.mem.eql(u8, key, "smtp_server")) {
            if (value == .null) {
                source.smtp_server = true;
            } else if (value != .string) {
                return error.InvalidFieldType;
            } else {
                if (config.smtp_server) |old| allocator.free(old);
                config.smtp_server = try allocator.dupe(u8, value.string);
                source.smtp_server = true;
            }
        } else if (std.mem.eql(u8, key, "smtp_port")) {
            if (value == .null) {
                source.smtp_port = true;
            } else if (value != .string) {
                return error.InvalidFieldType;
            } else {
                if (config.smtp_port) |old| allocator.free(old);
                config.smtp_port = try allocator.dupe(u8, value.string);
                source.smtp_port = true;
            }
        } else if (std.mem.eql(u8, key, "smtp_user")) {
            if (value == .null) {
                source.smtp_user = true;
            } else if (value != .string) {
                return error.InvalidFieldType;
            } else {
                if (config.smtp_user) |old| allocator.free(old);
                config.smtp_user = try allocator.dupe(u8, value.string);
                source.smtp_user = true;
            }
        } else if (std.mem.eql(u8, key, "smtp_pass")) {
            if (value == .null) {
                source.smtp_pass = true;
            } else if (value != .string) {
                return error.InvalidFieldType;
            } else {
                if (config.smtp_pass) |old| allocator.free(old);
                config.smtp_pass = try allocator.dupe(u8, value.string);
                source.smtp_pass = true;
            }
        } else if (std.mem.eql(u8, key, "smtp_from")) {
            if (value == .null) {
                source.smtp_from = true;
            } else if (value != .string) {
                return error.InvalidFieldType;
            } else {
                if (config.smtp_from) |old| allocator.free(old);
                config.smtp_from = try allocator.dupe(u8, value.string);
                source.smtp_from = true;
            }
        } else if (std.mem.eql(u8, key, "smtp_to")) {
            if (value == .null) {
                source.smtp_to = true;
            } else if (value != .string) {
                return error.InvalidFieldType;
            } else {
                if (config.smtp_to) |old| allocator.free(old);
                config.smtp_to = try allocator.dupe(u8, value.string);
                source.smtp_to = true;
            }
        } else {
            // Unknown field - ignore for forward compatibility
            // Could optionally return error.UnknownField for strict parsing
        }
    }

    return .{ .config = config, .source = source };
}

/// Merge command line arguments with config file values.
/// Command line arguments take precedence over config file values.
/// Only fields marked in cli_source will override the config file values.
pub fn mergeConfigs(
    file_config: Config,
    cli_config: Config,
    cli_source: ConfigSource,
) Config {
    var result = file_config;

    // Override with CLI values where explicitly set
    if (cli_source.interface) {
        // Note: This doesn't handle memory management for the old value
        // Caller must handle freeing the old interface string
        result.interface = cli_config.interface;
    }
    if (cli_source.interval_sec) {
        result.interval_sec = cli_config.interval_sec;
    }
    if (cli_source.daemon_mode) {
        result.daemon_mode = cli_config.daemon_mode;
    }
    if (cli_source.foreground) {
        result.foreground = cli_config.foreground;
    }
    if (cli_source.use_sqlite) {
        result.use_sqlite = cli_config.use_sqlite;
    }
    if (cli_source.retention_days) {
        result.retention_days = cli_config.retention_days;
    }
    if (cli_source.log_file) {
        result.log_file = cli_config.log_file;
    }
    if (cli_source.pid_file) {
        result.pid_file = cli_config.pid_file;
    }
    if (cli_source.list_only) {
        result.list_only = cli_config.list_only;
    }
    if (cli_source.day_count) {
        result.day_count = cli_config.day_count;
    }
    // ── Quota 配置 ──
    if (cli_source.quota_limit_bytes) {
        result.quota_limit_bytes = cli_config.quota_limit_bytes;
    }
    if (cli_source.quota_warning_threshold) {
        result.quota_warning_threshold = cli_config.quota_warning_threshold;
    }
    if (cli_source.quota_disconnect_threshold) {
        result.quota_disconnect_threshold = cli_config.quota_disconnect_threshold;
    }
    if (cli_source.quota_reset_day) {
        result.quota_reset_day = cli_config.quota_reset_day;
    }
    if (cli_source.reset_day) {
        result.reset_day = cli_config.reset_day;
    }
    // ── 通知配置 ──
    if (cli_source.webhook_url) {
        result.webhook_url = cli_config.webhook_url;
    }
    if (cli_source.smtp_server) {
        result.smtp_server = cli_config.smtp_server;
    }
    if (cli_source.smtp_port) {
        result.smtp_port = cli_config.smtp_port;
    }
    if (cli_source.smtp_user) {
        result.smtp_user = cli_config.smtp_user;
    }
    if (cli_source.smtp_pass) {
        result.smtp_pass = cli_config.smtp_pass;
    }
    if (cli_source.smtp_from) {
        result.smtp_from = cli_config.smtp_from;
    }
    if (cli_source.smtp_to) {
        result.smtp_to = cli_config.smtp_to;
    }
    if (cli_source.restore_network) {
        result.restore_network = cli_config.restore_network;
    }

    return result;
}

/// Validate configuration values
pub fn validateConfig(config: Config) ConfigError!void {
    // Check for conflicting options
    if (config.daemon_mode and config.foreground) {
        return error.ConflictingOptions;
    }

    // Validate interval
    if (config.interval_sec == 0 or config.interval_sec > 86400) {
        return error.ValueOutOfRange;
    }

    // Validate retention days
    if (config.retention_days == 0 or config.retention_days > 3650) {
        return error.ValueOutOfRange;
    }

    // Validate day_count
    if (config.day_count > 365) {
        return error.ValueOutOfRange;
    }
}

/// Free all allocated memory in a Config
pub fn deinitConfig(allocator: Allocator, config_to_free: *const Config) void {
    // Note: We can't set fields to null on a const pointer, but we can free the memory
    if (config_to_free.interface) |iface| {
        allocator.free(iface);
    }
    if (config_to_free.log_file) |path| {
        allocator.free(path);
    }
    if (config_to_free.pid_file) |path| {
        allocator.free(path);
    }
}

/// Get default config file path ($HOME/.config/traffic-manager/config.json)
pub fn defaultConfigPath(allocator: Allocator, home_dir: ?[]const u8) ![]const u8 {
    const home = home_dir orelse return error.MissingRequiredValue;
    return std.fmt.allocPrint(allocator, "{s}/.config/traffic-manager/config.json", .{home});
}

/// Get sample configuration JSON
pub fn sampleConfig() []const u8 {
    return 
        \\{
        \\    "interface": null,
        \\    "interval_sec": 1,
        \\    "daemon_mode": false,
        \\    "foreground": false,
        \\    "use_sqlite": false,
        \\    "retention_days": 30,
        \\    "log_file": null,
        \\    "pid_file": null,
        \\    "list_only": false,
        \\    "day_count": 0
        \\}
    ;
}

// ============================================================================
// Tests
// ============================================================================

test "parse empty JSON object" {
    const allocator = std.testing.allocator;
    const json = "{}";
    const result = try parseConfigJson(allocator, json);
    defer deinitConfig(allocator, &result.config);

    try std.testing.expectEqual(@as(u64, 1), result.config.interval_sec);
    try std.testing.expect(result.config.interface == null);
    try std.testing.expectEqual(false, result.source.interface);
}

test "parse interface field" {
    const allocator = std.testing.allocator;
    const json = "{\"interface\": \"eth0\"}";
    const result = try parseConfigJson(allocator, json);
    defer deinitConfig(allocator, &result.config);

    try std.testing.expect(result.config.interface != null);
    try std.testing.expectEqualStrings("eth0", result.config.interface.?);
    try std.testing.expect(result.source.interface);
}

test "parse interval_sec field" {
    const allocator = std.testing.allocator;
    const json = "{\"interval_sec\": 5}";
    const result = try parseConfigJson(allocator, json);
    defer deinitConfig(allocator, &result.config);

    try std.testing.expectEqual(@as(u64, 5), result.config.interval_sec);
    try std.testing.expect(result.source.interval_sec);
}

test "parse boolean fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\    "daemon_mode": true,
        \\    "use_sqlite": true,
        \\    "foreground": false
        \\}
    ;
    const result = try parseConfigJson(allocator, json);
    defer deinitConfig(allocator, &result.config);

    try std.testing.expectEqual(true, result.config.daemon_mode);
    try std.testing.expectEqual(true, result.config.use_sqlite);
    try std.testing.expectEqual(false, result.config.foreground);
    try std.testing.expect(result.source.daemon_mode);
    try std.testing.expect(result.source.use_sqlite);
}

test "parse multiple fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\    "interface": "wlan0",
        \\    "interval_sec": 10,
        \\    "retention_days": 60,
        \\    "log_file": "/var/log/traffic.log"
        \\}
    ;
    const result = try parseConfigJson(allocator, json);
    defer deinitConfig(allocator, &result.config);

    try std.testing.expectEqualStrings("wlan0", result.config.interface.?);
    try std.testing.expectEqual(@as(u64, 10), result.config.interval_sec);
    try std.testing.expectEqual(@as(u32, 60), result.config.retention_days);
    try std.testing.expectEqualStrings("/var/log/traffic.log", result.config.log_file.?);
}

test "reject invalid JSON" {
    const allocator = std.testing.allocator;
    const json = "not valid json";
    const result = parseConfigJson(allocator, json);

    try std.testing.expectError(error.InvalidJson, result);
}

test "reject invalid field type" {
    const allocator = std.testing.allocator;
    const json = "{\"interval_sec\": \"not a number\"}";
    const result = parseConfigJson(allocator, json);

    try std.testing.expectError(error.InvalidFieldType, result);
}

test "reject out of range value" {
    const allocator = std.testing.allocator;
    const json = "{\"interval_sec\": 0}";
    const result = parseConfigJson(allocator, json);

    try std.testing.expectError(error.ValueOutOfRange, result);
}

test "validate conflicting options" {
    const test_config = Config{
        .daemon_mode = true,
        .foreground = true,
    };

    try std.testing.expectError(error.ConflictingOptions, validateConfig(test_config));
}

test "validate valid config" {
    const config = Config{
        .interval_sec = 5,
        .retention_days = 30,
        .day_count = 7,
    };

    try validateConfig(config);
}

test "merge configs - CLI overrides file" {
    const file_config = Config{
        .interface = null,
        .interval_sec = 1,
        .use_sqlite = false,
    };

    const cli_config = Config{
        .interface = "eth0",
        .interval_sec = 5,
        .use_sqlite = true,
    };
    const cli_source = ConfigSource{
        .interface = true,
        .use_sqlite = true,
    };

    const result = mergeConfigs(file_config, cli_config, cli_source);

    // CLI overrides: interface and use_sqlite
    try std.testing.expect(result.interface != null);
    try std.testing.expectEqualStrings("eth0", result.interface.?);
    try std.testing.expectEqual(true, result.use_sqlite);
    // File value preserved: interval_sec (not in cli_source)
    try std.testing.expectEqual(@as(u64, 1), result.interval_sec);
}

test "merge configs - empty CLI" {
    const file_config = Config{
        .interface = "wlan0",
        .interval_sec = 10,
    };

    const cli_config = Config{};
    const cli_source = ConfigSource{};

    const result = mergeConfigs(file_config, cli_config, cli_source);

    // All file values preserved
    try std.testing.expectEqualStrings("wlan0", result.interface.?);
    try std.testing.expectEqual(@as(u64, 10), result.interval_sec);
}

test "sample config is valid JSON" {
    const allocator = std.testing.allocator;
    const sample = sampleConfig();
    const result = try parseConfigJson(allocator, sample);
    defer deinitConfig(allocator, &result.config);

    // Should parse without error
    try std.testing.expectEqual(@as(u64, 1), result.config.interval_sec);
}

test "parse reset_day field" {
    const allocator = std.testing.allocator;
    const json = "{\"reset_day\": 15}";
    const result = try parseConfigJson(allocator, json);
    defer deinitConfig(allocator, &result.config);

    try std.testing.expectEqual(@as(u8, 15), result.config.reset_day);
    try std.testing.expect(result.source.reset_day);
    // quota_reset_day should remain at default
    try std.testing.expectEqual(@as(u8, 1), result.config.quota_reset_day);
    try std.testing.expect(!result.source.quota_reset_day);
}

test "parse quota_reset_day field" {
    const allocator = std.testing.allocator;
    const json = "{\"quota_reset_day\": 20}";
    const result = try parseConfigJson(allocator, json);
    defer deinitConfig(allocator, &result.config);

    try std.testing.expectEqual(@as(u8, 20), result.config.quota_reset_day);
    try std.testing.expect(result.source.quota_reset_day);
    // reset_day should remain at default
    try std.testing.expectEqual(@as(u8, 1), result.config.reset_day);
    try std.testing.expect(!result.source.reset_day);
}

test "reset_day out of range rejected" {
    const allocator = std.testing.allocator;
    const json = "{\"reset_day\": 29}";
    const result = parseConfigJson(allocator, json);

    try std.testing.expectError(error.ValueOutOfRange, result);
}

test "merge configs - reset_day CLI overrides file" {
    const file_config = Config{
        .reset_day = 10,
    };

    const cli_config = Config{
        .reset_day = 25,
    };
    const cli_source = ConfigSource{
        .reset_day = true,
    };

    const result = mergeConfigs(file_config, cli_config, cli_source);

    // CLI overrides file
    try std.testing.expectEqual(@as(u8, 25), result.reset_day);
}

test "merge configs - reset_day file preserved when no CLI" {
    const file_config = Config{
        .reset_day = 10,
    };

    const cli_config = Config{};
    const cli_source = ConfigSource{};

    const result = mergeConfigs(file_config, cli_config, cli_source);

    // File value preserved
    try std.testing.expectEqual(@as(u8, 10), result.reset_day);
}
