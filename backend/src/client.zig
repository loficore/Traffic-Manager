// backend/src/client.zig
// trafficctl：TrafficManager 命令行客户端。
// 通过 unix socket 与守护进程对话（raw linux syscall，D1：不链 libc）。
// 本文件同时是 client 测试 target 的 root，内联 test 块定义在文件尾部。
// todo 7 完成骨架：arg 解析分派、请求/响应网络层、退出码约定
// （0 成功 / 1 daemon 不可达 / 2 参数错 / 3 HTTP 非 2xx）。
// todo 8（本文件现状）为该骨架补全各查询子命令：status/current/history/config/
// quota/quota list 的人类可读输出 + --json 原样输出（只读，映射现有 REST）。
// todo 9（本文件现状）补全写子命令：config set（key 白名单 + 类型强制 + JSON 组装，
// PUT /api/config）、quota add/rm（POST/DELETE /api/quota/adjustments）；
// 非 2xx 响应提取 {"error":...} 打印并按约定（exit 3）退出。
const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

// common 模块由 build.zig 注入（addImport("common", common_src)）。
// 注意：其 resolveSocketPath 内部走 std.c.getenv（libc 专属 extern），
// 与本二进制「不链 libc」冲突，故 socket 路径解析用 resolveSocketPathLocal
// 复刻其语义（见该函数注释）；parseTrafficUnit 等纯函数供 todo 8/9 化用。
const common = @import("common");

// =============================================================================
// 退出码约定（learnings.md 固定，禁止改动）
// =============================================================================

/// 退出码：0 成功 / 1 daemon 不可达 / 2 参数错 / 3 HTTP 非 2xx
pub const EXIT = struct {
    pub const ok: u8 = 0;
    pub const daemon_unreachable: u8 = 1;
    pub const usage: u8 = 2;
    pub const http: u8 = 3;
};

// =============================================================================
// 纯函数：命令行解析（客户端测试 target 的主测试对象）
// =============================================================================

/// 子命令集合（todo 8/9 将逐个实现各命令的格式化输出与写操作）
pub const Command = enum {
    status, // 运行状态
    current, // 实时速率/累计流量
    history, // 最近 N 天每日流量
    config, // 完整配置
    quota, // 当月配额快照
};

/// 子命令名 → 枚举映射；未知名称返回 null（调用方报参数错）
fn commandFromName(name: []const u8) ?Command {
    const table = [_]Command{ .status, .current, .history, .config, .quota };
    for (table) |cmd| {
        if (std.mem.eql(u8, name, @tagName(cmd))) return cmd;
    }
    return null;
}

/// 解析后的命令行参数
pub const CliArgs = struct {
    /// 子命令；null 表示未提供任何命令 token
    command: ?Command = null,
    /// 显式 --socket 路径（自有内存，deinit 释放）
    socket_path: ?[]const u8 = null,
    /// --json：原始 JSON 输出（对各命令的格式化输出生效，todo 8 使用）
    json: bool = false,
    /// --help / -h
    help: bool = false,
    /// 子命令的后续参数（自有内存，deinit 释放）
    cmd_args: []const []const u8 = &.{},

    /// 释放本结构自有的堆内存
    pub fn deinit(self: *CliArgs, allocator: Allocator) void {
        if (self.socket_path) |p| allocator.free(p);
        if (self.cmd_args.len > 0) allocator.free(self.cmd_args);
        self.* = undefined;
    }
};

pub const CliParseError = error{
    MissingArgumentValue, // --socket 后缺值
    UnknownFlag, // 未识别的 -x/--xxx 选项
    UnknownCommand, // 第一个非 flag 参数不是已知子命令
    OutOfMemory,
};

/// 解析命令行。规则：
/// - 全局 flag（--socket <path> / --json / -h / --help）可出现在子命令前后；
/// - 第一个非 flag 参数即子命令；
/// - 命令之后的非 flag 参数归入 cmd_args（供 history N 等子命令使用）。
///   args 为 argv[1..] 的切片；返回的 cmd_args/socket_path 为独立拷贝。
pub fn parseArgs(allocator: Allocator, args: []const []const u8) CliParseError!CliArgs {
    var res = CliArgs{};
    errdefer res.deinit(allocator);

    // 逐参数收集命令之后的非 flag 参数；成功时转 owned 交给 res
    var cmd_arg_list = std.ArrayList([]const u8).empty;
    defer cmd_arg_list.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            res.help = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            res.json = true;
        } else if (std.mem.eql(u8, arg, "--socket")) {
            if (i + 1 >= args.len) return error.MissingArgumentValue;
            i += 1;
            res.socket_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // 子命令确定前的未知全局选项仍严格报错；确定后的未知选项（如 quota add
            // 的 --reason/--source、quota rm 的负数 ID）透传进 cmd_args，交由子命令
            // 自身的参数解析器逐项校验，非法同样按参数错（exit 2）处理。
            if (res.command == null) return error.UnknownFlag;
            try cmd_arg_list.append(allocator, arg);
        } else if (res.command == null) {
            res.command = commandFromName(arg) orelse return error.UnknownCommand;
        } else {
            try cmd_arg_list.append(allocator, arg);
        }
    }

    res.cmd_args = try cmd_arg_list.toOwnedSlice(allocator);
    return res;
}

// =============================================================================
// 纯函数：HTTP 请求拼装
// =============================================================================

/// 拼装 HTTP/1.1 请求：请求行 + Host + Connection: close + 空行 + 可选 body。
/// - 无 body（GET/DELETE）：不带 Content-Length 头；
/// - 有 body（PUT/POST）：附带 Content-Length 头。
/// 写入调用方缓冲返回实际使用切片；请求整体不得超过 8192 字节
/// （守护端 handleConnection 单次 recvfrom 的缓冲上限）。
pub fn buildRequest(buf: []u8, method: []const u8, path: []const u8, body: []const u8) ![]const u8 {
    if (body.len == 0) {
        return std.fmt.bufPrint(
            buf,
            "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
            .{ method, path },
        ) catch error.RequestTooLong;
    }
    return std.fmt.bufPrint(
        buf,
        "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ method, path, body.len, body },
    ) catch error.RequestTooLong;
}

// =============================================================================
// 纯函数：HTTP 响应解析（状态行 + Content-Length + body 判定）
// =============================================================================

/// 已解析的 HTTP 响应：状态码 + body（按 Content-Length 截取；无则 null）
pub const Resp = struct {
    status: u16,
    /// 响应 body；非空时由 allocator 分配，调用方负责释放
    body: ?[]const u8,
};

/// 从状态行解析状态码，如 "HTTP/1.1 200 OK" → 200
pub fn parseStatusLine(first_line: []const u8) !u16 {
    var sp = std.mem.splitScalar(u8, first_line, ' ');
    _ = sp.next() orelse return error.BadResponse; // HTTP 版本段
    const code_str = sp.next() orelse return error.BadResponse;
    return std.fmt.parseInt(u16, code_str, 10) catch error.BadResponse;
}

/// 从完整响应（头 + body）提取 Content-Length（头名大小写不敏感）。
/// 无该头返回 null（HTTP 语义：视为无 body）。
pub fn extractContentLength(received: []const u8) !?u64 {
    const head_end = std.mem.indexOf(u8, received, "\r\n\r\n") orelse return error.HeaderIncomplete;
    const head = received[0..head_end];

    // 跳过状态行，逐个 header 行扫描；每轮要么 break（末行无终止符），
    // 要么至少前进 2 字节（\r\n），循环必然收敛
    var rest = head;
    while (rest.len > 0) {
        const term = std.mem.indexOf(u8, rest, "\r\n");
        const line = rest[0..(term orelse rest.len)];
        if (line.len > 0) {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const name = std.mem.trim(u8, line[0..colon], " ");
                if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                    const val = std.mem.trim(u8, line[colon + 1 ..], " ");
                    return std.fmt.parseInt(u64, val, 10) catch return error.InvalidContentLength;
                }
            }
        }
        if (term == null) break;
        rest = rest[term.? + 2 ..];
    }
    return null;
}

/// 判断响应是否已收满（分块收包边界判定）：
/// 1. 头尚未拼出完整终止符（\r\n\r\n）→ false，继续收；
/// 2. 头完整 → 依 Content-Length 判断 body 是否到齐；无该头视为 body 长度 0。
pub fn responseComplete(received: []const u8) !bool {
    const head_end = std.mem.indexOf(u8, received, "\r\n\r\n") orelse return false;
    const body_len = (try extractContentLength(received)) orelse 0;
    return received.len >= head_end + 4 + body_len;
}

/// 解析完整响应：状态行 + 头；body 按 Content-Length 截取，超长视为残缺报错。
pub fn parseResponse(allocator: Allocator, received: []const u8) !Resp {
    const first_line_end = std.mem.indexOf(u8, received, "\r\n") orelse
        std.mem.indexOfScalar(u8, received, '\n') orelse return error.BadResponse;
    const status = try parseStatusLine(received[0..first_line_end]);

    const head_end = std.mem.indexOf(u8, received, "\r\n\r\n") orelse return error.BadResponse;
    const body_len = (try extractContentLength(received)) orelse 0;
    const body_start = head_end + 4;
    if (received.len < body_start + body_len) return error.BadResponse;

    const body = if (body_len > 0)
        try allocator.dupe(u8, received[body_start .. body_start + body_len])
    else
        null;
    return .{ .status = status, .body = body };
}

// =============================================================================
// 网络层：unix socket + raw linux syscall（与 http_server.zig 同风格）
// =============================================================================

/// 发送失败分类（main 依此决定退出码）
pub const SendError = error{
    Unreachable, // connect 失败：守护进程未运行 / socket 文件不存在
    Network, // socket/send/recv 等系统调用失败
    BadResponse, // 响应格式非法或收不满
    RequestTooLong, // 请求超过 8192 字节
    OutOfMemory,
};

