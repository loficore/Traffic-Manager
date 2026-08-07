# TrafficManager

A Linux network traffic monitor that reads `/proc/net/dev` directly, computes per-second speeds, and persists daily totals. Built with Zig 0.16 for embedded and headless systems.

## Features

- Real-time RX/TX speed and packet rate monitoring
- Two storage backends: binary file (default) or SQLite with WAL mode
- Daemon mode for background operation without a terminal
- PID file locking to prevent duplicate instances
- File-based logging with automatic rotation
- Configurable data retention for sample cleanup
- Automatic migration from binary to SQLite format

## Requirements

- Linux (reads `/proc/net/dev` directly)
- Zig 0.16.0 or later

## Building

All commands run from the `backend/` directory:

```bash
cd backend
zig build
```

The compiled binary lands at `zig-out/bin/traffic-backend`.

Run the test suite:

```bash
zig build test
```

## Usage

### Foreground mode

Run with defaults (auto-select NIC, 1-second interval):

```bash
zig build run
```

List available network interfaces:

```bash
zig build run -- -l
```

Monitor a specific interface with a 2-second interval:

```bash
zig build run -- -d 2 -i eth0
```

View the last 7 days of traffic history:

```bash
zig build run -- -D 7
```

### SQLite storage

Use SQLite instead of the binary file backend:

```bash
zig build run -- --sqlite
```

Set a 60-day retention policy (samples older than 60 days get deleted):

```bash
zig build run -- --sqlite --retention-days 60
```

Query history from the SQLite database:

```bash
zig build run -- --sqlite -D 7
```

The SQLite database lives at `$HOME/.local/share/traffic-manager/traffic.db` by default. It uses WAL mode and buffers writes, flushing to disk every 5 minutes.

### Daemon mode

Run as a background daemon:

```bash
zig build run -- --daemon --pid-file /var/run/traffic-manager.pid
```

Combine daemon mode with SQLite storage and logging:

```bash
zig build run -- --daemon --sqlite \
  --pid-file /var/run/traffic-manager.pid \
  --log-file /var/log/traffic-manager.log
```

Monitor a specific interface in daemon mode with a 5-second interval:

```bash
zig build run -- --daemon -d 5 -i eth0 --sqlite \
  --pid-file /var/run/traffic-manager.pid \
  --log-file /var/log/traffic-manager.log
```

The `--daemon` and `--foreground` flags are mutually exclusive. Daemon mode performs a classic Unix double-fork: the original parent exits, the grandchild runs in its own session with stdin/stdout/stderr redirected to `/dev/null`.

## Command-line options

| Option | Description | Default |
|---|---|---|
| `-d`, `--duration <sec>` | Sampling interval in seconds | 1 |
| `-i`, `--interface <name>` | Network interface to monitor | Auto-detected |
| `-l`, `--list` | List interfaces and exit | |
| `-D`, `--day <n>` | Show last N days of history | 0 (disabled) |
| `--daemon` | Run as background daemon | |
| `-f`, `--foreground` | Force foreground (conflicts with `--daemon`) | |
| `--pid-file <path>` | PID file location | `/var/run/traffic-manager.pid` |
| `--log-file <path>` | Log file location | `/var/log/traffic-manager.log` |
| `--sqlite` | Use SQLite storage | |
| `--no-sqlite` | Use binary file storage | Binary |
| `--retention-days <n>` | Days to keep sample data | 30 |
| `-h`, `--help` | Show help | |

## Installing as a system service

### OpenRC (Alpine, Gentoo)

Create `/etc/init.d/traffic-manager`:

```bash
#!/sbin/openrc-run

name="traffic-manager"
description="Network traffic monitor"
command="/usr/local/bin/traffic-backend"
command_args="--daemon --sqlite --pid-file /run/traffic-manager.pid --log-file /var/log/traffic-manager.log"
pidfile="/run/traffic-manager.pid"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --owner root:root --mode 0755 /run/traffic-manager
    checkpath --directory --owner root:root --mode 0755 /var/log
}
```

Enable and start:

```bash
chmod +x /etc/init.d/traffic-manager
rc-update add traffic-manager default
rc-service traffic-manager start
```

### systemd

Create `/etc/systemd/system/traffic-manager.service`:

