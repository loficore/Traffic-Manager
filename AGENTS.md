# AGENTS.md — TrafficManager

## Project overview

Linux network traffic monitor. Zig 0.16 CLI backend that reads `/proc/net/dev`, computes per-second speeds, and persists daily totals. Supports two storage backends (binary file and SQLite) and a daemon mode for headless/embedded deployment. A TypeScript frontend skeleton exists but has no real code yet.

## Repo structure

- `backend/` — Zig 0.16 CLI application (`build.zig` + `src/`)
  - `src/main.zig` — Entrypoint, arg parsing, live monitor loop, daemon orchestration
  - `src/traffic.zig` — TrafficTracker, `/proc/net/dev` parsing, interface enumeration
  - `src/storage.zig` — Binary persistence of DailyRecord (40 bytes each) to `$HOME/.local/share/traffic-manager/state.bin`
  - `src/sqlite_storage.zig` — SQLite storage with WAL mode, buffered writes, auto-flush (5 min), data retention cleanup
  - `src/sqlite_schema.zig` — SQLite schema definitions (samples + daily_summary tables, indexes)
  - `src/daemon.zig` — Classic Unix double-fork daemon (setsid, fd redirect to /dev/null, umask, chdir)
  - `src/pidfile.zig` — PID file management with flock(2) exclusive locking, duplicate instance detection
  - `src/log.zig` — File-based logging with rotation (10 MB default), supports ERROR/WARN/INFO/DEBUG levels
  - `src/root.zig` — Empty (unused)
- `frontend/` — TypeScript skeleton; `index.ts` is a type-checking demo, not a real app

## Build & test commands

All build commands run from `backend/`, NOT the repo root (there is no root-level build.zig).

    cd backend
    zig build                          # compile to zig-out/bin/traffic-backend
    zig build run                      # build + run with defaults (auto-select NIC, 1s interval)
    zig build run -- -l                # list network interfaces
    zig build run -- -d 2 -i eth0      # 2s interval on eth0
    zig build run -- -D 3              # show last 3 days of traffic history
    zig build test                     # run all unit tests (embedded test blocks in src/*.zig)

    # Daemon mode
    zig build run -- --daemon --pid-file /var/run/traffic-manager.pid
    zig build run -- --daemon --sqlite --pid-file /var/run/traffic-manager.pid
    zig build run -- --daemon -d 5 -i eth0 --sqlite --log-file /var/log/traffic-manager.log

    # SQLite storage (standalone, foreground)
    zig build run -- --sqlite
    zig build run -- --sqlite --retention-days 60 -D 7

There is no separate test runner, no CI, no lint step, and no formatter config.

## Zig version requirement

`build.zig.zon` declares `minimum_zig_version = "0.16.0"`. The code uses 0.16-only APIs:
- `std.Io` (the new async I/O abstraction, NOT the old `std.io`)
- `std.process.Init` as main's parameter type
- `std.Io.Dir.openFileAbsolute`, `file.readPositionalAll`, `file.writeStreamingAll`
- `std.Io.Timestamp.now(io, .real)` for wall-clock time
- `std.ArrayList` with `.empty` + explicit allocator (NOT `ArrayList.init(allocator)`)

If ZLS reports errors but `zig build` compiles fine, the installed Zig version is likely < 0.16.

## Key architecture notes

- **Linux-only**: reads `/proc/net/dev` directly. Tests that call `listInterfaces`/`findDefaultInterface` skip on non-Linux.
- **Signal handling**: installs SIGINT/SIGTERM handlers via `std.posix.sigaction`; an atomic `should_exit` flag controls the monitor loop exit. State is saved and PID file is cleaned up on clean shutdown.
- **Daemon mode** (`daemon.zig`): classic Unix double-fork pattern. The original parent exits, the grandchild runs in its own session with stdin/stdout/stderr redirected to `/dev/null`. Use `--daemon` to enable; `--foreground` forces the opposite. The two flags are mutually exclusive.
- **PID file** (`pidfile.zig`): uses `flock(2)` exclusive non-blocking lock to prevent duplicate instances. Default path: `/var/run/traffic-manager.pid`, falls back to `/tmp/traffic-manager.pid` if `/var/run/` is not writable. Custom path via `--pid-file`.
- **Logging** (`log.zig`): file-based logging with automatic rotation at 10 MB. Default path: `/var/log/traffic-manager.log`, falls back to `/tmp/traffic-manager.log`. Four levels: ERROR, WARN, INFO, DEBUG. Format: `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`.
- **SQLite storage** (`sqlite_storage.zig`): WAL mode, NORMAL synchronous. Two tables: `daily_traffic` (persistent daily totals) and `samples` (per-second samples, auto-cleaned by retention policy). Buffered writes with 5-minute auto-flush. Auto-migrates from binary format on database corruption/rebuild. Default path: `$HOME/.local/share/traffic-manager/traffic.db`.
- **Binary storage** (`storage.zig`): `DailyRecord` is an `extern struct` (40 bytes, packed). Files are arrays of these records sorted by date descending. Path: `$HOME/.local/share/traffic-manager/state.bin` (falls back to `/tmp` if `$HOME` is unset).
- **Overflow handling**: `calcDelta` in traffic.zig handles 32-bit counter wraparound and NIC reset scenarios.
- **Test structure**: tests are `test` blocks inside source files, not separate files. `main.zig` has `test { std.testing.refAllDecls(...); }` which pulls in tests from all modules.
- **Frontend**: `frontend/package.json` specifies pnpm >=11.17 as the package manager. The single `index.ts` is a TypeScript type-checking playground, not application code.