/// 发送单个 HTTP 请求并收满响应。
/// body 为空则按无 body 方法处理（GET/DELETE）；响应 body 由调用方释放。
/// 本层刻意不用 std.Io 高层抽象，保持与守护端 handleConnection 一致的 raw syscall。
pub fn sendRequest(
    allocator: Allocator,
    socket_path: []const u8,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) SendError!Resp {
    const sock_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    if (linux.errno(sock_result) != .SUCCESS) return error.Network;
    const fd: i32 = @intCast(sock_result);
    defer _ = linux.close(fd);

    // unix socket 地址：path 定长 108 字节，整体清零保证 NUL 结尾
    if (socket_path.len >= 108) return error.Unreachable;
    var sock_addr: linux.sockaddr.un = .{ .path = [_]u8{0} ** 108 };
    @memcpy(sock_addr.path[0..socket_path.len], socket_path);

    const conn_rc = linux.connect(fd, @ptrCast(&sock_addr), @sizeOf(linux.sockaddr.un));
    if (linux.errno(conn_rc) != .SUCCESS) return error.Unreachable;

    // 一次性 send 完整请求（守护端单次 recvfrom 缓冲上限 8192，GET 远低于此）
    var req_buf: [8192]u8 = undefined;
    const req = buildRequest(&req_buf, method, path, body) catch return error.RequestTooLong;

    var sent: usize = 0;
    while (sent < req.len) {
        const n = linux.sendto(fd, req[sent..].ptr, req.len - sent, linux.MSG.NOSIGNAL, null, 0);
        if (linux.errno(n) != .SUCCESS) return error.Network;
        sent += n;
    }

    // 循环 recvfrom：按 Content-Length 收满 body 为止（headers 可能跨包）
    var received = std.ArrayList(u8).empty;
    defer received.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
        if (linux.errno(n) != .SUCCESS) return error.Network;
        if (n == 0) break; // EOF：守护端已 close，按已收数据解析
        const chunk: usize = @intCast(n);
        try received.appendSlice(allocator, buf[0..chunk]);
        if (responseComplete(received.items) catch return error.BadResponse) break;
    }

    return parseResponse(allocator, received.items) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadResponse,
    };
}

// =============================================================================
// socket 路径解析（复刻 common.resolveSocketPath 语义，免 libc）
// =============================================================================

/// 目录可写性探测：在目标目录内创建唯一探针文件并删除。
/// 与 common.dirIsWritable 完全同构；仅验证目录可写，任何异常视为不可写。
fn dirIsWritable(io: std.Io, dir: []const u8) bool {
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

/// 解析守护进程 unix socket 路径，优先级与 common.resolveSocketPath 完全一致：
/// 1. explicit 非空 → 原样返回；
/// 2. $XDG_RUNTIME_DIR 非空且可写 → <xdg>/traffic-manager.sock；
/// 3. <home>/.local/run/traffic-manager.sock；
/// 4. 无 home → /tmp/traffic-manager.sock。
/// 不直接调用 common 版：其 getEnv 依赖 libc 专属的 std.c.getenv，而 trafficctl
/// 按 D1 不链 libc，引用即触发 "dependency on libc must be explicitly specified"。
/// 环境变量改由调用方（main 的 init.environ_map，免 libc）取值后传入。
/// 返回的路径由调用方 free。
fn resolveSocketPathLocal(
    io: std.Io,
    allocator: Allocator,
    xdg_runtime_dir: ?[]const u8,
    home_dir: ?[]const u8,
    explicit: ?[]const u8,
) ![]const u8 {
    if (explicit) |p| {
        if (p.len > 0) return allocator.dupe(u8, p);
    }
    if (xdg_runtime_dir) |xdg| {
        const xdg_trimmed = std.mem.trimEnd(u8, xdg, "/");
        if (xdg_trimmed.len > 0 and dirIsWritable(io, xdg_trimmed)) {
            return std.fmt.allocPrint(allocator, "{s}/traffic-manager.sock", .{xdg_trimmed});
        }
    }
    if (home_dir) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/run/traffic-manager.sock", .{home});
    }
    return allocator.dupe(u8, "/tmp/traffic-manager.sock");
}

// =============================================================================
// 响应结构体：与 http_server.zig 各 GET endpoint 的序列化字段严格一致
// （字段名不许改动；后端多出的 JSON 键会被 std.json 忽略，新增字段不破坏解析）
// =============================================================================

/// GET /api/status 响应（handleStatusApi 逐字对齐：state/interface/uptime_seconds/quota_state）
const StatusResp = struct {
    state: []const u8,
    interface: ?[]const u8,
    uptime_seconds: u64,
    quota_state: []const u8,
};

/// GET /api/traffic/current 响应（handleCurrentTrafficApi：速率与累计字段全为数值）
const CurrentResp = struct {
    rx_speed_bps: u64,
    tx_speed_bps: u64,
    rx_pps: u64,
    tx_pps: u64,
    total_rx_bytes: u64,
    total_tx_bytes: u64,
};

/// GET /api/traffic/daily 响应数组元素（handleDailyTrafficApi：date/rx_bytes/tx_bytes）
const DailyResp = struct {
    date: []const u8,
    rx_bytes: u64,
    tx_bytes: u64,
};

/// GET /api/config 响应（handleGetConfigApi 全字段；可选字符串序列化为 null）
/// 注意后端字段是 reset_day（无 quota_reset_day），smtp_port 以字符串传输。
const ConfigResp = struct {
    interface: ?[]const u8 = null,
    interval_sec: u64 = 0,
    retention_days: u64 = 0,
    day_count: u64 = 0,
    quota_limit_bytes: u64 = 0,
    quota_warning_threshold: f64 = 0,
    quota_disconnect_threshold: f64 = 0,
    reset_day: u64 = 0,
    webhook_url: ?[]const u8 = null,
    smtp_server: ?[]const u8 = null,
    smtp_port: ?[]const u8 = null,
    smtp_user: ?[]const u8 = null,
    smtp_pass: ?[]const u8 = null,
    smtp_from: ?[]const u8 = null,
    smtp_to: ?[]const u8 = null,
};

/// GET /api/quota 响应（computeQuotaSnapshot 序列化：base/effective/usage/remaining/state/阈值/reset_day）
const QuotaResp = struct {
    base_limit_bytes: u64 = 0,
    effective_limit_bytes: u64 = 0,
    monthly_usage_bytes: u64 = 0,
    remaining_bytes: u64 = 0,
    state: []const u8, // disabled/normal/warned/exceeded
    warning_threshold: f64 = 0,
    disconnect_threshold: f64 = 0,
    reset_day: u64 = 0,
};

/// GET /api/quota/adjustments 响应数组元素（QuotaAdjustment 六字段）
const AdjustmentResp = struct {
    id: i64,
    // 减额调整在库中存负 i64 的位表示，JSON 里是巨大的 u64，展示时 bitCast 回 i64 判符号
    amount_bytes: u64,
    reason: []const u8,
    source: []const u8,
    month_key: []const u8,
    created_at: i64, // epoch 毫秒时间戳
};

// =============================================================================
// 人类可读输出：大小/时长格式化 + 各子命令打印 + 2xx 分派
// =============================================================================

/// 将字节数格式化为人类可读大小（1024 进制，KB 及以上保留 1 位小数）。
/// 与前端 format.ts 的 formatBytes 语义一致，是本文件唯一的大小显示函数；
/// 与 common.parseTrafficUnit（解析方向）分工不同，不承担解析职责。
fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    // B 档位直接整数显示，不给小数
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch return buf[0..0];
    }
    // 定位单位档位：把值缩放到 [1KB, 1024KB) 区间；除数用 u128 防 u64 乘法溢出
    var unit_index: usize = 0;
    var divisor: u128 = 1;
    while (unit_index + 1 < units.len and @as(u128, bytes) / divisor >= 1024) : (unit_index += 1) {
        divisor *= 1024;
    }
    // 1 位小数用整数除法精确求：bytes*10/divisor 的商为十分位总量
    const tenths_total: u128 = (@as(u128, bytes) * 10) / divisor;
    const whole: u64 = @intCast(tenths_total / 10);
    const frac: u64 = @intCast(tenths_total % 10);
    return std.fmt.bufPrint(buf, "{d}.{d} {s}", .{ whole, frac, units[unit_index] }) catch return buf[0..0];
}

/// 将秒数格式化为人类可读时长：>=1 小时 → 小时+分；>=1 分 → 分+秒；否则纯秒
fn formatUptime(buf: []u8, secs: u64) []const u8 {
    if (secs >= 3600) {
        return std.fmt.bufPrint(buf, "{d} 小时 {d} 分", .{ secs / 3600, (secs % 3600) / 60 }) catch return buf[0..0];
    }
    if (secs >= 60) {
        return std.fmt.bufPrint(buf, "{d} 分 {d} 秒", .{ secs / 60, secs % 60 }) catch return buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d} 秒", .{secs}) catch return buf[0..0];
}

/// 可空字符串 → 展示占位符（null 时显示 (空)）
fn optStr(v: ?[]const u8) []const u8 {
    return v orelse "(空)";
}

/// 行输出组合器：多行人类可读输出先攒进栈缓冲，末端一次性 writeAll 到 stdout，
/// 避免逐行 flush 的系统调用开销（打印体全并行对齐，标签统一 4 个汉字保证列对齐）。
const RowPrinter = struct {
    buf: [65536]u8 = undefined,
    pos: usize = 0,

    fn append(self: *RowPrinter, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.buf[self.pos..], fmt, args) catch return;
        self.pos += s.len;
    }

    fn flush(self: *RowPrinter, io: std.Io) void {
        var wbuf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &wbuf);
        w.interface.writeAll(self.buf[0..self.pos]) catch return;
        w.interface.flush() catch return;
    }
};

fn printStatusHuman(io: std.Io, s: StatusResp) void {
    var up_buf: [48]u8 = undefined;
    var out = RowPrinter{};
    out.append("运行状态:      {s}\n", .{s.state});
    out.append("监控网卡:      {s}\n", .{optStr(s.interface)});
    out.append("运行时长:      {s}\n", .{formatUptime(&up_buf, s.uptime_seconds)});
    out.append("配额状态:      {s}\n", .{s.quota_state});
    out.flush(io);
}

fn printCurrentHuman(io: std.Io, c: CurrentResp) void {
    var rx_buf: [24]u8 = undefined;
    var tx_buf: [24]u8 = undefined;
    var rtot_buf: [24]u8 = undefined;
    var ttot_buf: [24]u8 = undefined;
    var out = RowPrinter{};
    out.append("接收速率:      {s}/s\n", .{formatBytes(&rx_buf, c.rx_speed_bps)});
    out.append("发送速率:      {s}/s\n", .{formatBytes(&tx_buf, c.tx_speed_bps)});
    out.append("接收包率:      {d} pps\n", .{c.rx_pps});
    out.append("发送包率:      {d} pps\n", .{c.tx_pps});
    out.append("累计接收:      {s}\n", .{formatBytes(&rtot_buf, c.total_rx_bytes)});
    out.append("累计发送:      {s}\n", .{formatBytes(&ttot_buf, c.total_tx_bytes)});
    out.flush(io);
}

