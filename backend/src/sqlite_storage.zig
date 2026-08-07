// backend/src/sqlite_storage.zig
// SQLite storage with data retention: daily_traffic (kept) + samples (auto-cleaned).
const std = @import("std");
const zqlite = @import("zqlite");
const storage = @import("storage.zig");
const traffic = @import("traffic.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const SQLiteError = error{
    DatabaseOpenFailed,
    DatabaseInitFailed,
    DatabaseCorrupt,
    DatabaseRebuildFailed,
    QueryFailed,
    InsertFailed,
    TransactionFailed,
    OutOfMemory,
};

pub const Sample = struct {
    timestamp_ms: i64,
    interface: []const u8,
    rx_bytes: u64,
    tx_bytes: u64,
    rx_packets: u64,
    tx_packets: u64,
    rx_speed_bps: u64,
    tx_speed_bps: u64,
};

pub const SQLiteStorage = struct {
    conn: zqlite.Conn,
    allocator: Allocator,
    io: Io,
    sample_buffer: std.ArrayList(Sample),
    pending: std.ArrayList(storage.DailyRecord),
    last_flush_ms: i64,
    db_path: []const u8,
    retention_days: u32,

    pub const FLUSH_INTERVAL_MS: i64 = 5 * 60 * 1000;

    const SCHEMA =
        \\CREATE TABLE IF NOT EXISTS daily_traffic (
        \\    date INTEGER PRIMARY KEY,
        \\    total_rx_bytes INTEGER NOT NULL DEFAULT 0,
        \\    total_tx_bytes INTEGER NOT NULL DEFAULT 0,
        \\    total_rx_packets INTEGER NOT NULL DEFAULT 0,
        \\    total_tx_packets INTEGER NOT NULL DEFAULT 0
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS samples (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    timestamp_ms INTEGER NOT NULL,
        \\    interface TEXT NOT NULL,
        \\    rx_bytes INTEGER NOT NULL DEFAULT 0,
        \\    tx_bytes INTEGER NOT NULL DEFAULT 0,
        \\    rx_packets INTEGER NOT NULL DEFAULT 0,
        \\    tx_packets INTEGER NOT NULL DEFAULT 0,
        \\    rx_speed_bps INTEGER NOT NULL DEFAULT 0,
        \\    tx_speed_bps INTEGER NOT NULL DEFAULT 0
        \\);
    ;

    pub fn open(allocator: Allocator, io: Io, db_path: []const u8, home_dir: ?[]const u8, retention_days: u32) SQLiteError!SQLiteStorage {
        if (std.fs.path.dirname(db_path)) |dir| {
            Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return SQLiteError.DatabaseInitFailed,
            };
        }

        const db_path_z = allocator.dupeZ(u8, db_path) catch return SQLiteError.OutOfMemory;
        defer allocator.free(db_path_z);

        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode;
        var conn = zqlite.open(db_path_z, flags) catch return SQLiteError.DatabaseOpenFailed;

        conn.busyTimeout(10000) catch {};

        const is_corrupt = checkIntegrity(&conn);
        if (is_corrupt) {
            // Close the corrupt connection BEFORE reopening — no errdefer here
            // to avoid double-close when the reopen itself fails.
            conn.close();
            std.debug.print("警告: SQLite 数据库损坏，正在重建...\n", .{});
            cleanupDbFiles(io, db_path);
            conn = zqlite.open(db_path_z, flags) catch return SQLiteError.DatabaseRebuildFailed;
            conn.busyTimeout(10000) catch {};
            try initSchema(&conn);
            try migrateFromBinary(&conn, allocator, io, home_dir);
        } else {
            try initSchema(&conn);
        }

        // errdefer placed AFTER corruption recovery so it only covers the final
        // connection — avoids double-close when the old conn was already closed
        // during corruption recovery and the reopen fails.
        errdefer conn.close();

        return .{
            .conn = conn,
            .allocator = allocator,
            .io = io,
            .sample_buffer = .empty,
            .pending = .empty,
            .last_flush_ms = 0,
            .db_path = db_path,
            .retention_days = retention_days,
        };
    }

    fn initSchema(conn: *zqlite.Conn) SQLiteError!void {
        conn.execNoArgs("PRAGMA journal_mode=WAL") catch {};
        conn.execNoArgs("PRAGMA synchronous=NORMAL") catch {};
        conn.execNoArgs(SCHEMA) catch return SQLiteError.DatabaseInitFailed;
    }

    fn checkIntegrity(conn: *zqlite.Conn) bool {
        var rows = conn.rows("PRAGMA integrity_check", .{}) catch return true;
        defer rows.deinit();
        while (rows.next()) |row| {
            const result = row.text(0);
            if (std.mem.eql(u8, result, "ok")) return false;
            return true;
        }
        return true;
    }

    fn cleanupDbFiles(io: Io, db_path: []const u8) void {
        Io.Dir.deleteFileAbsolute(io, db_path) catch {};
        var buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}-wal", .{db_path})) |wal| {
            Io.Dir.deleteFileAbsolute(io, wal) catch {};
        } else |_| {}
        if (std.fmt.bufPrint(&buf, "{s}-shm", .{db_path})) |shm| {
            Io.Dir.deleteFileAbsolute(io, shm) catch {};
        } else |_| {}
    }

    fn migrateFromBinary(conn: *zqlite.Conn, allocator: Allocator, io: Io, home_dir: ?[]const u8) SQLiteError!void {
        const bin_path = storage.defaultStateFilePath(allocator, home_dir) catch return;
        defer allocator.free(bin_path);
        var bin_storage = storage.Storage.init(allocator, io, bin_path);
        bin_storage.load() catch return;
        defer bin_storage.deinit();
        if (bin_storage.history.items.len == 0) return;
        conn.transaction() catch return SQLiteError.DatabaseRebuildFailed;
        errdefer conn.rollback();
        for (bin_storage.history.items) |record| {
            conn.exec(
                \\INSERT OR REPLACE INTO daily_traffic (date, total_rx_bytes, total_tx_bytes, total_rx_packets, total_tx_packets)
                \\VALUES (?1, ?2, ?3, ?4, ?5)
            , .{
                @as(i64, @intCast(record.date)),
                @as(i64, @bitCast(record.total_rx_bytes)),
                @as(i64, @bitCast(record.total_tx_bytes)),
                @as(i64, @bitCast(record.total_rx_packets)),
                @as(i64, @bitCast(record.total_tx_packets)),
            }) catch return SQLiteError.DatabaseRebuildFailed;
        }
        conn.commit() catch return SQLiteError.DatabaseRebuildFailed;
    }

    pub fn insertSample(self: *SQLiteStorage, stats: traffic.TrafficStatistics, iface: []const u8) SQLiteError!void {
        self.sample_buffer.append(self.allocator, .{
            .timestamp_ms = stats.timestamp_ms,
            .interface = iface,
            .rx_bytes = stats.raw_rx_bytes,
            .tx_bytes = stats.raw_tx_bytes,
            .rx_packets = stats.raw_rx_packets,
            .tx_packets = stats.raw_tx_packets,
            .rx_speed_bps = stats.rx_speed_bps,
            .tx_speed_bps = stats.tx_speed_bps,
        }) catch return SQLiteError.OutOfMemory;
    }

    pub fn update(self: *SQLiteStorage, stats: traffic.TrafficStatistics, today_epoch_secs: u64) SQLiteError!void {
        const es = std.time.epoch.EpochSeconds{ .secs = today_epoch_secs };
        const day = es.getEpochDay();
        const today_date: u32 = @intCast(day.day);

        for (self.pending.items) |*record| {
            if (record.date == today_date) {
                record.total_rx_bytes = stats.raw_rx_bytes;
                record.total_tx_bytes = stats.raw_tx_bytes;
                record.total_rx_packets = stats.raw_rx_packets;
                record.total_tx_packets = stats.raw_tx_packets;
                try self.autoFlush(stats.timestamp_ms);
                return;
            }
        }

        self.pending.append(self.allocator, .{
            .date = today_date,
            .total_rx_bytes = stats.raw_rx_bytes,
            .total_tx_bytes = stats.raw_tx_bytes,
            .total_rx_packets = stats.raw_rx_packets,
            .total_tx_packets = stats.raw_tx_packets,
        }) catch return SQLiteError.OutOfMemory;

        try self.autoFlush(stats.timestamp_ms);
    }

    fn autoFlush(self: *SQLiteStorage, current_ms: i64) SQLiteError!void {
        if (self.last_flush_ms == 0 or (current_ms - self.last_flush_ms) >= FLUSH_INTERVAL_MS) {
            try self.flush();
            self.last_flush_ms = current_ms;
        }
    }

    pub fn flush(self: *SQLiteStorage) SQLiteError!void {
        if (self.pending.items.len > 0) {
            self.conn.transaction() catch return SQLiteError.InsertFailed;
            errdefer self.conn.rollback();
            for (self.pending.items) |record| {
                self.conn.exec(
                    \\INSERT OR REPLACE INTO daily_traffic (date, total_rx_bytes, total_tx_bytes, total_rx_packets, total_tx_packets)
                    \\VALUES (?1, ?2, ?3, ?4, ?5)
                , .{
                    @as(i64, @intCast(record.date)),
                    @as(i64, @bitCast(record.total_rx_bytes)),
                    @as(i64, @bitCast(record.total_tx_bytes)),
                    @as(i64, @bitCast(record.total_rx_packets)),
                    @as(i64, @bitCast(record.total_tx_packets)),
                }) catch return SQLiteError.InsertFailed;
            }
            self.conn.commit() catch return SQLiteError.InsertFailed;
            self.pending.clearRetainingCapacity();
        }

        if (self.sample_buffer.items.len > 0) {
            self.conn.transaction() catch return SQLiteError.InsertFailed;
            errdefer self.conn.rollback();
            for (self.sample_buffer.items) |sample| {
                self.conn.exec(
                    \\INSERT INTO samples (timestamp_ms, interface, rx_bytes, tx_bytes, rx_packets, tx_packets, rx_speed_bps, tx_speed_bps)
                    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                , .{
                    sample.timestamp_ms,
                    sample.interface,
                    @as(i64, @intCast(sample.rx_bytes)),
                    @as(i64, @intCast(sample.tx_bytes)),
                    @as(i64, @intCast(sample.rx_packets)),
                    @as(i64, @intCast(sample.tx_packets)),
                    @as(i64, @intCast(sample.rx_speed_bps)),
                    @as(i64, @intCast(sample.tx_speed_bps)),
                }) catch return SQLiteError.InsertFailed;
            }
            self.conn.commit() catch return SQLiteError.InsertFailed;
            self.sample_buffer.clearRetainingCapacity();
        }

        if (self.retention_days > 0) {
            try self.cleanupSamples();
        }
    }

    fn cleanupSamples(self: *SQLiteStorage) SQLiteError!void {
        const now_ms = Io.Timestamp.now(self.io, .real).nanoseconds;
        const now_secs: u64 = @intCast(@divTrunc(now_ms, std.time.ns_per_s));
        const es = std.time.epoch.EpochSeconds{ .secs = now_secs };
        const day = es.getEpochDay();
        const today_date: i64 = @intCast(day.day);
        const cutoff_date: i64 = today_date - @as(i64, @intCast(self.retention_days));
        self.conn.exec(
            \\DELETE FROM samples WHERE CAST((timestamp_ms / 86400000) AS INTEGER) < ?1
        , .{cutoff_date}) catch return SQLiteError.QueryFailed;
    }

    pub fn runRetentionCleanup(self: *SQLiteStorage) SQLiteError!void {
        if (self.retention_days == 0) return;
        self.conn.transaction() catch return SQLiteError.TransactionFailed;
        errdefer self.conn.rollback();
        try self.cleanupSamples();
        self.conn.commit() catch return SQLiteError.TransactionFailed;
    }

    pub fn save(self: *SQLiteStorage) SQLiteError!void {
        try self.flush();
    }

    pub fn getLastDays(self: *SQLiteStorage, n: u32) SQLiteError![]storage.DailyRecord {
        var result_list: std.ArrayList(storage.DailyRecord) = .empty;
        errdefer result_list.deinit(self.allocator);
        var rows = self.conn.rows(
            "SELECT date, total_rx_bytes, total_tx_bytes, total_rx_packets, total_tx_packets FROM daily_traffic ORDER BY date DESC LIMIT ?1",
            .{@as(i64, @intCast(n))},
        ) catch return SQLiteError.QueryFailed;
        defer rows.deinit();
        while (rows.next()) |row| {
            result_list.append(self.allocator, .{
                .date = @intCast(row.int(0)),
                .total_rx_bytes = @bitCast(row.int(1)),
                .total_tx_bytes = @bitCast(row.int(2)),
                .total_rx_packets = @bitCast(row.int(3)),
                .total_tx_packets = @bitCast(row.int(4)),
            }) catch return SQLiteError.OutOfMemory;
        }
        if (rows.err) |_| return SQLiteError.QueryFailed;
        return result_list.toOwnedSlice(self.allocator) catch return SQLiteError.OutOfMemory;
    }

    pub fn dailyTrafficCount(self: *SQLiteStorage) anyerror!u64 {
        if (try self.conn.row("SELECT COUNT(*) FROM daily_traffic", .{})) |row| {
            defer row.deinit();
            return @intCast(row.int(0));
        }
        return 0;
    }

    pub fn sampleCount(self: *SQLiteStorage) anyerror!u64 {
        if (try self.conn.row("SELECT COUNT(*) FROM samples", .{})) |row| {
            defer row.deinit();
            return @intCast(row.int(0));
        }
        return 0;
    }

    pub fn deinit(self: *SQLiteStorage) void {
        self.sample_buffer.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.conn.close();
    }
};

