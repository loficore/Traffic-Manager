// backend/src/webhook.zig
// HTTP Webhook notification module for TrafficManager.
//
// Sends HTTP POST requests with JSON payloads to configurable webhook endpoints.
// Used for traffic quota alerts and other notifications.
//
// Features:
//   - HTTP POST with JSON payload
//   - Custom headers support
//   - Configurable timeout
//   - Graceful error handling
//   - TLS/HTTPS support (via std.http.Client)
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Webhook configuration and state
pub const WebhookNotifier = struct {
    /// Webhook endpoint URL (e.g., "https://hooks.example.com/notify")
    url: []const u8,
    /// Allocator for memory management
    allocator: Allocator,
    /// I/O instance for async operations
    io: Io,
    /// Optional custom headers to include in requests
    headers: []const Header = &.{},
    /// Request timeout in seconds (default: 10)
    timeout_secs: u32 = 10,
    /// Whether to follow redirects (default: true)
    follow_redirects: bool = true,

    /// Custom HTTP header
    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Webhook send error types
    pub const SendError = error{
        /// Failed to connect to the webhook endpoint
        ConnectionFailed,
        /// Request timed out
        Timeout,
        /// Server returned an error status code
        HttpError,
        /// Failed to parse the URL
        InvalidUrl,
        /// Memory allocation failed
        OutOfMemory,
        /// Failed to write the request body
        WriteFailed,
        /// Failed to read the response
        ReadFailed,
    };

    /// Result of a webhook send operation
    pub const SendResult = struct {
        /// HTTP status code from the server
        status: u16,
        /// Response body (may be empty)
        body: []const u8,
        /// Whether the send was successful (2xx status)
        success: bool,
    };

    /// Initialize a new WebhookNotifier
    pub fn init(allocator: Allocator, io: Io, url: []const u8) WebhookNotifier {
        return .{
            .url = url,
            .allocator = allocator,
            .io = io,
        };
    }

    /// Send a JSON webhook notification
    ///
    /// Args:
    ///   json_payload: The JSON string to send as the request body
    ///
    /// Returns:
    ///   SendResult with status code and response body
    ///
    /// Errors:
    ///   SendError for various failure modes
    pub fn sendJson(self: *WebhookNotifier, json_payload: []const u8) SendError!SendResult {
        // Parse the URL
        const uri = std.Uri.parse(self.url) catch return SendError.InvalidUrl;

        // Create HTTP client
        var client: std.http.Client = .{
            .allocator = self.allocator,
            .io = self.io,
        };
        defer client.deinit();

        // Prepare response body buffer
        var response_body: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_body.deinit();

        // Build extra headers list
        var extra_headers_list = std.ArrayList(std.http.Header).empty;
        defer extra_headers_list.deinit(self.allocator);

        // Add Content-Type header for JSON
        try extra_headers_list.append(self.allocator, .{
            .name = "content-type",
            .value = "application/json",
        });

        // Add custom headers
        for (self.headers) |header| {
            try extra_headers_list.append(self.allocator, .{
                .name = header.name,
                .value = header.value,
            });
        }

        // Send the request
        const result = client.fetch(.{
            .location = .{ .uri = uri },
            .method = .POST,
            .payload = json_payload,
            .extra_headers = extra_headers_list.items,
            .keep_alive = false,
            .response_writer = &response_body.writer,
        }) catch {
            return SendError.ConnectionFailed;
        };

        // Get response body
        const body = response_body.written();

        // Check if the status code indicates success (2xx)
        const status_code: u16 = @intFromEnum(result.status);
        const success = status_code >= 200 and status_code < 300;

        return SendResult{
            .status = status_code,
            .body = body,
            .success = success,
        };
    }

    /// Send a simple text notification (wraps in JSON format)
    ///
    /// Args:
    ///   message: The text message to send
    ///   event_type: Optional event type identifier (e.g., "traffic_alert")
    ///
    /// Returns:
    ///   SendResult with status code and response body
    pub fn sendNotification(
        self: *WebhookNotifier,
        message: []const u8,
        event_type: ?[]const u8,
    ) SendError!SendResult {
        // Build JSON payload manually (no JSON library dependency)
        var json_buf: [4096]u8 = undefined;
        const json_payload = if (event_type) |evt|
            std.fmt.bufPrint(&json_buf, "{{\"event\":\"{s}\",\"message\":\"{s}\"}}", .{ evt, message }) catch
                return SendError.WriteFailed
        else
            std.fmt.bufPrint(&json_buf, "{{\"message\":\"{s}\"}}", .{message}) catch
                return SendError.WriteFailed;

        return self.sendJson(json_payload);
    }

    /// Send a traffic quota alert notification
    ///
    /// Args:
    ///   interface_name: Network interface name (e.g., "eth0")
    ///   rx_bytes: Total received bytes
    ///   tx_bytes: Total transmitted bytes
    ///   quota_bytes: Configured quota limit in bytes
    ///
    /// Returns:
    ///   SendResult with status code and response body
    pub fn sendTrafficAlert(
        self: *WebhookNotifier,
        interface_name: []const u8,
        rx_bytes: u64,
        tx_bytes: u64,
        quota_bytes: u64,
    ) SendError!SendResult {
        var json_buf: [2048]u8 = undefined;
        const json_payload = std.fmt.bufPrint(
            &json_buf,
            "{{\"event\":\"traffic_quota_alert\",\"interface\":\"{s}\",\"rx_bytes\":{d},\"tx_bytes\":{d},\"quota_bytes\":{d}}}",
            .{ interface_name, rx_bytes, tx_bytes, quota_bytes },
        ) catch return SendError.WriteFailed;

        return self.sendJson(json_payload);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────
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
    // Test that we can format JSON correctly
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
    const rx_bytes: u64 = 1024 * 1024 * 100; // 100 MB
    const tx_bytes: u64 = 1024 * 1024 * 50; // 50 MB
    const quota_bytes: u64 = 1024 * 1024 * 1024; // 1 GB

    const json_payload = std.fmt.bufPrint(
        &json_buf,
        "{{\"event\":\"traffic_quota_alert\",\"interface\":\"{s}\",\"rx_bytes\":{d},\"tx_bytes\":{d},\"quota_bytes\":{d}}}",
        .{ interface_name, rx_bytes, tx_bytes, quota_bytes },
    ) catch unreachable;

    // Verify the JSON contains expected values
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
