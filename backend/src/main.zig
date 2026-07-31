// backend/src/main.zig
// Traffic Manager 后端 Demo
//
// 在 backend/ 目录下运行：
//   zig build run                自动选择默认网卡，每秒采样一次
//   zig build run -- -d 2 -i eth0 每 2 秒采样一次 eth0
//   zig build run -- -l          列出系统所有网卡
const std = @import("std");
pub const traffic = @import("traffic.zig");
pub const storage = @import("storage.zig");

const Allocator = std.mem.Allocator;

pub const AppConfig = struct {
    /// 采样间隔时间（秒），默认 1 秒
    interval_sec: u64 = 1,
    /// 指定网卡，默认为 null（自动匹配）
    interface: ?[]const u8 = null,
    /// 仅列出系统网卡后退出
    list_only: bool = false,
    /// 查询 N 天历史流量，0 表示不查询
    day_count: u32 = 0,
    /// -d/--duration 是否被显式指定
    interval_explicit: bool = false,
};

pub fn parseArgs(allocator: Allocator, args_vec: std.process.Args) !AppConfig {
    var config = AppConfig{};

    var args = try std.process.Args.Iterator.initAllocator(args_vec, allocator);
    defer args.deinit();

    // 跳过第 0 个参数（程序自身路径）
    _ = args.skip();

    while (args.next()) |arg| {
        // 采样间隔（秒）
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--duration")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: -d/--duration 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            config.interval_sec = std.fmt.parseInt(u64, val_str, 10) catch {
                std.debug.print("错误: -d/--duration 参数值 '{s}' 不是有效数字!\n", .{val_str});
                return error.InvalidArgumentValue;
            };
            config.interval_explicit = true;
        }
        // 指定监听网卡
        else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interface")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: -i/--interface 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            // args.deinit() 会释放 val_str，因此复制一份
            config.interface = try allocator.dupe(u8, val_str);
        }
        // 列出网卡
        else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            config.list_only = true;
        }
        // 查询历史流量
        else if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--day")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: -D/--day 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            config.day_count = std.fmt.parseInt(u32, val_str, 10) catch {
                std.debug.print("错误: -D/--day 参数值 '{s}' 不是有效数字!\n", .{val_str});
                return error.InvalidArgumentValue;
            };
        }
        // 帮助
        else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        }
    }

    return config;
}

fn printHelp() void {
    std.debug.print(
        \\Traffic Manager — 网卡流量监控 Demo
        \\
        \\用法: traffic-backend [选项]
        \\
        \\选项:
        \\  -d, --duration <秒>    采样间隔（默认: 1）
        \\  -i, --interface <名>   指定监听网卡（例如: eth0, wlan0）
        \\  -l, --list             列出系统所有网卡后退出
        \\  -D, --day <天数>        显示最近 N 天流量统计（最多显示 3 天详情）
        \\  -h, --help             显示帮助信息
        \\
        \\示例:
        \\  traffic-backend                自动选择默认网卡，每秒采样一次
        \\  traffic-backend -d 2 -i eth0   每 2 秒采样一次 eth0
        \\  traffic-backend -l             查看系统有哪些网卡
        \\  traffic-backend -D 3           显示最近 3 天的流量统计
        \\
    , .{});
}

// Zig 0.16 标准入口：runtime 自动提供带泄漏检测的 allocator、Io 实例与命令行参数
pub fn main(init: std.process.Init) !void {
    // 安装 SIGINT / SIGTERM 处理器，使进程退出前有机会保存历史数据
    installSignalHandlers();
    const home_dir = init.environ_map.get("HOME");
    try runDemo(init.io, init.gpa, init.minimal.args, home_dir);
}

/// 全局退出标志，由信号处理器置位
var should_exit: std.atomic.Value(bool) = .init(false);

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    should_exit.store(true, .release);
}

fn installSignalHandlers() void {
    const posix = std.posix;
    if (posix.Sigaction == void) return;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &act, null);
    posix.sigaction(.TERM, &act, null);
}

