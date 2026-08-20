// backend/tests/test_http_server.zig
// HTTP 服务器与全部 API 端点的集成回归测试。
//
// 设计说明：
// - 每个 test 启动一个真实 HTTP 服务器（http_server.startHttpServer），
//   端口由 pid + 自增偏移唯一分配，数据库用独立 :memory: SQLite，测试互不污染。
// - 客户端使用原始 posix socket：服务端对每个连接只做一次 recvfrom（上限 8192
//   字节），因此整个请求（含 body）必须一次性发送，std.http.Client 会分两次写
//   头部与 body，存在服务端只收到头的竞态；单次 send 则可确定性覆盖真实行为。
// - 服务器 accept 线程是无限循环且无停止 API，无法优雅 join/释放其引用的堆状态；
//   故服务器相关状态有意用 c_allocator 分配并保留至进程退出（zig test 进程退出时
//   由内核回收线程与内存，不会触发 c_allocator 泄漏检测）。
const std = @import("std");
const http_server = @import("http_server");
const zqlite = @import("zqlite");

const Io = std.Io;

/// 单次 HTTP 响应的解析结果（body 引用调用方提供的缓冲）
const Resp = struct {
    status: u16,
    body: []const u8,
};

/// 响应缓冲大小：GET / 返回整份内嵌 HTML（约 17KB），放宽到 128KB
const RESP_BUF_SIZE = 128 * 1024;
/// 请求缓冲大小：须小于服务端单次 recvfrom 的 8192 上限
const REQ_BUF_SIZE = 4096;

/// 建表语句：与生产 SCHEMA 一致（http 各端点依赖的三张表）
const TEST_SCHEMA =
    \\CREATE TABLE IF NOT EXISTS daily_traffic (
    \\    date INTEGER PRIMARY KEY,
    \\    total_rx_bytes INTEGER NOT NULL DEFAULT 0,
    \\    total_tx_bytes INTEGER NOT NULL DEFAULT 0,
    \\    total_rx_packets INTEGER NOT NULL DEFAULT 0,
    \\    total_tx_packets INTEGER NOT NULL DEFAULT 0
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS config (
    \\    key TEXT PRIMARY KEY,
    \\    value TEXT NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS quota_adjustments (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    amount_bytes INTEGER NOT NULL,
    \\    reason TEXT NOT NULL DEFAULT '',
    \\    source TEXT NOT NULL DEFAULT '',
    \\    month_key TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL
    \\);
;

/// 端口分配：基准端口由进程 pid 决定（多个 zig test 进程并行时互不冲突），每实例递增
var next_port_offset = std.atomic.Value(u32).init(0);

fn allocTestPort() u16 {
    const pid_raw: i64 = @intCast(std.os.linux.getpid());
    const pid_base: u32 = @intCast(@mod(pid_raw, 20000));
    const base: u16 = @intCast(10000 + pid_base);
    const off = next_port_offset.fetchAdd(1, .monotonic);
    return base + @as(u16, @intCast(off % 30000));
}

/// 非 Linux 平台跳过（本项目仅支持 Linux）
fn requireLinux() !void {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
}

/// 测试服务器：启动真实服务器并持有其唯一端口与堆状态指针
const TestServer = struct {
    port: u16,
    state: *http_server.AppState,
    conn: *zqlite.Conn,

    fn start() !TestServer {
        const alloc = std.heap.c_allocator; // 有意泄漏，见文件头说明
        const io = Io.Threaded.global_single_threaded.io();
        const port = allocTestPort();

        // 独立 :memory: 数据库，保证测试之间互不污染
        var conn = try alloc.create(zqlite.Conn);
        errdefer alloc.destroy(conn);
        conn.* = try zqlite.open(":memory:", 0);
        errdefer conn.close();
        try conn.execNoArgs(TEST_SCHEMA);

        var state = try alloc.create(http_server.AppState);
        errdefer alloc.destroy(state);
        state.* = .{};
        state.iface = "lo"; // 回环口必然存在，确保 /api/traffic/current 可读
        state.config = .{
            .interval_sec = 2,
            .retention_days = 30,
            .quota_limit_bytes = 1024 * 1024 * 1024, // 1GB 基础配额，供 /api/quota 断言调整生效
        };
        state.start_time_secs = @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));

        const ctx = http_server.HttpServerContext{
            .allocator = alloc,
            .state = state,
            .conn = conn,
            .io = io,
            .port = port,
        };
        const thread = try http_server.startHttpServer(ctx);
        thread.detach(); // accept 无限循环无法 join，随进程退出回收
        return .{ .port = port, .state = state, .conn = conn };
    }
};