pub fn defaultDbPath(allocator: Allocator, home_dir: ?[]const u8) ![]const u8 {
    const home = home_dir orelse "/tmp";
    return std.fmt.allocPrint(allocator, "{s}/.local/share/traffic-manager/traffic.db", .{home});
}

test "defaultDbPath with home" {
    const path = try defaultDbPath(std.testing.allocator, "/home/user");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/.local/share/traffic-manager/traffic.db", path);
}

test "defaultDbPath without home" {
    const path = try defaultDbPath(std.testing.allocator, null);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/.local/share/traffic-manager/traffic.db", path);
}

test "SQLiteStorage open, insert, query cycle" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const db_path = "/tmp/zqlite_test_cycle.db";
    defer Io.Dir.deleteFileAbsolute(io, db_path) catch {};
    defer Io.Dir.deleteFileAbsolute(io, db_path ++ "-wal") catch {};
    defer Io.Dir.deleteFileAbsolute(io, db_path ++ "-shm") catch {};

    var stor = try SQLiteStorage.open(allocator, io, db_path, null, 30);
    defer stor.deinit();

    try stor.conn.exec(
        "INSERT INTO daily_traffic (date, total_rx_bytes, total_tx_bytes, total_rx_packets, total_tx_packets) VALUES (100, 1000, 500, 10, 5)",
        .{},
    );
    try stor.conn.exec(
        "INSERT INTO daily_traffic (date, total_rx_bytes, total_tx_bytes, total_rx_packets, total_tx_packets) VALUES (200, 2000, 1000, 20, 10)",
        .{},
    );

    const days = try stor.getLastDays(5);
    defer allocator.free(days);
    try std.testing.expectEqual(@as(usize, 2), days.len);
    try std.testing.expectEqual(@as(u32, 200), days[0].date);
    try std.testing.expectEqual(@as(u32, 100), days[1].date);
}

