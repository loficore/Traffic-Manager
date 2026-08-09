// backend/tests/test_webhook.zig
// Independent tests for the webhook module.
// Tests only public API of src/webhook.zig.
const std = @import("std");
const webhook = @import("webhook");

const WebhookNotifier = webhook.WebhookNotifier;

test "WebhookNotifier Header struct" {
    const header = WebhookNotifier.Header{
        .name = "X-Custom-Header",
        .value = "custom-value",
    };
    try std.testing.expectEqualStrings("X-Custom-Header", header.name);
    try std.testing.expectEqualStrings("custom-value", header.value);
}

test "SendResult struct fields" {
    const result = WebhookNotifier.SendResult{
        .status = 200,
        .body = "OK",
        .success = true,
    };
    try std.testing.expectEqual(@as(u16, 200), result.status);
    try std.testing.expect(result.success);
}

test "SendResult error status" {
    const result = WebhookNotifier.SendResult{
        .status = 500,
        .body = "Internal Server Error",
        .success = false,
    };
    try std.testing.expectEqual(@as(u16, 500), result.status);
    try std.testing.expect(!result.success);
}

test "JSON payload format" {
    var json_buf: [2048]u8 = undefined;
    const message = "Test notification";
    const event_type = "test_event";

    const json_payload = std.fmt.bufPrint(
        &json_buf,
        "{{\"event\":\"{s}\",\"message\":\"{s}\"}}",
        .{ event_type, message },
    ) catch unreachable;

    try std.testing.expectEqualStrings(
        "{\"event\":\"test_event\",\"message\":\"Test notification\"}",
        json_payload,
    );
}

test "Traffic alert JSON format" {
    var json_buf: [2048]u8 = undefined;
    const interface_name = "eth0";
    const rx_bytes: u64 = 1024 * 1024 * 100;
    const tx_bytes: u64 = 1024 * 1024 * 50;
    const quota_bytes: u64 = 1024 * 1024 * 1024;

    const json_payload = std.fmt.bufPrint(
        &json_buf,
        "{{\"event\":\"traffic_quota_alert\",\"interface\":\"{s}\",\"rx_bytes\":{d},\"tx_bytes\":{d},\"quota_bytes\":{d}}}",
        .{ interface_name, rx_bytes, tx_bytes, quota_bytes },
    ) catch unreachable;

    try std.testing.expect(std.mem.indexOf(u8, json_payload, "eth0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_payload, "traffic_quota_alert") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_payload, "\"rx_bytes\":104857600") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_payload, "\"tx_bytes\":52428800") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_payload, "\"quota_bytes\":1073741824") != null);
}

test "Simple message JSON format" {
    var json_buf: [4096]u8 = undefined;
    const message = "Simple test message";

    const json_payload = std.fmt.bufPrint(
        &json_buf,
        "{{\"message\":\"{s}\"}}",
        .{message},
    ) catch unreachable;

    try std.testing.expectEqualStrings(
        "{\"message\":\"Simple test message\"}",
        json_payload,
    );
}
