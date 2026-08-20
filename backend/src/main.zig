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
pub const sqlite_storage = @import("sqlite_storage.zig");
pub const pidfile = @import("pidfile.zig");
pub const daemon = @import("daemon.zig");
pub const log = @import("log.zig");
pub const sqlite_schema = @import("sqlite_schema.zig");
pub const network = @import("network.zig");
pub const webhook = @import("webhook.zig");
pub const smtp = @import("smtp.zig");
pub const cfg = @import("config.zig");
pub const notify_template = @import("notify_template.zig");
pub const quota = @import("quota.zig");
pub const config_store = @import("config_store.zig");
pub const http_server = @import("http_server.zig");

const Allocator = std.mem.Allocator;

/// 存储后端标签
const StorageBackend = union(enum) {
    file: *storage.Storage,
    sqlite: *sqlite_storage.SQLiteStorage,
};

/// 命令行指定的临时配额调整参数
pub const QuotaAdjustmentArg = struct {
    /// 调整额度（字节）
    amount_bytes: u64,
    /// 调整原因（未提供时为空字符串）
    reason: []const u8,
};

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
    /// 以守护进程模式运行
    daemon_mode: bool = false,
    /// 强制前台运行（与 --daemon 互斥）
    foreground: bool = false,
    /// 日志文件路径
    log_file: ?[]const u8 = null,
    /// PID 文件路径
    pid_file: ?[]const u8 = null,
    /// 历史记录保留天数
    retention_days: u32 = 30,
    /// 使用 SQLite 存储
    use_sqlite: bool = false,
    // ── Quota 配置 ──
    /// 月度流量配额限制（字节），0 = 禁用配额检查
    quota_limit_bytes: u64 = 0,
    /// 警告阈值（占配额比例，如 0.9 = 90%）
    quota_warning_threshold: f64 = 0.9,
    /// 断网阈值（占配额比例，如 1.0 = 100%）
    quota_disconnect_threshold: f64 = 1.0,
    // ── 通知配置 ──
    /// Webhook URL（用于 HTTP POST 通知）
    webhook_url: ?[]const u8 = null,
    /// SMTP 服务器地址
    smtp_server: ?[]const u8 = null,
    /// SMTP 端口
    smtp_port: ?[]const u8 = null,
    /// SMTP 认证用户名
    smtp_user: ?[]const u8 = null,
    /// SMTP 认证密码
    smtp_pass: ?[]const u8 = null,
    /// SMTP 发件人地址
    smtp_from: ?[]const u8 = null,
    /// SMTP 收件人地址
    smtp_to: ?[]const u8 = null,
    // ── 运行时控制 ──
    /// 手动恢复网络并重置配额状态
    restore_network: bool = false,
    /// 配额重置日（1-28），用于自动恢复判断
    reset_day: u8 = 1,
    /// CLI 指定的临时配额调整（仅命令行生效，不参与配置合并，也不存入 ConfigStore）
    quota_adjustments: []QuotaAdjustmentArg = &.{},
    /// HTTP 服务器端口（0 = 不启动 HTTP 服务器）
    web_port: u16 = 0,
};

/// parseArgs 返回结果，包含合并后的配置和 CLI 来源信息
/// 用于 runDemo 中 SQLite ConfigStore 加载后重新合并 CLI 覆盖
pub const ParseResult = struct {
    config: AppConfig,
    cli_source: cfg.ConfigSource,
    cli_cfg: cfg.Config,
};

