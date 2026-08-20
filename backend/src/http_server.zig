// backend/src/http_server.zig
// HTTP 服务器模块：在独立线程中基于 posix fd 运行 TCP 监听，
// 通过自旋锁保护的共享状态与监控线程通信。
//
// 设计要点（Plan Wave 3）：
// - 端口预绑定：socket/bind/listen 在 startHttpServer 调用线程内同步完成，
//   端口被占用等错误立即返回调用方，线程只做 accept，避免静默失败。
// - 所有 API 数据均实时查询 SQLite / 读取 /proc/net/dev，不依赖监控线程
//   写入共享状态（监控循环无需触碰 http 线程状态，降低耦合与锁竞争）。
// - 自旋锁替代 Zig 0.16 已移除的 std.Thread.Mutex，保护共享配置指针与
//   跨线程的 zqlite 连接访问。
const std = @import("std");
const zqlite = @import("zqlite");
/// 前端页面内容：编译期嵌入（产物由 justfile 构建流程复制到本目录）
const EMBEDDED_HTML = @embedFile("dashboard.html");
const traffic_mod = @import("traffic.zig");
const quota_mod = @import("quota.zig");
const cfg = @import("config.zig");
const cfg_store = @import("config_store.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
// Zig 0.16 的 std.posix 不再提供 socket/bind/accept 等封装，
// 原始系统调用收敛在 std.os.linux，直接复用。
const linux = std.os.linux;

/// 连接套接字类型别名：Zig 0.16 移除 std.net.Stream，统一使用 posix fd
const Stream = std.posix.socket_t;

pub const HttpServerError = error{
    BindFailed,
    ListenFailed,
    SystemResources,
    OutOfMemory,
    LockedMemoryLimitExceeded,
    ThreadQuotaExceeded,
    Unexpected,
};

/// 轻量互斥锁：Zig 0.16 移除了 std.Thread.Mutex，
/// 此自旋锁保持旧 API（无参 lock/unlock），保护共享状态并发访问。
const Mutex = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
};

/// 获取当前 Unix 时间戳（秒）。Zig 0.16 移除 std.time.timestamp，
/// 直接调用 Linux clock_gettime 系统调用（返回 0 表示成功）。
fn unixTimeSecs() i64 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @intCast(ts.sec);
}

/// 共享应用状态：由 HTTP 线程持有并读写。
/// 监控线程不写此状态，避免锁竞争；所有接口数据实时计算。
pub const AppState = struct {
    mu: Mutex = .{},
    /// 流量取样器：按请求间隔连续读取 /proc/net/dev，
    /// 在前后两次请求之间计算实时速率（与监控线程各自持有独立样本）。
    tracker: traffic_mod.TrafficTracker = traffic_mod.TrafficTracker.init(null),
    /// 当前生效配置（PUT /api/config 会就地更新）
    config: cfg.Config = .{},
    /// 正在监听的目标网卡名（由监控线程启动时传入的生命期稳定的字符串）
    iface: []const u8 = "",
    /// 服务器启动时间（epoch 秒），用于计算 uptime
    start_time_secs: u64 = 0,
};

/// HTTP 服务器上下文
pub const HttpServerContext = struct {
    allocator: Allocator,
    state: *AppState,
    conn: *zqlite.Conn,
    port: u16,
    /// 监控主循环的 Io 实例：HTTP 线程复用其读取 /proc/net/dev
    io: std.Io,
};

/// 启动 HTTP 服务器。
/// 采用「主线程预绑定」策略：socket/bind/listen 全部在调用线程同步完成，
/// 任何一步失败（典型如端口被占用）都返回显式错误给调用方，而非在线程里
/// 静默退出——这样 main.zig 能在启动阶段就确定端口冲突并提示用户。
/// 成功后才派生子线程进入 accept 循环；失败时通过 errdefer 关闭 fd。
pub fn startHttpServer(ctx: HttpServerContext) HttpServerError!std.Thread {
    // 创建 TCP 监听套接字（IPv4，0.0.0.0）
    const sock_result = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (linux.errno(sock_result) != .SUCCESS) return error.SystemResources;
    const sockfd: Stream = @intCast(sock_result);
    errdefer _ = linux.close(sockfd);
    // 允许地址复用，避免重启时 TIME_WAIT 导致 bind 失败
    const one: c_int = 1;
    std.posix.setsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch {};
    const addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, ctx.port),
        .addr = 0, // 0.0.0.0
        .zero = [_]u8{0} ** 8,
    };
    const bind_rc = linux.bind(sockfd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in));
    if (linux.errno(bind_rc) != .SUCCESS) return error.BindFailed;
    const listen_rc = linux.listen(sockfd, 128);
    if (linux.errno(listen_rc) != .SUCCESS) return error.ListenFailed;
    // 绑定/监听成功后派生 accept 线程（失败时 errdefer 关闭 fd）
    return std.Thread.spawn(.{}, serverThreadFn, .{ ctx, sockfd });
}

