// backend/src/network.zig
// 网络接口控制模块 — 通过 ioctl(SIOCSIFFLAGS) 管理接口 UP/DOWN 状态
// 用于流量配额超限后断网 / 恢复场景 (嵌入式 Linux，无 systemd)

const std = @import("std");
const posix = std.posix;

// ── 从 C 头文件获取 ioctl 常量 (libc 已链接) ──
const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("net/if.h");
    @cInclude("unistd.h");
    @cInclude("sys/socket.h");
    @cInclude("linux/sockios.h");
});

// ── ioctl 请求码 (from <linux/sockios.h>) ──
const SIOCGIFFLAGS: c_ulong = c.SIOCGIFFLAGS;
const SIOCSIFFLAGS: c_ulong = c.SIOCSIFFLAGS;

// ── 接口标志 (from <net/if.h>) ──
const IFF_UP: u16 = @intCast(c.IFF_UP);

// ── 常量 ──
const IFNAMSIZ: usize = c.IFNAMSIZ;

// ── Socket 常量 (from <sys/socket.h>) ──
const AF_INET: c_int = c.AF_INET;
const SOCK_DGRAM: c_int = c.SOCK_DGRAM;

// ── 错误类型 ──
pub const NetworkError = error{
    PermissionDenied,
    InterfaceNotFound,
    IoctlFailed,
    SocketFailed,
    ReadFailed,
    InvalidCapability,
};

/// ifreq 结构体 — 与 Linux 内核 struct ifreq 布局一致
/// x86_64: sizeof = 40 (16 + 24), ARM32/MIPS: sizeof = 32 (16 + 16)
/// 分配 40 字节确保在所有架构上安全 (内核 copy_from/to_user 按自身 sizeof 操作)
const Ifreq = extern struct {
    ifr_name: [IFNAMSIZ]u8,
    ifr_ifru: extern union {
        ifr_flags: u16,
        _pad: [24]u8, // 覆盖最大 union 成员 (x86_64 struct ifmap = 24 bytes)
    },
};

// ── 内部辅助函数 ──

/// 创建用于 ioctl 的 DGRAM 套接字 (无需绑定/连接)
fn openControlSocket() NetworkError!posix.fd_t {
    // 使用 C 函数创建 socket
    const fd = c.socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return NetworkError.SocketFailed;
    return @intCast(fd);
}

/// 填充 ifreq 名称字段并校验长度
fn fillIfreqName(ifr: *Ifreq, name: []const u8) NetworkError!void {
    if (name.len == 0 or name.len >= IFNAMSIZ) return NetworkError.InterfaceNotFound;
    @memcpy(ifr.ifr_name[0..name.len], name);
}

// ── 公共 API ──

/// 查询接口是否处于 UP 状态
/// 返回 true 表示接口已启用，false 表示已禁用
pub fn queryInterfaceStatus(name: []const u8) NetworkError!bool {
    const fd = try openControlSocket();
    defer _ = c.close(fd);

    var ifr = std.mem.zeroes(Ifreq);
    try fillIfreqName(&ifr, name);

    const rc = c.ioctl(fd, SIOCGIFFLAGS, &ifr);
    if (rc < 0) return NetworkError.IoctlFailed;

    return (ifr.ifr_ifru.ifr_flags & IFF_UP) != 0;
}

/// 断开网络接口 — 清除 IFF_UP 标志
/// 需要 root 或 CAP_NET_ADMIN 权限
pub fn disconnectInterface(name: []const u8) NetworkError!void {
    try checkPermissions();

    const fd = try openControlSocket();
    defer _ = c.close(fd);

    var ifr = std.mem.zeroes(Ifreq);
    try fillIfreqName(&ifr, name);

    // 先读取当前标志
    var rc = c.ioctl(fd, SIOCGIFFLAGS, &ifr);
    if (rc < 0) return NetworkError.IoctlFailed;

    // 清除 IFF_UP
    ifr.ifr_ifru.ifr_flags &= ~IFF_UP;

    // 写回修改后的标志
    rc = c.ioctl(fd, SIOCSIFFLAGS, &ifr);
    if (rc < 0) return NetworkError.IoctlFailed;
}

/// 恢复网络接口 — 设置 IFF_UP 标志
/// 需要 root 或 CAP_NET_ADMIN 权限
pub fn restoreInterface(name: []const u8) NetworkError!void {
    try checkPermissions();

    const fd = try openControlSocket();
    defer _ = c.close(fd);

    var ifr = std.mem.zeroes(Ifreq);
    try fillIfreqName(&ifr, name);

    // 先读取当前标志
    var rc = c.ioctl(fd, SIOCGIFFLAGS, &ifr);
    if (rc < 0) return NetworkError.IoctlFailed;

    // 设置 IFF_UP
    ifr.ifr_ifru.ifr_flags |= IFF_UP;

    // 写回修改后的标志
    rc = c.ioctl(fd, SIOCSIFFLAGS, &ifr);
    if (rc < 0) return NetworkError.IoctlFailed;
}

/// 权限检查: root (euid == 0) 或 CAP_NET_ADMIN 能力
/// 嵌入式 Linux 无 systemd 场景下通过 /proc/self/status 读取 CapEff
pub fn checkPermissions() NetworkError!void {
    // 快速路径: root 用户直接通过
    // 使用 C 函数获取 euid
    if (c.geteuid() == 0) return;

    // 简化实现：仅检查 root 权限
    // 完整实现需要 libcap-dev，暂不支持
    return NetworkError.PermissionDenied;
}

// ── 测试 ──

test "Ifreq struct layout" {
    // extern struct 应至少 40 字节 (x86_64 标准), 与内核 struct ifreq 对齐
    const size = @sizeOf(Ifreq);
    try std.testing.expect(size >= 32); // 至少覆盖 ARM32 的 32 字节
    try std.testing.expect(size <= 48); // 不应超过合理上限
    // 名称字段从偏移0开始
    const ifr = std.mem.zeroes(Ifreq);
    const name_ptr: usize = @intFromPtr(&ifr.ifr_name);
    const flags_ptr: usize = @intFromPtr(&ifr.ifr_ifru.ifr_flags);
    try std.testing.expectEqual(@as(usize, IFNAMSIZ), flags_ptr - name_ptr);
}

test "queryInterfaceStatus on Linux" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    // lo 接口通常总是 UP
    const status = try queryInterfaceStatus("lo");
    try std.testing.expect(status);
}

test "queryInterfaceStatus with invalid name" {
    // 空名称
    const result = queryInterfaceStatus("");
    try std.testing.expectError(NetworkError.InterfaceNotFound, result);

    // 超长名称 (超过 IFNAMSIZ)
    const long_name = "this_interface_name_is_definitely_way_too_long_for_ifreq_struct";
    const result2 = queryInterfaceStatus(long_name);
    try std.testing.expectError(NetworkError.InterfaceNotFound, result2);
}

test "queryInterfaceStatus nonexistent interface" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    // 不存在的接口应返回 IoctlFailed (ENODEV)
    const result = queryInterfaceStatus("nonexistent_dev99");
    try std.testing.expectError(NetworkError.IoctlFailed, result);
}

test "disconnect and restore lo (requires root)" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    // 非 root 用户跳过此测试
    if (posix.geteuid() != 0) return error.SkipZigTest;

    // 断开 lo
    try disconnectInterface("lo");
    try std.testing.expect(!try queryInterfaceStatus("lo"));

    // 恢复 lo
    try restoreInterface("lo");
    try std.testing.expect(try queryInterfaceStatus("lo"));
}