pub fn parseArgs(io: std.Io, allocator: Allocator, args_vec: std.process.Args) !ParseResult {
    var args = try std.process.Args.Iterator.initAllocator(args_vec, allocator);
    defer args.deinit();

    // 跳过第 0 个参数（程序自身路径）
    _ = args.skip();

    // First pass: find --config flag
    var config_path_arg: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            config_path_arg = args.next() orelse {
                std.debug.print("错误: --config 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            break;
        }
    }

    // Reset iterator for second pass
    args.deinit();
    args = try std.process.Args.Iterator.initAllocator(args_vec, allocator);
    defer args.deinit();
    _ = args.skip();

    // Parse config file if specified
    var file_config = cfg.Config{};
    var file_source = cfg.ConfigSource{};
    if (config_path_arg) |path| {
        const parsed = cfg.parseConfigFile(io, allocator, path) catch |err| {
            std.debug.print("错误: 无法解析配置文件 '{s}': {s}\n", .{ path, @errorName(err) });
            return err;
        };
        file_config = parsed.config;
        file_source = parsed.source;
    }

    // Second pass: parse CLI arguments
    var cli_config = AppConfig{};
    var cli_source = cfg.ConfigSource{};

    // 待处理的配额调整参数（--quota-adjust 与 --quota-adjust-reason 配对使用）
    var pending_adjust_amount: ?[]const u8 = null;
    var pending_adjust_reason: ?[]const u8 = null;
    // 收集所有 CLI 指定的配额调整
    var adjust_list = std.ArrayList(QuotaAdjustmentArg).empty;

    while (args.next()) |arg| {
        // 配置文件路径（已在第一轮处理，这里跳过值）
        if (std.mem.eql(u8, arg, "--config")) {
            _ = args.next(); // skip value
        }
        // 采样间隔（秒）
        else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--duration")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: -d/--duration 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.interval_sec = std.fmt.parseInt(u64, val_str, 10) catch {
                std.debug.print("错误: -d/--duration 参数值 '{s}' 不是有效数字!\n", .{val_str});
                return error.InvalidArgumentValue;
            };
            cli_config.interval_explicit = true;
            cli_source.interval_sec = true;
        }
        // 指定监听网卡
        else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interface")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: -i/--interface 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            // args.deinit() 会释放 val_str，因此复制一份
            cli_config.interface = try allocator.dupe(u8, val_str);
            cli_source.interface = true;
        }
        // 列出网卡
        else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            cli_config.list_only = true;
            cli_source.list_only = true;
        }
        // 查询历史流量
        else if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--day")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: -D/--day 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.day_count = std.fmt.parseInt(u32, val_str, 10) catch {
                std.debug.print("错误: -D/--day 参数值 '{s}' 不是有效数字!\n", .{val_str});
                return error.InvalidArgumentValue;
            };
            cli_source.day_count = true;
        }
        // 守护进程模式（无短标志，避免与 -D 冲突）
        else if (std.mem.eql(u8, arg, "--daemon")) {
            cli_config.daemon_mode = true;
            cli_source.daemon_mode = true;
        }
        // 强制前台运行
        else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--foreground")) {
            cli_config.foreground = true;
            cli_source.foreground = true;
        }
        // 日志文件路径
        else if (std.mem.eql(u8, arg, "--log-file")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --log-file 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.log_file = try allocator.dupe(u8, val_str);
            cli_source.log_file = true;
        }
        // PID 文件路径
        else if (std.mem.eql(u8, arg, "--pid-file")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --pid-file 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.pid_file = try allocator.dupe(u8, val_str);
            cli_source.pid_file = true;
        }
        // 历史记录保留天数
        else if (std.mem.eql(u8, arg, "--retention-days")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --retention-days 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.retention_days = std.fmt.parseInt(u32, val_str, 10) catch {
                std.debug.print("错误: --retention-days 参数值 '{s}' 不是有效数字!\n", .{val_str});
                return error.InvalidArgumentValue;
            };
            cli_source.retention_days = true;
        }
        // SQLite 存储开关
        else if (std.mem.eql(u8, arg, "--sqlite")) {
            cli_config.use_sqlite = true;
            cli_source.use_sqlite = true;
        } else if (std.mem.eql(u8, arg, "--no-sqlite")) {
            cli_config.use_sqlite = false;
            cli_source.use_sqlite = true;
        }
        // ── Quota 配置 ──
        // 月度流量配额限制（支持人类可读格式：100GB, 500MB, 1TB）
        else if (std.mem.eql(u8, arg, "--quota-limit")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --quota-limit 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.quota_limit_bytes = quota.parseTrafficUnit(val_str) catch {
                std.debug.print("错误: --quota-limit 参数值 '{s}' 无效（支持: 100GB, 500MB, 1TB）\n", .{val_str});
                return error.InvalidArgumentValue;
            };
            cli_source.quota_limit_bytes = true;
        }
        // 警告阈值（0.0-1.0）
        else if (std.mem.eql(u8, arg, "--quota-warning")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --quota-warning 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            const parsed = std.fmt.parseFloat(f64, val_str) catch {
                std.debug.print("警告: --quota-warning 参数值 '{s}' 不是有效数字，使用默认值 0.9\n", .{val_str});
                continue;
            };
            if (parsed < 0.0 or parsed > 1.0) {
                std.debug.print("警告: --quota-warning 参数值 '{s}' 不在有效范围内（0.0-1.0），使用默认值 0.9\n", .{val_str});
                continue;
            }
            cli_config.quota_warning_threshold = parsed;
            cli_source.quota_warning_threshold = true;
        }
        // 断网阈值（0.0-1.0）
        else if (std.mem.eql(u8, arg, "--quota-disconnect")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --quota-disconnect 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            const parsed = std.fmt.parseFloat(f64, val_str) catch {
                std.debug.print("警告: --quota-disconnect 参数值 '{s}' 不是有效数字，使用默认值 1.0\n", .{val_str});
                continue;
            };
            if (parsed < 0.0 or parsed > 1.0) {
                std.debug.print("警告: --quota-disconnect 参数值 '{s}' 不在有效范围内（0.0-1.0），使用默认值 1.0\n", .{val_str});
                continue;
            }
            cli_config.quota_disconnect_threshold = parsed;
            cli_source.quota_disconnect_threshold = true;
        }
        // ── 通知配置 ──
        // Webhook URL
        else if (std.mem.eql(u8, arg, "--webhook-url")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --webhook-url 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.webhook_url = try allocator.dupe(u8, val_str);
            cli_source.webhook_url = true;
        }
        // SMTP 服务器
        else if (std.mem.eql(u8, arg, "--smtp-server")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --smtp-server 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.smtp_server = try allocator.dupe(u8, val_str);
            cli_source.smtp_server = true;
        }
        // SMTP 端口
        else if (std.mem.eql(u8, arg, "--smtp-port")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --smtp-port 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.smtp_port = try allocator.dupe(u8, val_str);
            cli_source.smtp_port = true;
        }
        // SMTP 用户名
        else if (std.mem.eql(u8, arg, "--smtp-user")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --smtp-user 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.smtp_user = try allocator.dupe(u8, val_str);
            cli_source.smtp_user = true;
        }
        // SMTP 密码
        else if (std.mem.eql(u8, arg, "--smtp-pass")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --smtp-pass 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.smtp_pass = try allocator.dupe(u8, val_str);
            cli_source.smtp_pass = true;
        }
        // SMTP 发件人
        else if (std.mem.eql(u8, arg, "--smtp-from")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --smtp-from 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.smtp_from = try allocator.dupe(u8, val_str);
            cli_source.smtp_from = true;
        }
        // SMTP 收件人
        else if (std.mem.eql(u8, arg, "--smtp-to")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --smtp-to 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.smtp_to = try allocator.dupe(u8, val_str);
            cli_source.smtp_to = true;
        }
        // 临时配额调整（可多次指定，每次添加一条调整记录）
        else if (std.mem.eql(u8, arg, "--quota-adjust")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --quota-adjust 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            // 固化上一个待定调整，保证原因（--quota-adjust-reason）若出现在其前也能正确配对
            if (pending_adjust_amount) |prev_str| {
                const prev_amount = quota.parseTrafficUnit(prev_str) catch |err| {
                    std.debug.print("错误: --quota-adjust 参数值 '{s}' 无效 ({s})\n", .{ prev_str, @errorName(err) });
                    allocator.free(prev_str);
                    return error.InvalidArgumentValue;
                };
                allocator.free(prev_str);
                try adjust_list.append(allocator, .{
                    .amount_bytes = prev_amount,
                    .reason = pending_adjust_reason orelse "",
                });
                // 原因指针已移交给记录（runDemo 统一释放），此处只清空挂起状态
                pending_adjust_amount = null;
                pending_adjust_reason = null;
            }
            pending_adjust_amount = try allocator.dupe(u8, val_str);
        }
        // 配额调整原因（与最近一次的 --quota-adjust 配对，可出现在其前或后）
        else if (std.mem.eql(u8, arg, "--quota-adjust-reason")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --quota-adjust-reason 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            // 覆盖旧原因前先释放，避免内存泄漏
            if (pending_adjust_reason) |old| allocator.free(old);
            pending_adjust_reason = try allocator.dupe(u8, val_str);
        }
        // 手动恢复网络并重置配额
        else if (std.mem.eql(u8, arg, "--resume")) {
            cli_config.restore_network = true;
            cli_source.restore_network = true;
        }
        // 配额重置日（1-28）
        else if (std.mem.eql(u8, arg, "--reset-day")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --reset-day 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.reset_day = std.fmt.parseInt(u8, val_str, 10) catch {
                std.debug.print("错误: --reset-day 参数值 '{s}' 不是有效数字!\n", .{val_str});
                return error.InvalidArgumentValue;
            };
            cli_source.reset_day = true;
        }
        // HTTP 服务器端口
        else if (std.mem.eql(u8, arg, "--web-port")) {
            const val_str = args.next() orelse {
                std.debug.print("错误: --web-port 选项缺少参数值\n", .{});
                return error.MissingArgumentValue;
            };
            cli_config.web_port = std.fmt.parseInt(u16, val_str, 10) catch {
                std.debug.print("错误: --web-port 参数值 '{s}' 不是有效数字!\n", .{val_str});
                return error.InvalidArgumentValue;
            };
        }
        // 帮助
        else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        }

    }

    // 循环结束后固化仍挂起的最后一个配额调整
    if (pending_adjust_amount) |amt_str| {
        const amount = quota.parseTrafficUnit(amt_str) catch |err| {
            std.debug.print("错误: --quota-adjust 参数值 '{s}' 无效 ({s})\n", .{ amt_str, @errorName(err) });
            allocator.free(amt_str);
            return error.InvalidArgumentValue;
        };
        allocator.free(amt_str);
        try adjust_list.append(allocator, .{
            .amount_bytes = amount,
            .reason = pending_adjust_reason orelse "",
        });
        // 原因指针已移交给记录（runDemo 统一释放），此处只清空挂起状态
        pending_adjust_amount = null;
        pending_adjust_reason = null;
    } else if (pending_adjust_reason) |r| {
        // 只给了原因却没有对应的调整量，释放遗留原因避免泄漏
        allocator.free(r);
        pending_adjust_reason = null;
    }

    // 将收集到的 CLI 配额调整挂到 CLI 配置上（非 cfg.Config 字段，仅 CLI 生效）
    cli_config.quota_adjustments = try adjust_list.toOwnedSlice(allocator);

    // Merge configs: CLI takes precedence over file
    // Convert cli_config to cfg.Config for merging
    const cli_cfg_config = cfg.Config{
        .interface = cli_config.interface,
        .interval_sec = cli_config.interval_sec,
        .daemon_mode = cli_config.daemon_mode,
        .foreground = cli_config.foreground,
        .use_sqlite = cli_config.use_sqlite,
        .retention_days = cli_config.retention_days,
        .log_file = cli_config.log_file,
        .pid_file = cli_config.pid_file,
        .list_only = cli_config.list_only,
        .day_count = cli_config.day_count,
        .quota_limit_bytes = cli_config.quota_limit_bytes,
        .quota_warning_threshold = cli_config.quota_warning_threshold,
        .quota_disconnect_threshold = cli_config.quota_disconnect_threshold,
        .reset_day = cli_config.reset_day,
        .webhook_url = cli_config.webhook_url,
        .smtp_server = cli_config.smtp_server,
        .smtp_port = cli_config.smtp_port,
        .smtp_user = cli_config.smtp_user,
        .smtp_pass = cli_config.smtp_pass,
        .smtp_from = cli_config.smtp_from,
        .smtp_to = cli_config.smtp_to,
        .restore_network = cli_config.restore_network,
    };
    const merged = cfg.mergeConfigs(file_config, cli_cfg_config, cli_source);

    // Convert to AppConfig
    const result = AppConfig{
        .interval_sec = merged.interval_sec,
        .interface = merged.interface,
        .list_only = merged.list_only,
        .day_count = merged.day_count,
        .interval_explicit = cli_config.interval_explicit or file_source.interval_sec,
        .daemon_mode = merged.daemon_mode,
        .foreground = merged.foreground,
        .log_file = merged.log_file,
        .pid_file = merged.pid_file,
        .retention_days = merged.retention_days,
        .use_sqlite = merged.use_sqlite,
        // Quota 配置
        .quota_limit_bytes = merged.quota_limit_bytes,
        .quota_warning_threshold = merged.quota_warning_threshold,
        .quota_disconnect_threshold = merged.quota_disconnect_threshold,
        // 通知配置
        .webhook_url = merged.webhook_url,
        .smtp_server = merged.smtp_server,
        .smtp_port = merged.smtp_port,
        .smtp_user = merged.smtp_user,
        .smtp_pass = merged.smtp_pass,
        .smtp_from = merged.smtp_from,
        .smtp_to = merged.smtp_to,
        // 运行时控制
        .restore_network = merged.restore_network,
        .reset_day = merged.reset_day,
        // CLI 配额调整（不参与配置合并，直接透传）
        .quota_adjustments = cli_config.quota_adjustments,
        .web_port = cli_config.web_port,
    };

    // Validate
    cfg.validateConfig(.{
        .interval_sec = result.interval_sec,
        .daemon_mode = result.daemon_mode,
        .foreground = result.foreground,
        .retention_days = result.retention_days,
        .day_count = result.day_count,
    }) catch |err| {
        std.debug.print("错误: 配置验证失败: {s}\n", .{@errorName(err)});
        return err;
    };

    // Validate reset_day range (1-28)
    if (result.reset_day < 1 or result.reset_day > 28) {
        std.debug.print("错误: --reset-day 必须在 1-28 之间\n", .{});
        return error.InvalidArgumentValue;
    }

    return .{
        .config = result,
        .cli_source = cli_source,
        .cli_cfg = cli_cfg_config,
    };
}