/// 服务器线程主函数：套接字已在主线程就绪（预绑定），这里只负责 accept
fn serverThreadFn(ctx: HttpServerContext, sockfd: Stream) void {
    defer _ = linux.close(sockfd);
    while (true) {
        const conn_result = linux.accept(sockfd, null, null);
        if (linux.errno(conn_result) != .SUCCESS) continue;
        handleConnection(ctx, @intCast(conn_result));
    }
}

/// 处理单个连接
fn handleConnection(ctx: HttpServerContext, conn: Stream) void {
    defer _ = linux.close(conn);
    var buf: [8192]u8 = undefined;
    const n = linux.recvfrom(conn, &buf, buf.len, 0, null, null);
    if (linux.errno(n) != .SUCCESS) return;
    if (n == 0) return;
    const request = buf[0..n];

    // 解析请求行
    const first_line_end = std.mem.indexOfScalar(u8, request, '\r') orelse
        std.mem.indexOfScalar(u8, request, '\n') orelse return;
    const first_line = request[0..first_line_end];

    var sp = std.mem.splitScalar(u8, first_line, ' ');
    const method = sp.next() orelse return;
    const path = sp.next() orelse return;

    if (std.mem.eql(u8, method, "GET")) {
        handleGet(ctx, path, conn);
    } else if (std.mem.eql(u8, method, "PUT")) {
        handlePut(ctx, path, conn, request);
    } else if (std.mem.eql(u8, method, "POST")) {
        handlePost(ctx, path, conn, request);
    } else if (std.mem.eql(u8, method, "DELETE")) {
        handleDelete(ctx, path, conn);
    } else {
        sendNotFound(conn);
    }
}

// ── 路由表（供后续 frontend 对接参考） ──
// GET  /                                   → 嵌入的 HTML 仪表盘
// GET  /index.html                         → 同上
// GET  /api/status                         → 运行状态
// GET  /api/traffic/current                → 实时速率/累计流量
// GET  /api/traffic/daily?days=N           → N 天历史（默认 7），date 为 YYYY-MM-DD
// GET  /api/config                         → 完整配置
// PUT  /api/config                         → 部分更新配置（持久化到 SQLite config 表）
// GET  /api/quota                          → 配额快照（实时计算）
// GET  /api/quota/adjustments              → 当月配额调整列表
// POST /api/quota/adjustments              → 新增调整（amount_bytes 或 amount）
// DELETE /api/quota/adjustments/<id>       → 删除调整（不存在返回 404）

fn handleGet(ctx: HttpServerContext, path: []const u8, stream: Stream) void {
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        sendHtml(stream, EMBEDDED_HTML);
    } else if (std.mem.eql(u8, path, "/api/status")) {
        handleStatusApi(ctx, stream);
    } else if (std.mem.eql(u8, path, "/api/traffic/current")) {
        handleCurrentTrafficApi(ctx, stream);
    } else if (std.mem.startsWith(u8, path, "/api/traffic/daily")) {
        handleDailyTrafficApi(ctx, path, stream);
    } else if (std.mem.eql(u8, path, "/api/config")) {
        handleGetConfigApi(ctx, stream);
    } else if (std.mem.eql(u8, path, "/api/quota")) {
        handleGetQuotaApi(ctx, stream);
    } else if (std.mem.eql(u8, path, "/api/quota/adjustments")) {
        handleGetAdjustmentsApi(ctx, stream);
    } else {
        sendNotFound(stream);
    }
}

// ── PUT 路由 ──

fn handlePut(ctx: HttpServerContext, path: []const u8, stream: Stream, request: []const u8) void {
    if (std.mem.eql(u8, path, "/api/config")) {
        handlePutConfigApi(ctx, stream, request);
    } else {
        sendNotFound(stream);
    }
}

// ── POST 路由 ──

fn handlePost(ctx: HttpServerContext, path: []const u8, stream: Stream, request: []const u8) void {
    if (std.mem.eql(u8, path, "/api/quota/adjustments")) {
        handlePostAdjustmentApi(ctx, stream, request);
    } else {
        sendNotFound(stream);
    }
}

// ── DELETE 路由 ──

