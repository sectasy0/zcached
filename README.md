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
- **Diverse Data Type Support**: Accommodates various data structures like strings, integers, floats, and lists, enhancing utility across different use cases.
- **Concurrent I/O**: Networking uses Zig's `std.Io.net` interface with cancellable connection tasks and backpressure. TLS uses OpenSSL memory BIOs, so encrypted socket traffic also goes through `std.Io`.
- **TLS Support**: Ensures secure data transmission with encryption, protecting data integrity and confidentiality during client-server communication.

The runtime uses a custom Zig 0.17.1 `std.Io` reactor: kqueue on macOS and
io_uring on Linux. Each `workers` entry creates an OS thread with its own
reactor; its connections run as cooperative fibers, not individual OS threads.
`max_clients` limits connections per worker. Filesystem/platform services
remain synchronous; see [network architecture](docs/internals/network_architecture.md)
for ownership, copying, cancellation, and platform requirements.

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

## Running Tests
Run the tests using `zig` in the root directory of the project:
```bash
zig build test
```
This prints individual test results and a final summary. A failing test makes the
command exit with a non-zero status.
Test-runner arguments can be passed after `--`, for example
`zig build test -- --seed=0x1234`. Zig 0.17's build run steps forward these
arguments directly.

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
the server config to `true` or `false` (the default is `true`). Restart the
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
with `.log_network_payloads = false` and `.max_memory = 0`:

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

### Pipelining stress results

Measured on 2026-11-16, Apple M2 (8 cores, 24 GiB), macOS 27.0.1,
Zig 0.17.1, ReleaseFast client/server, localhost TCP, 8 server workers,
TLS off, payload logging off, `.max_memory = 0`, AOF `.no`.
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

**64 clients, 20-byte values: saturation trial**

| Workload | Pipeline 1 ops/s | Pipeline 64 ops/s | 64 vs 1 | Batch P99, pipeline 64 (ms) |
| --- | ---: | ---: | ---: | ---: |
| GET | 211,711 | 5,789,001 | 27.34x | 2.361 |
| SET | 206,454 | 2,884,063 | 13.97x | 4.973 |
| Mixed | 195,473 | 3,403,556 | 17.41x | 2.341 |

Doubling clients did not double throughput. The 64-client, depth-64 SET
runs varied from 2,645,778 to 3,568,016 ops/s, so small differences should
not be treated as reliable improvements or regressions.

### Example results

Measured on 2026-11-16 on an Apple M2, 8 cores, 24 GiB RAM, macOS 27.0.1,
Zig 0.17.1, ReleaseFast server and benchmark, localhost TCP without TLS,
8 server workers, 20,000 requests per client and workload. Each row is a single
run with `.log_network_payloads = true`; results are not a cross-machine
comparison. RAM used AOF `.no`; persistence used `.always` with AOF rewriting
effectively disabled for this run. The latter writes each SET to the AOF file
before replying, but does **not** call `fsync`, so it is not a measurement of
crash-durable disk sync.

| Scenario | Clients | Requests | ops/s | P50 us | P95 us | P99 us |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| get | 1 | 20000 | 45246 | 19.88 | 37.13 | 57.88 |
| get | 2 | 40000 | 68414 | 23.83 | 59.17 | 90.00 |
| get | 4 | 80000 | 86870 | 36.71 | 90.42 | 135.54 |
| get | 8 | 160000 | 104253 | 56.00 | 153.00 | 263.96 |
| get | 16 | 320000 | 158430 | 74.96 | 223.96 | 375.79 |
| set | 1 | 20000 | 48605 | 19.46 | 26.63 | 37.25 |
| set | 2 | 40000 | 82951 | 22.96 | 34.75 | 51.92 |
| set | 4 | 80000 | 112748 | 29.75 | 67.38 | 94.79 |
| set | 8 | 160000 | 104710 | 53.50 | 145.75 | 233.88 |
| set | 16 | 320000 | 145058 | 74.38 | 279.42 | 496.83 |
| mixed | 1 | 20000 | 49162 | 19.38 | 25.79 | 34.83 |
| mixed | 2 | 40000 | 63924 | 23.42 | 52.00 | 102.54 |
| mixed | 4 | 80000 | 99643 | 31.63 | 81.33 | 118.13 |
| mixed | 8 | 160000 | 97417 | 53.42 | 178.96 | 341.88 |
| mixed | 16 | 320000 | 129109 | 72.75 | 294.33 | 605.92 |
| persistence | 1 | 20000 | 34581 | 26.50 | 39.88 | 85.79 |
| persistence | 2 | 40000 | 59229 | 30.67 | 54.04 | 106.08 |
| persistence | 4 | 80000 | 65683 | 46.33 | 119.96 | 191.04 |
| persistence | 8 | 160000 | 70820 | 72.04 | 232.13 | 426.67 |
| persistence | 16 | 320000 | 68913 | 94.42 | 465.88 | 1386.96 |

### Additional RAM run: direct GET serialization

Measured on 2026-11-16 after changing GET to serialize stored values directly
into the response buffer. ReleaseFast server and benchmark, localhost TCP
without TLS, 8 server workers, 10,000 requests per client and workload,
`.log_network_payloads = false`, and AOF `.no`. Each row is a single run; these
results are not an apples-to-apples comparison with the example above because
the logging setting and request count differ.

| Scenario | Clients | Requests | ops/s | P50 us | P95 us | P99 us |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| get | 1 | 10000 | 48870 | 18.17 | 39.33 | 52.71 |
| get | 2 | 20000 | 85704 | 21.29 | 41.33 | 64.08 |
| get | 4 | 40000 | 141901 | 24.17 | 48.54 | 66.13 |
| get | 8 | 80000 | 167771 | 42.04 | 78.25 | 109.67 |
| get | 16 | 160000 | 201668 | 67.58 | 135.71 | 186.75 |
| set | 1 | 10000 | 53354 | 18.00 | 23.00 | 33.63 |
| set | 2 | 20000 | 90534 | 20.96 | 30.17 | 50.96 |
| set | 4 | 40000 | 140143 | 24.46 | 49.13 | 68.13 |
| set | 8 | 80000 | 170456 | 39.21 | 85.83 | 123.71 |
| set | 16 | 160000 | 202904 | 68.88 | 142.83 | 208.08 |
| mixed | 1 | 10000 | 53438 | 17.92 | 23.63 | 35.63 |
| mixed | 2 | 20000 | 91107 | 20.96 | 30.04 | 49.08 |
| mixed | 4 | 40000 | 140226 | 24.58 | 48.67 | 67.25 |
| mixed | 8 | 80000 | 165236 | 39.75 | 85.54 | 120.67 |
| mixed | 16 | 160000 | 202231 | 67.17 | 147.13 | 203.17 |

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
When `.max_memory = 0` (unlimited), storage uses the base allocator directly,
without allocation tracking or the tracing allocator's mutex. A nonzero limit
enables allocation tracking and the existing memory-limit checks.

## Documentation
- For release history, see the [release_history.md](docs/release_history.md)
- For building/installation process please refer to the [installation.md](docs/installation.md)
- For supported types and their encodings, see the [types.md](docs/internals/types.md)
- For supported commands, see the [commands.md](docs/internals/commands.md)
- For network tasks, buffer ownership, copy paths, TLS, and shutdown behavior,
  see the [network architecture](docs/internals/network_architecture.md).

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.
