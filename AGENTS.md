# AGENTS.md — TrafficManager

**Generated:** 2026-08-21 | **Commit:** 635a52b | **Branch:** HEAD (detached)

## OVERVIEW

Linux network traffic monitor. Zig 0.16 CLI backend reads `/proc/net/dev`, computes per-second speeds, persists daily totals. Two storage backends (binary + SQLite), daemon mode, quota management with webhook/SMTP notifications. Frontend is a Preact + Tailwind web dashboard (4 tabs: Dashboard / Traffic History / Config / Quota).

## STRUCTURE

```
backend/
├── build.zig, build.zig.zon    # Zig 0.16 build; no root-level build.zig
├── src/                        # 17 .zig modules
│   ├── main.zig                # Entrypoint, arg parsing, monitor loop, daemon orchestration
│   ├── traffic.zig             # TrafficTracker, /proc/net/dev parsing, interface enumeration
│   ├── config.zig              # Config types, TOML/JSON parsing, CLI merge, validation
│   ├── config_store.zig        # SQLite-backed config key-value store (config table) with typed serialization; replaces the old JSON config, which auto-migrates on first run
│   ├── network.zig             # Network interface connect/disconnect (ip link)
│   ├── quota.zig               # Monthly traffic quota tracking, unit parsing, adjustment records
│   ├── storage.zig             # Binary persistence (DailyRecord, 40-byte extern struct)
│   ├── sqlite_storage.zig      # SQLite WAL, buffered writes, auto-flush (5 min), retention
│   ├── sqlite_schema.zig       # SQLite table/index definitions
│   ├── http_server.zig         # Threaded HTTP server exposing the REST API + embedded dashboard; pre-bound port, spinlock-protected shared state
│   ├── daemon.zig              # Unix double-fork daemon (setsid, fd redirect, umask, chdir)
│   ├── pidfile.zig             # PID file + flock(2) exclusive locking
│   ├── log.zig                 # File logging with rotation (10 MB), ERROR/WARN/INFO/DEBUG
│   ├── notify_template.zig     # Template-based notification rendering
│   ├── webhook.zig             # HTTP webhook notifier
│   ├── smtp.zig                # SMTP email sender (wraps vendor/smtp/smtp.c)
│   └── root.zig                # Empty (0 bytes, unused)
├── tests/                      # 10 standalone test files (public API, HTTP server, and integration)
├── vendor/smtp/                # C SMTP client (96 KB smtp.c + smtp.h)
├── scripts/                    # BusyBox init deployment script
└── zig-pkg/                    # Vendored zqlite dep (gitignored, cached)
frontend/                       # Preact + Tailwind web dashboard (single-file build)
├── src/App.tsx                 # Real 4-tab dashboard (Dashboard/History/Config/Quota); panels inline
├── src/components/             # Dashboard sub-components: TrafficChart, ConfigPanel, QuotaManager
├── src/api.ts                  # REST API client targeting the backend /api/* endpoints
├── src/format.ts               # Byte formatting + human-readable size parsing
├── src/index.tsx              # Preact mount point (renders <App/> into #app)
├── src/app.css                # Tailwind CSS entry
├── vite.config.ts             # vite-plugin-singlefile; dev proxy /api -> :8080
├── vitest.config.ts            # Vitest config (jsdom + preact preset); `pnpm test` runs *.test.ts(x)
└── package.json               # pnpm >=11.17; dev/build/preview/test/typecheck scripts
```

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
- **Quota management** (`quota.zig`): monthly traffic quota tracking with unit parsing (KB/MB/GB/TB). Checks quota on each sample; triggers notification via webhook or SMTP when exceeded.
- **Network control** (`network.zig`): disconnects and restores network interfaces via `ip link set {iface} down/up`. Used by quota enforcement to cut off traffic when quota is exceeded.
- **Notifications** (`notify_template.zig`, `webhook.zig`, `smtp.zig`): template-based notification rendering supports webhook (HTTP POST) and SMTP email. SMTP wraps a C library in `vendor/smtp/smtp.c`.
- - **Configuration** (`config.zig`): reads TOML config file, merges with CLI args, validates. Supports interface, interval, storage backend, quota, notification settings.
- **Config storage** (`config_store.zig`): the SQLite `config` table is now the single source of truth for configuration, replacing the old JSON config file. On first run with `--sqlite`, any existing JSON config is migrated into SQLite (renamed to `.bak`). `GET`/`PUT /api/config` read and persist these values.
- **HTTP server** (`http_server.zig`): runs in a separate OS thread. The listening socket is pre-bound in the calling thread (so a busy port fails fast at startup), then the accept loop runs in the spawned thread. All shared state (config pointer, per-request tracker, and the zqlite connection) is guarded by a custom spinlock, since Zig 0.16 removed `std.Thread.Mutex`. It serves the embedded dashboard at `GET /` and the REST API from `/api/*`. Requires `--sqlite`.
- **Command-line flags**: `--web-port <port>` starts the HTTP server (requires `--sqlite`). `--quota-adjust <amount>` (repeatable, human-readable like `500MB`) plus `--quota-adjust-reason <text>` record one-off monthly quota adjustments; these are SQLite-only (ignored with a warning in binary mode) and written to the monthly adjustments table.
- **Build flow**: `just build` runs `cd frontend && pnpm build`, copies `frontend/dist/index.html` to `backend/src/dashboard.html`, then `cd backend && zig build` embeds it via `@embedFile("dashboard.html")` in `http_server.zig`.
- **Test structure**: dual-layer — inline `test` blocks in `src/*.zig` (pulled via `refAllDecls` in `main.zig`) plus 10 standalone test files in `tests/` (public API, HTTP server, integration). Both layers run via `zig build test`.
- **Frontend**: `frontend/package.json` requires pnpm >=11.17. `src/App.tsx` is the real Preact + Tailwind dashboard (4 tabs: Dashboard / Traffic History / Config / Quota) with panels defined inline; `src/api.ts` is the REST client for the backend `/api/*` endpoints; `src/index.tsx` mounts the app.

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