fn handleDelete(ctx: HttpServerContext, path: []const u8, stream: Stream) void {
    // 路径形如 /api/quota/adjustments/123
    const prefix = "/api/quota/adjustments/";
    if (std.mem.startsWith(u8, path, prefix)) {
        const id_str = path[prefix.len..];
        const id = std.fmt.parseInt(i64, id_str, 10) catch {
            sendJson(stream, 400, "{\"error\":\"invalid id\"}");
            return;
        };
        ctx.state.mu.lock();
        quota_mod.removeAdjustment(ctx.conn, id) catch {
            ctx.state.mu.unlock();
            sendJson(stream, 500, "{\"error\":\"db error\"}");
            return;
        };
        // 删除影响行数为 0 说明该 id 不存在，返回 404
        const affected = ctx.conn.changes();
        ctx.state.mu.unlock();
        if (affected == 0) {
            sendJson(stream, 404, "{\"error\":\"adjustment not found\"}");
            return;
        }
        sendJson(stream, 200, "{\"ok\":true}");
    } else {
        sendNotFound(stream);
    }
}

// ── 配额快照：与 quota.zig 的 getEffectiveMonthlyQuota/checkQuota 语义保持一致 ──

/// 配额快照：一次请求内的完整配额视图
const QuotaSnapshot = struct {
    base_limit_bytes: u64,
    effective_limit_bytes: u64,
    monthly_usage_bytes: u64,
    remaining_bytes: u64,
    state: quota_mod.QuotaState,
    warning_threshold: f64,
    disconnect_threshold: f64,
    reset_day: u8,
};

/// 实时计算配额快照：基础配额 = 当前配置；有效配额 = 基础 + 当月调整之和；
/// 用量 = 数据库当月流量。与监控线程的配额检查逻辑完全一致，保证 API 语义一致。
fn computeQuotaSnapshot(ctx: HttpServerContext) !QuotaSnapshot {
    ctx.state.mu.lock();
    defer ctx.state.mu.unlock();

    const base = ctx.state.config.quota_limit_bytes;
    const warning = ctx.state.config.quota_warning_threshold;
    const disconnect = ctx.state.config.quota_disconnect_threshold;
    const reset_day = ctx.state.config.reset_day;

    // 计算滚动预算周期：起始日与周期起始月（重置日语义，由 computePeriod 统一）
    const now_secs: u64 = @intCast(unixTimeSecs());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = now_secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const period = quota_mod.computePeriod(reset_day, year_day.year, month_day.month.numeric(), month_day.day_index + 1);

    var month_key_buf: [16]u8 = undefined;
    const month_key = std.fmt.bufPrint(&month_key_buf, "{d:0>4}-{d:0>2}", .{ period.year, period.month }) catch
        return error.MonthKeyFormat;

    const usage = quota_mod.getMonthlyTraffic(ctx.conn, @intCast(period.start_epoch_day)) catch return error.QuotaQueryFailed;
    const effective = quota_mod.getEffectiveMonthlyQuota(ctx.conn, base, month_key) catch return error.QuotaQueryFailed;
    const qcfg = quota_mod.QuotaConfig{
        .limit_bytes = effective,
        .warning_threshold = warning,
        .disconnect_threshold = disconnect,
        .reset_day = reset_day,
    };
    const state = quota_mod.checkQuota(qcfg, usage);
    const remaining = if (effective > usage) effective - usage else 0;

    return .{
        .base_limit_bytes = base,
        .effective_limit_bytes = effective,
        .monthly_usage_bytes = usage,
        .remaining_bytes = remaining,
        .state = state,
        .warning_threshold = warning,
        .disconnect_threshold = disconnect,
        .reset_day = reset_day,
    };
}

// ── API 处理函数 ──

fn handleStatusApi(ctx: HttpServerContext, stream: Stream) void {
    const now: u64 = @intCast(unixTimeSecs());
    const uptime = if (ctx.state.start_time_secs > 0 and now > ctx.state.start_time_secs)
        now - ctx.state.start_time_secs
    else
        0;

    ctx.state.mu.lock();
    const iface = ctx.state.iface;
    ctx.state.mu.unlock();

    // 配额状态实时计算（与 checkQuota 语义一致）
    const qstate = computeQuotaSnapshot(ctx) catch {
        sendJson(stream, 500, "{\"error\":\"quota query failed\"}");
        return;
    };

    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"state\":\"running\",\"interface\":\"{s}\",\"uptime_seconds\":{d},\"quota_state\":\"{s}\"}}", .{
        iface,
        uptime,
        @tagName(qstate.state),
    }) catch {
        sendJson(stream, 500, "{\"error\":\"format error\"}");
        return;
    };
    sendJson(stream, 200, json);
}