test "SQLiteStorage buffered flush writes to db" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const db_path = "/tmp/zqlite_test_flush.db";
    defer Io.Dir.deleteFileAbsolute(io, db_path) catch {};
    defer Io.Dir.deleteFileAbsolute(io, db_path ++ "-wal") catch {};
    defer Io.Dir.deleteFileAbsolute(io, db_path ++ "-shm") catch {};

    var stor = try SQLiteStorage.open(allocator, io, db_path, null, 30);
    defer stor.deinit();

    const now_ns = Io.Timestamp.now(io, .real).nanoseconds;
    const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
    const stats = traffic.TrafficStatistics{
        .raw_rx_bytes = 4096,
        .raw_tx_bytes = 2048,
        .raw_rx_packets = 40,
        .raw_tx_packets = 20,
        .timestamp_ms = now_ms,
    };
    const epoch_secs: u64 = @intCast(@divTrunc(now_ms, 1000));
    try stor.update(stats, epoch_secs);

    try std.testing.expectEqual(@as(usize, 0), stor.pending.items.len);

    const days = try stor.getLastDays(1);
    defer allocator.free(days);
    try std.testing.expectEqual(@as(usize, 1), days.len);
    try std.testing.expectEqual(@as(u64, 4096), days[0].total_rx_bytes);
}

