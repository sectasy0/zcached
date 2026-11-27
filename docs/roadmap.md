# zcached 1.0.0 Roadmap

The 1.0.0 release should provide a stable, production-capable cache server,
a documented wire protocol, persistent storage with predictable recovery, and
a supported C API for client integration.

This roadmap describes goals and acceptance criteria for 1.0.0. It does not
commit to a delivery date.

## Status legend

- ✅ Ready in the current implementation
- ◐ Partially implemented or verified
- ❌ Not implemented or not yet proven complete
- 🧪 Implemented with automated coverage

**Overall status:** pre-1.0 implementation; core storage, network, TLS, snapshots,
and AOF are substantially advanced, while protocol completion, authentication,
the C API, corruption handling, and release hardening remain incomplete.

## 1. Protocol and command stability

**Status:** ✅ complete

- ✅ A RESP-compatible command parser and the core command set are implemented.
- 🧪 Unit and E2E coverage exists for commands, expiration, copy/rename,
  multiple-key operations, and the newly added `GSET`.
- ✅ Command syntax, behavior, complexity, responses, and validation errors are
  documented in [commands.md](internals/commands.md).
- 🧪 CI runs unit and E2E suites on Linux and macOS.
- ✅ Froze the RESP-compatible request and response format in the
  [wire protocol specification](internals/protocol.md).
- ✅ Command errors return stable codes without descriptive or request-provided
  text; diagnostic logs share the timestamp/severity format and strip legacy
  decoration markers.
- ✅ Marked `PEXPIREAT` as an internal AOF replay record and excluded it from
  the public command listing.
- ✅ Finalized the public command set and excluded internal replay commands from
  the public command listing.
- ✅ Added `INFO`, `COMMAND`, and `CLIENT` commands for basic introspection.
- ✅ Added the remaining standard cache operations required by the 1.0 API:
  `MSETNX`, `INCR`, `DECR`, `APPEND`, and `SIZEOF` (zcached's string-size
  command).
- ✅ Documented the scalar and compound values supported by the protocol and
  storage, including unsupported empty/binary string parser cases and the lack
  of set-specific member commands.
- ✅ Established backward-compatibility rules for commands, response types,
  and configuration fields in the [compatibility policy](compatibility.md).

Acceptance criteria:

- Every public command has syntax, behavior, complexity, and error
  documentation.
- Command tests cover valid inputs, invalid arity, wrong types, expiry, and
  persistence behavior.
- The wire protocol has conformance tests independent of server internals.

## 2. Storage and persistence

**Status:** ◐ partially complete

- ✅ Timestamped `.zcpf` snapshots with atomic replacement and retention.
- ✅ Snapshot and AOF TTL metadata using absolute deadlines.
- ✅ AOF flush strategies and background AOF rewrite.
- 🧪 Snapshot, replay, rewrite, expiry, and TTL unit/E2E coverage exists.
- ✅ Documented the CRC-bearing `zcpf` snapshot format and the headerless AOF v1
  format, with 1.x compatibility and future format-change rules in the
  [persistence format policy](internals/persistence_formats.md).
- ✅ Add integrity and corruption handling for snapshot and AOF files.
- ◐ Implement asynchronous save support (`ASAVE`); AOF rewrite is implemented.
- ✅ Applied snapshot retention to manual and scheduled saves, including
  protection for the just-completed snapshot, and documented snapshot-then-AOF
  recovery precedence.
- 🧪 Crash-recovery E2E tests cover abrupt process termination and partially
  written snapshot and AOF files, followed by new writes and another restart.
- 🧪 Fault-injection tests simulate disk-full errors during snapshot and AOF
  writes and syncing, and verify recovery after space becomes available.
- 🧪 Verify TTL, `COPY`, `RENAME`, `GSET`, and replay behavior across the
  available persistence modes.

Acceptance criteria:

- Snapshots and AOF recovery pass repeated restart and crash tests.
- Startup reports a clear, actionable error for corrupt or incompatible files.
- Persistence format compatibility is documented for 1.0.0 upgrades.

## 3. Security and operational behavior

**Status:** ◐ partially complete

- ✅ TLS support is available for server and E2E client builds.
- ✅ Per-worker client limits, idle/request timeouts, and pending-response
  limits are implemented.
- ✅ IP whitelisting and configurable memory/request-related limits exist.
- 🧪 Linux and macOS TLS builds and network timeout tests run in CI.
- ❌ Add authentication, including `AUTH` and a supported password configuration.
- ❌ Add ACL or role configuration, or explicitly keep 1.0.0 authentication scoped
  to a small, documented password-based model.
