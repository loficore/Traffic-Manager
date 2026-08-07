// backend/src/daemon.zig
// Classic Unix double-fork daemon pattern for embedded Linux (no systemd).
//
// After daemonize() returns .daemon:
//   - Process runs in its own session (no controlling terminal)
//   - stdin/stdout/stderr redirected to /dev/null
//   - umask(0) and cwd "/"
//   - Use getIo() to obtain a fresh std.Io instance
//
// PID file management is handled separately by pidfile.zig.
const std = @import("std");

/// Result of the double-fork daemonization.
pub const DaemonResult = enum {
    /// We are the original parent process. The caller should exit.
    parent,
    /// We are the grandchild (daemon). The caller should continue.
    daemon,
};

/// Perform the classic Unix double-fork daemonization.
///
/// 1. fork #1 — parent returns `.parent`, child continues
/// 2. setsid() — child becomes session leader, detaches from terminal
/// 3. fork #2 — session leader exits, grandchild continues
///    (prevents the grandchild from ever re-acquiring a controlling terminal)
/// 4. Close fds 0/1/2, reopen them as /dev/null
/// 5. umask(0), chdir("/")
pub fn daemonize() !DaemonResult {
    // ── Fork #1 ──────────────────────────────────────────────────────────
    const pid1 = std.os.linux.fork();
    if (pid1 < 0) return error.ForkFailed;
    if (pid1 > 0) {
        // Parent: child will be reaped by init; return to caller so it can exit.
        return .parent;
    }

    // ── setsid: detach from controlling terminal ──────────────────────────
    _ = std.os.linux.setsid();

    // ── Fork #2 ──────────────────────────────────────────────────────────
    const pid2 = std.os.linux.fork();
    if (pid2 < 0) return error.ForkFailed;
    if (pid2 > 0) {
        // Session leader: exit immediately so the grandchild is orphaned
        // and adopted by init, guaranteeing no controlling terminal.
        std.os.linux.exit(0);
    }

    // ── Grandchild (daemon) setup ────────────────────────────────────────
    // umask(0): allow creating files with any permissions
    _ = std.os.linux.syscall1(.umask, 0);
    _ = std.os.linux.chdir("/");

    // Close inherited standard file descriptors
    _ = std.os.linux.close(0);
    _ = std.os.linux.close(1);
    _ = std.os.linux.close(2);

    // Redirect stdin/stdout/stderr → /dev/null
    const devnull = std.os.linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    if (devnull < std.math.maxInt(usize)) {
        const fd: i32 = @intCast(devnull);
        _ = std.os.linux.dup2(fd, 0);
        _ = std.os.linux.dup2(fd, 1);
        _ = std.os.linux.dup2(fd, 2);
        if (fd > 2) _ = std.os.linux.close(fd);
    }

    return .daemon;
}

/// Obtain a fresh std.Io instance after daemonization.
///
/// The parent's Io carries event-loop state tied to its process.
/// After fork(), the grandchild must not reuse that state.
/// This function returns the global single-threaded Io which is
/// safe to use in the freshly-forked daemon process.
pub fn getIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// ── Tests ────────────────────────────────────────────────────────────────
test "daemonize compiles" {
    // We only verify the function signatures compile; actually forking
    // inside a test would break the test runner.
    _ = daemonize;
    _ = getIo;
}
