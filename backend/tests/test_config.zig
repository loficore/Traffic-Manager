// backend/tests/test_config.zig
// Independent tests for the config module.
// Tests only public API of src/config.zig.
const std = @import("std");
const cfg = @import("cfg");

const Config = cfg.Config;
const ConfigSource = cfg.ConfigSource;
const deinitConfig = cfg.deinitConfig;
const mergeConfigs = cfg.mergeConfigs;
const parseConfigJson = cfg.parseConfigJson;
const sampleConfig = cfg.sampleConfig;
const validateConfig = cfg.validateConfig;

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

    try std.testing.expect(result.interface != null);
    try std.testing.expectEqualStrings("eth0", result.interface.?);
    try std.testing.expectEqual(true, result.use_sqlite);
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

    try std.testing.expectEqualStrings("wlan0", result.interface.?);
    try std.testing.expectEqual(@as(u64, 10), result.interval_sec);
}

test "sample config is valid JSON" {
    const allocator = std.testing.allocator;
    const sample = sampleConfig();
    const result = try parseConfigJson(allocator, sample);
    defer deinitConfig(allocator, &result.config);

    try std.testing.expectEqual(@as(u64, 1), result.config.interval_sec);
}