```ini
[Unit]
Description=Network Traffic Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/local/bin/traffic-backend --daemon --sqlite --pid-file /run/traffic-manager.pid --log-file /var/log/traffic-manager.log
PIDFile=/run/traffic-manager.pid
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
systemctl daemon-reload
systemctl enable traffic-manager
systemctl start traffic-manager
```

### SysVinit (Debian, older systems)

Create `/etc/init.d/traffic-manager`:

```bash
#!/bin/sh
### BEGIN INIT INFO
# Provides:          traffic-manager
# Required-Start:    $network $remote_fs
# Required-Stop:     $network $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Description:       Network traffic monitor
### END INIT INFO

DAEMON=/usr/local/bin/traffic-backend
PIDFILE=/run/traffic-manager.pid
LOGFILE=/var/log/traffic-manager.log

case "$1" in
    start)
        echo "Starting traffic-manager..."
        $DAEMON --daemon --sqlite --pid-file $PIDFILE --log-file $LOGFILE
        ;;
    stop)
        echo "Stopping traffic-manager..."
        if [ -f "$PIDFILE" ]; then
            kill "$(cat $PIDFILE)" 2>/dev/null
            rm -f "$PIDFILE"
        fi
        ;;
    restart)
        "$0" stop
        sleep 1
        "$0" start
        ;;
    status)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
            echo "traffic-manager is running (PID $(cat $PIDFILE))"
        else
            echo "traffic-manager is not running"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
exit 0
```

Register the init script:

```bash
chmod +x /etc/init.d/traffic-manager
update-rc.d traffic-manager defaults
```

## File locations

| Path | Purpose |
|---|---|
| `$HOME/.local/share/traffic-manager/state.bin` | Binary storage (default backend) |
| `$HOME/.local/share/traffic-manager/traffic.db` | SQLite database |
| `/var/run/traffic-manager.pid` | PID file (falls back to `/tmp/`) |
| `/var/log/traffic-manager.log` | Log file (falls back to `/tmp/`) |

If `/var/run/` or `/var/log/` are not writable, the program falls back to `/tmp/` automatically.

## Troubleshooting

**"traffic-manager already running"**

Another instance is holding the PID file lock. Check if it's actually running:

```bash
cat /var/run/traffic-manager.pid
kill -0 $(cat /var/run/traffic-manager.pid)
```

If the process is dead but the file lingers, remove it:

```bash
rm /var/run/traffic-manager.pid
```

**"No usable interface found"**

The program couldn't find a non-loopback interface. Specify one manually:

```bash
zig build run -- -i eth0
```

List available interfaces with `-l`.

**SQLite database corruption**

The program detects corruption automatically and rebuilds the database, migrating any existing binary data. If you want a clean start:

```bash
rm ~/.local/share/traffic-manager/traffic.db*
```

**Log file growing too large**

Logs rotate automatically at 10 MB. The rotated file is `traffic-manager.log.1`. To disable logging, omit `--log-file`. To log to stdout in foreground mode, just don't pass `--log-file` or `--daemon`.

**ZLS shows errors but `zig build` works**

Your Zig version is likely older than 0.16. The code uses APIs that only exist in 0.16 (`std.Io`, `std.process.Init`, etc.). Check your version:

```bash
zig version
```

## Storage backend comparison

| Feature | Binary file | SQLite |
|---|---|---|
| Format | Raw struct array | WAL-mode SQLite |
| Daily totals | Yes | Yes |
| Per-second samples | No | Yes |
| Data retention | Manual cleanup | Automatic by `--retention-days` |
| Concurrent reads | No | Yes |
| Corruption recovery | None | Auto-rebuild + migration |
| Default path | `state.bin` | `traffic.db` |

SQLite is recommended for daemon deployments. The binary backend works fine for quick foreground checks.

## Architecture

The program reads `/proc/net/dev` on each sampling interval, parses the kernel counters for the target interface, and computes deltas between samples. Speed is calculated as bytes-per-second and packets-per-second.

32-bit counter wraparound is handled transparently. If the NIC resets (counter drops without reaching the 32-bit ceiling), the program treats the new value as a fresh start.

In daemon mode, the classic double-fork pattern detaches from the terminal. Signal handlers catch SIGINT and SIGTERM for clean shutdown, saving state and removing the PID file before exit.

## License

See repository for license information.