/// 通过真实 TCP 连接发送单次 HTTP 请求。
/// 整个请求（请求行 + 头 + body）在一次 send 内完成，适配服务端单次 recvfrom 的实现。
fn httpRequest(
    port: u16,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
    resp_buf: []u8,
) !Resp {
    var req_buf: [REQ_BUF_SIZE]u8 = undefined;
    var req_len: usize = 0;
    if (body) |b| {
        if (b.len + 128 > req_buf.len) return error.ReqTooLong;
        const head = std.fmt.bufPrint(
            &req_buf,
            "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n",
            .{ method, path, b.len },
        ) catch return error.ReqTooLong;
        req_len = head.len;
        @memcpy(req_buf[req_len..][0..b.len], b);
        req_len += b.len;
    } else {
        const head = std.fmt.bufPrint(
            &req_buf,
            "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
            .{ method, path },
        ) catch return error.ReqTooLong;
        req_len = head.len;
    }

    const sock_rc = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
    if (std.os.linux.errno(sock_rc) != .SUCCESS) return error.SocketFailed;
    const sockfd: i32 = @intCast(sock_rc);
    defer _ = std.os.linux.close(sockfd);

    const addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0x0100007F, // 127.0.0.1（网络字节序，服务端绑定 0.0.0.0）
        .zero = [_]u8{0} ** 8,
    };
    const connect_rc = std.os.linux.connect(sockfd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in));
    if (std.os.linux.errno(connect_rc) != .SUCCESS) return error.ConnectFailed;

    const send_rc = std.os.linux.sendto(sockfd, req_buf[0..req_len].ptr, req_len, 0, null, 0);
    if (std.os.linux.errno(send_rc) != .SUCCESS) return error.SendFailed;

    // 读取响应直至服务端关闭连接
    var pos: usize = 0;
    while (pos < resp_buf.len) {
        const n = std.os.linux.recvfrom(sockfd, resp_buf[pos..].ptr, resp_buf.len - pos, 0, null, null);
        if (std.os.linux.errno(n) != .SUCCESS) break;
        if (n == 0) break;
        pos += n;
    }
    const resp = resp_buf[0..pos];
    const head_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.BadResponse;
    const head = resp[0..head_end];
    var line_it = std.mem.splitScalar(u8, head, ' ');
    _ = line_it.next() orelse return error.BadResponse; // "HTTP/1.1"
    const status_str = line_it.next() orelse return error.BadResponse;
    const status = std.fmt.parseInt(u16, status_str, 10) catch return error.BadResponse;
    return .{ .status = status, .body = resp[head_end + 4 ..] };
}

// ── 断言辅助函数 ──

fn expectStatus(r: Resp, expected: u16) !void {
    try std.testing.expectEqual(expected, r.status);
}

fn expectContains(body: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, body, needle) != null);
}

/// 从 POST /api/quota/adjustments 的 201 响应中提取 id 字段值
fn extractAdjustmentId(body: []const u8) !i64 {
    const key = "\"id\":";
    const start = (std.mem.indexOf(u8, body, key) orelse return error.NoIdField) + key.len;
    var end = start;
    while (end < body.len and body[end] != ',' and body[end] != '}') : (end += 1) {}
    return std.fmt.parseInt(i64, body[start..end], 10);
}

/// 将 epoch day 格式化为 YYYY-MM-DD（与 http_server.formatDateFromEpochDay 一致）
fn fmtDate(epoch_day: u32, buf: []u8) ![]const u8 {
    const ed = std.time.epoch.EpochDay{ .day = epoch_day };
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 }) catch error.DateBufTooSmall;
}

// ── HTTP 页面与状态端点 ──

test "GET / 与 /index.html 返回内嵌仪表盘 HTML" {
    try requireLinux();
    const ts = try TestServer.start();
    var b1: [RESP_BUF_SIZE]u8 = undefined;
    const r1 = try httpRequest(ts.port, "GET", "/", null, &b1);
    try expectStatus(r1, 200);
    try expectContains(r1.body, "<!DOCTYPE html>");
    try expectContains(r1.body, "TrafficManager");

    var b2: [RESP_BUF_SIZE]u8 = undefined;
    const r2 = try httpRequest(ts.port, "GET", "/index.html", null, &b2);
    try expectStatus(r2, 200);
    try expectContains(r2.body, "<!DOCTYPE html>");
}

test "GET /api/status 返回运行状态 JSON" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "GET", "/api/status", null, &b);
    try expectStatus(r, 200);
    try expectContains(r.body, "\"state\":\"running\"");
    try expectContains(r.body, "\"interface\":\"lo\"");
    try expectContains(r.body, "\"uptime_seconds\":");
    try expectContains(r.body, "\"quota_state\":\"normal\"");
}

test "GET /api/traffic/current 返回六个速率字段" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "GET", "/api/traffic/current", null, &b);
    try expectStatus(r, 200);
    try expectContains(r.body, "\"rx_speed_bps\":");
    try expectContains(r.body, "\"tx_speed_bps\":");
    try expectContains(r.body, "\"rx_pps\":");
    try expectContains(r.body, "\"tx_pps\":");
    try expectContains(r.body, "\"total_rx_bytes\":");
    try expectContains(r.body, "\"total_tx_bytes\":");
}