fn printHelp() void {
    std.debug.print(
        \\Traffic Manager — 网卡流量监控 Demo
        \\
        \\用法: traffic-backend [选项]
        \\
        \\选项:
        \\  -d, --duration <秒>        采样间隔（默认: 1）
        \\  -i, --interface <名>       指定监听网卡（例如: eth0, wlan0）
        \\  -l, --list                 列出系统所有网卡后退出
        \\  -D, --day <天数>           显示最近 N 天流量统计（最多显示 3 天详情）
        \\  --config <路径>            指定配置文件路径（JSON 格式）
        \\  -h, --help                 显示帮助信息
        \\
        \\守护进程选项:
        \\  --daemon                   以守护进程模式运行（后台）
        \\  -f, --foreground           强制前台运行（与 --daemon 互斥）
        \\  --pid-file <路径>          写入 PID 文件
        \\  --log-file <路径>          输出日志到文件
        \\
        \\存储选项:
        \\  --retention-days <天数>    历史记录保留天数（默认: 30）
        \\  --sqlite                   使用 SQLite 存储
        \\  --no-sqlite                禁用 SQLite 存储（默认）
        \\
        \\配额管理选项:
        \\  --quota-limit <大小>       月度流量配额（支持: 100GB, 500MB, 1TB）
        \\  --quota-warning <比例>     警告阈值（0.0-1.0，默认: 0.9）
        \\  --quota-disconnect <比例>  断网阈值（0.0-1.0，默认: 1.0）
        \\  --quota-reset-day <日期>   配额每月重置日（1-28，默认: 1）
        \\  --resume                   手动恢复网络并重置配额状态
        \\  --reset-day <日期>         配额每月重置日（1-28，默认: 1）
        \\  --quota-adjust <金额>      添加当月临时配额（可多次指定，支持: 500MB, 1GB）
        \\  --quota-adjust-reason <文本>  配额调整原因（配合 --quota-adjust 使用）
        \\                               - 与最近一次的 --quota-adjust 配对
        \\
        \\通知配置选项:
        \\  --webhook-url <URL>        Webhook 通知地址
        \\  --smtp-server <地址>       SMTP 服务器地址
        \\  --smtp-port <端口>         SMTP 端口（默认: 25）
        \\  --smtp-user <用户名>       SMTP 认证用户名
        \\  --smtp-pass <密码>         SMTP 认证密码
        \\  --smtp-from <地址>         SMTP 发件人地址
        \\  --smtp-to <地址>           SMTP 收件人地址
        \\
        \\示例:
        \\  traffic-backend                自动选择默认网卡，每秒采样一次
        \\  traffic-backend -d 2 -i eth0   每 2 秒采样一次 eth0
        \\  traffic-backend -l             查看系统有哪些网卡
        \\  traffic-backend -D 3           显示最近 3 天的流量统计
        \\  traffic-backend --config /etc/traffic-manager.json
        \\                                 使用配置文件运行
        \\  traffic-backend --daemon --pid-file /tmp/traffic.pid
        \\                                 以守护进程模式运行
        \\  traffic-backend --resume       恢复网络并重置配额
        \\
        \\配置文件格式 (JSON):
        \\  {{{{
        \\      "interface": "eth0",
        \\      "interval_sec": 5,
        \\      "daemon_mode": false,
        \\      "use_sqlite": true,
        \\      "retention_days": 60,
        \\      "log_file": "/var/log/traffic-manager.log",
        \\      "pid_file": "/var/run/traffic-manager.pid",
        \\      "reset_day": 1,
        \\      "quota_limit_bytes": 107374182400,
        \\      "quota_warning_threshold": 0.9,
        \\      "quota_disconnect_threshold": 1.0,
        \\      "webhook_url": "https://hooks.example.com/notify",
        \\      "smtp_server": "smtp.example.com",
        \\      "smtp_port": "587",
        \\      "smtp_user": "user@example.com",
        \\      "smtp_pass": "password",
        \\      "smtp_from": "traffic@example.com",
        \\      "smtp_to": "admin@example.com"
        \\  }}}}
        \\
        \\注: 命令行参数优先于配置文件中的同名选项
        \\
    , .{});
}

