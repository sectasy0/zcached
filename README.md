# zcached - A Lightweight In-Memory Cache System

Welcome to `zcached`, a nimble and efficient in-memory caching system resembling databases like Redis. This README acts as a comprehensive guide, aiding in comprehension, setup, and optimal utilization.

![zig](https://img.shields.io/badge/Zig-v0.13-0074C1?logo=zig&logoColor=white&color=%230074C1)
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
- **TLS Support**: Ensures secure data transmission with encryption, protecting data integrity and confidentiality during client-server communication.

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

## Documentation
- For release history, see the [release_history.md](docs/release_history.md)
- For building/installation process please refer to the [installation.md](docs/installation.md)
- For supported types and their encodings, see the [types.md](docs/internals/types.md)
- For supported commands, see the [commands.md](docs/internals/commands.md)

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.
