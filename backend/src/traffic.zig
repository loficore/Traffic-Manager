const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

pub const TrafficError = error{
    NetworkCardNameError,
    InterfaceNotFound,
    FileAccessFailed,
    ParseError,
    OutOfMemory,
};

pub const TrafficStatistics = struct {
    raw_rx_bytes: u64 = 0,
    raw_tx_bytes: u64 = 0,
    raw_rx_packets: u64 = 0,
    raw_tx_packets: u64 = 0,
    raw_rx_errors: u32 = 0,
    raw_tx_errors: u32 = 0,

    rx_speed_bps: u64 = 0,
    tx_speed_bps: u64 = 0,
    rx_pps: u32 = 0,
    tx_pps: u32 = 0,

    total_rx_bytes: u64 = 0,
    total_tx_bytes: u64 = 0,

    timestamp_ms: i64 = 0,
};

pub const TrafficTracker = struct {
    last_stats: ?TrafficStatistics = null,

    pub fn init(initial_stats: ?TrafficStatistics) TrafficTracker {
        return .{
            .last_stats = initial_stats,
        };
    }

    /// 读取并更新流量数据，自动计算速率与溢出补偿
    pub fn update(self: *TrafficTracker, network_card_name: []const u8, allocator: Allocator, io: Io) TrafficError!TrafficStatistics {
        if (network_card_name.len >= 64 or network_card_name.len == 0) {
            return TrafficError.NetworkCardNameError;
        }

        // 从 /proc/net/dev 读取原始内核计数器
        var current = try fetchProcNetDev(network_card_name, allocator, io);

    // 获取当前 Unix 时间戳 (毫秒)：0.16 中通过 Io.Timestamp.now(io, .real) 获取
    current.timestamp_ms = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));

        // 计算增量与速率
        if (self.last_stats) |last| {
            const time_delta_ms = current.timestamp_ms - last.timestamp_ms;

            if (time_delta_ms > 0) {
                const time_delta_sec = @as(f64, @floatFromInt(time_delta_ms)) / 1000.0;

                // 计算 RX (下行) 增量与溢出补偿
                const rx_delta = calcDelta(last.raw_rx_bytes, current.raw_rx_bytes);
                current.rx_speed_bps = @intFromFloat(@as(f64, @floatFromInt(rx_delta)) / time_delta_sec);
                current.total_rx_bytes = last.total_rx_bytes + rx_delta;

                // 计算 TX (上行) 增量与溢出补偿
                const tx_delta = calcDelta(last.raw_tx_bytes, current.raw_tx_bytes);
                current.tx_speed_bps = @intFromFloat(@as(f64, @floatFromInt(tx_delta)) / time_delta_sec);
                current.total_tx_bytes = last.total_tx_bytes + tx_delta;

                // 计算 PPS (包速率)
                const rx_pkt_delta = calcDelta(last.raw_rx_packets, current.raw_rx_packets);
                current.rx_pps = @intCast(@as(u64, @intFromFloat(@as(f64, @floatFromInt(rx_pkt_delta)) / time_delta_sec)));

                const tx_pkt_delta = calcDelta(last.raw_tx_packets, current.raw_tx_packets);
                current.tx_pps = @intCast(@as(u64, @intFromFloat(@as(f64, @floatFromInt(tx_pkt_delta)) / time_delta_sec)));
            }
        } else {
            // 第一次采样，累计值直接赋初始值，速率为 0
            current.total_rx_bytes = current.raw_rx_bytes;
            current.total_tx_bytes = current.raw_tx_bytes;
        }

        self.last_stats = current;
        return current;
    }
};

/// 枚举系统所有网卡名称（解析 /proc/net/dev 的接口名部分）。
/// 返回的切片与其中每个字符串均由 allocator 分配，调用方负责释放。
pub fn listInterfaces(allocator: Allocator, io: Io) TrafficError![][]const u8 {
    var file = Dir.openFileAbsolute(io, "/proc/net/dev", .{
        .mode = .read_only,
    }) catch return TrafficError.FileAccessFailed;
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    const bytes_read = file.readPositionalAll(io, &buf, 0) catch return TrafficError.FileAccessFailed;
    const content = buf[0..bytes_read];

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |name| allocator.free(name);
        list.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // 接口行形如 "eth0: 12345 678 ..."，以冒号分隔接口名与统计字段；
        // 文件头两行（Inter-| Receive / face |bytes...）不含冒号，直接跳过。
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (name.len == 0) continue;

        try list.append(allocator, try allocator.dupe(u8, name));
    }

    return list.toOwnedSlice(allocator);
}

/// 自动选择默认网卡：返回第一个非回环（lo）网卡的名称。
/// 返回值由 allocator 分配，调用方负责释放。
pub fn findDefaultInterface(allocator: Allocator, io: Io) TrafficError![]const u8 {
    const ifaces = try listInterfaces(allocator, io);
    defer {
        for (ifaces) |name| allocator.free(name);
        allocator.free(ifaces);
    }

    for (ifaces) |name| {
        if (!std.mem.eql(u8, name, "lo")) return allocator.dupe(u8, name);
    }
    return TrafficError.InterfaceNotFound;
}