// Zig 0.16 标准入口：runtime 自动提供带泄漏检测的 allocator、Io 实例与命令行参数
pub fn main(init: std.process.Init) !void {
    // 安装 SIGINT / SIGTERM 处理器，使进程退出前有机会保存历史数据
    installSignalHandlers();
    const home_dir = init.environ_map.get("HOME");

    // 先解析参数，以便判断是否需要 daemonize
    const parse_result = try parseArgs(init.io, init.gpa, init.minimal.args);
    var app_config = parse_result.config;
    const cli_source = parse_result.cli_source;
    const cli_cfg = parse_result.cli_cfg;
    defer if (app_config.interface) |iface| init.gpa.free(iface);
    defer if (app_config.log_file) |path| init.gpa.free(path);
    defer if (app_config.pid_file) |path| init.gpa.free(path);
    defer if (app_config.webhook_url) |url| init.gpa.free(url);
    defer if (app_config.smtp_server) |s| init.gpa.free(s);
    defer if (app_config.smtp_port) |p| init.gpa.free(p);
    defer if (app_config.smtp_user) |u| init.gpa.free(u);
    defer if (app_config.smtp_pass) |p| init.gpa.free(p);
    defer if (app_config.smtp_from) |f| init.gpa.free(f);
    defer if (app_config.smtp_to) |t| init.gpa.free(t);

    // ── Daemon 模式 ──────────────────────────────────────────────────────
    var io = init.io;
    if (app_config.daemon_mode and !app_config.foreground) {
        const result = try daemon.daemonize();
        switch (result) {
            .parent => {
                // 原始父进程退出，子进程（daemon）继续运行
                return;
            },
            .daemon => {
                // Grandchild (daemon): 重新安装信号处理器，获取新的 Io 实例
                installSignalHandlers();
                io = daemon.getIo();
                // 重新解析 HOME（daemon 环境可能不同）
                // 注意：config 已在父进程解析完毕，daemon 继承相同的配置
            },
        }
    }

    try runDemo(io, init.gpa, &app_config, cli_source, cli_cfg, home_dir);
}

/// Handle --resume command: restore network interface and reset quota state
fn handleResume(io: std.Io, allocator: Allocator, config: *AppConfig) !void {
    // Get current time for logging
    const now_ms = std.Io.Timestamp.now(io, .real).nanoseconds;
    const now_secs: u64 = @intCast(@divTrunc(now_ms, std.time.ns_per_s));

    try printOut(io, "\n============ 恢复网络配额 ============\n", .{});

    // Determine which interface to restore
    const iface = if (config.interface) |name|
        try allocator.dupe(u8, name)
    else
        traffic.findDefaultInterface(allocator, io) catch |err| {
            std.debug.print("错误: 未找到可用网卡 ({s})，请用 -i <name> 手动指定\n", .{@errorName(err)});
            return err;
        };
    defer allocator.free(iface);

    // Check current interface status
    const is_up = if (network.queryInterfaceStatus(iface)) |up| up else |_| false;

    if (is_up) {
        try printOut(io, "接口 {s} 已经是 UP 状态，无需恢复\n", .{iface});
    } else {
        // Restore interface
        network.restoreInterface(iface) catch |err| {
            std.debug.print("错误: 无法恢复接口 {s}: {s}\n", .{ iface, @errorName(err) });
            return err;
        };
        try printOut(io, "✓ 接口 {s} 已恢复 (UP)\n", .{iface});
    }

    // Reset quota state
    quota.resetQuotaState(allocator);
    try printOut(io, "✓ 配额状态已重置\n", .{});

    // Log the restore event
    var time_buf: [20]u8 = undefined;
    const timestamp = formatTimestampFull(&time_buf, now_secs);
    try printOut(io, "✓ 恢复操作完成于 {s}\n", .{timestamp});
    try printOut(io, "=========================================\n\n", .{});
}