fn handleCurrentTrafficApi(ctx: HttpServerContext, stream: Stream) void {
    // 用共享取样器读取 /proc/net/dev：以两次 HTTP 请求的时间差计算实时速率。
    // 第一次请求速率字段为 0，累计值为内核计数器的绝对值。
    ctx.state.mu.lock();
    const s = ctx.state.tracker.update(ctx.state.iface, ctx.allocator, ctx.io) catch {
        ctx.state.mu.unlock();
        sendJson(stream, 500, "{\"error\":\"read failed\"}");
        return;
    };
    ctx.state.mu.unlock();

    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"rx_speed_bps\":{d},\"tx_speed_bps\":{d},\"rx_pps\":{d},\"tx_pps\":{d},\"total_rx_bytes\":{d},\"total_tx_bytes\":{d}}}", .{
        s.rx_speed_bps,
        s.tx_speed_bps,
        s.rx_pps,
        s.tx_pps,
        s.total_rx_bytes,
        s.total_tx_bytes,
    }) catch {
        sendJson(stream, 500, "{\"error\":\"format error\"}");
        return;
    };
    sendJson(stream, 200, json);
}

/// 将 epoch day（1970-01-01 为 0）格式化为 YYYY-MM-DD 日期字符串
fn formatDateFromEpochDay(buf: []u8, epoch_day: u32) ?[]const u8 {
    const ed = std.time.epoch.EpochDay{ .day = epoch_day };
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
    }) catch null;
}

fn handleDailyTrafficApi(ctx: HttpServerContext, path: []const u8, stream: Stream) void {
    // 解析 ?days=N（可带其它 query 参数），缺省 7；
    // 必须为正整数，0 或非法值返回 400
    var days: ?u32 = null;
    if (std.mem.indexOfScalar(u8, path, '?')) |q_idx| {
        const query = path[q_idx + 1 ..];
        var params = std.mem.splitScalar(u8, query, '&');
        while (params.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "days=")) {
                days = std.fmt.parseInt(u32, pair[5..], 10) catch {
                    sendJson(stream, 400, "{\"error\":\"invalid days parameter\"}");
                    return;
                };
                if (days.? == 0) {
                    sendJson(stream, 400, "{\"error\":\"days must be >= 1\"}");
                    return;
                }
            }
        }
    }
    const n_days = days orelse 7;

    ctx.state.mu.lock();
    const rows_result = ctx.conn.rows(
        "SELECT date, total_rx_bytes, total_tx_bytes FROM daily_traffic ORDER BY date DESC LIMIT ?1",
        .{@as(i64, @intCast(n_days))},
    );
    var rows = rows_result catch {
        ctx.state.mu.unlock();
        sendJson(stream, 500, "{\"error\":\"db error\"}");
        return;
    };
    defer rows.deinit();

    // SQLite 的 daily_traffic.date 存的是 epoch day，需换算为 YYYY-MM-DD 字符串
    var json_buf: [32768]u8 = undefined;
    var pos: usize = 0;
    json_buf[pos] = '[';
    pos += 1;

    var first = true;
    while (rows.next()) |row| {
        if (!first) {
            json_buf[pos] = ',';
            pos += 1;
        }
        first = false;

        const date: u32 = @intCast(row.int(0));
        const rx: u64 = @bitCast(row.int(1));
        const tx: u64 = @bitCast(row.int(2));

        var date_buf: [16]u8 = undefined;
        const date_str = formatDateFromEpochDay(&date_buf, date) orelse break;
        const entry = std.fmt.bufPrint(json_buf[pos..], "{{\"date\":\"{s}\",\"rx_bytes\":{d},\"tx_bytes\":{d}}}", .{ date_str, rx, tx }) catch break;
        pos += entry.len;
    }
    ctx.state.mu.unlock();

    json_buf[pos] = ']';
    pos += 1;

    sendJson(stream, 200, json_buf[0..pos]);
}

// ── JSON 手工格式化工具（不引入第三方 JSON 库，参照 webhook.zig 的写法） ──

