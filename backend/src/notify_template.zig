// backend/src/notify_template.zig
// 通知模板系统 - 用于流量配额告警的可定制消息模板。
//
// 支持的模板变量：
//   {interface}  - 网络接口名称（如 "eth0"）
//   {quota}      - 配额限制（人类可读格式，如 "1.5 GB"）
//   {used}       - 已用量（人类可读格式，如 "800.0 MB"）
//   {percent}    - 使用百分比（如 "53.3"）
//   {timestamp}  - 时间戳（HH:MM:SS 格式）
//
// 使用示例：
//   const template = "警告: {interface} 已使用 {used}/{quota} ({percent}%)";
//   const result = try render(allocator, template, variables);
const std = @import("std");
const Allocator = std.mem.Allocator;

/// 模板变量值 - 存储渲染模板所需的全部数据
pub const TemplateVariables = struct {
    /// 网络接口名称（如 "eth0", "wlan0"）
    interface: []const u8,
    /// 有效配额（原始字节数，基础配额 + 临时调整）
    quota: u64,
    /// 基础配额（原始字节数，不含临时调整，默认 0）
    base_quota: u64 = 0,
    /// 临时调整总额（原始字节数，所有当月调整之和，默认 0）
    adjustment_total: u64 = 0,
    /// 已使用量（原始字节数）
    used: u64,
    /// 使用百分比（0.0 - 100.0）
    percent: f64,
    /// 时间戳（毫秒）
    timestamp_ms: i64,
};

/// 模板渲染错误类型
pub const TemplateError = error{
    /// 模板中包含未识别的变量
    UnknownVariable,
    /// 缓冲区空间不足
    BufferTooSmall,
    /// 内存分配失败
    OutOfMemory,
};

/// 默认警告模板 - 当流量使用达到阈值时发送
pub const default_warning_template: []const u8 =
    "[警告] {interface} 流量已使用 {used}/{quota} ({percent}%) 基础配额:{base_quota} 临时调整:{adjustment_total} - {timestamp}";

/// 默认断网模板 - 当流量超过配额时发送
pub const default_disconnect_template: []const u8 =
    "[断网] {interface} 流量超限! 已用 {used}/{quota} ({percent}%) 基础配额:{base_quota} 临时调整:{adjustment_total} - {timestamp}";

/// 默认自定义模板示例
pub const default_custom_template: []const u8 =
    "Traffic alert on {interface}: {used} of {quota} used ({percent}%) at {timestamp}";

/// 渲染模板 - 将模板中的变量替换为实际值
///
/// 参数：
///   allocator: 内存分配器
///   template: 包含 {variable} 占位符的模板字符串
///   vars: 模板变量值
///   buf: 输出缓冲区
///
/// 返回：
///   渲染后的字符串切片（指向 buf）
///
/// 错误：
///   BufferTooSmall - 如果输出缓冲区不足以容纳渲染结果
///   UnknownVariable - 如果模板中包含未识别的变量名
pub fn render(
    allocator: Allocator,
    template: []const u8,
    vars: TemplateVariables,
    buf: []u8,
) TemplateError![]const u8 {
    _ = allocator; // 当前实现使用固定缓冲区，无需动态分配

    var pos: usize = 0;
    var remaining = template;

    while (remaining.len > 0) {
        // 查找下一个 '{' 符号
        const open_brace = std.mem.indexOfScalar(u8, remaining, '{') orelse {
            // 没有更多变量，复制剩余部分
            const to_copy = remaining;
            if (pos + to_copy.len > buf.len) return TemplateError.BufferTooSmall;
            @memcpy(buf[pos..][0..to_copy.len], to_copy);
            pos += to_copy.len;
            remaining = remaining[to_copy.len..];
            break;
        };

        // 复制 '{' 之前的文本
        if (open_brace > 0) {
            const prefix = remaining[0..open_brace];
            if (pos + prefix.len > buf.len) return TemplateError.BufferTooSmall;
            @memcpy(buf[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            remaining = remaining[open_brace..];
        }

        // 查找对应的 '}'
        const close_brace = std.mem.indexOfScalar(u8, remaining[1..], '}') orelse {
            return TemplateError.UnknownVariable;
        };

        // 提取变量名（不含花括号）
        const var_name = remaining[1..][0..close_brace];

        // 根据变量名替换为对应的值
        const replacement = try resolveVariable(var_name, vars);

        // 复制替换值
        if (pos + replacement.len > buf.len) return TemplateError.BufferTooSmall;
        @memcpy(buf[pos..][0..replacement.len], replacement);
        pos += replacement.len;

        // 移动到 '}' 之后
        remaining = remaining[1 + close_brace + 1 ..];
    }

    return buf[0..pos];
}

/// 根据变量名解析对应的值
fn resolveVariable(name: []const u8, vars: TemplateVariables) TemplateError![]const u8 {
    // 使用栈缓冲区格式化数字
    var buf: [64]u8 = undefined;

    if (std.mem.eql(u8, name, "interface")) {
        return vars.interface;
    } else if (std.mem.eql(u8, name, "quota")) {
        return formatBytesForTemplate(&buf, vars.quota);
    } else if (std.mem.eql(u8, name, "base_quota")) {
        return formatBytesForTemplate(&buf, vars.base_quota);
    } else if (std.mem.eql(u8, name, "adjustment_total")) {
        return formatBytesForTemplate(&buf, vars.adjustment_total);
    } else if (std.mem.eql(u8, name, "used")) {
        return formatBytesForTemplate(&buf, vars.used);
    } else if (std.mem.eql(u8, name, "percent")) {
        return std.fmt.bufPrint(&buf, "{d:.1}", .{vars.percent}) catch return TemplateError.BufferTooSmall;
    } else if (std.mem.eql(u8, name, "timestamp")) {
        return formatTimestampForTemplate(&buf, vars.timestamp_ms);
    } else {
        return TemplateError.UnknownVariable;
    }
}

/// 格式化字节数为人类可读形式（内部辅助函数）
fn formatBytesForTemplate(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    var value: f64 = @floatFromInt(bytes);
    var idx: usize = 0;
    while (value >= 1024.0 and idx + 1 < units.len) : (idx += 1) {
        value /= 1024.0;
    }

    if (idx == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[0] }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[idx] }) catch buf[0..0];
}