/// 全局退出标志，由信号处理器置位
var should_exit: std.atomic.Value(bool) = .init(false);
/// 当前活跃的 PID 文件路径，信号处理器用此路径清理文件
var active_pid_path: ?[]const u8 = null;

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    // 清理 PID 文件
    if (active_pid_path) |path| {
        pidfile.removePidFile(path);
    }
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

fn runDemo(io: std.Io, allocator: Allocator, config: *AppConfig, cli_source: cfg.ConfigSource, cli_cfg: cfg.Config, home_dir: ?[]const u8) !void {
    // Handle --resume command first
    if (config.restore_network) {
        try handleResume(io, allocator, config);
        return;
    }

    // Check for auto-restore on startup (monthly reset day)
    const now_ms = std.Io.Timestamp.now(io, .real).nanoseconds;
    const now_secs: u64 = @intCast(@divTrunc(now_ms, std.time.ns_per_s));

    if (quota.shouldRestore(config.reset_day, now_secs)) {
        try printOut(io, "\n[自动恢复] 检测到今日是配额重置日 (第 {d} 天)\n", .{config.reset_day});
        try handleResume(io, allocator, config);
        return;
    }

    if (config.list_only) {
        try printInterfaceList(io, allocator);
        return;
    }

    if (config.day_count > 0) {
        try printDayStats(io, allocator, config.day_count, home_dir, config.use_sqlite);
        if (!config.interval_explicit) {
            return;
        }
    }

    if (config.interval_sec == 0) {
        std.debug.print("错误: 采样间隔必须大于 0 秒\n", .{});
        return error.InvalidInterval;
    }

    // 写入 PID 文件（防止重复启动）
    const pid_result = pidfile.writePidFile(allocator, config.pid_file);
    if (pid_result) |path| {
        active_pid_path = path;
    } else |err| {
        switch (err) {
            error.AlreadyRunning => {
                std.debug.print("错误: traffic-manager 已经在运行\n", .{});
                return err;
            },
            error.PermissionDenied => {
                std.debug.print("错误: 另一个实例正在运行（权限不足）\n", .{});
                return err;
            },
            else => {
                std.debug.print("警告: 无法写入 PID 文件 ({s})，继续运行\n", .{@errorName(err)});
                // Non-fatal: continue without PID file
            },
        }
    }
    defer {
        if (active_pid_path) |path| {
            pidfile.removePidFile(path);
            allocator.free(path);
        }
    }

    // HTTP 服务器依赖 SQLite（共享 zqlite 连接、读取配置/配额/历史数据），
    // 非 SQLite 模式请求 --web-port 时明确拒绝启动，避免静默不可用。
    if (config.web_port > 0 and !config.use_sqlite) {
        std.debug.print("错误: --web-port 需要 SQLite 存储模式（请加 --sqlite 选项）\n", .{});
        return error.WebRequiresSqlite;
    }

    if (config.use_sqlite) {
        // SQLite 存储模式
        const db_path = sqlite_storage.defaultDbPath(allocator, home_dir) catch |err| {
            std.debug.print("警告: 无法确定数据库路径 ({s})，回退到二进制存储\n", .{@errorName(err)});
            return runLiveMonitorFile(io, allocator, config.*, null);
        };
        defer allocator.free(db_path);

        var sqlite_stor = sqlite_storage.SQLiteStorage.open(allocator, io, db_path, home_dir, config.retention_days) catch |err| {
            std.debug.print("警告: 无法打开 SQLite 数据库 ({s})，回退到二进制存储\n", .{@errorName(err)});
            return runLiveMonitorFile(io, allocator, config.*, null);
        };
        defer {
            sqlite_stor.save() catch {};
            sqlite_stor.deinit();
        }

        // ── ConfigStore: 从 SQLite 加载配置 ──
        const store = config_store.ConfigStore.init(&sqlite_stor.conn, allocator);

        // 首次运行时自动迁移 JSON 配置到 SQLite
        store.migrateFromJson(io, home_dir);

        // 从 SQLite 加载配置，与 CLI 参数重新合并
        if (store.loadAll()) |db_config| {
            // 使用 SQLite 存储的配置作为基础，CLI 参数覆盖
            const remerged = cfg.mergeConfigs(db_config, cli_cfg, cli_source);
            // 更新 AppConfig 中非 CLI 指定的字段
            if (!cli_source.interval_sec) config.interval_sec = remerged.interval_sec;
            if (!cli_source.interface) config.interface = remerged.interface;
            if (!cli_source.daemon_mode) config.daemon_mode = remerged.daemon_mode;
            if (!cli_source.foreground) config.foreground = remerged.foreground;
            if (!cli_source.use_sqlite) config.use_sqlite = remerged.use_sqlite;
            if (!cli_source.retention_days) config.retention_days = remerged.retention_days;
            if (!cli_source.log_file) config.log_file = remerged.log_file;
            if (!cli_source.pid_file) config.pid_file = remerged.pid_file;
            if (!cli_source.list_only) config.list_only = remerged.list_only;
            if (!cli_source.day_count) config.day_count = remerged.day_count;
            if (!cli_source.quota_limit_bytes) config.quota_limit_bytes = remerged.quota_limit_bytes;
            if (!cli_source.quota_warning_threshold) config.quota_warning_threshold = remerged.quota_warning_threshold;
            if (!cli_source.quota_disconnect_threshold) config.quota_disconnect_threshold = remerged.quota_disconnect_threshold;
            if (!cli_source.reset_day) config.reset_day = remerged.reset_day;
            if (!cli_source.webhook_url) config.webhook_url = remerged.webhook_url;
            if (!cli_source.smtp_server) config.smtp_server = remerged.smtp_server;
            if (!cli_source.smtp_port) config.smtp_port = remerged.smtp_port;
            if (!cli_source.smtp_user) config.smtp_user = remerged.smtp_user;
            if (!cli_source.smtp_pass) config.smtp_pass = remerged.smtp_pass;
            if (!cli_source.smtp_from) config.smtp_from = remerged.smtp_from;
            if (!cli_source.smtp_to) config.smtp_to = remerged.smtp_to;
            if (!cli_source.restore_network) config.restore_network = remerged.restore_network;
            log.info("配置来源: SQLite", .{});
        } else |_| {
            log.info("配置来源: 默认值（SQLite 配置表为空）", .{});
        }

        // 处理 CLI 指定的临时配额调整（将每条记录写入预算周期调整表）
        if (config.quota_adjustments.len > 0) {
            // 用当前日期计算滚动预算周期（重置日语义），月份键取周期起始月
            const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = now_secs };
            const epoch_day = epoch_seconds.getEpochDay();
            const year_day = epoch_day.calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const period = quota.computePeriod(config.reset_day, year_day.year, month_day.month.numeric(), month_day.day_index + 1);

            var adj_buf: [16]u8 = undefined;
            const adj_month_key = periodMonthKey(&period, &adj_buf);
            if (adj_month_key) |month_key| {
                const created_at: i64 = @intCast(@divTrunc(now_ms, std.time.ns_per_ms));
                for (config.quota_adjustments) |adj| {
                    _ = quota.addAdjustment(allocator, &sqlite_stor.conn, adj.amount_bytes, adj.reason, "cli", month_key, created_at) catch |err| {
                        log.warn("添加配额调整失败: {s}", .{@errorName(err)});
                    };
                }
            } else {
                log.warn("月份键生成失败，跳过配额调整", .{});
            }

            // 释放配额调整参数占用的内存
            for (config.quota_adjustments) |adj| {
                if (adj.reason.len > 0) allocator.free(adj.reason);
            }
            allocator.free(config.quota_adjustments);
            config.quota_adjustments = &.{};
        }

        try runLiveMonitorSqlite(io, allocator, config.*, &sqlite_stor);
    } else {
        // 二进制文件存储模式
        // 配额调整仅支持 SQLite 模式，二进制模式下仅告警不报错
        if (config.quota_adjustments.len > 0) {
            // 前台无 --log-file 时 log.warn 静默，故额外用 stderr 打印可见警告
            std.debug.print("警告: --quota-adjust 仅在 SQLite 模式下生效，已忽略 {d} 条配额调整\n", .{config.quota_adjustments.len});
            log.warn("--quota-adjust 仅在 SQLite 模式下生效，已忽略 {d} 条配额调整", .{config.quota_adjustments.len});
            for (config.quota_adjustments) |adj| {
                if (adj.reason.len > 0) allocator.free(adj.reason);
            }
            allocator.free(config.quota_adjustments);
            config.quota_adjustments = &.{};
        }
        const state_path = storage.defaultStateFilePath(allocator, home_dir) catch |err| {
            std.debug.print("警告: 无法确定状态文件路径 ({s})，历史记录功能已禁用\n", .{@errorName(err)});
            return runLiveMonitorFile(io, allocator, config.*, null);
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

        try runLiveMonitorFile(io, allocator, config.*, &stor);
    }
}