fn calcDelta(last: u64, current: u64) u64 {
    // 正常递增
    if (current >= last) {
        return current - last;
    }

    // 32 位溢出回绕判断：
    // 要求 last 必须在大数值区间（例如 > 2GB），且 current 跌回低位（< 1GB）
    const threshold_2gb = 0x8000_0000; // 2,147,483,648
    if (last >= threshold_2gb and last <= std.math.maxInt(u32) and current < (1024 * 1024 * 1024)) {
        const u32_period: u64 = @as(u64, std.math.maxInt(u32)) + 1;
        return (u32_period - last) + current;
    }

    // 否则视为网卡重启/PPPoE重连等导致的计数器清零，直接返回 current
    return current;
}

fn fetchProcNetDev(network_card_name: []const u8, allocator: Allocator, io: Io) TrafficError!TrafficStatistics {
    _ = allocator; // 使用固定栈 Buffer，无需内存分配

    // 打开 /proc/net/dev（Zig 0.16 使用 openFileAbsolute + readPositionalAll）
    var file = Dir.openFileAbsolute(io, "/proc/net/dev", .{
        .mode = .read_only,
    }) catch return TrafficError.FileAccessFailed;
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    const bytes_read = file.readPositionalAll(io, &buf, 0) catch return TrafficError.FileAccessFailed;
    const content = buf[0..bytes_read];

    // 按行分割并解析字段
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, network_card_name)) |_| {
            var tokens = std.mem.tokenizeAny(u8, line, " :\t\r");

            const iface_tok = tokens.next() orelse continue;
            if (!std.mem.eql(u8, iface_tok, network_card_name)) continue;

            var stats = TrafficStatistics{};

            // RX 字段：bytes packets errs drop fifo frame compressed multicast
            stats.raw_rx_bytes = parseU64(tokens.next()) catch return TrafficError.ParseError;
            stats.raw_rx_packets = parseU64(tokens.next()) catch return TrafficError.ParseError;
            stats.raw_rx_errors = parseU32(tokens.next()) catch return TrafficError.ParseError;

            // 跳过 5 个无用字段 (drop, fifo, frame, compressed, multicast)
            _ = tokens.next();
            _ = tokens.next();
            _ = tokens.next();
            _ = tokens.next();
            _ = tokens.next();

            // TX 字段：bytes packets errs drop fifo colls carrier compressed
            stats.raw_tx_bytes = parseU64(tokens.next()) catch return TrafficError.ParseError;
            stats.raw_tx_packets = parseU64(tokens.next()) catch return TrafficError.ParseError;
            stats.raw_tx_errors = parseU32(tokens.next()) catch return TrafficError.ParseError;

            return stats;
        }
    }

    return TrafficError.InterfaceNotFound;
}

inline fn parseU64(opt_str: ?[]const u8) !u64 {
    const str = opt_str orelse return error.InvalidFormat;
    return std.fmt.parseInt(u64, str, 10);
}

inline fn parseU32(opt_str: ?[]const u8) !u32 {
    const str = opt_str orelse return error.InvalidFormat;
    return std.fmt.parseInt(u32, str, 10);
}

test "TrafficTracker initialization" {
    // 默认空初始化
    const tracker_default = TrafficTracker.init(null);
    try std.testing.expect(tracker_default.last_stats == null);

    // 带初始预设值的初始化
    const mock_initial = TrafficStatistics{
        .raw_rx_bytes = 1000,
        .raw_tx_bytes = 500,
        .timestamp_ms = 1000000,
    };
    const tracker_preset = TrafficTracker.init(mock_initial);

    try std.testing.expect(tracker_preset.last_stats != null);
    try std.testing.expectEqual(@as(u64, 1000), tracker_preset.last_stats.?.raw_rx_bytes);
}

test "calcDelta logic" {
    // 正常递增
    try std.testing.expectEqual(@as(u64, 500), calcDelta(1000, 1500));

    // 32位溢出绕回 (例如从 4GB 附近溢出归零)
    const max_u32 = std.math.maxInt(u32);
    try std.testing.expectEqual(@as(u64, 100), calcDelta(max_u32 - 50, 49));

    //  接口重启/清零 (last 很大但未达到 32位上限，current 突然变成很小的数)
    try std.testing.expectEqual(@as(u64, 200), calcDelta(88888888, 200));
}

test "listInterfaces and findDefaultInterface on Linux" {
    // 依赖 /proc/net/dev，仅支持 Linux
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.testing.allocator;

    // 至少能枚举出网卡，且包含回环口 lo
    const ifaces = try listInterfaces(allocator, io);
    defer {
        for (ifaces) |name| allocator.free(name);
        allocator.free(ifaces);
    }
    try std.testing.expect(ifaces.len > 0);

    var has_lo = false;
    for (ifaces) |name| {
        if (std.mem.eql(u8, name, "lo")) has_lo = true;
    }
    try std.testing.expect(has_lo);

    // 自动检测出的默认网卡不应是回环口
    const default = try findDefaultInterface(allocator, io);
    defer allocator.free(default);
    try std.testing.expect(!std.mem.eql(u8, default, "lo"));
}