/// 将字符串以带转义的 JSON 字符串形式追加到缓冲（含首尾引号），写满返回 false
fn appendJsonString(buf: []u8, pos: *usize, s: []const u8) bool {
    if (buf.len - pos.* < 2) return false;
    buf[pos.*] = '"';
    pos.* += 1;
    for (s) |c| {
        switch (c) {
            '"' => {
                if (buf.len - pos.* < 2) return false;
                buf[pos.*] = '\\';
                pos.* += 1;
                buf[pos.*] = '"';
                pos.* += 1;
            },
            '\\' => {
                if (buf.len - pos.* < 2) return false;
                buf[pos.*] = '\\';
                pos.* += 1;
                buf[pos.*] = '\\';
                pos.* += 1;
            },
            0...31 => {
                // 控制字符使用 \u00XX 转义，保证 JSON 合法性
                if (buf.len - pos.* < 7) return false;
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
    buf[pos.*] = '"';
    pos.* += 1;
    return true;
}

/// 追加 JSON 字段分隔逗号（第一个字段不加）
fn appendComma(buf: []u8, pos: *usize, first: *bool) bool {
    if (!first.*) {
        if (buf.len - pos.* < 1) return false;
        buf[pos.*] = ',';
        pos.* += 1;
    }
    first.* = false;
    return true;
}

/// 追加 "key": 前缀
fn appendKey(buf: []u8, pos: *usize, key: []const u8) bool {
    if (buf.len - pos.* < key.len + 4) return false;
    buf[pos.*] = '"';
    pos.* += 1;
    @memcpy(buf[pos.*..][0..key.len], key);
    pos.* += key.len;
    buf[pos.*] = '"';
    pos.* += 1;
    buf[pos.*] = ':';
    pos.* += 1;
    return true;
}

/// 追加字符串 / null 字段
fn appendStrField(buf: []u8, pos: *usize, first: *bool, key: []const u8, value: ?[]const u8) bool {
    if (!appendComma(buf, pos, first)) return false;
    if (!appendKey(buf, pos, key)) return false;
    if (value) |v| {
        return appendJsonString(buf, pos, v);
    }
    if (buf.len - pos.* < 4) return false;
    @memcpy(buf[pos.*..][0..4], "null");
    pos.* += 4;
    return true;
}

/// 追加数值字段（支持整型/浮点）
fn appendNumField(buf: []u8, pos: *usize, first: *bool, key: []const u8, value: anytype) bool {
    if (!appendComma(buf, pos, first)) return false;
    if (!appendKey(buf, pos, key)) return false;
    const s = std.fmt.bufPrint(buf[pos.*..], "{d}", .{value}) catch return false;
    pos.* += s.len;
    return true;
}

// ── 配置 API ──

fn handleGetConfigApi(ctx: HttpServerContext, stream: Stream) void {
    ctx.state.mu.lock();
    const c = ctx.state.config;
    ctx.state.mu.unlock();

    // 输出完整配置（与 config_store.saveAll 覆盖的字段一致，可 PUT-GET 往返）
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var first = true;
    buf[pos] = '{';
    pos += 1;

    if (!appendStrField(&buf, &pos, &first, "interface", c.interface)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "interval_sec", c.interval_sec)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "retention_days", c.retention_days)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "day_count", c.day_count)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "quota_limit_bytes", c.quota_limit_bytes)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "quota_warning_threshold", c.quota_warning_threshold)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "quota_disconnect_threshold", c.quota_disconnect_threshold)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "reset_day", c.reset_day)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "webhook_url", c.webhook_url)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "smtp_server", c.smtp_server)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "smtp_port", c.smtp_port)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "smtp_user", c.smtp_user)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "smtp_pass", c.smtp_pass)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "smtp_from", c.smtp_from)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "smtp_to", c.smtp_to)) return sendErr(stream);

    buf[pos] = '}';
    pos += 1;
    sendJson(stream, 200, buf[0..pos]);
}

/// 响应缓冲区写满时的统一兜底响应
fn sendErr(stream: Stream) void {
    sendJson(stream, 500, "{\"error\":\"format error\"}");
}

/// 将配置中的字符串字段复制为独立分配，使配置不再引用临时解析内存。
/// 返回 false 表示内存不足。
fn ownConfigStrings(allocator: Allocator, c: *cfg.Config) bool {
    if (c.interface) |v| c.interface = allocator.dupe(u8, v) catch return false;
    if (c.log_file) |v| c.log_file = allocator.dupe(u8, v) catch return false;
    if (c.pid_file) |v| c.pid_file = allocator.dupe(u8, v) catch return false;
    if (c.webhook_url) |v| c.webhook_url = allocator.dupe(u8, v) catch return false;
    if (c.smtp_server) |v| c.smtp_server = allocator.dupe(u8, v) catch return false;
    if (c.smtp_port) |v| c.smtp_port = allocator.dupe(u8, v) catch return false;
    if (c.smtp_user) |v| c.smtp_user = allocator.dupe(u8, v) catch return false;
    if (c.smtp_pass) |v| c.smtp_pass = allocator.dupe(u8, v) catch return false;
    if (c.smtp_from) |v| c.smtp_from = allocator.dupe(u8, v) catch return false;
    if (c.smtp_to) |v| c.smtp_to = allocator.dupe(u8, v) catch return false;
    return true;
}

