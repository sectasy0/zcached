# Operations guide

This guide covers production configuration and day-to-day operation of
zcached. Build and platform prerequisites are documented in
[installation.md](installation.md).

## Start with an explicit configuration

Run the server with absolute paths outside ad-hoc development directories:

```sh
/usr/bin/zcached \
  --config-path /etc/zcached/zcached.conf \
  --log-path /var/log/zcached/zcached.log
```

`--config-path` selects the ZON configuration file. `--log-path` selects the
operational log. `--sout` additionally mirrors logs to standard output/stderr,
which is useful under a service manager or container. Do not use `--daemon`
when a supervisor such as systemd or Docker already manages the process.

Review these security-sensitive settings before exposing a listener:

- Bind to a specific interface with `.address`; `0.0.0.0` is appropriate only
  behind an external access policy.
- Restrict `.whitelist` to trusted source addresses. An empty whitelist must
  not be treated as authentication.
- The current pre-1.0 implementation does not yet provide password
  authentication or command ACLs. Put an untrusted network behind a trusted
  proxy/firewall or isolate the instance at the network layer.
- Use TLS for traffic crossing an untrusted network. The TLS-enabled binary
  is built with `zig build -Dtls-enabled=true`.

## Resource limits

Configure limits according to process memory, value size, client count, and
worst-case pipeline depth:

```zon
.{
    .workers = 4,
    .max_clients = 1024,
    .memory = .{ .limit = 1073741824 },
    .max_request_size = 10485760,
    .network = .{
        .idle_timeout_ms = 30000,
        .request_timeout_ms = 5000,
        .max_pipeline_commands = 256,
        .max_pending_response_bytes = 1048576,
        .max_response_bytes = 8388608,
    },
}
```

| Setting | Meaning |
| --- | --- |
| `.memory.limit` | Global requested-byte limit across live stored data. `0` falls back to legacy `.max_memory`, which also defaults to `0` (unlimited). |
| `.max_request_size` | Unread request bytes allowed per connection, covering incomplete and pipelined input. `0` disables this limit. |
| `.network.max_pipeline_commands` | Commands processed in one batch before completed replies are flushed. `0` disables the count boundary. |
| `.network.max_pending_response_bytes` | Queued response-byte threshold for a batch flush. One permitted reply can take the batch beyond the threshold. |
| `.network.max_response_bytes` | Maximum encoded size of one response. Oversized replies return `RESPONSE_TOO_LARGE` without first serializing the stored value. |
| `.network.request_timeout_ms` | Deadline to finish an incomplete frame. |
| `.network.idle_timeout_ms` | Deadline for incoming bytes and TLS handshake progress. |
| `.max_clients` | Connection permits **per worker**, not globally. |
| `.workers` | Number of OS worker/reactor threads. |

The practical connection ceiling is `workers * max_clients`. Account for
per-connection receive/response buffers, TLS state, and native allocator
overhead; these are not included in `.memory.limit`. Leave container and host
memory headroom above the configured data limit.

## Behavior under resource pressure and malformed input

The following behavior is the operational contract:

| Condition | Client-visible behavior | State and server behavior |
| --- | --- | --- |
| `.memory.limit` is reached | The storage write returns `MEMORY_LIMIT_EXCEEDED`. | The failed key is not inserted or replaced. Existing keys remain readable, deletions remain available, and expired entries are purged before admission is rejected. |
| A single accepted mutation crosses the threshold | The command succeeds. | The check occurs before allocation, so the final requested-byte usage may exceed the configured threshold by that accepted mutation. Configure headroom. |
| Concurrent writes approach the limit | Some writes may cross the threshold together. | Limit admission is advisory across shards. It is not a reservation or transactional memory quota. |
| All permits for one worker's `.max_clients` are occupied | The client receives no protocol response and may remain in the operating-system backlog until a permit is released. | Existing connections continue; the accept loop resumes admission after a client closes. There is no global strict client ceiling or `MAX_CLIENTS_REACHED` reply on the accepted connection path. |
| A complete malformed command is received | One stable error response is queued, such as `UNPROCESSABLE`, `INVALID_LENGTH`, or `PAYLOAD_EXCEEDED`. | That frame is not executed. If another complete pipeline frame follows, it is processed normally. |
| A frame is incomplete | No response is sent yet. | Bytes remain buffered until the frame finishes or `.network.request_timeout_ms` expires. An incomplete-read timeout closes the connection. |
| Unread input reaches `.max_request_size` | The connection is closed without guessing a response boundary. | Already processed pipeline replies were flushed in earlier batches; the unsafe unread tail is discarded with the connection. |
| One response exceeds `.max_response_bytes` | That command returns `RESPONSE_TOO_LARGE`. | The stored value is not serialized into the response buffer. Later complete pipeline frames continue normally. |
| A pipeline reaches a response-byte or command-count boundary | Completed responses are flushed before the next batch. | Mutations in the flushed batch are complete; unread pipeline frames remain owned by the connection and are processed after the flush. |
| The peer is slow to read | The connection stops processing more pipeline input while `writeAll` is blocked. | No additional response bytes are generated for that connection during the blocked write. Other connection tasks remain independent. |

Clients must correlate one response with each command in pipeline order. Limits
do not silently drop complete commands: a complete command either returns a
success/error response or the connection ends because the transport or an
unframed input boundary failed.

Multi-key commands are not a transaction. `MSET` stores pairs in sequence; if a
later pair fails, earlier pairs remain committed and the command returns the
failure. `MSETNX` keeps its all-or-nothing insertion rule for condition failure,
rolling back partial inserts if storage admission or allocation fails.

## Snapshots

Snapshots are atomic `.zcpf` files in `.snapshot.path`:

```zon
.snapshot = .{
    .path = "/var/lib/zcached/snapshots",
    .interval_secs = 300,
    .keep_last = 6,
},
```

- `SAVE` creates a snapshot synchronously and returns only after replacement
  and sync succeed.
- `interval_secs = 0` leaves snapshots manual; a positive value schedules them.
- `keep_last = 0` preserves every snapshot. A positive value applies retention
  after every successful manual or scheduled save.
- A dedicated snapshot directory is recommended. Keep unrelated files out of
  it.
- Snapshots validate their CRC and entries. Corrupt newer files fall back to
  the newest older valid snapshot.

Snapshots are periodic point-in-time backups, not a substitute for AOF when
recent acknowledged writes must survive a crash. Monitor free disk space and
the time since a successful save.

## Append-only file

Configure the journal with a durability strategy:

```zon
.aof = .{
    .flush_strategy = .everysec,
    .path = "/var/lib/zcached/appendonly.aof",
    .rewrite_percentage = 100,
    .rewrite_min_size = 67108864,
},
```

| Strategy | Behavior |
| --- | --- |
| `.always` | Writes and syncs each successful mutation immediately; strongest durability and highest I/O cost. |
| `.everysec` | Flushes buffered records on the recurring background schedule. Up to the pending interval can be lost on abrupt failure. |
| `.auto` | Flushes when the internal buffer threshold is reached. |
| `.no` | Disables AOF appends and replay. |

A rewrite writes and syncs a separate file before atomically replacing the
journal. Its full-state baseline starts with `FLUSH`, so it is safe to replay
without an older snapshot.

On startup, recovery order is deterministic:

1. Restore the newest valid snapshot.
2. If AOF is enabled, replay it over the snapshot.
3. If no valid snapshot exists, continue with AOF-only recovery.
4. If AOF is disabled, use snapshot-only recovery.

This means later AOF mutations take precedence over snapshot contents.
Back up snapshot and AOF files with their directory atomically as part of a
consistent backup procedure. Do not copy an actively rewritten file without a
filesystem snapshot or stopping the service.

## Logs