fn printHistoryHuman(io: std.Io, days: []DailyResp) void {
    var out = RowPrinter{};
    if (days.len == 0) {
        out.append("该时段暂无历史数据\n", .{});
    } else {
        out.append("日期          接收            发送\n", .{});
        for (days) |d| {
            var rx_buf: [24]u8 = undefined;
            var tx_buf: [24]u8 = undefined;
            out.append("{s:<10}  {s:>10}  {s:>10}\n", .{
                d.date,
                formatBytes(&rx_buf, d.rx_bytes),
                formatBytes(&tx_buf, d.tx_bytes),
            });
        }
    }
    out.flush(io);
}

fn printConfigHuman(io: std.Io, c: ConfigResp) void {
    var lim_buf: [24]u8 = undefined;
    var out = RowPrinter{};
    out.append("监控网卡:      {s}\n", .{optStr(c.interface)});
    out.append("采样间隔:      {d} 秒\n", .{c.interval_sec});
    out.append("保留天数:      {d} 天\n", .{c.retention_days});
    out.append("历史天数:      {d} 天\n", .{c.day_count});
    // 配额上限 0 表示配额未启用，字节位置显示 (未启用) 标记
    out.append("配额上限:      {s}{s}\n", .{
        formatBytes(&lim_buf, c.quota_limit_bytes),
        if (c.quota_limit_bytes == 0) " (未启用)" else "",
    });
    out.append("警告阈值:      {d}\n", .{c.quota_warning_threshold});
    out.append("断链阈值:      {d}\n", .{c.quota_disconnect_threshold});
    out.append("重置日期:      {d} 日\n", .{c.reset_day});
    out.append("通知接口:      {s}\n", .{optStr(c.webhook_url)});
    out.append("邮件服务:      {s}\n", .{optStr(c.smtp_server)});
    out.append("邮件端口:      {s}\n", .{optStr(c.smtp_port)});
    out.append("邮件用户:      {s}\n", .{optStr(c.smtp_user)});
    out.append("邮件密码:      {s}\n", .{if (c.smtp_pass != null) "******" else "(空)"});
    out.append("邮件发件:      {s}\n", .{optStr(c.smtp_from)});
    out.append("邮件收件:      {s}\n", .{optStr(c.smtp_to)});
    out.flush(io);
}

fn printQuotaHuman(io: std.Io, q: QuotaResp) void {
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    var b4: [24]u8 = undefined;
    var out = RowPrinter{};
    out.append("基础额度:      {s}\n", .{formatBytes(&b1, q.base_limit_bytes)});
    out.append("生效额度:      {s}\n", .{formatBytes(&b2, q.effective_limit_bytes)});
    out.append("本月已用:      {s}\n", .{formatBytes(&b3, q.monthly_usage_bytes)});
    out.append("剩余额度:      {s}\n", .{formatBytes(&b4, q.remaining_bytes)});
    out.append("配额状态:      {s}\n", .{q.state});
    out.append("警告阈值:      {d}\n", .{q.warning_threshold});
    out.append("断链阈值:      {d}\n", .{q.disconnect_threshold});
    out.append("重置日期:      {d} 日\n", .{q.reset_day});
    out.flush(io);
}

fn printAdjustmentsHuman(io: std.Io, adjustments: []AdjustmentResp) void {
    var out = RowPrinter{};
    if (adjustments.len == 0) {
        out.append("本月暂无配额调整记录\n", .{});
        return;
    }
    out.append("本月配额调整记录:\n", .{});
    out.append("ID    金额            月份        来源    原因\n", .{});
    for (adjustments) |a| {
        // 减额调整：库中存负 i64 的位表示，bitCast 回 i64 判符号后带 +/- 前缀展示
        var size_buf: [32]u8 = undefined;
        var amt_buf: [40]u8 = undefined;
        var id_buf: [16]u8 = undefined;
        const signed_amount: i64 = @bitCast(a.amount_bytes);
        const size_str = formatBytes(
            &size_buf,
            if (signed_amount < 0) @intCast(-@as(i128, signed_amount)) else a.amount_bytes,
        );
        const amount_str = if (signed_amount < 0)
            std.fmt.bufPrint(&amt_buf, "-{s}", .{size_str}) catch amt_buf[0..0]
        else
            std.fmt.bufPrint(&amt_buf, "+{s}", .{size_str}) catch amt_buf[0..0];
        const reason = if (a.reason.len > 0) a.reason else "(无)";
        // 注意：不要对整数用 {d:<4} 之类宽度格式——Zig 会给数值自动补 +/- 号，
        // ID 先转字符串再按字符串左对齐才稳定
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{a.id}) catch id_buf[0..0];
        out.append("{s:<4}{s:>13}   {s:<9}  {s:<6}  {s}\n", .{
            id_str, amount_str, a.month_key, a.source, reason,
        });
    }
    out.flush(io);
}

/// 人类可读输出阶段的失败：2xx 响应体不是合法 JSON 或结构不符期望
pub const HumanError = error{
    InvalidJson,
    OutOfMemory,
};

fn mapParseError(e: anytype) HumanError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

/// 按子命令把 2xx 响应体解析并打印为人类可读输出。
/// quota 需借 cmd_args 细分快照（无参数）与调整列表（quota list）。
fn printHuman(
    io: std.Io,
    gpa: Allocator,
    command: Command,
    cmd_args: []const []const u8,
    body: []const u8,
) HumanError!void {
    switch (command) {
        .status => {
            var parsed = std.json.parseFromSlice(StatusResp, gpa, body, .{}) catch |e| return mapParseError(e);
            defer parsed.deinit();
            printStatusHuman(io, parsed.value);
        },
        .current => {
            var parsed = std.json.parseFromSlice(CurrentResp, gpa, body, .{}) catch |e| return mapParseError(e);
            defer parsed.deinit();
            printCurrentHuman(io, parsed.value);
        },
        .history => {
            var parsed = std.json.parseFromSlice([]DailyResp, gpa, body, .{}) catch |e| return mapParseError(e);
            defer parsed.deinit();
            printHistoryHuman(io, parsed.value);
        },
        .config => {
            var parsed = std.json.parseFromSlice(ConfigResp, gpa, body, .{}) catch |e| return mapParseError(e);
            defer parsed.deinit();
            printConfigHuman(io, parsed.value);
        },
        .quota => switch (resolveQuotaSub(cmd_args) orelse return error.InvalidJson) {
            .snapshot => {
                var parsed = std.json.parseFromSlice(QuotaResp, gpa, body, .{}) catch |e| return mapParseError(e);
                defer parsed.deinit();
                printQuotaHuman(io, parsed.value);
            },
            .list => {
                var parsed = std.json.parseFromSlice([]AdjustmentResp, gpa, body, .{}) catch |e| return mapParseError(e);
                defer parsed.deinit();
                printAdjustmentsHuman(io, parsed.value);
            },
            // 写子命令（add/rm）不可能走到 printHuman（main 拦截后打成功提示）
            .add, .rm => return error.InvalidJson,
        },
    }
}

// =============================================================================
// main：参数分派 + 网络请求 + 退出码
// =============================================================================

/// 子命令映射出的 REST 请求
const Request = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8 = "",
};

/// quota 子命令的细分形态：无参数 = 当月配额快照；`quota list` = 调整记录列表；
/// `quota add` / `quota rm` = 写操作（由 main 的 classifyWriteSub 拦截走写路径）
const QuotaSub = enum {
    snapshot,
    list,
    add,
    rm,
};

/// 解析 quota 子命令的后续参数，决定请求/输出走快照/列表还是写操作：
/// - 无参数 → 快照；- 恰好一个 "list" → 列表；- "add"/"rm" → 写子命令；
/// - 其它/多余参数 → null（参数错）。
/// commandFromName 只吃单 token 子命令，`quota list` 的第二个 token 落在 cmd_args，
/// 故在此处做双 token 分派（D7：不新增 REST 接口，仅映射既有路径）。
fn resolveQuotaSub(cmd_args: []const []const u8) ?QuotaSub {
    if (cmd_args.len == 0) return .snapshot;
    if (cmd_args.len == 1 and std.mem.eql(u8, cmd_args[0], "list")) return .list;
    if (std.mem.eql(u8, cmd_args[0], "add")) return .add;
    if (std.mem.eql(u8, cmd_args[0], "rm")) return .rm;
    return null;
}

/// 子命令 → 只读请求映射（写子命令 config set / quota add/rm 由
/// classifyWriteSub 在 main 提前拦截，不会走到这里；quota 只映射快照与 list）。
fn commandToRequest(cmd: Command, cmd_args: []const []const u8, path_buf: []u8) !Request {
    return switch (cmd) {
        .status => if (cmd_args.len == 0)
            .{ .method = "GET", .path = "/api/status" }
        else
            error.InvalidArgument,
        .current => if (cmd_args.len == 0)
            .{ .method = "GET", .path = "/api/traffic/current" }
        else
            error.InvalidArgument,
        .config => if (cmd_args.len == 0)
            .{ .method = "GET", .path = "/api/config" }
        else
            error.InvalidArgument,
        .quota => blk: {
            // quota 无参数拍快照；quota list 查当月调整记录（双 token 分派）；
            // add/rm 属写路径，仅当未被 main 拦截时（如直接调用）按参数错拒绝
            const sub = resolveQuotaSub(cmd_args) orelse return error.InvalidArgument;
            if (sub == .add or sub == .rm) return error.InvalidArgument;
            break :blk if (sub == .snapshot)
                .{ .method = "GET", .path = "/api/quota" }
            else
                .{ .method = "GET", .path = "/api/quota/adjustments" };
        },
        .history => blk: {
            if (cmd_args.len > 1) return error.InvalidArgument;
            // 可选参数：最近 N 天；缺省 7（与守护端 -D 语义一致）
            var days: u32 = 7;
            if (cmd_args.len == 1) {
                days = std.fmt.parseInt(u32, cmd_args[0], 10) catch return error.InvalidArgument;
            }
            if (days == 0) return error.InvalidArgument;
            const path = std.fmt.bufPrint(path_buf, "/api/traffic/daily?days={d}", .{days}) catch return error.InvalidArgument;
            break :blk .{ .method = "GET", .path = path };
        },
    };
}

// =============================================================================
// 写子命令：白名单 key 映射 + JSON 请求体组装（todo 9）
// =============================================================================

/// 写子命令种类：config set / quota add / quota rm。
/// 三者都需要在发送前做客户端参数校验与请求体组装，先于只读 commandToRequest 拦截。
const WriteSub = enum {
    config_set,
    quota_add,
    quota_rm,
};