/// PUT /api/config：解析部分 JSON 配置，合并到当前配置后写回 SQLite config 表，
/// 并就地更新共享状态使 GET 立即返回新值；重启后由 runDemo 的 ConfigStore 重载生效。
/// 注意：重复 PUT 会丢弃旧字符串字段，与现有代码对 state.config 不做深度释放的
/// 风格一致，属可接受的小内存滞留。
fn handlePutConfigApi(ctx: HttpServerContext, stream: Stream, request: []const u8) void {
    // 定位请求体（请求头与请求体以空行 \r\n\r\n 分隔，第一行是请求行）
    const body_raw = extractBody(request) orelse {
        sendJson(stream, 400, "{\"error\":\"missing body\"}");
        return;
    };
    const body = std.mem.trim(u8, body_raw, " \t\r\n");
    if (body.len == 0) {
        sendJson(stream, 400, "{\"error\":\"empty body\"}");
        return;
    }

    // 复用 config 模块的 JSON 解析器：支持仅含部分字段的配置，含范围校验
    var parsed = cfg.parseConfigJson(ctx.allocator, body) catch {
        sendJson(stream, 400, "{\"error\":\"invalid json or field value\"}");
        return;
    };
    defer cfg.deinitConfig(ctx.allocator, &parsed.config);

    ctx.state.mu.lock();
    // 以当前生效配置为基础，覆盖 JSON 中出现的字段
    var merged = cfg.mergeConfigs(ctx.state.config, parsed.config, parsed.source);
    // 字符串字段自持拷贝，避免后续释放 parsed 后悬垂
    if (!ownConfigStrings(ctx.allocator, &merged)) {
        ctx.state.mu.unlock();
        sendJson(stream, 500, "{\"error\":\"out of memory\"}");
        return;
    }

    // 写回 SQLite config 表；重启后依然生效
    const store = cfg_store.ConfigStore.init(ctx.conn, ctx.allocator);
    if (store.saveAll(merged)) |_| {} else |_| {
        ctx.state.mu.unlock();
        sendJson(stream, 500, "{\"error\":\"db error\"}");
        return;
    }

    // 更新共享配置，使 GET 立即返回新值
    ctx.state.config = merged;
    ctx.state.mu.unlock();

    // 响应完整新配置
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var first = true;
    buf[pos] = '{';
    pos += 1;
    if (!appendStrField(&buf, &pos, &first, "interface", merged.interface)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "interval_sec", merged.interval_sec)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "retention_days", merged.retention_days)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "day_count", merged.day_count)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "quota_limit_bytes", merged.quota_limit_bytes)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "quota_warning_threshold", merged.quota_warning_threshold)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "quota_disconnect_threshold", merged.quota_disconnect_threshold)) return sendErr(stream);
    if (!appendNumField(&buf, &pos, &first, "reset_day", merged.reset_day)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "webhook_url", merged.webhook_url)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "smtp_server", merged.smtp_server)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "smtp_port", merged.smtp_port)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "smtp_user", merged.smtp_user)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "smtp_pass", merged.smtp_pass)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "smtp_from", merged.smtp_from)) return sendErr(stream);
    if (!appendStrField(&buf, &pos, &first, "smtp_to", merged.smtp_to)) return sendErr(stream);
    buf[pos] = '}';
    pos += 1;
    sendJson(stream, 200, buf[0..pos]);
}

// ── 配额 API ──

/// GET /api/quota：返回配额快照（与 checkQuota 语义一致）
fn handleGetQuotaApi(ctx: HttpServerContext, stream: Stream) void {
    const snap = computeQuotaSnapshot(ctx) catch {
        sendJson(stream, 500, "{\"error\":\"quota query failed\"}");
        return;
    };

    var buf: [2048]u8 = undefined;
    const json = std.fmt.bufPrint(
        &buf,
        "{{\"base_limit_bytes\":{d},\"effective_limit_bytes\":{d},\"monthly_usage_bytes\":{d},\"remaining_bytes\":{d},\"state\":\"{s}\",\"warning_threshold\":{d},\"disconnect_threshold\":{d},\"reset_day\":{d}}}",
        .{
            snap.base_limit_bytes,
            snap.effective_limit_bytes,
            snap.monthly_usage_bytes,
            snap.remaining_bytes,
            @tagName(snap.state),
            snap.warning_threshold,
            snap.disconnect_threshold,
            snap.reset_day,
        },
    ) catch {
        sendJson(stream, 500, "{\"error\":\"format error\"}");
        return;
    };
    sendJson(stream, 200, json);
}