/// 生成预算周期月份键（YYYY-MM），语义为周期起始月（见 quota.computePeriod）。
/// 返回 null 表示缓冲不足（正常 [16]u8 不会发生）。
fn periodMonthKey(period: *const quota.PeriodInfo, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}", .{ period.year, period.month }) catch null;
}

fn runLiveMonitorFile(io: std.Io, allocator: Allocator, config: AppConfig, stor: ?*storage.Storage) !void {
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

fn runLiveMonitorSqlite(io: std.Io, allocator: Allocator, config: AppConfig, stor: *sqlite_storage.SQLiteStorage) !void {
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

    // ── 配额状态跟踪 ──
    var prev_quota_state: quota.QuotaState = .disabled;
    var is_disconnected: bool = false;
    var last_quota_check_ms: i64 = 0;
    const quota_check_interval_ms: i64 = 60 * 1000; // 每分钟检查一次配额
    var rx_total_buf: [24]u8 = undefined;
    var tx_total_buf: [24]u8 = undefined;

    // 初始化全局日志（可选，失败时继续运行）
    if (config.log_file) |log_path| {
        log.initGlobal(allocator, io, log_path, .info_level) catch |err| {
            std.debug.print("警告: 无法初始化日志 ({s})，日志功能已禁用\n", .{@errorName(err)});
        };
    }
    defer log.deinitGlobal();

    // 配额信息输出
    try printOut(io, "\n============ Traffic Manager (SQLite) ============\n", .{});
    try printOut(io, "  网卡: {s}    采样间隔: {d} 秒    保留: {d} 天    按 Ctrl+C 退出\n", .{
        iface,
        config.interval_sec,
        config.retention_days,
    });
    if (config.quota_limit_bytes > 0) {
        try printOut(io, "  配额: {s}    警告: {d:.0}%    断网: {d:.0}%    重置日: 每月 {d} 日\n", .{
            formatBytes(&rx_total_buf, config.quota_limit_bytes, ""),
            config.quota_warning_threshold * 100,
            config.quota_disconnect_threshold * 100,
            config.reset_day,
        });
    }
    if (config.webhook_url) |url| {
        try printOut(io, "  Webhook: {s}\n", .{url});
    }
    if (config.smtp_server) |server| {
        try printOut(io, "  SMTP: {s}:{s}\n", .{ server, config.smtp_port orelse "25" });
    }
    try printOut(io, "--------------------------------------------------------------\n", .{});
    try printOut(io, "  时间          ↓ 下行速率      ↑ 上行速率      ↓ PPS    ↑ PPS    累计下行        累计上行\n", .{});
    try printOut(io, "--------------------------------------------------------------\n", .{});

    // ── 启动 HTTP 服务器（如果配置了端口） ──
    var app_state = http_server.AppState{};
    var http_thread: ?std.Thread = null;
    if (config.web_port > 0) {
        app_state.config = .{
            .interval_sec = config.interval_sec,
            .retention_days = config.retention_days,
            .quota_limit_bytes = config.quota_limit_bytes,
            .quota_warning_threshold = config.quota_warning_threshold,
            .quota_disconnect_threshold = config.quota_disconnect_threshold,
            .reset_day = config.reset_day,
        };
        app_state.iface = iface;
        app_state.start_time_secs = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));

        const ctx = http_server.HttpServerContext{
            .allocator = allocator,
            .state = &app_state,
            .conn = &stor.conn,
            .io = io,
            .port = config.web_port,
        };
        http_thread = http_server.startHttpServer(ctx) catch |err| blk: {
            std.debug.print("错误: HTTP 服务器启动失败（端口 {d} 可能被占用或不可用，错误: {s}），Web 仪表盘不可用\n", .{ config.web_port, @errorName(err) });
            break :blk null;
        };
        try printOut(io, "  HTTP 服务器: http://localhost:{d}/\n", .{config.web_port});
    }

    var time_buf: [16]u8 = undefined;
    var rx_speed_buf: [24]u8 = undefined;
    var tx_speed_buf: [24]u8 = undefined;

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

        // 更新今日流量（缓冲写入，每 5 分钟自动刷盘）
        const epoch_secs: u64 = @intCast(@divTrunc(stats.timestamp_ms, 1000));
        stor.update(stats, epoch_secs) catch |err| {
            std.debug.print("SQLite 写入失败: {s}\n", .{@errorName(err)});
        };

        // ── 配额检查（每分钟执行一次） ──
        if (config.quota_limit_bytes > 0 and stats.timestamp_ms - last_quota_check_ms >= quota_check_interval_ms) {
            last_quota_check_ms = stats.timestamp_ms;

            // 计算滚动预算周期：起始日与周期起始月（重置日语义，由 computePeriod 统一）
            const now_secs: u64 = @intCast(@divTrunc(stats.timestamp_ms, std.time.ns_per_s));
            const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = now_secs };
            const epoch_day = epoch_seconds.getEpochDay();
            const year_day = epoch_day.calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const period = quota.computePeriod(config.reset_day, year_day.year, month_day.month.numeric(), month_day.day_index + 1);

            // 生成周期月份键（YYYY-MM），用于查询预算周期内配额调整记录
            var month_key_buf: [16]u8 = undefined;
            const month_key = periodMonthKey(&period, &month_key_buf) orelse {
                log.warn("月份键生成失败", .{});
                continue;
            };

            // 查询预算周期内流量
            const monthly_traffic = quota.getMonthlyTraffic(&stor.conn, @intCast(period.start_epoch_day)) catch |err| {
                log.warn("配额查询失败: {s}", .{@errorName(err)});
                continue;
            };

            // 获取当月有效配额（基础配额 + 临时调整）
            const effective_quota = quota.getEffectiveMonthlyQuota(&stor.conn, config.quota_limit_bytes, month_key) catch |err| {
                log.warn("有效配额计算失败: {s}", .{@errorName(err)});
                continue;
            };
            // 临时调整总额 = 有效配额 - 基础配额（饱和减法，防止下溢）
            const adjustment_total = std.math.sub(u64, effective_quota, config.quota_limit_bytes) catch 0;

            // 检查配额状态
            const quota_config = quota.QuotaConfig{
                .limit_bytes = effective_quota,
                .warning_threshold = config.quota_warning_threshold,
                .disconnect_threshold = config.quota_disconnect_threshold,
                .reset_day = config.reset_day,
            };
            const current_state = quota.checkQuota(quota_config, monthly_traffic);

            // 检测状态转换并触发通知
            if (current_state != prev_quota_state) {
                // 状态发生变化，记录日志
                log.info("配额状态变化: {s} -> {s} (已用: {s}/{s})", .{
                    @tagName(prev_quota_state),
                    @tagName(current_state),
                    formatBytes(&rx_total_buf, monthly_traffic, ""),
                    formatBytes(&tx_total_buf, effective_quota, ""),
                });

                // 发送通知
                const base_quota = config.quota_limit_bytes;
                sendQuotaNotification(
                    allocator,
                    io,
                    config,
                    iface,
                    monthly_traffic,
                    effective_quota,
                    base_quota,
                    adjustment_total,
                    current_state,
                );

                // 处理断网/恢复
                if (current_state == .exceeded and !is_disconnected) {
                    // 超限，断开网络
                    network.disconnectInterface(iface) catch |err| {
                        log.err("断网失败: {s}", .{@errorName(err)});
                    };
                    is_disconnected = true;
                    log.info("已断开网络接口: {s}", .{iface});
                } else if (current_state == .normal and is_disconnected) {
                    // 恢复正常，恢复网络
                    network.restoreInterface(iface) catch |err| {
                        log.err("恢复网络失败: {s}", .{@errorName(err)});
                    };
                    is_disconnected = false;
                    log.info("已恢复网络接口: {s}", .{iface});
                }

                prev_quota_state = current_state;
            }
        }

        // 使用 clock_nanosleep（保证被信号中断，不会自动重启）
        const sleep_ns: u64 = config.interval_sec * std.time.ns_per_s;
        var req = std.os.linux.timespec{ .sec = @intCast(@divTrunc(sleep_ns, std.time.ns_per_s)), .nsec = @intCast(@mod(sleep_ns, std.time.ns_per_s)) };
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = false }, &req, &rem);
        // clock_nanosleep 返回 EINTR 时，循环顶部的 should_exit 检查会捕获退出信号
    }

    // 收到信号，保存剩余缓冲数据
    stor.save() catch |err| {
        std.debug.print("SQLite 保存失败: {s}\n", .{@errorName(err)});
    };

    // 如果网络被断开，尝试恢复
    if (is_disconnected) {
        network.restoreInterface(iface) catch {};
        log.info("程序退出，已恢复网络接口: {s}", .{iface});
    }
}

