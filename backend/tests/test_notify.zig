// backend/tests/test_notify.zig
// Independent tests for the notify_template module.
// Tests only public API of src/notify_template.zig.
// Note: formatBytesForTemplate and formatTimestampForTemplate tests are excluded
// because those are private functions.
const std = @import("std");
const notify = @import("notify");

const TemplateVariables = notify.TemplateVariables;
const TemplateError = notify.TemplateError;
const render = notify.render;
const renderAlloc = notify.renderAlloc;
const default_warning_template = notify.default_warning_template;
const default_disconnect_template = notify.default_disconnect_template;
const default_custom_template = notify.default_custom_template;

test "TemplateVariables struct" {
    const vars = TemplateVariables{
        .interface = "eth0",
        .quota = 1024 * 1024 * 1024,
        .used = 1024 * 1024 * 512,
        .percent = 50.0,
        .timestamp_ms = 1234567890000,
    };

    try std.testing.expectEqualStrings("eth0", vars.interface);
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), vars.quota);
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 512), vars.used);
    try std.testing.expectEqual(@as(f64, 50.0), vars.percent);
    try std.testing.expectEqual(@as(i64, 1234567890000), vars.timestamp_ms);
}

test "render simple template with interface variable" {
    const allocator = std.testing.allocator;
    const template = "Interface: {interface}";
    const vars = TemplateVariables{
        .interface = "eth0",
        .quota = 0,
        .used = 0,
        .percent = 0.0,
        .timestamp_ms = 0,
    };

    var buf: [256]u8 = undefined;
    const result = try render(allocator, template, vars, &buf);

    try std.testing.expectEqualStrings("Interface: eth0", result);
}

test "render template with all variables" {
    const allocator = std.testing.allocator;
    const template = "{interface} {quota} {used} {percent} {timestamp}";
    const vars = TemplateVariables{
        .interface = "wlan0",
        .quota = 1024 * 1024 * 1024,
        .used = 1024 * 1024 * 512,
        .percent = 50.0,
        .timestamp_ms = 0,
    };

    var buf: [256]u8 = undefined;
    const result = try render(allocator, template, vars, &buf);

    try std.testing.expect(std.mem.indexOf(u8, result, "wlan0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1.0 GB") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "512.0 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "50.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "00:00:00") != null);
}

test "render default warning template" {
    const allocator = std.testing.allocator;
    const vars = TemplateVariables{
        .interface = "eth0",
        .quota = 1024 * 1024 * 1024,
        .used = 1024 * 1024 * 768,
        .percent = 75.0,
        .timestamp_ms = 1700000000000,
    };

    var buf: [1024]u8 = undefined;
    const result = try render(allocator, default_warning_template, vars, &buf);

    try std.testing.expect(std.mem.indexOf(u8, result, "[警告]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "eth0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "768.0 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1.0 GB") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "75.0") != null);
}

test "render default disconnect template" {
    const allocator = std.testing.allocator;
    const vars = TemplateVariables{
        .interface = "wlan0",
        .quota = 1024 * 1024 * 1024 * 2,
        .used = 1024 * 1024 * 1024 * 2,
        .percent = 100.0,
        .timestamp_ms = 1700000000000,
    };

    var buf: [1024]u8 = undefined;
    const result = try render(allocator, default_disconnect_template, vars, &buf);

    try std.testing.expect(std.mem.indexOf(u8, result, "[断网]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "wlan0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "2.0 GB") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "100.0") != null);
}

test "render custom template" {
    const allocator = std.testing.allocator;
    const template = "Traffic alert: {interface} used {used} of {quota}";
    const vars = TemplateVariables{
        .interface = "eth1",
        .quota = 1024 * 1024 * 500,
        .used = 1024 * 1024 * 250,
        .percent = 50.0,
        .timestamp_ms = 0,
    };

    var buf: [256]u8 = undefined;
    const result = try render(allocator, template, vars, &buf);

    try std.testing.expectEqualStrings("Traffic alert: eth1 used 250.0 MB of 500.0 MB", result);
}

test "render template with no variables" {
    const allocator = std.testing.allocator;
    const template = "No variables here!";
    const vars = TemplateVariables{
        .interface = "eth0",
        .quota = 0,
        .used = 0,
        .percent = 0.0,
        .timestamp_ms = 0,
    };

    var buf: [256]u8 = undefined;
    const result = try render(allocator, template, vars, &buf);

    try std.testing.expectEqualStrings("No variables here!", result);
}

test "render template with consecutive variables" {
    const allocator = std.testing.allocator;
    const template = "{interface}{percent}";
    const vars = TemplateVariables{
        .interface = "eth0",
        .quota = 0,
        .used = 0,
        .percent = 75.5,
        .timestamp_ms = 0,
    };

    var buf: [256]u8 = undefined;
    const result = try render(allocator, template, vars, &buf);

    try std.testing.expectEqualStrings("eth075.5", result);
}

test "render template with escaped braces" {
    const allocator = std.testing.allocator;
    const template = "Use {{interface}} for the interface name";
    const vars = TemplateVariables{
        .interface = "eth0",
        .quota = 0,
        .used = 0,
        .percent = 0.0,
        .timestamp_ms = 0,
    };

    var buf: [256]u8 = undefined;
    const result = render(allocator, template, vars, &buf);

    if (result) |r| {
        try std.testing.expect(r.len > 0);
    } else |err| {
        try std.testing.expectEqual(TemplateError.UnknownVariable, err);
    }
}

test "render template with unknown variable" {
    const allocator = std.testing.allocator;
    const template = "Unknown: {nonexistent}";
    const vars = TemplateVariables{
        .interface = "eth0",
        .quota = 0,
        .used = 0,
        .percent = 0.0,
        .timestamp_ms = 0,
    };

    var buf: [256]u8 = undefined;
    const result = render(allocator, template, vars, &buf);

    try std.testing.expectError(TemplateError.UnknownVariable, result);
}

test "render template buffer too small" {
    const allocator = std.testing.allocator;
    const template = "Long template with interface: {interface}";
    const vars = TemplateVariables{
        .interface = "eth0",
        .quota = 0,
        .used = 0,
        .percent = 0.0,
        .timestamp_ms = 0,
    };

    var buf: [5]u8 = undefined;
    const result = render(allocator, template, vars, &buf);

    try std.testing.expectError(TemplateError.BufferTooSmall, result);
}

test "renderAlloc returns allocated string" {
    const allocator = std.testing.allocator;
    const template = "Hello {interface}!";
    const vars = TemplateVariables{
        .interface = "world",
        .quota = 0,
        .used = 0,
        .percent = 0.0,
        .timestamp_ms = 0,
    };

    const result = try renderAlloc(allocator, template, vars);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello world!", result);
}

test "default templates are valid" {
    const required_vars = [_][]const u8{ "{interface}", "{quota}", "{used}", "{percent}", "{timestamp}" };

    for (required_vars) |var_name| {
        try std.testing.expect(std.mem.indexOf(u8, default_warning_template, var_name) != null);
        try std.testing.expect(std.mem.indexOf(u8, default_disconnect_template, var_name) != null);
        try std.testing.expect(std.mem.indexOf(u8, default_custom_template, var_name) != null);
    }
}
