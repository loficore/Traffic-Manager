// backend/src/common.zig
// 共享工具模块：存放 quota.zig、后续 client.zig 等共同使用的纯函数。
// 本模块零依赖（不 import 任何项目内模块），解析语义自 quota.zig 原样迁移，
// 属于公共契约，禁止改动。
const std = @import("std");
const Allocator = std.mem.Allocator;

// 测试专用：libc setenv 声明（仅供内联测试块注入 XDG_RUNTIME_DIR 使用；
// 所有产物——exe 与测试二进制——均已链接 libc，故文件级 extern 可安全引用）
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// 解析人类可读的流量单位字符串为字节数。
/// 支持：B、KB、MB、GB、TB（大小写不敏感）；裸数字按字节解释。
/// 出错返回 error.InvalidUnit（非法输入）或 error.Overflow（乘法溢出）。
/// 语义自 quota.zig 原样迁移，禁止改动。
pub fn parseTrafficUnit(s: []const u8) !u64 {
    if (s.len == 0) return error.InvalidUnit;

    // 找到数字与单位的边界：数字前缀之后即为单位部分
    var digit_end: usize = 0;
    while (digit_end < s.len and isDigit(s[digit_end])) : (digit_end += 1) {}

    // 纯单位字符串（无数字前缀）直接拒绝
    if (digit_end == 0) return error.InvalidUnit;

    const num_str = s[0..digit_end];
    const unit_str = s[digit_end..];

    // 数字前缀无法解析为 u64 视为非法输入
    const num = std.fmt.parseInt(u64, num_str, 10) catch return error.InvalidUnit;

    const multiplier: u64 = if (unit_str.len == 0)
        1 // 无单位后缀：裸字节数
    else
        unitToMultiplier(unit_str) orelse return error.InvalidUnit;

    // 溢出防护：num × multiplier 超出 u64 时显式报 Overflow
    const result = std.math.mul(u64, num, multiplier) catch return error.Overflow;
    return result;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// 单位后缀 → 乘数（2^10 进制逐级放大）
fn unitToMultiplier(unit: []const u8) ?u64 {
    if (unit.len == 0) return null;

    const multipliers = [_]struct { suffix: []const u8, value: u64 }{
        .{ .suffix = "B", .value = 1 },
        .{ .suffix = "KB", .value = 1024 },
        .{ .suffix = "MB", .value = 1024 * 1024 },
        .{ .suffix = "GB", .value = 1024 * 1024 * 1024 },
        .{ .suffix = "TB", .value = 1024 * 1024 * 1024 * 1024 },
    };

    // 大小写不敏感匹配
    for (multipliers) |m| {
        if (std.ascii.eqlIgnoreCase(unit, m.suffix)) return m.value;
    }
    return null;
}

/// 读取环境变量。Zig 0.16 的 std 层不再提供免 libc 的 getenv（posix.getenv 已移除），
/// 故借由 std.c 经 libc 读取。返回的 slice 指向进程环境区，存活期随进程，不可释放。
fn getEnv(comptime name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

/// 目录可写性探测：在目标目录内创建唯一探针文件并删除（沿用 pidfile.isPathWritable 思路）。
/// 仅验证目录本身是否可写；任何异常一律视为不可写。
fn dirIsWritable(dir: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var name_buf: [192]u8 = undefined;
    const probe_name = std.fmt.bufPrint(&name_buf, "{s}/.socket_probe_{d}", .{ dir, std.os.linux.getpid() }) catch return false;
    const file = std.Io.Dir.createFileAbsolute(io, probe_name, .{
        .truncate = true,
        .exclusive = true,
    }) catch return false;
    file.close(io);
    std.Io.Dir.deleteFileAbsolute(io, probe_name) catch {};
    return true;
}

/// 解析 socket 路径，按优先级：
/// 1. explicit 非空 → 原样返回；
/// 2. $XDG_RUNTIME_DIR 非空且可写 → <xdg>/traffic-manager.sock；
/// 3. <home>/.local/run/traffic-manager.sock；
/// 4. 无 home → /tmp/traffic-manager.sock。
/// 返回的内存由调用方负责释放。仅 Linux。
pub fn resolveSocketPath(allocator: Allocator, home_dir: ?[]const u8, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |p| {
        if (p.len > 0) {
            // 显式路径：内容原样保留，dupe 便于调用方统一释放（沿用 pidfile.resolvePath 惯例）
            return allocator.dupe(u8, p);
        }
    }

    // XDG 运行目录优先级最高：避免流量守护进程长期占用家目录盘 I/O
    if (getEnv("XDG_RUNTIME_DIR")) |xdg| {
        const xdg_trimmed = std.mem.trimEnd(u8, xdg, "/");
        if (xdg_trimmed.len > 0 and dirIsWritable(xdg_trimmed)) {
            return std.fmt.allocPrint(allocator, "{s}/traffic-manager.sock", .{xdg_trimmed});
        }
    }

    // 回退到用户级运行时目录
    if (home_dir) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/run/traffic-manager.sock", .{home});
    }

    // 无 HOME：最后兜底 /tmp
    return allocator.dupe(u8, "/tmp/traffic-manager.sock");
}

// =============================================================================
// Tests
// =============================================================================

test "parseTrafficUnit: 全单位 happy path" {
    try std.testing.expectEqual(@as(u64, 100), try parseTrafficUnit("100"));
    try std.testing.expectEqual(@as(u64, 1), try parseTrafficUnit("1B"));
    try std.testing.expectEqual(@as(u64, 1024), try parseTrafficUnit("1KB"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024), try parseTrafficUnit("1MB"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), try parseTrafficUnit("1GB"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024 * 1024), try parseTrafficUnit("1TB"));
}

test "parseTrafficUnit: 非法输入 error path" {
    try std.testing.expectError(error.InvalidUnit, parseTrafficUnit(""));
    try std.testing.expectError(error.InvalidUnit, parseTrafficUnit("GB"));
    try std.testing.expectError(error.InvalidUnit, parseTrafficUnit("abc"));
    // 不支持小数（无小数点扫描逻辑），如实断言其报 InvalidUnit
    try std.testing.expectError(error.InvalidUnit, parseTrafficUnit("1.5GB"));
}

test "parseTrafficUnit: u64 溢出报 Overflow" {
    // maxU64 × TB 必然溢出，验证显式溢出路径
    try std.testing.expectError(error.Overflow, parseTrafficUnit("18446744073709551615TB"));
}

test "resolveSocketPath: explicit 优先" {
    const allocator = std.testing.allocator;
    const p = try resolveSocketPath(allocator, "/home/user", "/var/run/traffic.sock");
    defer allocator.free(p);
    try std.testing.expectEqualStrings("/var/run/traffic.sock", p);
}

test "resolveSocketPath: XDG_RUNTIME_DIR 非空优先于 home" {
    const allocator = std.testing.allocator;
    // 注入可写的 /tmp 作为 XDG 运行目录；explicit 为空走 XDG 分支
    try std.testing.expectEqual(@as(c_int, 0), setenv("XDG_RUNTIME_DIR", "/tmp", 1));
    defer _ = setenv("XDG_RUNTIME_DIR", "", 1); // 复原为空值（视为未设置）

    const p = try resolveSocketPath(allocator, "/home/user", null);
    defer allocator.free(p);
    try std.testing.expectEqualStrings("/tmp/traffic-manager.sock", p);
}

test "resolveSocketPath: 无 XDG 时回退 home" {
    const allocator = std.testing.allocator;
    // 确保 XDG_RUNTIME_DIR 为空值（未设置），走 home 分支
    _ = setenv("XDG_RUNTIME_DIR", "", 1);
    defer _ = setenv("XDG_RUNTIME_DIR", "", 1);

    const p = try resolveSocketPath(allocator, "/home/user", null);
    defer allocator.free(p);
    try std.testing.expectEqualStrings("/home/user/.local/run/traffic-manager.sock", p);
}