fn handleGetAdjustmentsApi(ctx: HttpServerContext, stream: Stream) void {
    // 获取当前预算周期月份键（YYYY-MM），只列出当前周期调整
    const now_secs: u64 = @intCast(unixTimeSecs());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = now_secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const period = quota_mod.computePeriod(ctx.state.config.reset_day, year_day.year, month_day.month.numeric(), month_day.day_index + 1);

    var month_key_buf: [16]u8 = undefined;
    const month_key = std.fmt.bufPrint(&month_key_buf, "{d:0>4}-{d:0>2}", .{ period.year, period.month }) catch {
        sendJson(stream, 500, "{\"error\":\"format error\"}");
        return;
    };

    ctx.state.mu.lock();
    const adjustments = quota_mod.listAdjustments(ctx.allocator, ctx.conn, month_key) catch {
        ctx.state.mu.unlock();
        sendJson(stream, 500, "{\"error\":\"db error\"}");
        return;
    };
    ctx.state.mu.unlock();
    defer {
        for (adjustments) |adj| {
            ctx.allocator.free(adj.reason);
            ctx.allocator.free(adj.source);
            ctx.allocator.free(adj.month_key);
        }
        ctx.allocator.free(adjustments);
    }

    // 构建 JSON 数组（reason/source 可能含引号，做 JSON 转义）
    var json_buf: [16384]u8 = undefined;
    var pos: usize = 0;
    json_buf[pos] = '[';
    pos += 1;

    var first = true;
    for (adjustments) |adj| {
        var entry_buf: [2048]u8 = undefined;
        var epos: usize = 0;
        var efirst = true;
        entry_buf[epos] = '{';
        epos += 1;

        var ok = true;
        ok = ok and appendNumField(&entry_buf, &epos, &efirst, "id", adj.id);
        ok = ok and appendNumField(&entry_buf, &epos, &efirst, "amount_bytes", adj.amount_bytes);
        ok = ok and appendStrField(&entry_buf, &epos, &efirst, "reason", adj.reason);
        ok = ok and appendStrField(&entry_buf, &epos, &efirst, "source", adj.source);
        ok = ok and appendStrField(&entry_buf, &epos, &efirst, "month_key", adj.month_key);
        ok = ok and appendNumField(&entry_buf, &epos, &efirst, "created_at", adj.created_at);
        entry_buf[epos] = '}';
        epos += 1;
        if (!ok) continue; // 单条条目异常则跳过，保证整体 JSON 合法

        if (!first) {
            json_buf[pos] = ',';
            pos += 1;
        }
        first = false;
        const entry = entry_buf[0..epos];
        if (json_buf.len - pos < entry.len) continue;
        @memcpy(json_buf[pos..][0..entry.len], entry);
        pos += entry.len;
    }

    json_buf[pos] = ']';
    pos += 1;

    sendJson(stream, 200, json_buf[0..pos]);
}

/// 从原始请求中剥离请求行与各头部，返回请求体（以空行 \r\n\r\n / \n\n 为界）
fn extractBody(request: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, request, "\r\n\r\n")) |idx| {
        return request[idx + 4 ..];
    }
    if (std.mem.indexOf(u8, request, "\n\n")) |idx| {
        return request[idx + 2 ..];
    }
    return null;
}

/// 从 JSON body 中提取 "key" 后面的字段值；找不到返回 null。
/// 字符串值（以引号开头）按引号感知扫描：内部逗号/空白不再截断，
/// 支持反斜杠转义（\" 不作为结束引号）；返回结果不含两端引号。
/// 裸值（数字等）保持原终止条件（, } 行尾/空白），行为不变。
fn extractJsonField(body: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, body, key) orelse return null;
    var start = pos + key.len;
    while (start < body.len and (body[start] == ' ' or body[start] == '\t')) start += 1;
    if (start >= body.len) return null;
    var end = start;
    // 引号感知：扫描到下一个未转义引号作为字符串边界
    if (body[start] == '"') {
        var i = start + 1;
        while (i < body.len) : (i += 1) {
            // 反斜杠转义：跳过转义字符本身，避免把 \" 误判为结束引号
            if (body[i] == '\\' and i + 1 < body.len) {
                i += 1;
                continue;
            }
            if (body[i] == '"') {
                end = i;
                // 直接返回去除两端引号后的内容（含逗号不截断）
                return body[start + 1 .. end];
            }
        }
        // 防御：引号未闭合时退化为裸值扫描（正常 JSON 不会走到）
    }
    // 裸值路径：保持原有终止条件（逗号/右花括号/行尾）
    while (end < body.len and body[end] != ',' and body[end] != '}' and body[end] != '\n' and body[end] != '\r') end += 1;
    return std.mem.trim(u8, body[start..end], " \t");
}