test "SQLiteStorage retention cleanup deletes old samples" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const db_path = "/tmp/zqlite_test_retention.db";
    defer Io.Dir.deleteFileAbsolute(io, db_path) catch {};
    defer Io.Dir.deleteFileAbsolute(io, db_path ++ "-wal") catch {};
    defer Io.Dir.deleteFileAbsolute(io, db_path ++ "-shm") catch {};

    var stor = try SQLiteStorage.open(allocator, io, db_path, null, 7);
    defer stor.deinit();

    const now_ns = Io.Timestamp.now(io, .real).nanoseconds;
    const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
    const eight_days_ms: i64 = 8 * 24 * 60 * 60 * 1000;

    try stor.conn.exec(
        \\INSERT INTO samples (timestamp_ms, interface, rx_bytes, tx_bytes, rx_packets, tx_packets, rx_speed_bps, tx_speed_bps)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    , .{
        now_ms - eight_days_ms, "eth0",
        @as(i64, 100), @as(i64, 50), @as(i64, 10), @as(i64, 5), @as(i64, 100), @as(i64, 50),
    });

    try stor.conn.exec(
        \\INSERT INTO samples (timestamp_ms, interface, rx_bytes, tx_bytes, rx_packets, tx_packets, rx_speed_bps, tx_speed_bps)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    , .{
        now_ms, "eth0",
        @as(i64, 200), @as(i64, 100), @as(i64, 20), @as(i64, 10), @as(i64, 200), @as(i64, 100),
    });

    const before_count = try stor.sampleCount();
    try std.testing.expectEqual(@as(u64, 2), before_count);

    try stor.runRetentionCleanup();

    const after_count = try stor.sampleCount();
    try std.testing.expectEqual(@as(u64, 1), after_count);
}