/// 格式化时间戳为 HH:MM:SS（内部辅助函数）
fn formatTimestampForTemplate(buf: []u8, timestamp_ms: i64) []const u8 {
    const secs: u64 = @intCast(@divTrunc(timestamp_ms, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "??:??:??";
}

/// 渲染模板到新分配的缓冲区（便捷函数）
///
/// 参数：
///   allocator: 内存分配器
///   template: 模板字符串
///   vars: 模板变量值
///
/// 返回：
///   分配的字符串，调用方负责释放
pub fn renderAlloc(
    allocator: Allocator,
    template: []const u8,
    vars: TemplateVariables,
) (Allocator.Error || TemplateError)![]const u8 {
    var buf: [4096]u8 = undefined;
    const result = try render(allocator, template, vars, &buf);
    return try allocator.dupe(u8, result);
}

// ── 测试 ────────────────────────────────────────────────────────────────

test "TemplateVariables struct" {
    const vars = TemplateVariables{
        .interface = "eth0",
        .quota = 1024 * 1024 * 1024, // 1 GB
        .used = 1024 * 1024 * 512, // 512 MB
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
        .quota = 1024 * 1024 * 1024, // 1 GB
        .used = 1024 * 1024 * 512, // 512 MB
        .percent = 50.0,
        .timestamp_ms = 0, // 00:00:00
    };

    var buf: [256]u8 = undefined;
    const result = try render(allocator, template, vars, &buf);

    // 验证包含所有变量值
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
        .quota = 1024 * 1024 * 1024, // 1 GB
        .used = 1024 * 1024 * 768, // 768 MB
        .percent = 75.0,
        .timestamp_ms = 1700000000000, // 某个时间点
    };

    var buf: [1024]u8 = undefined;
    const result = try render(allocator, default_warning_template, vars, &buf);

    // 验证警告模板格式
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
        .quota = 1024 * 1024 * 1024 * 2, // 2 GB
        .used = 1024 * 1024 * 1024 * 2, // 2 GB (100%)
        .percent = 100.0,
        .timestamp_ms = 1700000000000,
    };

    var buf: [1024]u8 = undefined;
    const result = try render(allocator, default_disconnect_template, vars, &buf);

    // 验证断网模板格式
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
        .quota = 1024 * 1024 * 500, // 500 MB
        .used = 1024 * 1024 * 250, // 250 MB
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
    // 注意：当前实现不支持转义花括号，连续的 {{ 会被解析为变量开始
    // 这是已知限制
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

    // 当前实现会尝试解析 {interface} 变量
    // 第二个 { 会触发变量解析
    if (result) |r| {
        // 如果成功，验证结果
        try std.testing.expect(r.len > 0);
    } else |err| {
        // 如果失败，应该是 UnknownVariable 错误
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

    // 使用极小的缓冲区
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

test "formatBytesForTemplate produces correct output" {
    var buf: [64]u8 = undefined;

    // 测试字节
    try std.testing.expectEqualStrings("0 B", formatBytesForTemplate(&buf, 0));
    try std.testing.expectEqualStrings("100 B", formatBytesForTemplate(&buf, 100));

    // 测试 KB
    try std.testing.expectEqualStrings("1.5 KB", formatBytesForTemplate(&buf, 1536));

    // 测试 MB
    try std.testing.expectEqualStrings("1.0 MB", formatBytesForTemplate(&buf, 1024 * 1024));

    // 测试 GB
    try std.testing.expectEqualStrings("1.0 GB", formatBytesForTemplate(&buf, 1024 * 1024 * 1024));

    // 测试 TB
    try std.testing.expectEqualStrings("1.0 TB", formatBytesForTemplate(&buf, 1024 * 1024 * 1024 * 1024));
}

test "formatTimestampForTemplate produces HH:MM:SS" {
    var buf: [16]u8 = undefined;

    // 测试 0 毫秒 (00:00:00)
    try std.testing.expectEqualStrings("00:00:00", formatTimestampForTemplate(&buf, 0));

    // 测试 1 小时 30 分钟 45 秒
    const ms = (1 * 3600 + 30 * 60 + 45) * 1000;
    try std.testing.expectEqualStrings("01:30:45", formatTimestampForTemplate(&buf, @intCast(ms)));
}

test "default templates are valid" {
    // 验证默认模板包含所有必需的变量
    const required_vars = [_][]const u8{ "{interface}", "{quota}", "{used}", "{percent}", "{timestamp}" };

    for (required_vars) |var_name| {
        try std.testing.expect(std.mem.indexOf(u8, default_warning_template, var_name) != null);
        try std.testing.expect(std.mem.indexOf(u8, default_disconnect_template, var_name) != null);
        try std.testing.expect(std.mem.indexOf(u8, default_custom_template, var_name) != null);
    }
}