/// 发送配额通知（通过 Webhook 和/或 SMTP）
fn sendQuotaNotification(
    allocator: Allocator,
    io: std.Io,
    config: AppConfig,
    iface: []const u8,
    used_bytes: u64,
    effective_quota: u64,
    base_quota: u64,
    adjustment_total: u64,
    state: quota.QuotaState,
) void {
    const timestamp_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));

    // 构建模板变量
    const vars = notify_template.TemplateVariables{
        .interface = iface,
        .quota = effective_quota,
        .base_quota = base_quota,
        .adjustment_total = adjustment_total,
        .used = used_bytes,
        .percent = if (effective_quota > 0)
            @as(f64, @floatFromInt(used_bytes)) / @as(f64, @floatFromInt(effective_quota)) * 100.0
        else
            0.0,
        .timestamp_ms = timestamp_ms,
    };

    // 选择模板
    const template = switch (state) {
        .warned => notify_template.default_warning_template,
        .exceeded => notify_template.default_disconnect_template,
        else => return, // normal/disabled 状态不发送通知
    };

    // 渲染消息
    var msg_buf: [4096]u8 = undefined;
    const message = notify_template.render(allocator, template, vars, &msg_buf) catch |err| {
        log.err("模板渲染失败: {s}", .{@errorName(err)});
        return;
    };

    // 通过 Webhook 发送
    if (config.webhook_url) |url| {
        var notifier = webhook.WebhookNotifier.init(allocator, io, url);
        const result = notifier.sendTrafficAlert(
            iface,
            used_bytes,
            0, // tx_bytes (我们使用总流量)
            effective_quota,
        ) catch |err| {
            log.err("Webhook 通知失败: {s}", .{@errorName(err)});
            return;
        };
        if (result.success) {
            log.info("Webhook 通知已发送", .{});
        } else {
            log.warn("Webhook 通知失败 (HTTP {d})", .{result.status});
        }
    }

    // 通过 SMTP 发送（如果配置了）
    if (config.smtp_server) |server| {
        // 检查必要的 SMTP 配置
        const from_addr = config.smtp_from orelse {
            log.warn("SMTP: 缺少发件人地址 (--smtp-from)，跳过 SMTP 通知", .{});
            return;
        };
        const to_addr = config.smtp_to orelse {
            log.warn("SMTP: 缺少收件人地址 (--smtp-to)，跳过 SMTP 通知", .{});
            return;
        };

        // 分配以零结尾的字符串副本（C API 需要）
        const zt_server = allocator.dupeZ(u8, server) catch {
            log.err("SMTP: 内存分配失败", .{});
            return;
        };
        defer allocator.free(zt_server);

        const port_str = config.smtp_port orelse "25";
        const zt_port = allocator.dupeZ(u8, port_str) catch {
            log.err("SMTP: 内存分配失败", .{});
            return;
        };
        defer allocator.free(zt_port);

        // 根据端口确定安全模式
        const security: smtp.Security = if (std.mem.eql(u8, port_str, "465"))
            .tls
        else if (std.mem.eql(u8, port_str, "587"))
            .starttls
        else
            .none;

        // 根据用户名确定认证方式
        const auth_method: smtp.AuthMethod = if (config.smtp_user != null)
            .plain
        else
            .none;

        // 准备认证凭据
        var zt_user: ?[:0]const u8 = null;
        var zt_pass: ?[:0]const u8 = null;
        defer {
            if (zt_user) |u| allocator.free(u);
            if (zt_pass) |p| allocator.free(p);
        }
        if (config.smtp_user) |user| {
            zt_user = allocator.dupeZ(u8, user) catch {
                log.err("SMTP: 内存分配失败", .{});
                return;
            };
        }
        if (config.smtp_pass) |pass| {
            zt_pass = allocator.dupeZ(u8, pass) catch {
                log.err("SMTP: 内存分配失败", .{});
                return;
            };
        }

        const zt_from = allocator.dupeZ(u8, from_addr) catch {
            log.err("SMTP: 内存分配失败", .{});
            return;
        };
        defer allocator.free(zt_from);

        const zt_to = allocator.dupeZ(u8, to_addr) catch {
            log.err("SMTP: 内存分配失败", .{});
            return;
        };
        defer allocator.free(zt_to);

        // 根据状态生成邮件主题
        const subject_str = switch (state) {
            .warned => "Traffic Manager: 配额警告",
            .exceeded => "Traffic Manager: 配额超限 - 已断网",
            else => "Traffic Manager: 通知",
        };
        const zt_subject = allocator.dupeZ(u8, subject_str) catch {
            log.err("SMTP: 内存分配失败", .{});
            return;
        };
        defer allocator.free(zt_subject);

        // 使用渲染后的消息作为邮件正文
        const zt_body = allocator.dupeZ(u8, message) catch {
            log.err("SMTP: 内存分配失败", .{});
            return;
        };
        defer allocator.free(zt_body);

        // 发送邮件
        smtp.sendEmail(
            allocator,
            zt_server,
            zt_port,
            security,
            auth_method,
            zt_user orelse "",
            zt_pass orelse "",
            zt_from,
            zt_to,
            zt_subject,
            zt_body,
        ) catch |err| {
            log.err("SMTP 通知发送失败: {s}", .{@errorName(err)});
            return;
        };

        log.info("SMTP 通知已发送至 {s}", .{to_addr});
    }

    // 记录到日志文件
    var rx_buf: [24]u8 = undefined;
    var tx_buf: [24]u8 = undefined;
    log.info("[配额] {s}: {s} (已用: {s}/{s})", .{
        @tagName(state),
        iface,
        formatBytes(&rx_buf, used_bytes, ""),
        formatBytes(&tx_buf, effective_quota, ""),
    });
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

