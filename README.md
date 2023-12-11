# zcached - A simple in-memory cache

Welcome to `zcached`, a lightweight and efficient in-memory caching system akin to databases like Redis. This README serves as a guide to understanding, setting up, and utilizing effectively.

## Introduction
`zcached` is designed to provide fast, in-memory caching capabilities similar to popular databases such as Redis. It aims to be user-friendly, lightweight, and efficient, making it suitable for a wide range of applications where quick data retrieval and storage are crucial.

Developed using Zig, a modern, versatile, compiled programming language, `zcached` boasts a zero-dependency architecture. This distinctive trait empowers it to seamlessly compile and execute on any system equipped with a Zig compiler, ensuring exceptional portability and ease of deployment.


## Features
- **Zero-Dependency Architecture** - `zcached` is built entirely using Zig, a modern, versatile, compiled programming language. This distinctive trait empowers it to seamlessly compile and execute on any system equipped with a Zig compiler, ensuring exceptional portability and ease of deployment.
- **Lightweight Design** - Engineered for efficiency, zcached prides itself on a lightweight structure, boasting a diminutive memory footprint and minimal CPU usage. This streamlined design optimizes performance while minimizing resource consumption.
- **Optimized Efficiency** - Emphasizing swift data retrieval and storage, zcached prioritizes efficiency at its core. Its design intricacies prioritize expeditious operations, ensuring prompt data handling for diverse application requirements.
- **Diverse Data Type Support** - With a comprehensive range of supported data types including strings, integers, floats, and lists, provides versatility in accommodating various data structures, enhancing its utility across multiple use cases.

## Installation
### Prerequisites
- [Zig](https://ziglang.org/download/) (0.11.0 or newer)

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
zig test --main-pkg-path .. tests.zig
```

## Usage
Actually `zcached` don't come with any CLI, so if you want to use it from the terminal you can use `nc` (netcat) to send commands to the server.

### Example Commands
#### SET
Set a key to hold the string value. If key already holds a value, it is overwritten, regardless of its type.
```bash
echo "*3\r\n\$3\r\nSET\r\n\$9\r\nmycounter\r\n:42\r\n" | netcat -N localhost 7556
```
explaining the command:
- `*3\r\n` - number of element in the array (commands are always arrays)
- `\$3\r\nSET\r\n` - `$3` means that the next string is 3 bytes long, `SET` is the command
- `\$9\r\nmycounter\r\n` - `$9` means that the next string is 9 bytes long, `mycounter` is the key
- `:42\r\n` - `:` means that the next string is a number, `42` is the value

#### GET
Get the value of key. If the key does not exist `-not found` is returned. GET only accepts strings as keys.
```bash
echo "*2\r\n\$3\r\nGET\r\n\$9\r\nmycounter\r\n" | netcat -N localhost 7556
```

## Todo
- [ ] Support for more data types eg. Hashes, Sets, Sorted Sets.
- [ ] Create CLI Interface.
- [ ] Add `SAVE` command.
- [ ] Ability to set a TTL for a key.
- [ ] Logging commands (to be able to replay data inside the server if it crashes).
- [ ] Server events logging.
- [ ] Configurable server (port, max clients, max memory, etc.).
- [ ] Client side library.

## Release History
* 0.0.1
		* Initial release

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.
