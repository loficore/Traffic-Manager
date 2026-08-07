// backend/src/sqlite_schema.zig
// SQLite schema definitions and initialization for traffic data storage.
//
// Tables:
//   - samples: per-second traffic samples with speed metrics
//   - daily_summary: aggregated daily totals per interface
//
// Uses karlseguin/zqlite.zig for SQLite access with WAL mode for
// concurrent read/write performance on embedded Linux.

const std = @import("std");
const zqlite = @import("zqlite");

pub const SchemaError = error{
    DatabaseOpenFailed,
    SchemaCreationFailed,
    AggregationFailed,
};

/// Initialize the SQLite database with schema and pragmas.
/// Opens the database at `db_path`, creates tables if they don't exist,
/// and configures WAL mode for better concurrent performance.
pub fn initSchema(db_path: [*:0]const u8) SchemaError!zqlite.Conn {
    const conn = zqlite.open(db_path, zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite) catch
        return SchemaError.DatabaseOpenFailed;

    // Enable WAL mode for better concurrent read/write performance
    conn.execNoArgs("PRAGMA journal_mode=WAL") catch
        return SchemaError.SchemaCreationFailed;

    // Use NORMAL synchronous for better write performance (safe with WAL)
    conn.execNoArgs("PRAGMA synchronous=NORMAL") catch
        return SchemaError.SchemaCreationFailed;

    // Create samples table for per-second traffic data
    conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS samples (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    timestamp INTEGER NOT NULL,
        \\    interface TEXT NOT NULL,
        \\    rx_bytes INTEGER NOT NULL,
        \\    tx_bytes INTEGER NOT NULL,
        \\    rx_packets INTEGER NOT NULL,
        \\    tx_packets INTEGER NOT NULL,
        \\    rx_speed INTEGER NOT NULL,
        \\    tx_speed INTEGER NOT NULL
        \\)
    ) catch return SchemaError.SchemaCreationFailed;

    // Create daily_summary table for aggregated daily totals
    conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS daily_summary (
        \\    date INTEGER NOT NULL,
        \\    interface TEXT NOT NULL,
        \\    total_rx INTEGER NOT NULL,
        \\    total_tx INTEGER NOT NULL,
        \\    total_rx_packets INTEGER NOT NULL,
        \\    total_tx_packets INTEGER NOT NULL,
        \\    PRIMARY KEY (date, interface)
        \\)
    ) catch return SchemaError.SchemaCreationFailed;

    // Create indexes for efficient querying
    conn.execNoArgs(
        \\CREATE INDEX IF NOT EXISTS idx_samples_timestamp ON samples (timestamp)
    ) catch return SchemaError.SchemaCreationFailed;

    conn.execNoArgs(
        \\CREATE INDEX IF NOT EXISTS idx_samples_interface ON samples (interface)
    ) catch return SchemaError.SchemaCreationFailed;

    conn.execNoArgs(
        \\CREATE INDEX IF NOT EXISTS idx_daily_summary_date ON daily_summary (date)
    ) catch return SchemaError.SchemaCreationFailed;

    return conn;
}

/// Insert a traffic sample into the samples table.
pub fn insertSample(
    conn: zqlite.Conn,
    timestamp: i64,
    interface: []const u8,
    rx_bytes: u64,
    tx_bytes: u64,
    rx_packets: u64,
    tx_packets: u64,
    rx_speed: u64,
    tx_speed: u64,
) !void {
    try conn.exec(
        \\INSERT INTO samples (timestamp, interface, rx_bytes, tx_bytes, rx_packets, tx_packets, rx_speed, tx_speed)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    , .{ timestamp, interface, rx_bytes, tx_bytes, rx_packets, tx_packets, rx_speed, tx_speed });
}

/// Aggregate samples into daily_summary for a given date (days since epoch).
/// This sums up rx_bytes, tx_bytes, rx_packets, tx_packets for each interface
/// on the specified date and upserts into daily_summary.
pub fn aggregateSamplesToDate(
    conn: zqlite.Conn,
    date: u32,
    interface: []const u8,
) SchemaError!void {
    // Get the start and end timestamps for the given date (days since epoch)
    const date_i64: i64 = @intCast(date);
    const start_ts = date_i64 * 86400; // seconds in a day
    const end_ts = start_ts + 86400;

    // Aggregate samples for this interface on this date
    const result = conn.row(
        \\SELECT
        \\    COALESCE(SUM(rx_bytes), 0) as total_rx,
        \\    COALESCE(SUM(tx_bytes), 0) as total_tx,
        \\    COALESCE(SUM(rx_packets), 0) as total_rx_packets,
        \\    COALESCE(SUM(tx_packets), 0) as total_tx_packets
        \\FROM samples
        \\WHERE interface = ? AND timestamp >= ? AND timestamp < ?
    , .{ interface, start_ts, end_ts }) catch return SchemaError.AggregationFailed;

    if (result) |r| {
        defer r.deinit();

        const total_rx: u64 = @intCast(r.int(0));
        const total_tx: u64 = @intCast(r.int(1));
        const total_rx_packets: u64 = @intCast(r.int(2));
        const total_tx_packets: u64 = @intCast(r.int(3));

        // Upsert into daily_summary
        conn.exec(
            \\INSERT INTO daily_summary (date, interface, total_rx, total_tx, total_rx_packets, total_tx_packets)
            \\VALUES (?, ?, ?, ?, ?, ?)
            \\ON CONFLICT (date, interface) DO UPDATE SET
            \\    total_rx = excluded.total_rx,
            \\    total_tx = excluded.total_tx,
            \\    total_rx_packets = excluded.total_rx_packets,
            \\    total_tx_packets = excluded.total_tx_packets
        , .{ date, interface, total_rx, total_tx, total_rx_packets, total_tx_packets }) catch
            return SchemaError.AggregationFailed;
    }
}

/// Get the last N daily summaries ordered by date descending.
pub const DailySummary = struct {
    date: u32,
    interface: []const u8,
    total_rx: u64,
    total_tx: u64,
    total_rx_packets: u64,
    total_tx_packets: u64,
};

test "Schema initialization" {
    // Test that schema creation works with an in-memory database
    const test_db = ":memory:";
    const conn = initSchema(test_db) catch unreachable;
    defer conn.close();
}