fn runDemo(io: std.Io, allocator: Allocator, args_vec: std.process.Args, home_dir: ?[]const u8) !void {
    const config = try parseArgs(allocator, args_vec);
    defer if (config.interface) |iface| allocator.free(iface);

    if (config.list_only) {
        try printInterfaceList(io, allocator);
        return;
    }

    if (config.day_count > 0) {
        try printDayStats(io, allocator, config.day_count, home_dir);
        if (!config.interval_explicit) {
            return;
        }
    }

    if (config.interval_sec == 0) {
        std.debug.print("错误: 采样间隔必须大于 0 秒\n", .{});
        return error.InvalidInterval;
    }

    // 初始化历史存储（用于记录每日流量）
    const state_path = storage.defaultStateFilePath(allocator, home_dir) catch |err| {
        std.debug.print("警告: 无法确定状态文件路径 ({s})，历史记录功能已禁用\n", .{@errorName(err)});
        return runLiveMonitor(io, allocator, config, null);
    };
    defer allocator.free(state_path);

    var stor = storage.Storage.init(allocator, io, state_path);
    stor.load() catch |err| {
        std.debug.print("警告: 加载历史记录失败 ({s})，将创建新记录\n", .{@errorName(err)});
    };
    defer {
        stor.save() catch {};
        stor.deinit();
    }

    try runLiveMonitor(io, allocator, config, &stor);
}

fn runLiveMonitor(io: std.Io, allocator: Allocator, config: AppConfig, stor: ?*storage.Storage) !void {
    // 解析监听网卡
    const iface = if (config.interface) |name|
        try allocator.dupe(u8, name)
    else
        traffic.findDefaultInterface(allocator, io) catch |err| {
            std.debug.print("错误: 未找到可用网卡 ({s})，请用 -i <name> 手动指定\n", .{@errorName(err)});
            return err;
        };
    defer allocator.free(iface);

    var tracker = traffic.TrafficTracker.init(null);

    try printOut(io, "\n============ Traffic Manager Demo ============\n", .{});
    try printOut(io, "  网卡: {s}    采样间隔: {d} 秒    按 Ctrl+C 退出\n", .{ iface, config.interval_sec });
    try printOut(io, "--------------------------------------------------------------\n", .{});
    try printOut(io, "  时间          ↓ 下行速率      ↑ 上行速率      ↓ PPS    ↑ PPS    累计下行        累计上行\n", .{});
    try printOut(io, "--------------------------------------------------------------\n", .{});

    var time_buf: [16]u8 = undefined;
    var rx_speed_buf: [24]u8 = undefined;
    var tx_speed_buf: [24]u8 = undefined;
    var rx_total_buf: [24]u8 = undefined;
    var tx_total_buf: [24]u8 = undefined;
    // 首次采样后立即保存（确保有数据），此后每 30 次采样保存一次
    var sample_count: u64 = 0;

    while (!should_exit.load(.acquire)) {
        const stats = tracker.update(iface, allocator, io) catch |err| {
            std.debug.print("采样失败: {s}\n", .{@errorName(err)});
            return err;
        };

        try printOut(io, "{s}   {s:>13}   {s:>13}   {d:>7}   {d:>7}   {s:>14}   {s:>14}\n", .{
            formatTimestamp(&time_buf, stats.timestamp_ms),
            formatBytes(&rx_speed_buf, stats.rx_speed_bps, "/s"),
            formatBytes(&tx_speed_buf, stats.tx_speed_bps, "/s"),
            stats.rx_pps,
            stats.tx_pps,
            formatBytes(&rx_total_buf, stats.total_rx_bytes, ""),
            formatBytes(&tx_total_buf, stats.total_tx_bytes, ""),
        });

        // 更新历史记录：首次采样立即保存，之后每 30 次保存一次
        sample_count += 1;
        if (stor) |s| {
            if (sample_count == 1 or sample_count % 30 == 0) {
                const epoch_secs: u64 = @intCast(@divTrunc(stats.timestamp_ms, 1000));
                s.update(stats, epoch_secs) catch {};
                s.save() catch {};
            }
        }

        // 使用 clock_nanosleep（保证被信号中断，不会自动重启）
        const sleep_ns: u64 = config.interval_sec * std.time.ns_per_s;
        var req = std.os.linux.timespec{ .sec = @intCast(@divTrunc(sleep_ns, std.time.ns_per_s)), .nsec = @intCast(@mod(sleep_ns, std.time.ns_per_s)) };
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = false }, &req, &rem);
        // clock_nanosleep 返回 EINTR 时，循环顶部的 should_exit 检查会捕获退出信号
    }

    // 收到信号，保存并退出
    if (stor) |s| {
        const now_ms = std.Io.Timestamp.now(io, .real).nanoseconds;
        const epoch_secs: u64 = @intCast(@divTrunc(now_ms, std.time.ns_per_s));
        if (sample_count > 0) {
            const last_stats = tracker.last_stats orelse return;
            s.update(last_stats, epoch_secs) catch {};
        }
        s.save() catch {};
    }
}

