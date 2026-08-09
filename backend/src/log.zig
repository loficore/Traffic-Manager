// backend/src/log.zig
// File-based logging system with rotation for TrafficManager.
//
// Supports ERROR, WARN, INFO, DEBUG levels.
// Log format: [YYYY-MM-DD HH:MM:SS] [LEVEL] message
// Rotation: by size, default 10MB.
// Default path: /var/log/traffic-manager.log (falls back to /tmp/traffic-manager.log)
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const LogLevel = enum {
    err_level,
    warn_level,
    info_level,
    debug_level,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .err_level => "ERROR",
            .warn_level => "WARN",
            .info_level => "INFO",
            .debug_level => "DEBUG",
        };
    }

    pub fn fromString(s: []const u8) ?LogLevel {
        if (std.mem.eql(u8, s, "ERROR")) return .err_level;
        if (std.mem.eql(u8, s, "WARN")) return .warn_level;
        if (std.mem.eql(u8, s, "INFO")) return .info_level;
        if (std.mem.eql(u8, s, "DEBUG")) return .debug_level;
        return null;
    }

    pub fn intValue(self: LogLevel) u8 {
        return switch (self) {
            .err_level => 0,
            .warn_level => 1,
            .info_level => 2,
            .debug_level => 3,
        };
    }
};