- ✅ Added configurable request, pipeline-command, batch-response, and
  single-response limits, including bounds for malformed collection counts.
- ✅ Graceful shutdown and startup diagnostics are implemented: startup failures
  identify the lifecycle phase, network readiness is logged, SIGTERM/SIGINT are
  distinguished, worker shutdown is coordinated, and AOF is flushed on exit.
- ✅ TLS now validates credential and CA requirements at startup, loads PEM
  certificate chains, rejects TLS requests in plaintext-only builds, and
  disables payload logging by default. Client-certificate verification remains
  opt-in to preserve ordinary TLS client compatibility.
- ✅ Published an [operational guide](operations.md) covering logs, resource
  limits, snapshots, AOF, Docker, systemd, monitoring, and recovery checks.

Acceptance criteria:

- TLS and authentication have positive and negative integration tests.
- Boundaries for active connections, pending responses, input size, memory,
  and request timeouts are documented.
- The server shuts down cleanly without invalidating persistence guarantees.

## 4. C API and official client

**Status:** ❌ not started

The release will include a supported C API, with its ABI and behavior covered
by separate documentation and conformance tests.

Proposed surface:

```c
typedef enum zcached_result {
    ZCACHED_RESULT_OK = 0,
    ZCACHED_RESULT_NOT_FOUND,
    ZCACHED_RESULT_INVALID_ARGUMENT,
    ZCACHED_RESULT_INVALID_RESPONSE,
    ZCACHED_RESULT_SERVER_ERROR,
    ZCACHED_RESULT_CONNECTION_CLOSED,
    ZCACHED_RESULT_TIMEOUT,
    ZCACHED_RESULT_IO_ERROR,
    ZCACHED_RESULT_TLS_ERROR,
    ZCACHED_RESULT_OUT_OF_MEMORY
} zcached_result;

typedef enum zcached_command {
    ZCACHED_COMMAND_PING,
    ZCACHED_COMMAND_GET,
    ZCACHED_COMMAND_SET,
    ZCACHED_COMMAND_GSET,
    ZCACHED_COMMAND_EXPIRE,
    ZCACHED_COMMAND_TTL,
    ZCACHED_COMMAND_PERSIST,
    ZCACHED_COMMAND_DELETE,
    ZCACHED_COMMAND_FLUSH,
    ZCACHED_COMMAND_MGET,
    ZCACHED_COMMAND_MSET,
    ZCACHED_COMMAND_MSETNX,
    ZCACHED_COMMAND_INCR,
    ZCACHED_COMMAND_DECR,
    ZCACHED_COMMAND_APPEND,
    ZCACHED_COMMAND_DBSIZE,
    ZCACHED_COMMAND_SAVE,
    ZCACHED_COMMAND_KEYS,
    ZCACHED_COMMAND_LASTSAVE,
    ZCACHED_COMMAND_SIZEOF,
    ZCACHED_COMMAND_RENAME,
    ZCACHED_COMMAND_ECHO,
    ZCACHED_COMMAND_COPY,
    ZCACHED_COMMAND_INFO,
    ZCACHED_COMMAND_COMMAND,
    ZCACHED_COMMAND_CLIENT
} zcached_command;

typedef struct zcached_value zcached_value;

typedef struct zcached_request {
    zcached_command command;
    const zcached_value *arguments;
    size_t argument_count;
} zcached_request;

zcached_client *zcached_connect(const zcached_options *options);
void zcached_close(zcached_client *client);

zcached_result zcached_ping(zcached_client *client);
zcached_result zcached_get(zcached_client *client, const char *key,
                           zcached_value **value);
zcached_result zcached_set(zcached_client *client, const char *key,
                           const zcached_value *value);
zcached_result zcached_delete(zcached_client *client, const char *key);

zcached_pipeline *zcached_pipeline_create(zcached_client *client);
zcached_result zcached_pipeline_add(zcached_pipeline *pipeline,
                                    zcached_request *request);
zcached_result zcached_pipeline_execute(zcached_pipeline *pipeline);
void zcached_pipeline_free(zcached_pipeline *pipeline);
void zcached_value_free(zcached_value *value);
```

`zcached_result` provides a stable operation status consistently across
single-command and pipeline calls. It replaces untyped integer status codes.
Detailed server or transport diagnostics, if exposed, will use a separate
opaque error value so ownership remains explicit.
Pipeline requests use RESP-neutral command and argument data. The request and
its referenced strings are borrowed only for the duration of
`zcached_pipeline_add`; the pipeline copies the complete request before the
function returns.
`zcached_value` is an opaque handle backed by the existing Zig protocol value
type. Its tagged-union layout and allocator details are not exported through
the C ABI. Returned values are owned by the caller and released with
`zcached_value_free`; values supplied to `SET` or pipeline requests remain
caller-owned. Type-safe constructors and accessors for all scalar and compound
value variants are part of the final public header.