## Version control

Uses Jujutsu (jj) with a git backend. `.jj/` is the jj workspace root.

## Code Comment Guidelines

All code in this project must have comprehensive Chinese comments that explain logic and code intent while remaining concise.

### Comment Principles

1. **Language**: All comments must be in Chinese
2. **Concise**: Comments should be brief, avoiding redundant descriptions
3. **Explain Intent**: Comments should explain "why" rather than just "what"
4. **Critical Logic**: Complex algorithms, business logic, and important decisions must have comments
5. **Interface Documentation**: Public functions, structs, and enums require doc comments

### Comment Format

- **Line comments**: Use `//` for short explanations
- **Doc comments**: Use `///` for functions, structs, and enums documentation
- **Section comments**: Use `// ── Title ──` format for code section separators

### Comment Content Requirements

#### Function Comments
```zig
/// 计算两个时间戳之间的差值（毫秒）
/// 
/// 参数：
///   - start: 起始时间戳（毫秒）
///   - end: 结束时间戳（毫秒）
/// 
/// 返回：时间差值（毫秒），如果 start > end 则返回 0
fn calcTimeDiff(start: u64, end: u64) u64 {
    // 确保结束时间不早于开始时间
    if (end <= start) return 0;
    return end - start;
}
```

#### Struct Comments
```zig
/// 网络流量统计信息
/// 
/// 包含采样时刻的上下行速率、包数和累计流量
const TrafficStats = struct {
    /// 采样时间戳（毫秒）
    timestamp_ms: i64,
    /// 下行速率（字节/秒）
    rx_speed_bps: u64,
    /// 上行速率（字节/秒）
    tx_speed_bps: u64,
};
```

#### Complex Logic Comments
```zig
// 处理 32 位计数器溢出情况
// 当计数器重置（新值小于旧值）时，视为新的开始
if (new_rx < old_rx) {
    // 可能是计数器溢出或网卡重置
    // 采用新值作为本次增量
    delta_rx = new_rx;
} else {
    delta_rx = new_rx - old_rx;
}
```

#### Code Section Separators
```zig
// ── 初始化阶段 ──
// 加载配置文件
const config = loadConfig();
// 初始化数据库连接
var db = try Database.open(config.db_path);

// ── 主循环 ──
while (!should_exit) {
    // 采样网络流量
    const stats = sampleTraffic();
    // 更新数据库
    try db.update(stats);
}
```

### Comment Checklist

- [ ] Do all public functions have doc comments?
- [ ] Do complex algorithms have logic explanations?
- [ ] Do business decisions have reasoning?
- [ ] Are comments in Chinese?
- [ ] Are comments concise?

### Prohibited Practices

- No meaningless comments (e.g., `// Set variable x`)
- No English comments (except proper nouns or code references)
- No commented-out code (use version control instead)
- No over-commenting (simple code needs no comments)

## Agent rules

Agents operating in this repository must adhere to the following rules to prevent accidental version control operations and keep commits under human control.

### Forbidden operations

Agents are **not authorized** to perform any write operations with `jj` or `git`. This includes, but is not limited to:

- `jj commit`, `jj new`, `jj describe`, `jj squash`, `jj rebase`, `jj bookmark`, `jj git push`, `jj git fetch`
- `git commit`, `git add`, `git push`, `git pull`, `git branch`, `git checkout`, `git merge`, `git rebase`, `git stash`

Agents must never stage, commit, amend, or push changes to the repository.

### Allowed operations

Agents may perform the following **read-only** operations with version control tools:

- `jj log`, `jj status`, `jj diff`, `jj show`, `jj describe` (read-only, no writes)
- `git log`, `git status`, `git diff`, `git show`, `git blame`, `git branch -l`

Agents may also:

- Read and modify source code files (`.zig`, `.ts`, `.md`, etc.)
- Run build commands (`zig build`, `zig build test`)
- Run tests (`zig build test`)
- Run the application in foreground mode for verification (`zig build run`)
- List files and directories

### Summary

| Category | Allowed | Forbidden |
|---|---|---|
| Read version history | Yes | — |
| Modify source code | Yes | — |
| Build & test | Yes | — |
| Run app (foreground) | Yes | — |
| Any jj write command | — | Yes |
| Any git write command | — | Yes |
| Commit, push, rebase | — | Yes |