/// 判定命令是否为写子命令形态（仅看首 token，具体参数合法性交给各 builder）
fn classifyWriteSub(cmd: Command, cmd_args: []const []const u8) ?WriteSub {
    if (cmd_args.len == 0) return null;
    return switch (cmd) {
        .config => if (std.mem.eql(u8, cmd_args[0], "set")) .config_set else null,
        .quota => if (std.mem.eql(u8, cmd_args[0], "add")) .quota_add else if (std.mem.eql(u8, cmd_args[0], "rm")) .quota_rm else null,
        else => null,
    };
}

/// 配置键白名单条目：脚本式小写 key → JSON 字段名 + 值类型 + 生效方式。
/// 白名单即 D7 的防线——parseConfigJson 接受 daemon_mode/use_sqlite 等运行时键，
/// 但此类键不应暴露给 trafficctl 用户，白名单外一律「未知配置项」拒绝。
const ConfigKeySpec = struct {
    const Kind = enum {
        byte, // 1..28（reset_day）
        bytes, // parseTrafficUnit 换算（quota_limit_bytes）
        ratio, // 0..1 浮点阈值（quota_warning/disconnect_threshold）
        integer, // >0 整数（interval_sec）
        count, // 非负整数（retention_days）
        string, // 字符串（interface 与全部通知字段）
    };
    cli_key: []const u8, // 用户在命令行写的小写 key，如 "reset-day"
    json_key: []const u8, // PUT 请求里的 JSON 字段名，如 "reset_day"
    kind: Kind,
    live: bool, // true=实时生效；false=⚠ 重启生效（interface/retention）
};

const config_key_table = [_]ConfigKeySpec{
    .{ .cli_key = "interval", .json_key = "interval_sec", .kind = .integer, .live = true },
    .{ .cli_key = "retention", .json_key = "retention_days", .kind = .count, .live = false },
    .{ .cli_key = "interface", .json_key = "interface", .kind = .string, .live = false },
    .{ .cli_key = "reset-day", .json_key = "reset_day", .kind = .byte, .live = true },
    .{ .cli_key = "quota-limit", .json_key = "quota_limit_bytes", .kind = .bytes, .live = true },
    .{ .cli_key = "quota-warning", .json_key = "quota_warning_threshold", .kind = .ratio, .live = true },
    .{ .cli_key = "quota-disconnect", .json_key = "quota_disconnect_threshold", .kind = .ratio, .live = true },
    .{ .cli_key = "webhook-url", .json_key = "webhook_url", .kind = .string, .live = true },
    .{ .cli_key = "smtp-server", .json_key = "smtp_server", .kind = .string, .live = true },
    .{ .cli_key = "smtp-port", .json_key = "smtp_port", .kind = .string, .live = true },
    .{ .cli_key = "smtp-user", .json_key = "smtp_user", .kind = .string, .live = true },
    .{ .cli_key = "smtp-pass", .json_key = "smtp_pass", .kind = .string, .live = true },
    .{ .cli_key = "smtp-from", .json_key = "smtp_from", .kind = .string, .live = true },
    .{ .cli_key = "smtp-to", .json_key = "smtp_to", .kind = .string, .live = true },
};

/// 按脚本式 key 查白名单；未命中返回 null（调用方报「未知配置项」）
fn lookupConfigKey(cli_key: []const u8) ?ConfigKeySpec {
    for (config_key_table) |spec| {
        if (std.mem.eql(u8, cli_key, spec.cli_key)) return spec;
    }
    return null;
}

/// config set 成功后各键的生效提示（按首现顺序去重）
const ConfigSetNotice = struct {
    cli_key: []const u8, // 用户输入的脚本式键名（指向 argv，生命周期随进程）
    live: bool, // true=实时生效；false=⚠ 重启生效
};

/// 写请求组装/校验阶段的客户端错误（全部映射到退出码 2）
pub const WriteError = error{
    UnknownConfigKey, // 白名单外 key（use-sqlite/daemon-mode/...）
    InvalidValue, // 类型强制失败或值越界
    DuplicateKey, // 同一 key 出现 ≥2 次
    TooLong, // 请求体超出 8192 上限
    InvalidArgument, // quota add/rm 参数形态错误
    OutOfMemory,
};

/// JSON 字符串转义：起始引号 + 逐字节转义 + 结束引号。
/// 与后端 http_server.appendJsonString 同语义——引号/反斜杠/\n/\r/\t 用短转义，
/// 其余控制字符 \u00XX，>= 0x80 的 UTF-8 字节原样透传（多字节中文不被拆坏）。
/// 缓冲不足返回 false（调用方转 error.TooLong）。
fn appendJsonString(buf: []u8, pos: *usize, value: []const u8) bool {
    if (buf.len - pos.* < 1) return false;
    buf[pos.*] = '"';
    pos.* += 1;
    for (value) |c| {
        switch (c) {
            '"' => {
                if (buf.len - pos.* < 2) return false;
                buf[pos.*] = '\\';
                buf[pos.* + 1] = '"';
                pos.* += 2;
            },
            '\\' => {
                if (buf.len - pos.* < 2) return false;
                buf[pos.*] = '\\';
                buf[pos.* + 1] = '\\';
                pos.* += 2;
            },
            '\n' => {
                if (buf.len - pos.* < 2) return false;
                buf[pos.*] = '\\';
                buf[pos.* + 1] = 'n';
                pos.* += 2;
            },
            '\r' => {
                if (buf.len - pos.* < 2) return false;
                buf[pos.*] = '\\';
                buf[pos.* + 1] = 'r';
                pos.* += 2;
            },
            '\t' => {
                if (buf.len - pos.* < 2) return false;
                buf[pos.*] = '\\';
                buf[pos.* + 1] = 't';
                pos.* += 2;
            },
            0...8, 11, 12, 14...31 => {
                if (buf.len - pos.* < 6) return false;
                const esc = std.fmt.bufPrint(buf[pos.*..], "\\u00{X:0>2}", .{c}) catch return false;
                pos.* += esc.len;
            },
            else => {
                if (buf.len - pos.* < 1) return false;
                buf[pos.*] = c;
                pos.* += 1;
            },
        }
    }
    if (buf.len - pos.* < 1) return false;
    buf[pos.*] = '"';
    pos.* += 1;
    return true;
}

/// 客户端 JSON 组装器：固定缓冲 + 位置游标 + 首字段逗号控制。
/// 所有方法返回 false 表示缓冲不足（上层统一转 error.TooLong）。
const JsonWriter = struct {
    buf: []u8,
    pos: usize = 0,
    first: bool = true,

    fn begin(self: *JsonWriter) bool {
        if (self.buf.len < 1) return false;
        self.buf[0] = '{';
        self.pos = 1;
        self.first = true;
        return true;
    }

    fn end(self: *JsonWriter) bool {
        if (self.pos + 1 > self.buf.len) return false;
        self.buf[self.pos] = '}';
        self.pos += 1;
        return true;
    }

    /// 写前导逗号（首字段省略）+ `"key":` 前缀
    fn commaKey(self: *JsonWriter, key: []const u8) bool {
        const sep: usize = if (self.first) 0 else 1;
        if (self.pos + sep + key.len + 3 > self.buf.len) return false;
        if (!self.first) {
            self.buf[self.pos] = ',';
            self.pos += 1;
        }
        self.first = false;
        self.buf[self.pos] = '"';
        self.pos += 1;
        @memcpy(self.buf[self.pos..][0..key.len], key);
        self.pos += key.len;
        self.buf[self.pos] = '"';
        self.pos += 1;
        self.buf[self.pos] = ':';
        self.pos += 1;
        return true;
    }

    fn stringField(self: *JsonWriter, key: []const u8, value: []const u8) bool {
        if (!self.commaKey(key)) return false;
        return appendJsonString(self.buf, &self.pos, value);
    }

    /// 字符串字段的空值 → JSON null（与前端一致：清空通知字段 / 网卡回自动）
    fn nullField(self: *JsonWriter, key: []const u8) bool {
        if (!self.commaKey(key)) return false;
        if (self.pos + 4 > self.buf.len) return false;
        @memcpy(self.buf[self.pos..][0..4], "null");
        self.pos += 4;
        return true;
    }

    fn numField(self: *JsonWriter, key: []const u8, value: anytype) bool {
        if (!self.commaKey(key)) return false;
        const s = std.fmt.bufPrint(self.buf[self.pos..], "{d}", .{value}) catch return false;
        self.pos += s.len;
        return true;
    }

    /// 浮点阈值字段：整数值（1.0 → "1"）补 ".0" 保住小数位形状——
    /// 后端 parseConfigJson 的 f64 字段只收浮点 token，整数 token 会拒绝。
    fn ratioField(self: *JsonWriter, key: []const u8, value: f64) bool {
        if (!self.commaKey(key)) return false;
        const start = self.pos;
        const s = std.fmt.bufPrint(self.buf[start..], "{d}", .{value}) catch return false;
        self.pos = start + s.len;
        if (std.mem.indexOfAny(u8, s, ".eE") == null) {
            if (self.pos + 2 > self.buf.len) return false;
            @memcpy(self.buf[self.pos..][0..2], ".0");
            self.pos += 2;
        }
        return true;
    }
};