test "SQLiteStorage retention_days=0 disables cleanup" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const db_path = "/tmp/zqlite_test_noretention.db";
    defer Io.Dir.deleteFileAbsolute(io, db_path) catch {};
    defer Io.Dir.deleteFileAbsolute(io, db_path ++ "-wal") catch {};
    defer Io.Dir.deleteFileAbsolute(io, db_path ++ "-shm") catch {};

    var stor = try SQLiteStorage.open(allocator, io, db_path, null, 0);
    defer stor.deinit();

    const now_ns = Io.Timestamp.now(io, .real).nanoseconds;
    const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
    const eight_days_ms: i64 = 8 * 24 * 60 * 60 * 1000;

    try stor.conn.exec(
        \\INSERT INTO samples (timestamp_ms, interface, rx_bytes, tx_bytes, rx_packets, tx_packets, rx_speed_bps, tx_speed_bps)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    , .{
        now_ms - eight_days_ms, "eth0",
        @as(i64, 100), @as(i64, 50), @as(i64, 10), @as(i64, 5), @as(i64, 100), @as(i64, 50),
    });

    try stor.runRetentionCleanup();

    const count = try stor.sampleCount();
    try std.testing.expectEqual(@as(u64, 1), count);
}

test "SQLiteStorage daily_traffic preserved during retention cleanup" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const db_path = "/tmp/zqlite_test_daily_preserve.db";
    defer Io.Dir.deleteFileAbsolute(io, db_path) catch {};
    defer Io.Dir.deleteFileAbsolute(io, db_path ++ "-wal") catch {};
    defer Io.Dir.deleteFileAbsolute(io, db_path ++ "-shm") catch {};

    var stor = try SQLiteStorage.open(allocator, io, db_path, null, 7);
    defer stor.deinit();

    try stor.conn.exec(
        "INSERT INTO daily_traffic (date, total_rx_bytes, total_tx_bytes, total_rx_packets, total_tx_packets) VALUES (100, 5000, 2500, 50, 25)",
        .{},
    );

    const now_ns = Io.Timestamp.now(io, .real).nanoseconds;
    const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
    const eight_days_ms: i64 = 8 * 24 * 60 * 60 * 1000;

    try stor.conn.exec(
        \\INSERT INTO samples (timestamp_ms, interface, rx_bytes, tx_bytes, rx_packets, tx_packets, rx_speed_bps, tx_speed_bps)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    , .{
        now_ms - eight_days_ms, "eth0",
        @as(i64, 100), @as(i64, 50), @as(i64, 10), @as(i64, 5), @as(i64, 100), @as(i64, 50),
    });

    try stor.runRetentionCleanup();

    const sample_count = try stor.sampleCount();
    try std.testing.expectEqual(@as(u64, 0), sample_count);

    const daily_count = try stor.dailyTrafficCount();
    try std.testing.expectEqual(@as(u64, 1), daily_count);
}