// ── 日流量历史端点 ──

test "GET /api/traffic/daily 缺省 days 返回数组" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "GET", "/api/traffic/daily", null, &b);
    try expectStatus(r, 200);
    try std.testing.expect(r.body.len > 0);
    try std.testing.expect(r.body[0] == '[');
}

test "GET /api/traffic/daily?days=7 返回历史日期与流量" {
    try requireLinux();
    const ts = try TestServer.start();
    const io = Io.Threaded.global_single_threaded.io();
    const now_secs: u64 = @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    const e_secs = std.time.epoch.EpochSeconds{ .secs = now_secs };
    const today: u32 = @intCast(e_secs.getEpochDay().day);
    try ts.conn.exec(
        "INSERT INTO daily_traffic (date, total_rx_bytes, total_tx_bytes) VALUES (?1, ?2, ?3)",
        .{ @as(i64, @intCast(today)), @as(i64, 500), @as(i64, 1200) },
    );
    try ts.conn.exec(
        "INSERT INTO daily_traffic (date, total_rx_bytes, total_tx_bytes) VALUES (?1, ?2, ?3)",
        .{ @as(i64, @intCast(today - 1)), @as(i64, 100), @as(i64, 200) },
    );

    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "GET", "/api/traffic/daily?days=7", null, &b);
    try expectStatus(r, 200);
    var date_buf: [16]u8 = undefined;
    try expectContains(r.body, try fmtDate(today, &date_buf));
    try expectContains(r.body, "\"rx_bytes\":500");
    try expectContains(r.body, try fmtDate(today - 1, &date_buf));
    try expectContains(r.body, "\"rx_bytes\":100");
}

test "GET /api/traffic/daily?days=abc 返回 400" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "GET", "/api/traffic/daily?days=abc", null, &b);
    try expectStatus(r, 400);
    try expectContains(r.body, "invalid days");
}

test "GET /api/traffic/daily?days=0 返回 400" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "GET", "/api/traffic/daily?days=0", null, &b);
    try expectStatus(r, 400);
}

// ── 配置端点 ──

test "GET /api/config 返回完整配置字段" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "GET", "/api/config", null, &b);
    try expectStatus(r, 200);
    try expectContains(r.body, "\"interface\"");
    try expectContains(r.body, "\"interval_sec\":2");
    try expectContains(r.body, "\"retention_days\"");
    try expectContains(r.body, "\"quota_limit_bytes\"");
    try expectContains(r.body, "\"quota_warning_threshold\"");
    try expectContains(r.body, "\"webhook_url\"");
    try expectContains(r.body, "\"smtp_to\"");
}

test "PUT /api/config 合法 JSON 合并并持久化，GET 立即返回新值" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const put_body = "{\"interface\":\"eth-test\",\"interval_sec\":5,\"retention_days\":60}";
    const r = try httpRequest(ts.port, "PUT", "/api/config", put_body, &b);
    try expectStatus(r, 200);
    try expectContains(r.body, "\"interval_sec\":5");

    var b2: [RESP_BUF_SIZE]u8 = undefined;
    const g = try httpRequest(ts.port, "GET", "/api/config", null, &b2);
    try expectStatus(g, 200);
    try expectContains(g.body, "\"interface\":\"eth-test\"");
    try expectContains(g.body, "\"interval_sec\":5");
    try expectContains(g.body, "\"retention_days\":60");
}

test "PUT /api/config 坏 JSON 返回 400" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "PUT", "/api/config", "{not-valid-json", &b);
    try expectStatus(r, 400);
}

test "PUT /api/config 空 body 返回 400" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "PUT", "/api/config", null, &b);
    try expectStatus(r, 400);
}

test "PUT /api/config 越界字段值返回 400" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "PUT", "/api/config", "{\"interval_sec\":0}", &b);
    try expectStatus(r, 400);
}

test "PUT 未知路径返回 404" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "PUT", "/api/quota", null, &b);
    try expectStatus(r, 404);
}

// ── 配额快照与调整端点 ──

test "GET /api/quota 返回配额快照 8 字段" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "GET", "/api/quota", null, &b);
    try expectStatus(r, 200);
    try expectContains(r.body, "\"base_limit_bytes\":1073741824");
    try expectContains(r.body, "\"effective_limit_bytes\":1073741824");
    try expectContains(r.body, "\"monthly_usage_bytes\":");
    try expectContains(r.body, "\"remaining_bytes\":");
    try expectContains(r.body, "\"state\":\"normal\"");
    try expectContains(r.body, "\"warning_threshold\":0.9");
    try expectContains(r.body, "\"disconnect_threshold\":1");
    try expectContains(r.body, "\"reset_day\":1");
}

