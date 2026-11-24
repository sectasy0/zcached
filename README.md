# zcached - A Lightweight In-Memory Cache System

Welcome to `zcached`, a nimble and efficient in-memory caching system resembling databases like Redis. This README acts as a comprehensive guide, aiding in comprehension, setup, and optimal utilization.

![zig](https://img.shields.io/badge/Zig-v0.17.1-0074C1?logo=zig&logoColor=white&color=%230074C1)
![tests](https://github.com/sectasy0/zcached/actions/workflows/zcached-tests.yml/badge.svg)
![build](https://github.com/sectasy0/zcached/actions/workflows/zcached-build.yml/badge.svg)

## Introduction
`zcached` aims to offer rapid, in-memory caching akin to widely-used databases such as Redis. Its focus lies in user-friendliness, efficiency, and agility, making it suitable for various applications requiring swift data retrieval and storage.

Crafted using Zig, a versatile, modern, compiled programming language, `zcached` prides itself on a zero-dependency architecture. This unique feature enables seamless compilation and execution across systems equipped with a Zig compiler, ensuring exceptional portability and deployment ease.

## Features
- **Zero-Dependency Architecture**: Entirely built using Zig, ensuring seamless execution across systems with a Zig compiler, enhancing portability (except openssl, but it's optional).
- **Lightweight Design**: Engineered for efficiency, `zcached` boasts a small memory footprint and minimal CPU usage, optimizing performance while conserving resources.
- **Optimized Efficiency**: Prioritizing swift data handling, `zcached` ensures prompt operations to cater to diverse application needs.
- **Protocol Value Support**: Stores scalar and compound values, including strings, integers, floats, booleans, nulls, arrays, string-keyed maps, and ordered or unordered sets. Set values are supported, but there are no set-specific member commands.
- **Concurrent I/O**: Networking uses Zig's `std.Io.net` interface with cancellable connection tasks and backpressure. TLS uses OpenSSL memory BIOs, so encrypted socket traffic also goes through `std.Io`.
- **TLS Support**: Ensures secure data transmission with encryption, protecting data integrity and confidentiality during client-server communication.

The runtime uses a custom Zig 0.17.1 `std.Io` reactor: kqueue on macOS and
io_uring on Linux. Each `workers` entry creates an OS thread with its own
reactor; its connections run as cooperative fibers, not individual OS threads.
`max_clients` limits connections per worker. Filesystem/platform services
remain synchronous; see [network architecture](docs/internals/network_architecture.md)
for ownership, copying, cancellation, and platform requirements.

Storage uses `Memory -> Fabric -> Shard`. Fabric hashes keys onto
`.memory.shard_count` shards (default 16); each shard owns a separate heap,
map, and reader/writer lock. `.memory.default_capacity` (default 64) is the
initial number of entries per shard. The shard count must be positive and
is fixed for the lifetime of the store.

`.memory.limit` limits live requested bytes across all shards, including
map capacities but excluding allocator metadata. Zero falls back to the legacy
`.max_memory`; both default to zero (unlimited). As before, writes are rejected
once the current usage reaches the limit, so an accepted write can exceed it.
AOF recovery temporarily bypasses the limit to replay historical writes without
dropping data. The limit applies again to new writes after recovery.
COPY and RENAME lock both shards in index order and copy data into the
destination's allocator before committing. FLUSH, key enumeration, snapshots,
and AOF rewrites coordinate all shards for a consistent view. Iterators hold
shared shard locks and must be released with `deinit()`, even on early exit.

### Operational settings

- `.network.idle_timeout_ms` limits the wait for incoming bytes (and for a TLS
  handshake). `.network.request_timeout_ms` limits how long an incomplete frame
  can take to arrive, even if the client keeps sending fragments. `0` disables
  either timeout.
- `.network.max_pending_response_bytes` flushes queued replies before processing
  more pipelined requests. `0` disables the threshold. A single reply may exceed
  it; it is not a hard cap on response size or allocated capacity.
- `.snapshot.path` defaults to `./persist`. `.snapshot.interval_secs = 0` leaves
  snapshots manual (`SAVE`); a positive value schedules periodic saves.
  `.snapshot.keep_last = 0` keeps all files; a positive value keeps the newest
  timestamped snapshots after a successful save. Use a dedicated directory.
  If automatic snapshots and AOF are both enabled, startup replays **only
  the AOF**; snapshots are backups and are not an automatic fallback for a
  missing journal. Disable AOF to start from a snapshot.
- `.log.level` filters operational messages (`.debug`, `.info`, `.warning`,
  `.@"error"`). `log_network_payloads` separately controls payload logs and is
  disabled by default because request and response data may contain secrets.
- TLS is disabled by default. Build with `zig build -Dtls-enabled=true`, then
  set `.tls.enabled = true`, `.tls.cert_path` to a PEM certificate chain
  (server certificate first), and `.tls.key_path` to its matching private key.
  Client-certificate verification is optional: `.peer` verifies a supplied
  certificate, while `.fail_if_no_peer_cert` also requires one. Either mode
  requires `.ca_path` to a PEM CA bundle. `.none` remains the default, so
  ordinary TLS clients do not need client certificates.

## Usage
While `zcached` lacks a CLI, you can utilize nc (netcat) from the terminal to send commands to the server.

#### SET
Set a key to hold the string value. If key already holds a value, it is overwritten, regardless of its type.
```bash
echo "*3\r\n\$3\r\nSET\r\n\$9\r\nmycounter\r\n:42\r\nx03" | netcat -N localhost 7556
```

```bash
echo "*3\r\n\$3\r\nSET\r\n\$9\r\nmycounter\r\n%2\r\n+first\r\n:1\r\n+second\r\n:2\r\nx03" | netcat -N localhost 7556
```

#### Command Breakdown:
- `*3\r\n` - number of elements in the array (commands are always arrays)
- `\$3\r\nSET\r\n` - `$3` denotes the following string as 3 bytes long, SET is the command
- `\$9\r\nmycounter\r\n` - `$9` means that the next string is 9 bytes long, `mycounter` is the key
- `:42\r\n` - `:` indicates the next string is a number, `42` is the value

#### GET
Retrieve the value of a key. If the key doesn’t exist, `-not found` is returned. GET only accepts strings as keys.
```bash
echo "*2\r\n\$3\r\nGET\r\n\$9\r\nmycounter\r\n\x03" | netcat -N localhost 7556
```

#### PING
Returns `PONG`. This command is often used to test if a connection is still alive, or to measure latency.
```bash
echo "*1\r\n\$4\r\nPING\r\n\x03" | netcat -N localhost 7556
```

#### Key expiration

Use `SET key value EX 60` for a 60-second lifetime or `SET key value PX 500`
for 500 ms. For an existing key, use `EXPIRE key 60` to set its lifetime,
`TTL key` to read the remaining seconds, or `PERSIST key` to remove its expiry.
`TTL` returns `-1` for a key without expiry and `-2` for a missing or expired
key. Expiration deadlines survive snapshot and AOF restores.

## Running Tests
Test cases live under [`src/tests/`](src/tests/), grouped by subsystem and
kept separate from implementation files.

Run the tests using `zig` in the root directory of the project:
```bash
zig build test
```
This runs the server, native I/O, benchmark, and profiler tests in one suite
with a single final summary. A failing test makes the command exit with a
non-zero status. Use `zig build test-io` to run only the native I/O tests.
Test-runner arguments can be passed after `--`, for example
`zig build test -- --seed=0x1234`. Zig 0.17's build run steps forward these
arguments directly.

Run `zig build e2e` to exercise the wire protocol on port 7556 over plaintext
and TLS, including key expiry and snapshot/AOF recovery across server restarts.

## Benchmark

The benchmark runs GET-only, SET-only, and alternating GET/SET 50:50 workloads
in RAM mode, or SET-only in persistence mode. By default, each workload is run
with 1, 2, 4, 8, and 16 concurrent clients, 20-byte values, and one request in
flight. Each client uses its own preloaded key. The reported
throughput is total completed requests divided by the time from the start
signal to the last client finishing. P50/P95/P99 are nearest-rank percentiles
of client-observed **whole-batch completion latencies** in microseconds:
at pipeline depth 1 these are individual round trips, but a pipelined batch's
latency is **not divided by its request count**. The final partial batch is
included as one sample. Connection setup and preloading are excluded.

To compare network payload logging on and off, set `.log_network_payloads` in
the server config to `true` or `false` (the default is `false`). Restart the
server and run the exact same benchmark for each setting. Keep the workload,
build mode, worker count, AOF strategy, and storage paths the same; use a fresh
log/data directory for each run. This setting only controls per-request and
per-response payload logs; operational messages and errors remain enabled.

Run against a **dedicated, plaintext** instance: the benchmark overwrites keys
named `__zcached_benchmark_<client>__` and does not remove them. It does not
configure or verify the server's AOF strategy; selecting `--mode` only selects
the workloads. Use separate empty working directories so existing snapshots,
AOF files, and logs cannot affect the run. For example:

1. Build the server with `zig build -Doptimize=ReleaseFast`.
2. In an empty directory, create `config.zon` with the following content,
   choosing an unused port. Use `.no` for the RAM run and `.always` for the
   persistence run:

   ```zig
   .{
       .address = "127.0.0.1",
       .port = 17556,
       .workers = 8,
       .log_network_payloads = true, // repeat with false for the comparison
       .tls = .{ .enabled = false },
       .aof = .{
           .flush_strategy = .no, // or .always for persistence
           .path = "./data/appendonly.aof",
           .rewrite_min_size = 1000000000,
       },
   }
   ```

3. From that directory, start the built server in a separate terminal with
   `/path/to/zcached/zig-out/bin/zcached --config-path config.zon --log-path log/zcached.log`.
   From the repository root, run the matching benchmark:

   ```bash
   zig build benchmark -Doptimize=ReleaseFast -- --mode ram --port 17556 --requests 20000
   # For a separate instance configured with .always:
   zig build benchmark -Doptimize=ReleaseFast -- --mode persistence --port 17556 --requests 20000
   ```

`--host` accepts an IP address (default `127.0.0.1`), `--port` defaults to
7556, and `--requests` is an even number of requests per client (default
10,000). Results are printed to stderr. Unexpected responses or connection
errors fail the run rather than being included in results.

Additional workload options:

- `--clients N`: run only this concurrency, from 1 to 128.
- `--pipeline N`: requests per batch, from 1 to 4096 (default 1). Each client
  sends a batch, validates every ordered response, then starts the next batch.
  Concurrent sending and receiving prevent bidirectional TCP buffer deadlock
  for large mixed workloads. Pipelined clients use two additional I/O tasks,
  so their scheduling overhead is included in the measurements.
- `--value-size N`: value bytes, from 1 to 1,048,576 (default 20). Ensure the
  server's request-size and memory limits accommodate the chosen workload.

`Value MiB/s` counts one value per operation (received for GET, sent for SET),
not full wire traffic or memory bandwidth. Protocol/key overhead is excluded.
For pipelining, compare throughput and batch tail latency together.

For a heavier matrix, use the dedicated 8-worker RAM instance described above
with `.log_network_payloads = false` and `.memory = .{ .limit = 0 }`:

```bash
for size in 20 1024 16384; do
  for depth in 1 16 64; do
    zig build benchmark -Doptimize=ReleaseFast -- \
      --mode ram --port 17556 --requests 20000 \
      --clients 32 --value-size "$size" --pipeline "$depth"
  done
done
```

Repeat the matrix at least three times, varying order, and compare medians.
The load generator runs on the same host and competes with the server for CPU;
this measures local end-to-end capacity, not isolated server capacity.

### Profiling on macOS

[tools/profile.zig](tools/profile.zig) runs the benchmark together with
Apple Instruments **Time Profiler**. It requires macOS and Xcode with a working
`xcrun xctrace` (check with `xcrun xctrace list templates`).

```bash
zig build profile -Doptimize=ReleaseFast -- --duration 30 --clients 32 --requests 2000000 --pipeline 64 --value-size 20
```

The build step compiles the server, benchmark, and profiling tool before
recording. The tool starts its own isolated RAM server: 8 workers by default,
an automatically selected localhost port, unlimited memory, TLS off, payload
logging off, and AOF `.no`. It waits for server readiness, attaches to that
server's PID, and waits for the profiler's Darwin recording-start notification
before launching the benchmark. It never attaches to an existing server.

Results are retained in a new `zig-out/profile-<timestamp>/` directory:

- `profile.trace`: open with `open /path/to/profile.trace` in Instruments.
- `benchmark.txt`: throughput and whole-batch latency results.
- `profiler.log`, `server.log`, `server-output.log`: diagnostic logs.
- `config.zon`: the generated server configuration.

After both profiling and benchmarking finish successfully, the profiler
automatically opens `profile.trace` in Instruments.

Use `--output /path/to/new-directory` to choose another destination; existing
directories are rejected, not overwritten. `--workers` and `--port` override
server settings; an occupied port fails without stopping its existing owner.
`--timeout` sets the whole-run deadline in seconds (default 600, must exceed
`--duration`). Run `zig build profile -- --help` for all options.
The tool cleans up only its own child processes on completion, failure,
timeout, or handled SIGINT/SIGTERM; diagnostic files are retained.

`--duration` controls recording time, not benchmark duration. The tool waits
for both to finish; short workloads can leave an idle recording tail, while
long workloads can continue after profiling stops. The benchmark runs GET,
SET, then mixed: select the corresponding active time interval in Instruments
rather than treating the entire trace as a GET-only profile. In Call Tree,
enable **Separate by Thread** and **Invert Call Tree**; initially leave system
libraries visible to see `recvmsg`, `sendmsg`, and `kevent`. Profiler overhead
can affect throughput, so compare clean benchmark runs separately.

### Pipelining stress results

Measured on 2026-11-16, Apple M2 (8 cores, 24 GiB), macOS 27.0.1,
Zig 0.17.1, ReleaseFast client/server, localhost TCP, 8 server workers,
TLS off, payload logging off, `.memory = .{ .limit = 0 }`, AOF `.no`.
Each client used a separate key and 20,000 requests per workload.
The tables show medians of three runs per configuration; the main matrix
order was shuffled with seed 95617. A 2,000-request-per-client warmup at
pipeline 16 for each value size was excluded. Including the 64-client
trial, this covered 99 measured workload runs and 74,880,000 operations.
This compares pipeline depths on the same server build, not before/after
server optimizations.

**32 clients: throughput in ops/s**

| Workload | Value | Pipeline 1 | Pipeline 16 | Pipeline 64 | 64 vs 1 |
| --- | ---: | ---: | ---: | ---: | ---: |
| GET | 20 B | 204,306 | 2,113,790 | 5,517,224 | 27.00x |
| SET | 20 B | 199,245 | 1,743,117 | 3,116,189 | 15.64x |
| Mixed | 20 B | 180,281 | 1,399,882 | 3,113,672 | 17.27x |
| GET | 1 KiB | 200,279 | 2,068,076 | 4,303,742 | 21.49x |
| SET | 1 KiB | 194,747 | 1,384,021 | 2,079,200 | 10.68x |
| Mixed | 1 KiB | 180,730 | 1,238,136 | 2,483,707 | 13.74x |
| GET | 16 KiB | 170,974 | 642,889 | 665,172 | 3.89x |
| SET | 16 KiB | 165,363 | 349,173 | 387,050 | 2.34x |
| Mixed | 16 KiB | 153,040 | 308,058 | 367,082 | 2.40x |

**16 KiB values, 32 clients: whole-batch P99 latency in milliseconds**

| Workload | Pipeline 1 | Pipeline 16 | Pipeline 64 |
| --- | ---: | ---: | ---: |
| GET | 0.632 | 5.343 | 19.978 |
| SET | 0.763 | 4.456 | 14.859 |
| Mixed | 1.120 | 5.169 | 14.873 |

For 16 KiB GET, increasing depth from 16 to 64 added only 3.5% throughput
while increasing batch P99 from 5.34 to 19.98 ms. The depth-64 GET result
represents 10,393 MiB/s of logical values, not full wire or memory bandwidth.
Depth 16 is therefore a useful latency/throughput compromise for this case;
the best depth depends on payload and latency requirements.

## Project Layout
- `src/runtime/`: shared I/O, filesystem, and synchronization adapters.
- `src/protocol/`: protocol types, parsing, and serialization.
- `src/server/context.zig`: shared references to server resources, independent of the network supervisor.
- `src/server/network/`: server supervision, accepting connections, socket I/O, and TLS transport.
- `src/server/processing/`: request framing, command execution, and protocol errors.
- `src/server/background/`: background task scheduling and its FIFO queue.
- `src/server/storage/`: memory storage, snapshots, and AOF persistence.
- `src/tests/`: protocol, network, background, server, and E2E tests.

Startup and shutdown are coordinated in `src/main.zig`. Resource cleanup is
scoped with `defer`; background tasks stop before the resources they reference
are released. The socket transport is shared by plaintext and TLS, and buffered
stream reading uses `std.Io.Reader`.

The network server owns supervision, accept loops, and connection tasks in one
module, without separate listener objects. Each accept loop keeps its own
`max_clients` semaphore, preserving the per-worker limit. Socket listening and
TLS setup remain in the reusable `StreamServer` transport, while access checks
are a stateless function.
The runtime manages worker threads and backend lifetimes. Network tasks receive
`std.Io` explicitly, and accepted streams retain it for plaintext/TLS operations.

AOF's `everysec` flush is a recurring task on the database's background queue,
not a dedicated flush thread. Due recurring work runs before the ready FIFO;
shutdown cancels the recurring task and flushes the remaining buffer.
Network payload logs remain enabled and are written in batches of approximately
64 KiB or by a recurring one-second flush on that same queue. Shutdown drains
ready log tasks before the logger's final flush.

Socket reads go directly into the receive accumulator, with chunks growing
from 4 KiB to 64 KiB after full reads. Partial frames retain an unread offset;
consumed prefixes are reclaimed only when the next read needs tail space.

Responses are encoded directly into the transmit buffer, and command arenas
are reset after each request. Network reads copy storage values under the read
lock before encoding, so concurrent mutations cannot invalidate their payloads.
ReleaseFast/ReleaseSmall use Zig's SMP allocator; Debug/ReleaseSafe retain debug
allocation and leak checks.
With no memory limit, writes skip Fabric's limit check and its mutex. Each
shard still uses its own allocator.

## Release verification

Versioned Git tags trigger release archives for Linux x86_64 and macOS ARM64.
Plaintext and TLS server binaries are included in each archive.

Verify a downloaded archive against the release manifest:

```bash
sha256sum -c SHA256SUMS
```

Always verify `SHA256SUMS` itself through the GitHub Release UI or another
trusted source before trusting the individual archive hashes.

## Documentation
- For the 1.0.0 development roadmap, see the [roadmap](docs/roadmap.md).
- For compatibility guarantees, see the
  [backward-compatibility policy](docs/compatibility.md).
- For release history, see the [release_history.md](docs/release_history.md)
- For building/installation process please refer to the [installation.md](docs/installation.md)
- For supported types and their encodings, see the [types.md](docs/internals/types.md)
- For supported commands, see the [commands.md](docs/internals/commands.md)
- For snapshot and AOF format guarantees, see the
  [persistence format policy](docs/internals/persistence_formats.md).
- For network tasks, buffer ownership, copy paths, TLS, and shutdown behavior,
  see the [network architecture](docs/internals/network_architecture.md).

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.