fn printInterfaceList(io: std.Io, allocator: Allocator) !void {
    const ifaces = traffic.listInterfaces(allocator, io) catch |err| {
        std.debug.print("错误: 无法读取网卡列表: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (ifaces) |name| allocator.free(name);
        allocator.free(ifaces);
    }

    try printOut(io, "系统网卡列表（{d} 个）:\n", .{ifaces.len});
    for (ifaces, 0..) |name, i| {
        try printOut(io, "  [{d}] {s}\n", .{ i + 1, name });
    }
    try printOut(io, "提示: 使用 -i <name> 指定要监听的网卡\n", .{});
}

fn printDayStats(io: std.Io, allocator: Allocator, day_count: u32, home_dir: ?[]const u8) !void {
    const state_path = storage.defaultStateFilePath(allocator, home_dir) catch {
        std.debug.print("错误: 无法确定状态文件路径\n", .{});
        return;
    };
    defer allocator.free(state_path);

    var stor = storage.Storage.init(allocator, io, state_path);
    stor.load() catch |err| {
        std.debug.print("错误: 加载历史记录失败: {s}\n", .{@errorName(err)});
        return;
    };
    defer stor.deinit();

    const days = stor.getLastDays(@intCast(day_count));
    if (days.len == 0) {
        try printOut(io, "\n暂无历史流量记录。请先运行一段时间后再查询。\n", .{});
        return;
    }

    const show_detail = @min(days.len, 3);

    try printOut(io, "\n============ 最近 {d} 天流量统计 ============\n", .{day_count});
    try printOut(io, "  日期            累计下行       累计上行       下行包数      上行包数\n", .{});
    try printOut(io, "--------------------------------------------------------------\n", .{});

    var rx_buf: [24]u8 = undefined;
    var tx_buf: [24]u8 = undefined;

    for (days, 0..) |record, i| {
        if (i < show_detail) {
            try printOut(io, "  {s}     {s:>14}   {s:>14}   {d:>11}   {d:>11}\n", .{
                formatDate(record.date),
                formatBytes(&rx_buf, record.total_rx_bytes, ""),
                formatBytes(&tx_buf, record.total_tx_bytes, ""),
                record.total_rx_packets,
                record.total_tx_packets,
            });
        }
    }

    // 汇总行
    if (days.len > 1) {
        var sum_rx: u64 = 0;
        var sum_tx: u64 = 0;
        for (days) |r| {
            sum_rx += r.total_rx_bytes;
            sum_tx += r.total_tx_bytes;
        }
        try printOut(io, "--------------------------------------------------------------\n", .{});
        try printOut(io, "  合计（{d} 天）    {s:>14}   {s:>14}\n", .{
            days.len,
            formatBytes(&rx_buf, sum_rx, ""),
            formatBytes(&tx_buf, sum_tx, ""),
        });
    }

    try printOut(io, "--------------------------------------------------------------\n", .{});
    if (days.len < day_count) {
        try printOut(io, "  注: 仅找到 {d} 天记录（请求 {d} 天）\n", .{ days.len, day_count });
    }
    try printOut(io, "  提示: 先运行 traffic-backend 一段时间积累数据，再用 -D N 查看统计\n\n", .{});
}

/// 向标准输出打印一行（可被管道/重定向捕获）
fn printOut(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.print(fmt, args);
    try w.flush();
}

/// 将毫秒时间戳格式化为 HH:MM:SS
fn formatTimestamp(buf: []u8, timestamp_ms: i64) []const u8 {
    const secs: u64 = @intCast(@divTrunc(timestamp_ms, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "??:??:??";
}

/// 将字节数格式化为人类可读形式，如 "1.5 MB"，suffix 用于附加 "/s" 等后缀
fn formatBytes(buf: []u8, bytes: u64, comptime suffix: []const u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    var value: f64 = @floatFromInt(bytes);
    var idx: usize = 0;
    while (value >= 1024.0 and idx + 1 < units.len) : (idx += 1) {
        value /= 1024.0;
    }

    if (idx == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}{s}", .{ bytes, units[0], suffix }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}{s}", .{ value, units[idx], suffix }) catch buf[0..0];
}

/// 将 days-since-epoch 格式化为 YYYY-MM-DD
fn formatDate(days_since_epoch: u32) []const u8 {
    const secs = @as(u64, days_since_epoch) * 86400;
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(&format_date_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
    }) catch "?000-00-00";
}
var format_date_buf: [16]u8 = undefined;

// 引入 traffic 模块的所有测试
test {
    std.testing.refAllDecls(traffic);
    std.testing.refAllDecls(storage);
}