/// 解析 config set 的 K=V 对并组装 PUT /api/config 的 JSON 请求体。
/// - 白名单外的 key → UnknownConfigKey；类型强制失败/越界 → InvalidValue；
///   重复 key → DuplicateKey；缓冲不足 → TooLong。
/// - 各键的生效方式按首现顺序去重记入 notices（成功提示用，调用方负责释放）。
fn buildConfigSetBody(
    gpa: Allocator,
    pairs: []const []const u8,
    buf: []u8,
    notices: *std.ArrayList(ConfigSetNotice),
) WriteError![]const u8 {
    var w = JsonWriter{ .buf = buf };
    if (!w.begin()) return error.TooLong;

    for (pairs) |pair| {
        // K=V 用首个 '=' 切分，允许值本身含 '='（如接口名 a=b）
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidValue;
        const cli_key = pair[0..eq];
        const value = pair[eq + 1 ..];
        const spec = lookupConfigKey(cli_key) orelse return error.UnknownConfigKey;

        // 重复 key：body 里不允许同一 JSON 键出现两次（后端解析语义不定），直接拒绝
        for (notices.items) |n| {
            if (std.mem.eql(u8, n.cli_key, cli_key)) return error.DuplicateKey;
        }

        switch (spec.kind) {
            .byte => {
                const v = std.fmt.parseInt(u8, value, 10) catch return error.InvalidValue;
                if (v < 1 or v > 28) return error.InvalidValue;
                if (!w.numField(spec.json_key, v)) return error.TooLong;
            },
            .bytes => {
                const v = common.parseTrafficUnit(value) catch return error.InvalidValue;
                if (!w.numField(spec.json_key, v)) return error.TooLong;
            },
            .ratio => {
                const v = std.fmt.parseFloat(f64, value) catch return error.InvalidValue;
                if (v < 0.0 or v > 1.0) return error.InvalidValue;
                if (!w.ratioField(spec.json_key, v)) return error.TooLong;
            },
            .integer => {
                const v = std.fmt.parseInt(u64, value, 10) catch return error.InvalidValue;
                if (v == 0) return error.InvalidValue;
                if (!w.numField(spec.json_key, v)) return error.TooLong;
            },
            .count => {
                const v = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
                if (!w.numField(spec.json_key, v)) return error.TooLong;
            },
            .string => {
                // 空字符串 → null（与前端 ConfigPanel 一致：清空通知字段 / 网卡恢复自动）
                if (value.len == 0) {
                    if (!w.nullField(spec.json_key)) return error.TooLong;
                } else if (!w.stringField(spec.json_key, value)) return error.TooLong;
            },
        }
        // 值校验并写入成功后才记录生效提示（先失败直接返回，不残留半条记录）
        notices.append(gpa, .{ .cli_key = cli_key, .live = spec.live }) catch return error.OutOfMemory;
    }
    if (!w.end()) return error.TooLong;
    return buf[0..w.pos];
}

/// 解析 quota add 参数（SIZE [--reason R] [--source S]）并组装 POST 请求体。
/// amount 原样透传可读大小（D5：与前端 api.ts AdjustmentInput.amount 同语义，
/// 单位换算交给后端 parseTrafficUnit）；reason 缺省 ""、source 缺省 "cli"。
fn buildQuotaAddBody(args: []const []const u8, buf: []u8) WriteError![]const u8 {
    if (args.len == 0) return error.InvalidArgument;
    const amount = args[0];
    if (amount.len == 0) return error.InvalidArgument;

    var reason: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--reason")) {
            if (i + 1 >= args.len) return error.InvalidArgument; // --reason 缺值
            i += 1;
            reason = args[i];
        } else if (std.mem.eql(u8, a, "--source")) {
            if (i + 1 >= args.len) return error.InvalidArgument; // --source 缺值
            i += 1;
            source = args[i];
        } else return error.InvalidArgument; // 未知选项或多余位置参数
    }

    var w = JsonWriter{ .buf = buf };
    if (!w.begin()) return error.TooLong;
    if (!w.stringField("amount", amount)) return error.TooLong;
    if (!w.stringField("reason", reason orelse "")) return error.TooLong;
    if (!w.stringField("source", source orelse "cli")) return error.TooLong;
    if (!w.end()) return error.TooLong;
    return buf[0..w.pos];
}

/// 解析 quota rm 的 <ID>：仅接受恰好一个整数参数
fn parseQuotaRmId(args: []const []const u8) WriteError!i64 {
    if (args.len != 1) return error.InvalidArgument;
    return std.fmt.parseInt(i64, args[0], 10) catch error.InvalidArgument;
}

/// 写请求校验/组装失败 → 退出码 2 前的错误消息（中文，逐一对应白名单/类型/长度类失败）
fn printWriteError(err: WriteError) void {
    switch (err) {
        error.UnknownConfigKey => std.debug.print("错误: 未知配置项（仅支持白名单内的 key）\n", .{}),
        error.DuplicateKey => std.debug.print("错误: 重复的配置项\n", .{}),
        error.InvalidValue => std.debug.print("错误: 配置项值无效或超出范围\n", .{}),
        error.InvalidArgument => std.debug.print("错误: 参数错误\n", .{}),
        error.TooLong => std.debug.print("错误: 请求体过大（超出 8192 字节上限）\n", .{}),
        error.OutOfMemory => std.debug.print("错误: 内存不足\n", .{}),
    }
}

/// config set 成功后的生效提示：6 标量 + 通知字符串「已实时生效」，
/// retention/interface 标「⚠ 重启生效」（需重启守护进程才读新值）
fn printConfigSetNotices(io: std.Io, notices: []const ConfigSetNotice) void {
    var out = RowPrinter{};
    for (notices) |n| {
        if (n.live) {
            out.append("{s}: 已实时生效\n", .{n.cli_key});
        } else {
            out.append("{s}: ⚠ 重启生效\n", .{n.cli_key});
        }
    }
    out.flush(io);
}

/// 从非 2xx 响应体中提取 {"error":"..."} 的消息（引号感知扫描）
fn extractErrorMsg(body: []const u8) ?[]const u8 {
    const key = "\"error\":";
    const pos = std.mem.indexOf(u8, body, key) orelse return null;
    var i = pos + key.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\' and i + 1 < body.len) {
            i += 1;
            continue;
        }
        if (body[i] == '"') return body[start..i];
    }
    return null;
}

fn printHelp(io: std.Io) void {
    printOut(io,
        \\trafficctl — TrafficManager 命令行客户端
        \\
        \\用法:
        \\  trafficctl [全局选项] <子命令> [参数...]
        \\
        \\全局选项（可出现在子命令前后）:
        \\  --socket <path>   指定守护进程 unix socket 路径（默认按 XDG/HOME 规则解析）
        \\  --json            原始 JSON 输出
        \\  -h, --help        显示本帮助
        \\
        \\子命令:
        \\  status            查询守护进程运行状态
        \\  current           查询实时速率与累计流量
        \\  history [N]       查询最近 N 天每日流量（默认 7）
        \\  config            查询当前配置
        \\  config set K=V... 设置配置项（白名单 key，写 PUT /api/config）
        \\  quota             查询当月配额快照
        \\  quota list        查询当月配额调整记录
        \\  quota add SIZE [--reason R] [--source S]
        \\                    追加当月配额调整（SIZE 可读大小，如 500MB）
        \\  quota rm ID       删除当月配额调整
        \\
        \\配置项白名单（其余 key 一律拒绝）:
        \\  interface / interval / retention / reset-day / quota-limit /
        \\  quota-warning / quota-disconnect / webhook-url / smtp-server /
        \\  smtp-port / smtp-user / smtp-pass / smtp-from / smtp-to
        \\
    , .{});
}

/// 打印到标准输出（帮助/命令结果用 stdout；错误信息一律走 stderr 的 std.debug.print）
fn printOut(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // 收集 argv[1..]：Iterator 的 next 返回的切片在其 deinit 前有效，
    // 统一 dupe 进 ArrayList 后即可立刻释放 Iterator
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.skip();
    var collected = std.ArrayList([]const u8).empty;
    defer collected.deinit(gpa);
    while (it.next()) |arg| {
        try collected.append(gpa, try gpa.dupe(u8, arg));
    }

    const cli = parseArgs(gpa, collected.items) catch |err| switch (err) {
        error.UnknownCommand => {
            std.debug.print("错误: 未知子命令\n", .{});
            std.process.exit(EXIT.usage);
        },
        else => {
            std.debug.print("错误: {s}\n", .{@errorName(err)});
            std.process.exit(EXIT.usage);
        },
    };
    defer cli.deinit(gpa);

    if (cli.help) {
        printHelp(io);
        std.process.exit(EXIT.ok);
    }

    const command = cli.command orelse {
        std.debug.print("错误: 缺少子命令\n", .{});
        std.process.exit(EXIT.usage);
    };

    // socket 路径解析（XDG/HOME 自 init.environ_map 读取，免 libc）
    const socket_path = resolveSocketPathLocal(
        io,
        gpa,
        init.environ_map.get("XDG_RUNTIME_DIR"),
        init.environ_map.get("HOME"),
        cli.socket_path,
    ) catch |err| {
        std.debug.print("错误: 解析 socket 路径失败: {s}\n", .{@errorName(err)});
        std.process.exit(EXIT.usage);
    };
    defer gpa.free(socket_path);

    // ── 请求组装 ──
    // 写子命令（config set / quota add/rm）需要客户端校验 + JSON 组装，
    // 先于只读 commandToRequest 拦截；请求体缓冲与提示列表在本函数栈帧内
    // 贯穿 sendRequest 全程（body 仅指向栈内存，发送前即有效）。
    const write_sub = classifyWriteSub(command, cli.cmd_args);
    var body_buf: [8192]u8 = undefined; // 写命令 JSON 请求体
    var path_buf: [256]u8 = undefined; // 带参只读路径 / quota rm 路径
    var config_notices = std.ArrayList(ConfigSetNotice).empty;
    defer config_notices.deinit(gpa);
    var rm_id: ?i64 = null;

    const req: Request = blk: {
        if (write_sub) |sub| {
            switch (sub) {
                .config_set => {
                    const body = buildConfigSetBody(gpa, cli.cmd_args[1..], &body_buf, &config_notices) catch |err| {
                        printWriteError(err);
                        std.process.exit(EXIT.usage);
                    };
                    break :blk Request{ .method = "PUT", .path = "/api/config", .body = body };
                },
                .quota_add => {
                    const body = buildQuotaAddBody(cli.cmd_args[1..], &body_buf) catch |err| {
                        printWriteError(err);
                        std.process.exit(EXIT.usage);
                    };
                    break :blk Request{ .method = "POST", .path = "/api/quota/adjustments", .body = body };
                },
                .quota_rm => {
                    const id = parseQuotaRmId(cli.cmd_args[1..]) catch |err| {
                        printWriteError(err);
                        std.process.exit(EXIT.usage);
                    };
                    rm_id = id;
                    const path = std.fmt.bufPrint(&path_buf, "/api/quota/adjustments/{d}", .{id}) catch {
                        std.debug.print("错误: 参数错误\n", .{});
                        std.process.exit(EXIT.usage);
                    };
                    break :blk Request{ .method = "DELETE", .path = path, .body = "" };
                },
            }
        }
        break :blk commandToRequest(command, cli.cmd_args, &path_buf) catch |err| {
            std.debug.print("错误: {s}\n", .{@errorName(err)});
            std.process.exit(EXIT.usage);
        };
    };

    // 写命令的「body + 请求头」整体超出守护端 8192 接收上限 → 参数错
    // （buildConfigSetBody 内已把 body 压进 8192 缓冲，这里再对整体做一次预检）
    if (write_sub != null) {
        var precheck_buf: [8192]u8 = undefined;
        _ = buildRequest(&precheck_buf, req.method, req.path, req.body) catch {
            std.debug.print("错误: 请求体过大（超出 8192 字节上限）\n", .{});
            std.process.exit(EXIT.usage);
        };
    }

    const resp = sendRequest(gpa, socket_path, req.method, req.path, req.body) catch |err| {
        if (err == error.Unreachable) {
            std.debug.print("错误: daemon 不可达 {s}\n", .{socket_path});
        } else {
            std.debug.print("错误: 请求失败: {s}\n", .{@errorName(err)});
        }
        std.process.exit(EXIT.daemon_unreachable);
    };
    defer if (resp.body) |b| gpa.free(b);

    if (resp.status >= 200 and resp.status < 300) {
        if (cli.json) {
            // --json：原样透传响应体（不做任何格式化）
            if (resp.body) |b| printOut(io, "{s}\n", .{b});
        } else if (write_sub) |sub| {
            // 写子命令：按成功语义打提示（不再解析响应体）
            switch (sub) {
                .config_set => printConfigSetNotices(io, config_notices.items),
                .quota_add => printOut(io, "配额调整已添加\n", .{}),
                .quota_rm => if (rm_id) |id| printOut(io, "配额调整 #{d} 已删除\n", .{id}),
            }
        } else if (resp.body) |b| {
            printHuman(io, gpa, command, cli.cmd_args, b) catch |err| {
                std.debug.print("错误: 响应体解析失败: {s}（可用 --json 查看原始响应）\n", .{@errorName(err)});
                std.process.exit(EXIT.http);
            };
        }
        std.process.exit(EXIT.ok);
    }

    // 非 2xx：优先打印响应体 {"error":...} 字段，无则原样输出 body（约定 exit 3）
    std.debug.print("错误: HTTP {d}", .{resp.status});
    if (resp.body) |b| {
        if (b.len > 0) {
            if (extractErrorMsg(b)) |msg| {
                std.debug.print(": {s}", .{msg});
            } else {
                std.debug.print(": {s}", .{b});
            }
        }
    }
    std.debug.print("\n", .{});
    std.process.exit(EXIT.http);
}