pub const Logger = struct {
    file_path: []const u8,
    allocator: Allocator,
    io: Io,
    min_level: LogLevel,
    max_size: u64,
    current_size: u64,

    const default_max_size: u64 = 10 * 1024 * 1024; // 10 MB

    pub const InitError = error{
        FileAccessFailed,
        DirCreationFailed,
        OutOfMemory,
    };

    /// Initialize logger with specified or default path.
    /// Always duplicates the provided path so Logger owns its own copy.
    /// Tries /var/log/traffic-manager.log first, falls back to /tmp/traffic-manager.log.
    pub fn init(allocator: Allocator, io: Io, file_path: ?[]const u8, min_level: LogLevel) InitError!Logger {
        // Always duplicate the path — both caller-provided and resolved paths
        // are owned by Logger and freed in deinit.
        const path = if (file_path) |fp|
            try allocator.dupe(u8, fp)
        else
            try resolveDefaultPath(allocator, io);
        errdefer allocator.free(path);

        // Ensure directory exists
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => return InitError.DirCreationFailed,
            };
        }

        // Check existing file size for rotation (if file doesn't exist, size stays 0)
        var current_size: u64 = 0;
        const existing_file = std.Io.Dir.openFileAbsolute(io, path, .{
            .mode = .read_only,
        }) catch |open_err| switch (open_err) {
            error.FileNotFound => {
                // File doesn't exist yet, size is 0
                return .{
                    .file_path = path,
                    .allocator = allocator,
                    .io = io,
                    .min_level = min_level,
                    .max_size = default_max_size,
                    .current_size = 0,
                };
            },
            else => return InitError.FileAccessFailed,
        };
        defer existing_file.close(io);

        const stat = existing_file.stat(io) catch return .{
            .file_path = path,
            .allocator = allocator,
            .io = io,
            .min_level = min_level,
            .max_size = default_max_size,
            .current_size = 0,
        };
        current_size = stat.size;

        return .{
            .file_path = path,
            .allocator = allocator,
            .io = io,
            .min_level = min_level,
            .max_size = default_max_size,
            .current_size = current_size,
        };
    }

    /// Resolve default log path: /var/log/traffic-manager.log
    /// Falls back to /tmp/traffic-manager.log if /var/log/ not writable.
    fn resolveDefaultPath(allocator: Allocator, io: Io) ![]const u8 {
        // Try /var/log first
        const var_log_path = "/var/log/traffic-manager.log";
        if (canWriteToDir(allocator, io, var_log_path)) {
            return try allocator.dupe(u8, var_log_path);
        }
        // Fallback to /tmp
        const tmp_path = "/tmp/traffic-manager.log";
        return try allocator.dupe(u8, tmp_path);
    }

    /// Check if directory is writable by attempting to create a test file
    fn canWriteToDir(allocator: Allocator, io: Io, path: []const u8) bool {
        const dir = std.fs.path.dirname(path) orelse return false;
        // Ensure directory exists first
        std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch {};

        // Try to create and delete a test file to check writability
        const test_path = std.fmt.allocPrint(allocator, "{s}/.traffic-manager-write-test", .{dir}) catch return false;
        defer allocator.free(test_path);

        const f = std.Io.Dir.createFileAbsolute(io, test_path, .{ .truncate = true }) catch return false;
        f.close(io);
        std.Io.Dir.deleteFileAbsolute(io, test_path) catch {};
        return true;
    }

    /// Log a message at specified level
    pub fn log(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (level.intValue() > self.min_level.intValue()) return;

        self.writeLog(level, fmt, args) catch {};
    }

    /// Internal: format and write log entry
    fn writeLog(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) !void {
        // Rotate if needed
        try self.rotateIfNeeded();

        // Separate buffers: msg_buf for the message, line_buf for the full log line.
        // Using the same buffer for both would cause the line_buf formatting to
        // overwrite msg data still being read by the format call.
        var msg_buf: [2048]u8 = undefined;
        var line_buf: [4096]u8 = undefined;
        var ts_buf: [20]u8 = undefined;
        const timestamp = try formatTimestamp(&ts_buf, self.io);

        // Format the message part
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch |fmt_err| switch (fmt_err) {
            error.NoSpaceLeft => return,
        };

        // Build full log line: [YYYY-MM-DD HH:MM:SS] [LEVEL] message\n
        const full_line = std.fmt.bufPrint(&line_buf, "[{s}] [{s}] {s}\n", .{
            timestamp,
            level.toString(),
            msg,
        }) catch |line_err| switch (line_err) {
            error.NoSpaceLeft => return,
        };

        // Open file for appending (O_APPEND ensures writes go to end of file)
        const fd = std.posix.openat(std.posix.AT.FDCWD, self.file_path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
        }, 0o644) catch return;

        var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        defer file.close(self.io);

        // Write the log line (O_APPEND ensures it goes to end of file)
        file.writeStreamingAll(self.io, full_line) catch return;

        self.current_size += full_line.len;
    }

    /// Rotate log file if it exceeds max_size
    fn rotateIfNeeded(self: *Logger) !void {
        if (self.current_size < self.max_size) return;

        // Build rotated filename: traffic-manager.log.1
        const rotated_path = std.fmt.allocPrint(self.allocator, "{s}.1", .{self.file_path}) catch return;
        defer self.allocator.free(rotated_path);

        // Delete old rotated file if exists
        std.Io.Dir.deleteFileAbsolute(self.io, rotated_path) catch {};

        // Rename current to rotated
        std.Io.Dir.renameAbsolute(self.file_path, rotated_path, self.io) catch {};

        // Reset size counter
        self.current_size = 0;
    }

    /// Format current timestamp as YYYY-MM-DD HH:MM:SS
    /// Caller provides the buffer to avoid dangling pointer (the returned slice aliases `buf`).
    fn formatTimestamp(buf: *[20]u8, io: Io) ![]const u8 {
        const now = Io.Timestamp.now(io, .real);
        const secs: u64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s));
        const es = std.time.epoch.EpochSeconds{ .secs = secs };
        const day_seconds = es.getDaySeconds();
        const epoch_day = es.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        }) catch error.InvalidFormat;
    }

    /// Deinitialize logger (no-op, file handles are closed per-write)
    pub fn deinit(self: *Logger) void {
        // Free the allocated path if it was allocated by init
        self.allocator.free(self.file_path);
    }
};

// Convenience functions for global logging
var global_logger: ?Logger = null;

/// Initialize global logger
pub fn initGlobal(allocator: Allocator, io: Io, file_path: ?[]const u8, min_level: LogLevel) Logger.InitError!void {
    global_logger = try Logger.init(allocator, io, file_path, min_level);
}

/// Deinitialize global logger
pub fn deinitGlobal() void {
    if (global_logger) |*logger| {
        logger.deinit();
        global_logger = null;
    }
}

/// Log error level message
pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (global_logger) |*logger| {
        logger.log(.err_level, fmt, args);
    }
}

/// Log warn level message
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (global_logger) |*logger| {
        logger.log(.warn_level, fmt, args);
    }
}