Operational logs are timestamped and severity-filtered by `.log.level`
(`.debug`, `.info`, `.warning`, `.@"error"`). Log initialization, lifecycle
changes, persistence failures, whitelist rejection, and protocol errors are
useful incident signals.

`log_network_payloads` separately enables complete request and response payload
logging. Keep it `false` in normal production operation: payloads may contain
secrets, significantly increase storage use, and add copying/queue work. Use
it briefly on a dedicated instance while investigating protocol issues.

Use external log rotation. zcached keeps the configured log file open, so copy
then truncate the active file for a `copytruncate` rotation policy, or restart
the service after moving it. Ensure the service account can create and append
to the configured file. Reserve separate disk capacity for AOF, snapshots,
and logs; a full filesystem can affect all three.

## Docker

Persist configuration and all state paths explicitly:

```yaml
services:
  server:
    image: sectasy/zcached:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:7556:7556"
    entrypoint:
      - ./zcached
      - --config-path
      - /etc/zcached/zcached.conf
      - --log-path
      - /var/log/zcached/zcached.log
      - --sout
    volumes:
      - ./zcached.conf:/etc/zcached/zcached.conf:ro
      - zcached-data:/var/lib/zcached
      - zcached-logs:/var/log/zcached

volumes:
  zcached-data:
  zcached-logs:
```

Set `.snapshot.path` and `.aof.path` under `/var/lib/zcached` in the mounted
configuration. Bind the port to localhost unless remote access is intentionally
required. The current container uses Alpine/Linux io_uring; its host must allow
the required io_uring syscalls and features. A denied ring is a startup failure,
not a signal to continue on another backend.

Stop with `docker compose stop`; the entrypoint receives normal termination and
the server performs its shutdown flush. Monitor container exit status and
logs, and test restore from volumes before relying on them as backups.

## systemd

Run zcached directly as a foreground service; let systemd own the process
lifecycle:

```ini
[Unit]
Description=zcached
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=zcached
Group=zcached
WorkingDirectory=/var/lib/zcached
ExecStart=/usr/bin/zcached --config-path /etc/zcached/zcached.conf --log-path /var/log/zcached/zcached.log --sout
Restart=on-failure
RestartSec=2
TimeoutStopSec=30
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/zcached /var/log/zcached

[Install]
WantedBy=multi-user.target
```

Create the service account and writable state directories before enabling the
unit. Confirm `ProtectSystem` and other sandbox options are compatible with the
distribution's systemd version and TLS certificate paths. Reload with
`systemctl daemon-reload`, then use `systemctl enable --now zcached`.

Inspect failures with:

```sh
systemctl status zcached
journalctl -u zcached --since "30 minutes ago"
tail -n 200 /var/log/zcached/zcached.log
```

`SIGTERM` and `SIGINT` initiate graceful shutdown. The server stops accepting
work, joins worker tasks, attempts the AOF flush, and then releases state.
Do not use repeated `SIGKILL` as a routine shutdown mechanism.

## Monitoring and recovery checks

There is currently no dedicated metrics endpoint. Monitor at least:

- process liveness and restart count;
- TCP connect and `PING` response checks;
- CPU, resident memory, and open file descriptors;
- disk capacity and inode availability for logs, snapshots, and AOF;
- snapshot modification time and `.keep_last` retention;
- AOF file size/growth and rewrite messages;
- `WARN`/`ERROR` events, especially save, sync, replay, and shutdown-flush
  failures.

A basic plaintext liveness probe sends one complete framed command:

```sh
printf '*1\r\n$4\r\nPING\r\n\003' | timeout 3 nc 127.0.0.1 7556
```

Treat `+PONG` followed by the frame terminator as healthy. Add a probe that
stores and reads a dedicated health key only if the extra mutation and AOF
growth are acceptable. For TLS deployments, perform the check through a
TLS-aware client.

Test recovery regularly using a copy of the persistence files and a separate
zcached instance on another port. A successful live `PING` does not prove that
restart recovery works. Verify restored keys and their expirations, then
document the measured recovery time and disk requirements.