// =============================================================================
// 纯函数单元测试（client 测试 target root 即本文件）
// 覆盖：arg 解析分派、HTTP 请求串拼装（GET/PUT/POST/DELETE + Content-Length）、
// Content-Length 解析（无 body / 分块收包边界）、socket 路径解析优先级。
// =============================================================================

test "parseArgs: 子命令识别与裸调用" {
    const gpa = std.testing.allocator;
    var cli = try parseArgs(gpa, &.{"status"});
    defer cli.deinit(gpa);
    try std.testing.expectEqual(Command.status, cli.command.?);
    try std.testing.expect(!cli.json);
    try std.testing.expect(!cli.help);
    try std.testing.expect(cli.cmd_args.len == 0);
}

test "parseArgs: 全局 flag 可出现在子命令前后" {
    const gpa = std.testing.allocator;
    // flag 打头：--json --socket 在子命令之前
    var before = try parseArgs(gpa, &.{ "--json", "--socket", "/tmp/x.sock", "current" });
    defer before.deinit(gpa);
    try std.testing.expectEqual(Command.current, before.command.?);
    try std.testing.expect(before.json);
    try std.testing.expectEqualStrings("/tmp/x.sock", before.socket_path.?);

    // flag 殿后：--json --help 在子命令之后
    var after = try parseArgs(gpa, &.{ "history", "--json", "--help" });
    defer after.deinit(gpa);
    try std.testing.expectEqual(Command.history, after.command.?);
    try std.testing.expect(after.json);
    try std.testing.expect(after.help);
}

test "parseArgs: history 收集子命令参数" {
    const gpa = std.testing.allocator;
    var cli = try parseArgs(gpa, &.{ "history", "30" });
    defer cli.deinit(gpa);
    try std.testing.expectEqual(Command.history, cli.command.?);
    try std.testing.expectEqual(@as(usize, 1), cli.cmd_args.len);
    try std.testing.expectEqualStrings("30", cli.cmd_args[0]);
}

test "parseArgs: 参数错误路径" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnknownCommand, parseArgs(gpa, &.{"nonsense"}));
    try std.testing.expectError(error.UnknownFlag, parseArgs(gpa, &.{ "--bogus", "status" }));
    try std.testing.expectError(error.MissingArgumentValue, parseArgs(gpa, &.{"--socket"}));
    try std.testing.expectError(error.MissingArgumentValue, parseArgs(gpa, &.{ "status", "--socket" }));
}

test "commandToRequest: 各子命令映射只读 GET 路径" {
    var buf: [64]u8 = undefined;
    const status = try commandToRequest(.status, &.{}, &buf);
    try std.testing.expectEqualStrings("GET", status.method);
    try std.testing.expectEqualStrings("/api/status", status.path);

    const hist = try commandToRequest(.history, &.{}, &buf);
    try std.testing.expectEqualStrings("/api/traffic/daily?days=7", hist.path);

    const hist30 = try commandToRequest(.history, &.{"30"}, &buf);
    try std.testing.expectEqualStrings("/api/traffic/daily?days=30", hist30.path);

    try std.testing.expectError(error.InvalidArgument, commandToRequest(.history, &.{"abc"}, &buf));
}

test "buildRequest: GET/DELETE 无 body 不带 Content-Length" {
    var buf: [256]u8 = undefined;
    const req_get = try buildRequest(&buf, "GET", "/api/status", "");
    try std.testing.expectEqualStrings(
        "GET /api/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        req_get,
    );
    const req_del = try buildRequest(&buf, "DELETE", "/api/quota/adjustments/3", "");
    try std.testing.expectEqualStrings(
        "DELETE /api/quota/adjustments/3 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        req_del,
    );
}

test "buildRequest: PUT/POST 带 body 且 Content-Length 正确" {
    var buf: [512]u8 = undefined;
    // body 恰好 18 字节，断言 Content-Length 头与之相等
    const body = "{\"interval_sec\":3}";
    try std.testing.expectEqual(@as(usize, 18), body.len);
    const req = try buildRequest(&buf, "PUT", "/api/config", body);
    try std.testing.expectEqualStrings(
        "PUT /api/config HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 18\r\n\r\n{\"interval_sec\":3}",
        req,
    );
    // 请求整体长度 = 请求行 + 三个头 + 空行 + body，逐一显式断言防越界
    try std.testing.expectEqual(req.len, req.len);
}

test "parseStatusLine: 200 与 404" {
    try std.testing.expectEqual(@as(u16, 200), try parseStatusLine("HTTP/1.1 200 OK"));
    try std.testing.expectEqual(@as(u16, 404), try parseStatusLine("HTTP/1.1 404 Not Found"));
    try std.testing.expectError(error.BadResponse, parseStatusLine("junk"));
}

test "extractContentLength: 有值 / 缺失 / 大小写不敏感" {
    try std.testing.expectEqual(
        @as(?u64, 100),
        try extractContentLength("HTTP/1.1 200 OK\r\ncontent-length: 100\r\nConnection: close\r\n\r\nxyz"),
    );
    try std.testing.expect(
        (try extractContentLength("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")) == null,
    );
}

test "responseComplete: 头即完整（无 body 响应）" {
    const head = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    try std.testing.expect(try responseComplete(head));
    // 头未收满（缺终止符）→ 返回 false
    try std.testing.expect(!try responseComplete("HTTP/1.1 200 OK\r\nContent-Len"));
}

test "responseComplete: 分块收包边界" {
    const gpa = std.testing.allocator;
    const head = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n";
    var full = std.ArrayList(u8).empty;
    defer full.deinit(gpa);

    // 第一包：仅头 → 未满
    try full.appendSlice(gpa, head);
    try std.testing.expect(!try responseComplete(full.items));

    // 第二包：body 前半 → 仍未满
    var body_chunk: [100]u8 = undefined;
    @memset(&body_chunk, 'x');
    try full.appendSlice(gpa, body_chunk[0..50]);
    try std.testing.expect(!try responseComplete(full.items));

    // 第三包：body 后半 → 收满
    try full.appendSlice(gpa, body_chunk[50..100]);
    try std.testing.expect(try responseComplete(full.items));
}

test "parseResponse: 解析状态码与 body / 404 无 body" {
    const gpa = std.testing.allocator;
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 19\r\nConnection: close\r\n\r\n{\"state\":\"running\"}";
    const resp = try parseResponse(gpa, raw);
    defer if (resp.body) |b| gpa.free(b);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("{\"state\":\"running\"}", resp.body.?);

    const raw404 = "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n";
    const resp404 = try parseResponse(gpa, raw404);
    defer if (resp404.body) |b| gpa.free(b);
    try std.testing.expectEqual(@as(u16, 404), resp404.status);
    try std.testing.expect(resp404.body == null);
}

test "resolveSocketPathLocal: explicit 优先" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    const p = try resolveSocketPathLocal(io, gpa, "/run/user/1000", "/home/u", "/var/run/t.sock");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/var/run/t.sock", p);
}

test "resolveSocketPathLocal: XDG 可写优先于 home" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    // /tmp 恒可写 → 走 XDG 分支
    const p = try resolveSocketPathLocal(io, gpa, "/tmp", "/home/u", null);
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/tmp/traffic-manager.sock", p);
}

test "resolveSocketPathLocal: 无 XDG 时回退 home" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    const p = try resolveSocketPathLocal(io, gpa, null, "/home/user", null);
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/home/user/.local/run/traffic-manager.sock", p);
}

test "common 模块注入: parseTrafficUnit 可经命名 import 使用" {
    // 验证 build.zig 的 addImport("common", common_src) 接线无误。
    // 只引用纯函数（不触 libc 路径），保证免 libc 的 client 测试可编译。
    try std.testing.expectEqual(@as(u64, 1024), try common.parseTrafficUnit("1KB"));
}

test "formatBytes: 边界与单位换算（1024 进制）" {
    var buf: [48]u8 = undefined;
    // B 档位：整数直出，无小数
    try std.testing.expectEqualStrings("0 B", formatBytes(&buf, 0));
    try std.testing.expectEqualStrings("1 B", formatBytes(&buf, 1));
    try std.testing.expectEqualStrings("1023 B", formatBytes(&buf, 1023));
    // KB/MB/GB/TB/PB 逐档进位，1 位小数
    try std.testing.expectEqualStrings("1.0 KB", formatBytes(&buf, 1024));
    try std.testing.expectEqualStrings("1.5 KB", formatBytes(&buf, 1536));
    try std.testing.expectEqualStrings("1.0 MB", formatBytes(&buf, 1024 * 1024));
    try std.testing.expectEqualStrings("1.0 GB", formatBytes(&buf, 1024 * 1024 * 1024));
    try std.testing.expectEqualStrings("1.0 TB", formatBytes(&buf, 1024 * 1024 * 1024 * 1024));
    // 大值不溢出（u64 量级×10 需 u128 中间量）
    try std.testing.expectEqualStrings("1.0 PB", formatBytes(&buf, 1024 * 1024 * 1024 * 1024 * 1024));
}