/// Log info level message
pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (global_logger) |*logger| {
        logger.log(.info_level, fmt, args);
    }
}

/// Log debug level message
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (global_logger) |*logger| {
        logger.log(.debug_level, fmt, args);
    }
}

// ── Tests ────────────────────────────────────────────────────────────────
test "LogLevel toString" {
    try std.testing.expectEqualStrings("ERROR", LogLevel.err_level.toString());
    try std.testing.expectEqualStrings("WARN", LogLevel.warn_level.toString());
    try std.testing.expectEqualStrings("INFO", LogLevel.info_level.toString());
    try std.testing.expectEqualStrings("DEBUG", LogLevel.debug_level.toString());
}

test "LogLevel fromString" {
    try std.testing.expectEqual(@as(?LogLevel, .err_level), LogLevel.fromString("ERROR"));
    try std.testing.expectEqual(@as(?LogLevel, .warn_level), LogLevel.fromString("WARN"));
    try std.testing.expectEqual(@as(?LogLevel, .info_level), LogLevel.fromString("INFO"));
    try std.testing.expectEqual(@as(?LogLevel, .debug_level), LogLevel.fromString("DEBUG"));
    try std.testing.expectEqual(@as(?LogLevel, null), LogLevel.fromString("INVALID"));
}

test "LogLevel intValue ordering" {
    try std.testing.expect(LogLevel.err_level.intValue() < LogLevel.warn_level.intValue());
    try std.testing.expect(LogLevel.warn_level.intValue() < LogLevel.info_level.intValue());
    try std.testing.expect(LogLevel.info_level.intValue() < LogLevel.debug_level.intValue());
}

test "Logger appends to file instead of overwriting" {
    // Create a temporary file path for testing
    const test_path = "/tmp/traffic-manager-test-append.log";
    const io = std.Io.Threaded.global_single_threaded.io();

    // Clean up any existing test file
    std.Io.Dir.deleteFileAbsolute(io, test_path) catch {};

    const allocator = std.testing.allocator;

    // Initialize logger
    var logger = Logger.init(allocator, io, test_path, .debug_level) catch return;
    defer logger.deinit();

    // Write first log entry
    logger.log(.info_level, "First entry: {s}", .{"hello"});

    // Read file to verify first entry
    {
        const file = std.Io.Dir.openFileAbsolute(io, test_path, .{ .mode = .read_only }) catch return;
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        const bytes_read = file.readPositionalAll(io, &buf, 0) catch return;
        const content = buf[0..bytes_read];
        try std.testing.expect(std.mem.indexOf(u8, content, "First entry: hello") != null);
    }

    // Write second log entry
    logger.log(.info_level, "Second entry: {s}", .{"world"});

    // Read file to verify BOTH entries exist (append, not overwrite)
    {
        const file = std.Io.Dir.openFileAbsolute(io, test_path, .{ .mode = .read_only }) catch return;
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        const bytes_read = file.readPositionalAll(io, &buf, 0) catch return;
        const content = buf[0..bytes_read];
        try std.testing.expect(std.mem.indexOf(u8, content, "First entry: hello") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "Second entry: world") != null);
    }

    // Clean up
    std.Io.Dir.deleteFileAbsolute(io, test_path) catch {};
}

test "Logger init owns its own copy of file_path (BUG-4 regression)" {
    // Use /tmp which should always exist on Linux
    const test_path = "/tmp/traffic-manager-test-log.txt";
    const io = std.Io.Threaded.global_single_threaded.io();

    const allocator = std.testing.allocator;

    // Simulate what main.zig does: parseArgs allocates a dupe of the CLI arg
    const caller_owned_path = try allocator.dupe(u8, test_path);
    defer allocator.free(caller_owned_path);

    // Logger.init should create its OWN copy (not store the caller's pointer)
    var logger = Logger.init(allocator, io, caller_owned_path, .info_level) catch return;
    // logger.deinit frees its own copy; main.zig frees caller_owned_path separately.
    // Before the fix, both freed the same pointer → double-free.
    logger.deinit();

    // Caller's pointer is still valid and freeable independently (no double-free)
    // (freed by defer above)

    // Cleanup test file if created
    std.Io.Dir.deleteFileAbsolute(io, test_path) catch {};
}
