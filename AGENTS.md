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