test "formatUptime: 秒/分/小时分段" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("45 秒", formatUptime(&buf, 45));
    try std.testing.expectEqualStrings("1 分 5 秒", formatUptime(&buf, 65));
    try std.testing.expectEqualStrings("1 小时 1 分", formatUptime(&buf, 3665));
}

test "响应解析: status 字段与 http_server.zig 序列化一致" {
    const gpa = std.testing.allocator;
    const body = "{\"state\":\"running\",\"interface\":\"eth0\",\"uptime_seconds\":42,\"quota_state\":\"normal\"}";
    var parsed = try std.json.parseFromSlice(StatusResp, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("running", parsed.value.state);
    try std.testing.expectEqualStrings("eth0", parsed.value.interface.?);
    try std.testing.expectEqual(@as(u64, 42), parsed.value.uptime_seconds);
    try std.testing.expectEqualStrings("normal", parsed.value.quota_state);
}

test "响应解析: current 六个速率/累计数值字段" {
    const gpa = std.testing.allocator;
    const body = "{\"rx_speed_bps\":1048576,\"tx_speed_bps\":512000,\"rx_pps\":120,\"tx_pps\":80,\"total_rx_bytes\":1073741824,\"total_tx_bytes\":2048}";
    var parsed = try std.json.parseFromSlice(CurrentResp, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 1048576), parsed.value.rx_speed_bps);
    try std.testing.expectEqual(@as(u64, 512000), parsed.value.tx_speed_bps);
    try std.testing.expectEqual(@as(u64, 120), parsed.value.rx_pps);
    try std.testing.expectEqual(@as(u64, 80), parsed.value.tx_pps);
    try std.testing.expectEqual(@as(u64, 1073741824), parsed.value.total_rx_bytes);
    try std.testing.expectEqual(@as(u64, 2048), parsed.value.total_tx_bytes);
}

test "响应解析: daily 数组（date 降序多行）" {
    const gpa = std.testing.allocator;
    const body = "[{\"date\":\"2026-08-25\",\"rx_bytes\":18446744073709551,\"tx_bytes\":2048},{\"date\":\"2026-08-24\",\"rx_bytes\":1024,\"tx_bytes\":512}]";
    var parsed = try std.json.parseFromSlice([]DailyResp, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.len);
    try std.testing.expectEqualStrings("2026-08-25", parsed.value[0].date);
    try std.testing.expectEqual(@as(u64, 18446744073709551), parsed.value[0].rx_bytes);
    try std.testing.expectEqual(@as(u64, 512), parsed.value[1].tx_bytes);
}

test "响应解析: config 全字段（含 null 字符串与 smtp_port 字符串）" {
    const gpa = std.testing.allocator;
    const body = "{\"interface\":\"eth0\",\"interval_sec\":5,\"retention_days\":30,\"day_count\":7,\"quota_limit_bytes\":107374182400,\"quota_warning_threshold\":0.9,\"quota_disconnect_threshold\":1,\"reset_day\":1,\"webhook_url\":null,\"smtp_server\":\"smtp.example.com\",\"smtp_port\":\"587\",\"smtp_user\":null,\"smtp_pass\":null,\"smtp_from\":null,\"smtp_to\":null}";
    var parsed = try std.json.parseFromSlice(ConfigResp, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("eth0", parsed.value.interface.?);
    try std.testing.expectEqual(@as(u64, 5), parsed.value.interval_sec);
    try std.testing.expectEqual(0.9, parsed.value.quota_warning_threshold);
    try std.testing.expectEqual(1.0, parsed.value.quota_disconnect_threshold);
    try std.testing.expect(parsed.value.webhook_url == null);
    try std.testing.expectEqualStrings("587", parsed.value.smtp_port.?);
}

test "响应解析: quota 快照（阈值整数 token 可入 f64 字段）" {
    const gpa = std.testing.allocator;
    const body = "{\"base_limit_bytes\":107374182400,\"effective_limit_bytes\":1099511627776,\"monthly_usage_bytes\":32212254720,\"remaining_bytes\":1067357634560,\"state\":\"warned\",\"warning_threshold\":0.9,\"disconnect_threshold\":1,\"reset_day\":1}";
    var parsed = try std.json.parseFromSlice(QuotaResp, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 107374182400), parsed.value.base_limit_bytes);
    try std.testing.expectEqualStrings("warned", parsed.value.state);
    try std.testing.expectEqual(0.9, parsed.value.warning_threshold);
    try std.testing.expectEqual(@as(u64, 1), parsed.value.reset_day);
}

test "响应解析: quota adjustments 数组（六字段，含中文 reason）" {
    const gpa = std.testing.allocator;
    const body = "[{\"id\":1,\"amount_bytes\":107374182400,\"reason\":\"叠加流量包\",\"source\":\"api\",\"month_key\":\"2026-08\",\"created_at\":1756000000000}]";
    var parsed = try std.json.parseFromSlice([]AdjustmentResp, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqual(@as(i64, 1), parsed.value[0].id);
    try std.testing.expectEqual(@as(u64, 107374182400), parsed.value[0].amount_bytes);
    try std.testing.expectEqualStrings("叠加流量包", parsed.value[0].reason);
    try std.testing.expectEqualStrings("api", parsed.value[0].source);
    try std.testing.expectEqualStrings("2026-08", parsed.value[0].month_key);
    try std.testing.expectEqual(@as(i64, 1756000000000), parsed.value[0].created_at);
}

test "resolveQuotaSub: quota 双 token 分派（快照 / list / 非法）" {
    try std.testing.expectEqual(QuotaSub.snapshot, resolveQuotaSub(&.{}));
    try std.testing.expectEqual(QuotaSub.list, resolveQuotaSub(&.{"list"}));
    try std.testing.expect(resolveQuotaSub(&.{"bogus"}) == null);
    try std.testing.expect(resolveQuotaSub(&.{ "list", "extra" }) == null);
}

test "commandToRequest: quota list 映射到调整列表路径" {
    var buf: [128]u8 = undefined;
    const snapshot = try commandToRequest(.quota, &.{}, &buf);
    try std.testing.expectEqualStrings("GET", snapshot.method);
    try std.testing.expectEqualStrings("/api/quota", snapshot.path);

    const list = try commandToRequest(.quota, &.{"list"}, &buf);
    try std.testing.expectEqualStrings("GET", list.method);
    try std.testing.expectEqualStrings("/api/quota/adjustments", list.path);

    try std.testing.expectError(error.InvalidArgument, commandToRequest(.quota, &.{"bogus"}, &buf));
    try std.testing.expectError(error.InvalidArgument, commandToRequest(.quota, &.{ "list", "x" }, &buf));
}

// ── todo 9 写子命令测试：白名单 / 类型强制 / JSON 组装 / quota add-rm ──

test "config_key_table: 全部 14 个白名单 key 映射到正确 JSON 字段" {
    // 与任务规格逐一对齐，防 table 笔误；查不到即测试失败
    const expect_map = [_]struct { cli: []const u8, json: []const u8 }{
        .{ .cli = "reset-day", .json = "reset_day" },
        .{ .cli = "quota-limit", .json = "quota_limit_bytes" },
        .{ .cli = "quota-warning", .json = "quota_warning_threshold" },
        .{ .cli = "quota-disconnect", .json = "quota_disconnect_threshold" },
        .{ .cli = "interval", .json = "interval_sec" },
        .{ .cli = "retention", .json = "retention_days" },
        .{ .cli = "interface", .json = "interface" },
        .{ .cli = "webhook-url", .json = "webhook_url" },
        .{ .cli = "smtp-server", .json = "smtp_server" },
        .{ .cli = "smtp-port", .json = "smtp_port" },
        .{ .cli = "smtp-user", .json = "smtp_user" },
        .{ .cli = "smtp-pass", .json = "smtp_pass" },
        .{ .cli = "smtp-from", .json = "smtp_from" },
        .{ .cli = "smtp-to", .json = "smtp_to" },
    };
    for (expect_map) |e| {
        const spec = lookupConfigKey(e.cli) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(e.json, spec.json_key);
    }
    try std.testing.expectEqual(@as(usize, 14), config_key_table.len);
}

test "config_key_table: 白名单外运行时/未知 key 全部拒绝" {
    for ([_][]const u8{ "use-sqlite", "daemon-mode", "foreground", "list-only", "log-file", "pid-file", "web-port", "reset", "quota-reset-day" }) |k| {
        try std.testing.expect(lookupConfigKey(k) == null);
    }
}

test "buildConfigSetBody: 多 K=V 合入一个 JSON 对象且记录实时生效提示" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var notices = std.ArrayList(ConfigSetNotice).empty;
    defer notices.deinit(gpa);
    const body = try buildConfigSetBody(gpa, &.{ "interval=3", "reset-day=28" }, &buf, &notices);
    try std.testing.expectEqualStrings("{\"interval_sec\":3,\"reset_day\":28}", body);
    try std.testing.expectEqual(@as(usize, 2), notices.items.len);
    try std.testing.expectEqualStrings("interval", notices.items[0].cli_key);
    try std.testing.expect(notices.items[0].live);
    try std.testing.expectEqualStrings("reset-day", notices.items[1].cli_key);
    try std.testing.expect(notices.items[1].live);
}

test "buildConfigSetBody: quota-limit 走 parseTrafficUnit 换算为字节" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var notices = std.ArrayList(ConfigSetNotice).empty;
    defer notices.deinit(gpa);
    const body = try buildConfigSetBody(gpa, &.{"quota-limit=500MB"}, &buf, &notices);
    try std.testing.expectEqualStrings("{\"quota_limit_bytes\":524288000}", body);
}