test "GET /api/quota/adjustments 初始返回空列表" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "GET", "/api/quota/adjustments", null, &b);
    try expectStatus(r, 200);
    try std.testing.expectEqualStrings("[]", r.body);
}

test "POST /api/quota/adjustments 新增调整：列表 +1 且有效配额增加" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "POST", "/api/quota/adjustments", "{\"amount\":\"500MB\",\"reason\":\"t\"}", &b);
    try expectStatus(r, 201);
    try expectContains(r.body, "\"amount_bytes\":524288000");
    const id = try extractAdjustmentId(r.body);
    try std.testing.expect(id > 0);

    // 列表应包含新条目
    var b2: [RESP_BUF_SIZE]u8 = undefined;
    const lst = try httpRequest(ts.port, "GET", "/api/quota/adjustments", null, &b2);
    try expectStatus(lst, 200);
    try expectContains(lst.body, "\"amount_bytes\":524288000");

    // 有效配额 = 1GB 基础 + 500MB
    var b3: [RESP_BUF_SIZE]u8 = undefined;
    const q = try httpRequest(ts.port, "GET", "/api/quota", null, &b3);
    try expectStatus(q, 200);
    try expectContains(q.body, "\"effective_limit_bytes\":1598029824");
}

test "POST /api/quota/adjustments 支持 amount_bytes 字段" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "POST", "/api/quota/adjustments", "{\"amount_bytes\":4096,\"reason\":\"x\"}", &b);
    try expectStatus(r, 201);
    try expectContains(r.body, "\"amount_bytes\":4096");
}

test "POST /api/quota/adjustments 非法 amount 返回 400" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "POST", "/api/quota/adjustments", "{\"amount\":\"xyz\"}", &b);
    try expectStatus(r, 400);
}

test "POST /api/quota/adjustments 缺少 amount 返回 400" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "POST", "/api/quota/adjustments", "{\"reason\":\"t\"}", &b);
    try expectStatus(r, 400);
}

test "POST /api/quota/adjustments 非法 amount_bytes 返回 400" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "POST", "/api/quota/adjustments", "{\"amount_bytes\":\"abc\"}", &b);
    try expectStatus(r, 400);
}

test "DELETE /api/quota/adjustments/:id 删除成功且有效配额回落" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const p = try httpRequest(ts.port, "POST", "/api/quota/adjustments", "{\"amount\":\"500MB\"}", &b);
    try expectStatus(p, 201);
    const id = try extractAdjustmentId(p.body);

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/quota/adjustments/{d}", .{id});
    var b2: [RESP_BUF_SIZE]u8 = undefined;
    const del = try httpRequest(ts.port, "DELETE", path, null, &b2);
    try expectStatus(del, 200);
    try expectContains(del.body, "\"ok\":true");

    // 列表应重新为空
    var b3: [RESP_BUF_SIZE]u8 = undefined;
    const lst = try httpRequest(ts.port, "GET", "/api/quota/adjustments", null, &b3);
    try expectStatus(lst, 200);
    try std.testing.expectEqualStrings("[]", lst.body);

    // 有效配额回落为基础 1GB
    var b4: [RESP_BUF_SIZE]u8 = undefined;
    const q = try httpRequest(ts.port, "GET", "/api/quota", null, &b4);
    try expectStatus(q, 200);
    try expectContains(q.body, "\"effective_limit_bytes\":1073741824");
}

test "DELETE /api/quota/adjustments/非法 id 返回 400" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "DELETE", "/api/quota/adjustments/abc", null, &b);
    try expectStatus(r, 400);
}

test "DELETE /api/quota/adjustments/不存在的 id 返回 404" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "DELETE", "/api/quota/adjustments/999999", null, &b);
    try expectStatus(r, 404);
}

// ── 路由兜底与服务器启动错误路径 ──

test "GET 未知路径返回 404" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "GET", "/api/does-not-exist", null, &b);
    try expectStatus(r, 404);
}

test "未知 HTTP 方法返回 404" {
    try requireLinux();
    const ts = try TestServer.start();
    var b: [RESP_BUF_SIZE]u8 = undefined;
    const r = try httpRequest(ts.port, "PATCH", "/", null, &b);
    try expectStatus(r, 404);
}

test "startHttpServer 端口被占用时返回 BindFailed" {
    try requireLinux();
    const ts = try TestServer.start();
    const io = Io.Threaded.global_single_threaded.io();
    const ctx2 = http_server.HttpServerContext{
        .allocator = std.heap.c_allocator,
        .state = ts.state,
        .conn = ts.conn,
        .io = io,
        .port = ts.port,
    };
    try std.testing.expectError(error.BindFailed, http_server.startHttpServer(ctx2));
}