fn printDayStats(io: std.Io, allocator: Allocator, day_count: u32, home_dir: ?[]const u8, use_sqlite: bool) !void {
    if (use_sqlite) {
        // SQLite 模式
        const db_path = sqlite_storage.defaultDbPath(allocator, home_dir) catch {
            std.debug.print("错误: 无法确定数据库路径\n", .{});
            return;
        };
        defer allocator.free(db_path);

        var sqlite_stor = sqlite_storage.SQLiteStorage.open(allocator, io, db_path, home_dir, 0) catch |err| {
            std.debug.print("错误: 无法打开 SQLite 数据库: {s}\n", .{@errorName(err)});
            return;
        };
        defer sqlite_stor.deinit();

        const days = sqlite_stor.getLastDays(day_count) catch |err| {
            std.debug.print("错误: 查询历史记录失败: {s}\n", .{@errorName(err)});
            return;
        };
        defer allocator.free(days);

        if (days.len == 0) {
            try printOut(io, "\n暂无历史流量记录。请先运行一段时间后再查询。\n", .{});
            return;
        }

        const show_detail = @min(days.len, 3);

        try printOut(io, "\n============ 最近 {d} 天流量统计 (SQLite) ============\n", .{day_count});
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
    } else {
        // 二进制文件模式
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

/// 将秒时间戳格式化为 YYYY-MM-DD HH:MM:SS
fn formatTimestampFull(buf: []u8, timestamp_secs: u64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = timestamp_secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "0000-00-00 00:00:00";
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
    std.testing.refAllDecls(sqlite_storage);
    std.testing.refAllDecls(pidfile);
    std.testing.refAllDecls(daemon);
    std.testing.refAllDecls(log);
    std.testing.refAllDecls(webhook);
    std.testing.refAllDecls(cfg);
    std.testing.refAllDecls(quota);
    std.testing.refAllDecls(http_server);
}
