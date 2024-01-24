# zcached - A Lightweight In-Memory Cache System

Welcome to `zcached`, a nimble and efficient in-memory caching system resembling databases like Redis. This README acts as a comprehensive guide, aiding in comprehension, setup, and optimal utilization.

![zig](https://img.shields.io/badge/Zig-v0.11-0074C1?logo=zig&logoColor=white&color=%230074C1)
![tests](https://github.com/sectasy0/zcached/actions/workflows/zcached-tests.yml/badge.svg)
![build](https://github.com/sectasy0/zcached/actions/workflows/zcached-build.yml/badge.svg)

## Introduction
`zcached` aims to offer rapid, in-memory caching akin to widely-used databases such as Redis. Its focus lies in user-friendliness, efficiency, and agility, making it suitable for various applications requiring swift data retrieval and storage.

Crafted using Zig, a versatile, modern, compiled programming language, `zcached` prides itself on a zero-dependency architecture. This unique feature enables seamless compilation and execution across systems equipped with a Zig compiler, ensuring exceptional portability and deployment ease.

## Features
- **Zero-Dependency Architecture**: Entirely built using Zig, ensuring seamless execution across systems with a Zig compiler, enhancing portability.
- **Lightweight Design**: Engineered for efficiency, `zcached` boasts a small memory footprint and minimal CPU usage, optimizing performance while conserving resources.
- **Optimized Efficiency**: Prioritizing swift data handling, `zcached` ensures prompt operations to cater to diverse application needs.
- **Diverse Data Type Support**: Accommodates various data structures like strings, integers, floats, and lists, enhancing utility across different use cases.
- **Evented I/O and Multithreading**: Leveraging evented I/O mechanisms and multithreading capabilities, zcached efficiently manages concurrent operations, enhancing responsiveness and scalability.

## Installation
### Prerequisites
- [zig](https://ziglang.org/download/) (0.11.0 or newer)

### Building from Source
1. Clone the repository
```bash
git clone
```
2. Build the project
```bash
zig build
```
3. Run the executable
```bash
./zcached
```

## Running Tests
Run this command in the root directory of the project:
```bash
zig test --main-pkg-path .. tests/run.zig -lc

```

## Usage
While `zcached` lacks a CLI, you can utilize nc (netcat) from the terminal to send commands to the server.

### Example Commands

#### SET
Set a key to hold the string value. If key already holds a value, it is overwritten, regardless of its type.
```bash
echo "*3\r\n\$3\r\nSET\r\n\$9\r\nmycounter\r\n:42\r\n" | netcat -N localhost 7556
```

```bash
echo "*3\r\n\$3\r\nSET\r\n\$9\r\nmycounter\r\n%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n" | netcat -N localhost 7556
```

#### Command Breakdown:
- `*3\r\n` - number of elements in the array (commands are always arrays)
- `\$3\r\nSET\r\n` - `$3` denotes the following string as 3 bytes long, SET is the command
- `\$9\r\nmycounter\r\n` - `$9` means that the next string is 9 bytes long, `mycounter` is the key
- `:42\r\n` - `:` indicates the next string is a number, `42` is the value

#### GET
Retrieve the value of a key. If the key doesn’t exist, `-not found` is returned. GET only accepts strings as keys.
```bash
echo "*2\r\n\$3\r\nGET\r\n\$9\r\nmycounter\r\n" | netcat -N localhost 7556
```

#### PING
Returns `PONG`. This command is often used to test if a connection is still alive, or to measure latency.
```bash
echo "*1\r\n$4\r\nPING\r\n" | netcat -N localhost 7556
```

for supported types and their encodings, see [types.md](types.md)

## Todo for v1.0.0
- [ ] Support for more data types eg. Hashes, Sets, Sorted Sets. (Currently only supports Strings, Integers, Floats, Booleans, Nulls, Arrays, and HashMaps).
- [x] Create CLI Interface.
- [x] Add `SAVE` command for manual saving.
- [x] Persistance mechanism, for further usage.
- [x] Add `DBSIZE` command for getting the number of keys in the database.
- [ ] Ability to set a TTL for a key, `EXPIRE` command for set, `TTL` command for check.
- [ ] Ability to set background save interval, `BGSAVE` command.
- [x] Server events logging.
- [x] Configurable server (port, max clients, max memory, etc.).
- [x] Connections whitelisting.
- [x] Pass different configuration file path from command line.
- [ ] Client side library.
- [ ] Encrypted connections, e.g TLS 1.3 or use QUIC (Currently there is no server-side support for TLS in zig, I could use `https://github.com/shiguredo/tls13-zig`).

## Release History

### [unreleased]
- Ability to configure server listen address and port from `zcached.conf` file.
- Ability to configure max clients from `zcached.conf` file.
- Ability to configure max memory from `zcached.conf` file.
- CLI interface for server binary.
- Ability to pass different configuration file path from the command line.
- Configurable logger with the option to log to a custom file.
- Logging requests, responses, and server events.
- Introducing `DBSIZE` command to retrieve the number of keys in the database.
- Implementation of `PING` command to test connection status.
- Configurable `thread` count from `zcached.conf` file.
- Extended debug logging in the configuration.
- Ability to configure `whitelist` from `zcached.conf` file.
- Support for `HashMap` data type.
- Ability to set `proto_max_bulk_len` from `zcached.conf` file, defining the maximum length of a bulk string that can be sent to the server (default is 512MB).
- Introduction of thread-safe `TracingAllocator`.
- Evented I/O mode.
- Added a method to log requests/responses to the logger.
- Implementation of persistence mechanism (pending `SAVE` command implementation).

### [version 0.0.1] - YYYY-MM-DD (Example)
- First working version.

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.
