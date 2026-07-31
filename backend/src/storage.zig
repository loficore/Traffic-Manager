// backend/src/storage.zig
// 持久化存储层：将每日流量快照保存到本地文件，支持历史查询。
//
// 文件格式：二进制序列化的 DailyRecord 数组，位于 $HOME/.local/share/traffic-manager/state.bin
// 文件结构：[record_0][record_1]...[record_N]，每条记录 40 字节，按日期降序排列。
const std = @import("std");
const traffic = @import("traffic.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const StorageError = error{
    FileAccessFailed,
    DirCreationFailed,
    OutOfMemory,
};

/// 单日流量快照（40 字节，对齐友好）
pub const DailyRecord = extern struct {
    date: u32, // days since epoch (0 = 1970-01-01)
    total_rx_bytes: u64, // 当日累计下行字节
    total_tx_bytes: u64, // 当日累计上行字节
    total_rx_packets: u64, // 当日累计下行包数
    total_tx_packets: u64, // 当日累计上行包数

    pub fn eql(a: DailyRecord, b: DailyRecord) bool {
        return a.date == b.date;
    }
};

/// 本地历史存储管理器
pub const Storage = struct {
    history: std.ArrayList(DailyRecord),
    file_path: []const u8,
    allocator: Allocator,
    io: Io,

    /// 初始化存储管理器，尝试从文件加载已有历史。
    /// file_path 由调用方分配，生命周期应覆盖 Storage 整个使用期。
    pub fn init(allocator: Allocator, io: Io, file_path: []const u8) Storage {
        return .{
            .history = .empty,
            .file_path = file_path,
            .allocator = allocator,
            .io = io,
        };
    }

    /// 加载历史记录。文件不存在时不报错（首次运行正常）。
    pub fn load(self: *Storage) StorageError!void {
        const file = std.Io.Dir.openFileAbsolute(self.io, self.file_path, .{
            .mode = .read_only,
        }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return StorageError.FileAccessFailed,
        };
        defer file.close(self.io);

        var buf: [8192]u8 = undefined;
        const bytes_read = file.readPositionalAll(self.io, &buf, 0) catch
            return StorageError.FileAccessFailed;
        const content = buf[0..bytes_read];

        if (content.len % @sizeOf(DailyRecord) != 0) return;

        const record_count = content.len / @sizeOf(DailyRecord);
        for (0..record_count) |i| {
            const start = i * @sizeOf(DailyRecord);
            const record: DailyRecord = @bitCast(content[start..][0..@sizeOf(DailyRecord)].*);
            self.history.append(self.allocator, record) catch return StorageError.OutOfMemory;
        }
    }

    /// 更新今日流量数据。按日期聚合：同一天累加，新一天插入。
    /// today_epoch_secs 为当前 Unix 时间戳（秒），用于计算日期。
    pub fn update(self: *Storage, stats: traffic.TrafficStatistics, today_epoch_secs: u64) StorageError!void {
        const es = std.time.epoch.EpochSeconds{ .secs = today_epoch_secs };
        const day = es.getEpochDay();
        const today_date: u32 = @intCast(day.day);

        // 在历史中查找今日记录
        for (self.history.items) |*record| {
            if (record.date == today_date) {
                // 用最新的 raw 值作为当日累计（假设当天内 raw 是单调递增的）
                record.total_rx_bytes = stats.raw_rx_bytes;
                record.total_tx_bytes = stats.raw_tx_bytes;
                record.total_rx_packets = stats.raw_rx_packets;
                record.total_tx_packets = stats.raw_tx_packets;
                return;
            }
        }

        // 新的一天，追加记录
        self.history.append(self.allocator, .{
            .date = today_date,
            .total_rx_bytes = stats.raw_rx_bytes,
            .total_tx_bytes = stats.raw_tx_bytes,
            .total_rx_packets = stats.raw_rx_packets,
            .total_tx_packets = stats.raw_tx_packets,
        }) catch return StorageError.OutOfMemory;
    }

    /// 将历史记录持久化到文件。若历史为空则删除文件。
    pub fn save(self: *Storage) StorageError!void {
        // 确保目录存在
        if (std.fs.path.dirname(self.file_path)) |dir| {
            std.Io.Dir.createDirAbsolute(self.io, dir, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return StorageError.DirCreationFailed,
            };
        }

        if (self.history.items.len == 0) {
            // 历史为空，删除文件
            std.Io.Dir.deleteFileAbsolute(self.io, self.file_path) catch {};
            return;
        }

        const file = std.Io.Dir.createFileAbsolute(self.io, self.file_path, .{
            .truncate = true,
        }) catch return StorageError.FileAccessFailed;
        defer file.close(self.io);

        // 按日期降序排列后写入（最新在前）
        std.mem.sort(DailyRecord, self.history.items, {}, struct {
            fn lessThan(_: void, a: DailyRecord, b: DailyRecord) bool {
                return a.date > b.date;
            }
        }.lessThan);

        const bytes: []const u8 = std.mem.sliceAsBytes(self.history.items);
        file.writeStreamingAll(self.io, bytes) catch return StorageError.FileAccessFailed;
    }

    /// 获取最近 N 天的记录（按日期降序），最多返回实际存在的条数。
    pub fn getLastDays(self: *const Storage, n: usize) []const DailyRecord {
        return self.history.items[0..@min(n, self.history.items.len)];
    }

    pub fn deinit(self: *Storage) void {
        self.history.deinit(self.allocator);
    }
};

/// 默认状态文件路径：$HOME/.local/share/traffic-manager/state.bin
/// home_dir 为 null 时使用 /tmp 作为 fallback。
/// 返回值由 allocator 分配，调用方负责释放。
pub fn defaultStateFilePath(allocator: Allocator, home_dir: ?[]const u8) ![]const u8 {
    const home = home_dir orelse "/tmp";
    return std.fmt.allocPrint(allocator, "{s}/.local/share/traffic-manager/state.bin", .{home});
}

test "DailyRecord size is 40 bytes" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(DailyRecord));
}