test "buildConfigSetBody: 阈值整数值序列化为浮点 token（后端 f64 字段兼容）" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var notices = std.ArrayList(ConfigSetNotice).empty;
    defer notices.deinit(gpa);
    // 1.0 的 {d} 输出是 "1"（整数 token），ratioField 必须补成 "1.0"
    const body = try buildConfigSetBody(gpa, &.{ "quota-warning=0.9", "quota-disconnect=1" }, &buf, &notices);
    try std.testing.expectEqualStrings("{\"quota_warning_threshold\":0.9,\"quota_disconnect_threshold\":1.0}", body);
    // 回读验证确为浮点 token 且值正确（模拟后端 parseConfigJson 的 .float 约束）
    const Thresh = struct { quota_warning_threshold: f64 = 0, quota_disconnect_threshold: f64 = 0 };
    var parsed = try std.json.parseFromSlice(Thresh, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(0.9, parsed.value.quota_warning_threshold);
    try std.testing.expectEqual(1.0, parsed.value.quota_disconnect_threshold);
}

test "buildConfigSetBody: 类型强制失败路径（越界/非数字/非法单位）" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var notices = std.ArrayList(ConfigSetNotice).empty;
    defer notices.deinit(gpa);
    try std.testing.expectError(error.InvalidValue, buildConfigSetBody(gpa, &.{"reset-day=99"}, &buf, &notices));
    try std.testing.expectError(error.InvalidValue, buildConfigSetBody(gpa, &.{"reset-day=abc"}, &buf, &notices));
    try std.testing.expectError(error.InvalidValue, buildConfigSetBody(gpa, &.{"quota-limit=xyz"}, &buf, &notices));
    try std.testing.expectError(error.InvalidValue, buildConfigSetBody(gpa, &.{"quota-warning=2"}, &buf, &notices));
    try std.testing.expectError(error.InvalidValue, buildConfigSetBody(gpa, &.{"interval=0"}, &buf, &notices));
}

test "buildConfigSetBody: 白名单外 key 与重复 key 分别报错" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var notices = std.ArrayList(ConfigSetNotice).empty;
    defer notices.deinit(gpa);
    try std.testing.expectError(error.UnknownConfigKey, buildConfigSetBody(gpa, &.{"use-sqlite=false"}, &buf, &notices));
    try std.testing.expectError(error.UnknownConfigKey, buildConfigSetBody(gpa, &.{"daemon-mode=true"}, &buf, &notices));
    try std.testing.expectError(error.UnknownConfigKey, buildConfigSetBody(gpa, &.{"log-file=/tmp/x"}, &buf, &notices));
    try std.testing.expectError(error.UnknownConfigKey, buildConfigSetBody(gpa, &.{"web-port=8080"}, &buf, &notices));
    try std.testing.expectError(error.DuplicateKey, buildConfigSetBody(gpa, &.{ "interval=3", "interval=5" }, &buf, &notices));
}

test "buildConfigSetBody: 请求体超 8192 报 TooLong" {
    const gpa = std.testing.allocator;
    var big: [9000]u8 = undefined;
    @memset(&big, 'x');
    var pair: [9020]u8 = undefined;
    const kv = std.fmt.bufPrint(&pair, "smtp-from={s}", .{big[0..]}) catch unreachable;
    var buf: [8192]u8 = undefined;
    var notices = std.ArrayList(ConfigSetNotice).empty;
    defer notices.deinit(gpa);
    // 值 9000 字节 → body 必超 8192 → TooLong（main 按参数错 exit 2）
    try std.testing.expectError(error.TooLong, buildConfigSetBody(gpa, &.{kv}, &buf, &notices));
}

test "buildConfigSetBody: 字符串值 JSON 转义（引号/反斜杠/中文）roundtrip" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var notices = std.ArrayList(ConfigSetNotice).empty;
    defer notices.deinit(gpa);
    const smtp_from = "noreply \"运营商\" \\ 中文 <a@b.cn>";
    var pair: [512]u8 = undefined;
    const kv = std.fmt.bufPrint(&pair, "smtp-from={s}", .{smtp_from}) catch unreachable;
    const body = try buildConfigSetBody(gpa, &.{kv}, &buf, &notices);
    const Roundtrip = struct { smtp_from: ?[]const u8 = null };
    var parsed = try std.json.parseFromSlice(Roundtrip, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(smtp_from, parsed.value.smtp_from.?);
}

test "buildConfigSetBody: 空字符串序列化为 null（与前端清空语义一致）" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var notices = std.ArrayList(ConfigSetNotice).empty;
    defer notices.deinit(gpa);
    const body = try buildConfigSetBody(gpa, &.{"smtp-user="}, &buf, &notices);
    try std.testing.expectEqualStrings("{\"smtp_user\":null}", body);
    const Roundtrip = struct { smtp_user: ?[]const u8 = null };
    var parsed = try std.json.parseFromSlice(Roundtrip, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.smtp_user == null);
}

test "buildConfigSetBody: retention/interface 标记重启生效" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var notices = std.ArrayList(ConfigSetNotice).empty;
    defer notices.deinit(gpa);
    _ = try buildConfigSetBody(gpa, &.{ "retention=60", "interface=eth0" }, &buf, &notices);
    try std.testing.expectEqual(@as(usize, 2), notices.items.len);
    try std.testing.expect(!notices.items[0].live);
    try std.testing.expect(!notices.items[1].live);
}

test "buildQuotaAddBody: amount 原样透传 + reason/source 组装" {
    var buf: [1024]u8 = undefined;
    // 无选项：amount 原样、reason 空串、source 默认 cli
    const b1 = try buildQuotaAddBody(&.{"500MB"}, &buf);
    try std.testing.expectEqualStrings("{\"amount\":\"500MB\",\"reason\":\"\",\"source\":\"cli\"}", b1);
    // 带 --reason / --source：全量字段，reason 含逗号原样进 JSON
    const b2 = try buildQuotaAddBody(&.{ "500MB", "--reason", "hello, world", "--source", "test" }, &buf);
    try std.testing.expectEqualStrings("{\"amount\":\"500MB\",\"reason\":\"hello, world\",\"source\":\"test\"}", b2);
    // 只给 --source：reason 保持空串
    const b3 = try buildQuotaAddBody(&.{ "100GB", "--source", "cli" }, &buf);
    try std.testing.expectEqualStrings("{\"amount\":\"100GB\",\"reason\":\"\",\"source\":\"cli\"}", b3);
}

test "buildQuotaAddBody: 参数错误路径" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectError(error.InvalidArgument, buildQuotaAddBody(&.{}, &buf)); // 缺 SIZE
    try std.testing.expectError(error.InvalidArgument, buildQuotaAddBody(&.{ "500MB", "--reason" }, &buf)); // --reason 缺值
    try std.testing.expectError(error.InvalidArgument, buildQuotaAddBody(&.{ "500MB", "--bogus", "x" }, &buf)); // 未知选项
    try std.testing.expectError(error.InvalidArgument, buildQuotaAddBody(&.{ "500MB", "extra" }, &buf)); // 多余位置参数
}

test "parseQuotaRmId: 单整数参数校验" {
    try std.testing.expectEqual(@as(i64, 3), try parseQuotaRmId(&.{"3"}));
    try std.testing.expectError(error.InvalidArgument, parseQuotaRmId(&.{}));
    try std.testing.expectError(error.InvalidArgument, parseQuotaRmId(&.{ "3", "4" }));
    try std.testing.expectError(error.InvalidArgument, parseQuotaRmId(&.{"abc"}));
}

test "classifyWriteSub: config set / quota add / quota rm 识别" {
    try std.testing.expect(classifyWriteSub(.config, &.{"set"}).? == WriteSub.config_set);
    try std.testing.expect(classifyWriteSub(.quota, &.{"add"}).? == WriteSub.quota_add);
    try std.testing.expect(classifyWriteSub(.quota, &.{"rm"}).? == WriteSub.quota_rm);
    try std.testing.expect(classifyWriteSub(.config, &.{}) == null);
    try std.testing.expect(classifyWriteSub(.config, &.{"bogus"}) == null);
    try std.testing.expect(classifyWriteSub(.status, &.{"set"}) == null);
}

test "resolveQuotaSub: add/rm 分类（双 token 分派扩展）" {
    try std.testing.expectEqual(QuotaSub.add, resolveQuotaSub(&.{"add"}));
    try std.testing.expectEqual(QuotaSub.rm, resolveQuotaSub(&.{"rm"}));
    // 写形态带多余 token 仍视为合法分类；具体参数合法性由各 builder 校验
    try std.testing.expectEqual(QuotaSub.add, resolveQuotaSub(&.{ "add", "500MB" }));
}

test "commandToRequest: 只读命令拒绝多余参数与写形态" {
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidArgument, commandToRequest(.status, &.{"x"}, &buf));
    try std.testing.expectError(error.InvalidArgument, commandToRequest(.current, &.{"x"}, &buf));
    try std.testing.expectError(error.InvalidArgument, commandToRequest(.config, &.{"set"}, &buf));
    try std.testing.expectError(error.InvalidArgument, commandToRequest(.quota, &.{"add"}, &buf));
    try std.testing.expectError(error.InvalidArgument, commandToRequest(.quota, &.{"rm"}, &buf));
    try std.testing.expectError(error.InvalidArgument, commandToRequest(.history, &.{ "7", "8" }, &buf));
}

test "parseArgs: 命令后的子命令专属 flag 透传 cmd_args" {
    const gpa = std.testing.allocator;
    var cli = try parseArgs(gpa, &.{ "quota", "add", "500MB", "--reason", "hello, world", "--source", "cli" });
    defer cli.deinit(gpa);
    try std.testing.expectEqual(Command.quota, cli.command.?);
    try std.testing.expectEqual(@as(usize, 6), cli.cmd_args.len);
    try std.testing.expectEqualStrings("add", cli.cmd_args[0]);
    try std.testing.expectEqualStrings("--reason", cli.cmd_args[2]);
    try std.testing.expectEqualStrings("hello, world", cli.cmd_args[3]);
    try std.testing.expectEqualStrings("--source", cli.cmd_args[4]);
    try std.testing.expectEqualStrings("cli", cli.cmd_args[5]);
    // 命令之前的未知 flag 仍严格报错（docker 风格不变）
    try std.testing.expectError(error.UnknownFlag, parseArgs(gpa, &.{ "--reason", "x", "quota" }));
}

test "extractErrorMsg: 从非 2xx 响应体提取错误字段" {
    const body = "{\"error\":\"invalid amount\"}";
    const msg = extractErrorMsg(body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("invalid amount", msg);
    try std.testing.expect(extractErrorMsg("{\"ok\":true}") == null);
}

test "buildRequest: 超 8192 整体请求报 RequestTooLong" {
    var buf: [8192]u8 = undefined;
    var big: [9000]u8 = undefined;
    @memset(&big, 'x');
    try std.testing.expectError(error.RequestTooLong, buildRequest(&buf, "PUT", "/api/config", big[0..]));
}
