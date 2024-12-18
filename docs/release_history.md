## Release History

### [unreleased] 31.05.2024 -> Today:
- feat(command): `MSET` and `MGET` for seting and geting multiple keys at once.
- fix: arrays and maps should be freed after returning to the client.
- feat(command): `KEYS` command for getting all database keys.
- fix: panic caused by unhandled command_set length.
- feat(command): `LASTSAVE` command to get the last db save timestamp.
- refactor(logger): create a new log file if the previous one is too big.
- feat: update zcached to use 0.12.0 zig version.
- feat: add fixtures for tests.
- feat(command): `SIZEOF` command for efficient data size retrieval.
- fix: memory leak after override with put.
- fix: show error message if address is not available (noticed in docker).
- fix: show error message when config is not a file.
- feat: update zcached to use 0.13.0 zig version.
- chore: add docker to help other people run zcached
- feat(command): add `ECHO` command implementation.
- feat(command): `RENAME` command implementation.
- feat(command): `COPY` command implementation.
- feat: systemd integration.
- feat: use .zon (Zig Object Notation) as a config format.

### [0.0.1-alpha] 31.05.2024
- feat: first working version.
- feat(config): ability to configure server listen address and port from `zcached.conf` file.
- feat(config): ability to configure max clients from `zcached.conf` file.
- feat(config): ability to configure max memory from `zcached.conf` file.
- feat: cli interface for server binary.
- feat(cli): ability to pass different configuration file path from the command line.
- feat(logger): configurable logger with the option to log to a custom file.
- feat(logger): logging requests, responses, and server events.
- feat(command): Introducing `DBSIZE` command to retrieve the number of keys in the database.
- feat(command): implementation of `PING` command to test connection status.
- feat(config): configurable `thread` count from `zcached.conf` file.
- feat(logger): extended debug logging in the configuration.
- feat(config): ability to configure `whitelist` from `zcached.conf` file.
- feat: support for `HashMap` data type.
- feat(config): ability to set `proto_max_bulk_len` from `zcached.conf` file, defining the maximum length of a bulk string that can be sent to the server (default is 512MB).
- feat: evented input/output mode.
- feat: Implementation of persistence mechanism.
- fix: segmentation fault after trying to get value that client send.
- feat(command): `SAVE` for dumping db to disk.