The final API may differ during API review, but 1.0.0 must provide:

- ❌ Stable public headers and ABI versioning.
- ❌ A small handle-based client API without exposing protocol internals.
- ❌ Connection pooling or a documented pattern for sharing work across threads.
- ❌ Automatic reconnect policy and configurable connect, read, write, and idle
  timeouts.
- ❌ RESP serialization, pipelining, TLS, and ordered response handling.
- ❌ Explicit ownership rules for strings, results, errors, and pipelines.
- ❌ Thread-safety documentation for each exported type.
- ❌ Shared library and static library builds.
- ❌ C examples for basic commands and pipelining.
- ❌ Bindings or examples for a Zig client if a separate C ABI is not sufficient
  for supported ecosystem use.

Acceptance criteria:

- The C API passes client/server integration tests over plaintext and TLS.
- API names, ABI versions, exported symbols, and ownership rules are
  documented.
- Network failures, timeouts, reconnects, and partial pipeline responses have
  deterministic behavior and tests.
- A downstream C program can build and link against a packaged release.

## 5. Reliability and performance

**Status:** ◐ partially complete

- 🧪 Unit, native I/O, benchmark, profiler, network, and E2E tests are in the
  build/test system.
- 🧪 Tests and E2E suites run on Linux and macOS in GitHub Actions.
- ✅ Benchmark and profiling tools are implemented and documented.
- ✅ Linux and macOS plaintext/TLS builds run in CI.
- ◐ Run unit, protocol, network, AOF, snapshot, E2E, and C API suites in CI.
- ◐ Add race, allocator, and resource-leak detection to relevant build modes.
- ❌ Add long-running soak tests and high-concurrency stress tests.
- ◐ Test Linux and macOS on x86_64 and aarch64 where supported.
- ◐ Test Debug, ReleaseSafe, and ReleaseFast builds.
- ◐ Publish benchmark methodology and regression thresholds.
- ◐ Define acceptable behavior for memory limits, client limits, malformed
  requests, and backpressure.

Acceptance criteria:

- Release builds pass on every supported platform and architecture.
- No known crashes or resource leaks remain in release-blocking tests.
- Benchmarks show no unapproved regressions against the 1.0 baseline.
- The benchmark report distinguishes throughput, tail latency, and host
  resources.

## 6. Packaging and documentation

**Status:** ◐ partially complete

- ✅ Native Linux/macOS build workflows exist.
- ✅ Docker packaging and Docker image publishing on releases exist.
- ◐ Installation, command, type, network, and benchmark documentation exists.
- ✅ Release workflows package Linux and macOS archives and publish a combined
  SHA-256 manifest named `SHA256SUMS`.
- ◐ Publish Linux and macOS builds plus an official Docker image.
- ❌ Package the C API headers and shared/static libraries.
- ◐ Add a complete user guide and migration guide.
- ❌ Add a 1.0.0 changelog and update the release history.
- ◐ Document supported platforms, Zig requirements, OpenSSL requirements, and
  container requirements.
- ◐ Add examples for server startup, persistence, TLS, C API usage, and ZON
  configuration.

Acceptance criteria:

- A clean-environment installation follows documented steps without
  repository-only assumptions.
- Docker and native builds start, serve requests, recover persistence data, and
  expose the C API consistently.
- Public documentation contains no instructions for features that are not
  implemented.

## 7. Release process

1. Freeze the protocol and C API for the release candidate.
2. Publish `1.0.0-rc.1` for interoperability and packaging feedback.
3. Run the complete test matrix and 24-hour soak tests.
4. Resolve release-blocking protocol, persistence, security, and ABI issues.
5. Publish migration notes, changelog, source archive, packages, Docker image,
   and C API artifacts.
6. Tag and publish stable `1.0.0`.

## 1.0.0 exit criteria

The 1.0.0 release is ready when all of the following are true:

- Public commands and wire responses are documented and stable.
- Authentication and TLS behavior are supported and tested.
- Snapshot and AOF recovery are predictable and crash-safe.
- Public persistence formats have compatibility guarantees.
- The C API has a stable, versioned ABI and documented ownership rules.
- The C API works in plaintext and TLS integration tests.
- Native and Docker releases pass clean-environment tests.
- The full suite passes on every supported platform.
- No known release-blocking data-loss, memory-safety, protocol, or security
  defects remain.
- Benchmark and soak-test baselines are published.
- The release includes migration, upgrade, and support documentation.