/// POST /api/quota/adjustments：
/// 支持 amount_bytes（整数，字节数）与 amount（可读单位字符串如 "500MB"）两种字段，
/// 自动检测；至少提供一种，解析失败返回 400。
/// month_key 自动取当前预算周期起始月，不跨周期。
fn handlePostAdjustmentApi(ctx: HttpServerContext, stream: Stream, request: []const u8) void {
    // 定位请求体（请求头与请求体以空行 \r\n\r\n 分隔，第一行是请求行）
    const body = extractBody(request) orelse {
        sendJson(stream, 400, "{\"error\":\"missing body\"}");
        return;
    };

    // 优先 amount_bytes（整数），其次 amount（单位字符串，如 "500MB"）
    var amount_bytes: ?u64 = null;
    if (extractJsonField(body, "\"amount_bytes\":")) |raw| {
        amount_bytes = std.fmt.parseInt(u64, raw, 10) catch null;
        if (amount_bytes == null) {
            sendJson(stream, 400, "{\"error\":\"invalid amount_bytes\"}");
            return;
        }
    } else if (extractJsonField(body, "\"amount\":")) |raw| {
        // amount 兼容 "500MB"/"500" 等可读单位，交由 parseTrafficUnit 解析
        amount_bytes = quota_mod.parseTrafficUnit(raw) catch {
            sendJson(stream, 400, "{\"error\":\"invalid amount\"}");
            return;
        };
    }
    const final_amount = amount_bytes orelse {
        sendJson(stream, 400, "{\"error\":\"missing amount or amount_bytes\"}");
        return;
    };

    // 提取 reason（可选，缺省为空字符串）
    var reason: []const u8 = "";
    if (extractJsonField(body, "\"reason\":")) |r| {
        reason = r;
    }

    // 提取 source（可选，缺省 \"api\"）
    var source: []const u8 = "api";
    if (extractJsonField(body, "\"source\":")) |s| {
        source = s;
    }
    // 获取当前预算周期月份键（周期起始月，不跨周期）
    const now_secs: u64 = @intCast(unixTimeSecs());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = now_secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const period = quota_mod.computePeriod(ctx.state.config.reset_day, year_day.year, month_day.month.numeric(), month_day.day_index + 1);

    var month_key_buf: [16]u8 = undefined;
    const month_key = std.fmt.bufPrint(&month_key_buf, "{d:0>4}-{d:0>2}", .{ period.year, period.month }) catch {
        sendJson(stream, 500, "{\"error\":\"format error\"}");
        return;
    };

    const created_at: i64 = unixTimeSecs() * 1000;

    ctx.state.mu.lock();
    const adj = quota_mod.addAdjustment(ctx.allocator, ctx.conn, final_amount, reason, source, month_key, created_at) catch {
        ctx.state.mu.unlock();
        sendJson(stream, 500, "{\"error\":\"db error\"}");
        return;
    };
    ctx.state.mu.unlock();

    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"amount_bytes\":{d},\"month_key\":\"{s}\"}}", .{ adj.id, adj.amount_bytes, adj.month_key }) catch {
        sendJson(stream, 500, "{\"error\":\"format error\"}");
        return;
    };
    sendJson(stream, 201, json);
}

// ── HTTP 响应工具函数 ──

/// 完整写入：循环处理部分写入，MSG.NOSIGNAL 防止 SIGPIPE 终止进程
fn writeAll(fd: Stream, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = linux.sendto(fd, data[off..].ptr, data.len - off, linux.MSG.NOSIGNAL, null, 0);
        if (linux.errno(n) != .SUCCESS) return;
        off += n;
    }
}

fn sendHtml(stream: Stream, html: []const u8) void {
    // 内嵌 HTML（约 17KB，可能更大）必须用足够大的响应缓冲，
    // 否则 bufPrint 失败会导致 curl 收到空响应
    var buf: [65536]u8 = undefined;
    const response = std.fmt.bufPrint(&buf, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ html.len, html }) catch return;
    writeAll(stream, response);
}

fn sendJson(stream: Stream, status: u16, json: []const u8) void {
    const status_text = switch (status) {
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "Unknown",
    };
    var buf: [65536]u8 = undefined;
    const response = std.fmt.bufPrint(&buf, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, status_text, json.len, json }) catch return;
    writeAll(stream, response);
}

fn sendNotFound(stream: Stream) void {
    sendJson(stream, 404, "{\"error\":\"not found\"}");
}

// ── extractJsonField 引号感知测试 ──

// 目标：字符串值内部含逗号时不再被截断（reason 含逗号的回归测试）
test "extractJsonField: 字符串值含逗号不截断" {
    const body = "{\"reason\":\"hello, world\",\"source\":\"api\"}";
    const got = extractJsonField(body, "\"reason\":");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("hello, world", got.?);
}

// 目标：无逗号的普通字符串值行为不变（无回归）
test "extractJsonField: 无逗号的字符串值无回归" {
    const body = "{\"reason\":\"hello\",\"source\":\"api\"}";
    const got = extractJsonField(body, "\"reason\":");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("hello", got.?);
}

// 目标：非字符串裸值路径不受引号感知改造影响
test "extractJsonField: 裸数值路径不受影响" {
    const body = "{\"amount_bytes\":123}";
    const got = extractJsonField(body, "\"amount_bytes\":");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("123", got.?);
}

// 目标：转义引号 \" 不被误判为字符串结束（内容保留原始转义，不做反转义）
test "extractJsonField: 转义引号不截断" {
    const body = "{\"reason\":\"say \\\"hi\\\"\",\"source\":\"api\"}";
    const got = extractJsonField(body, "\"reason\":");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("say \\\"hi\\\"", got.?);
}
