## Supported commands
This documentation page provides a comprehesive guid to the commands supported by zcached, including their usage and sytanx.

The request and response representation, including the zcached frame
delimiter, is defined by the [wire protocol specification](protocol.md).

Command errors use the common `-<CODE>\r\n` response followed by the
zcached frame terminator. Replies contain stable error codes only; they do not
include descriptive text or request-provided values.

| Code | Meaning |
| --- | --- |
| `UNKNOWN_COMMAND` | Command is not recognized. |
| `INVALID_TYPE` | A value has an unsupported type. |
| `KEY_NOT_STRING` | A key must be a string. |
| `INVALID_COMMAND` | Command syntax or arity is invalid. |
| `INVALID_ARGUMENTS` | Command arguments are invalid. |
| `NOT_FOUND` | The requested key does not exist. |
| `MEMORY_LIMIT_EXCEEDED` | A mutation cannot be admitted because the memory limit is reached. |
| `BUSY_KEY` | The destination key already exists. |
| `INVALID_EXPIRY` | An expiration value is invalid. |
| `INVALID_LENGTH` | A protocol length is invalid. |
| `PAYLOAD_EXCEEDED` | The request payload exceeds its configured limit. |
| `RESPONSE_TOO_LARGE` | One encoded response exceeds its configured limit. |
| `MAX_CLIENTS_REACHED` | The connection limit has been reached. |
| `NOT_WHITELISTED` | The client address is not allowed. |
| `SAVE_FAILURE` | A snapshot could not be saved. |
| `UNPROCESSABLE` | The request could not be parsed. |
| `INTERNAL_ERROR` | An unexpected error occurred. |

Unless a command documents a different error, a missing or extra argument
returns `-INVALID_COMMAND`, a non-string key returns `-KEY_NOT_STRING`, and an
unsupported value type returns `-INVALID_TYPE`. Empty `MGET` and malformed
multi-key syntax in `MSET` or `MSETNX` return `-INVALID_ARGUMENTS`. Missing
storage keys return `-NOT_FOUND` when the command is lookup-oriented; commands
with an explicitly documented integer return for missing keys use that result
instead.

`PEXPIREAT` is an internal AOF replay record, not a public command. Clients
cannot invoke it directly, and `COMMAND` does not list it.

### PING

**Available since**: 0.0.1\
**Time complexity**: O(M), where M is the encoded size of the stored value

Checks if the server is running.

```sh
PING
```

### INFO

**Time complexity**: O(N), where N is the number of live keys

Returns server and key-space metadata as a bulk string.

```sh
INFO
```

The response includes the zcached version, configured limits, TLS status,
connection and traffic counters, limit rejections, persistence state, key
count, and estimated storage memory usage. Monotonic `_total` counters reset
at process startup; `connections_active` and resource usage are gauges.

### COMMAND

**Time complexity**: O(C) for the list, O(1) for `COUNT`

Returns the public command names or the command count.

```sh
COMMAND
COMMAND COUNT
```

### CLIENT

**Time complexity**: O(1)

Returns basic connection metadata.

```sh
CLIENT LIST
CLIENT ID
```

### GET

**Available since**: 0.0.1\
**Time complexity**: O(M), where M is the copied value size; O(1) for scalar
values

Gets the value associated with a string key. Returns `-NOT_FOUND` if the key
does not exist.

```sh
GET <key>
```

### SET

**Available since**: 0.0.1\
**Time complexity**: O(1)

Set the value of a key.
```sh
SET <key> <value> [EX <seconds> | PX <milliseconds>]
```

The lifetime must be a positive integer when specified. An ordinary `SET`
(or `MSET`) clears the previous expiry, even when replacing an equal value.

### GSET

**Time complexity**: O(M), where M is the size of a compound stored value; O(1)
for scalar values

```sh
GSET <key> <value>
```

Returns the existing value without changing it or its expiry. If the string key
is missing or expired, atomically stores the supplied value without an expiry
and returns the stored value, just like `GET` after the insert.

### EXPIRE

**Time complexity**: O(1)

`EXPIRE <key> <seconds>` updates the lifetime of an existing key. Returns `1`
on success or `0` if the key is missing or already expired. A non-positive
lifetime deletes the key immediately.

### TTL

**Time complexity**: O(1)

`TTL <key>` returns the remaining lifetime rounded to the nearest second, `-1`
for a persistent key, or `-2` for a missing or expired key.

### PERSIST

**Time complexity**: O(1)

`PERSIST <key>` removes an existing expiry and returns `1`. It returns `0` if
the key is missing, expired, or already persistent.

`RENAME` and `COPY` preserve the source's absolute deadline. Expired keys are
hidden immediately from reads and enumeration, and reclaimed in the background.
Snapshots continue to read the original `zcpf` format; snapshots containing
expiry metadata use the same `zcpf` deadline field. Both snapshots and AOF store absolute Unix
deadlines rather than restarting the original lifetime during recovery. See
[persistence format compatibility](persistence_formats.md) for the on-disk
format details and upgrade guarantees.

### DELETE

**Available since**: 0.0.1\
**Time complexity**: O(M) for a key holding a compound value, where M is the
number of nested array, map, or set elements that must be freed. Scalar values
are removed in O(1).

Deletes a key and its associated value. Returns `OK` on success or
`-NOT_FOUND` if the key does not exist.

```sh
DELETE <key>
```

### FLUSH

**Available since**: 0.0.1\
**Time complexity**: O(N + M), where N is the number of keys and M is the total
nested value count to free

Delete all the keys from database. This command never fails.

```sh
FLUSH
```

### DBSIZE

**Available since**: 0.0.1\
**Time complexity**: O(N), where N is the number of live keys across all shards

Returns the number of keys in the database.

```sh
DBSIZE
```

### SAVE

**Available since**: 0.0.1\
**Time complexity**: O(N + M), where N is the number of keys and M is the total
serialized value size

`SAVE` performs a synchronous save of the dataset, producing a point-in-time
snapshot of all data in the zcached instance in `.zcpf` format. There is no
asynchronous `ASAVE` command.

```sh
SAVE
```

### MGET

**Available since**: 0.0.1\
**Time complexity**: O(N + M), where N is the number of keys and M is the total
copied value size

Returns the values of all specified keys. For every key that does not exist,
the special value `null` is returned. Existing values are returned regardless
of their stored type.

```sh
MGET <key1> <key...>
```

### MSET

**Available since**: 0.0.1\
**Time complexity**: O(N + M), where N is the number of pairs and M is the total
copied value size

Sets the given keys to their respective values. `MSET` replaces existing
values just like `SET`.

```sh
MSET key value [key value ...]
```

### MSETNX

**Time complexity**: O(N + M), where N is the number of pairs and M is the
total copied value size

Atomically sets the given key/value pairs only if none of the keys exists.
Returns `1` when all pairs are stored, or `0` when any key already exists. In
the latter case no value is changed or inserted. Repeated keys in one request
are evaluated as part of the same atomic operation.

```sh
MSETNX key value [key value ...]
```

### INCR

**Time complexity**: O(L), where L is the stored integer's decimal length

Atomically increments the integer value at a key by one and returns the new
value. Missing keys start at zero. Integer-valued bulk strings are accepted and
remain stored as strings. Expiry is preserved, and non-integer values or
integer overflow return `-INVALID_TYPE`.

```sh
INCR key
```

### DECR

**Time complexity**: O(L), where L is the stored integer's decimal length

Atomically decrements an integer value by one. Its missing-key, type, overflow,
and expiry behavior is the same as `INCR`.

```sh
DECR key
```

### APPEND

**Time complexity**: O(L + S), where L is the existing length and S is the
appended byte length

Appends the supplied string to a stored string and returns the new byte length.
If the key does not exist, it is created with the supplied value. The existing
expiry is preserved; non-string values return `-INVALID_TYPE`.

```sh
APPEND key value
```

### KEYS

**Available since**: 0.0.1\
**Time complexity**: O(N) where N is the total number of keys in databases

Returns all keys matching in database.

```sh
KEYS
```

### LASTSAVE

**Available since**: 0.0.1\
**Time complexity**: O(1)

Returns the Unix timestamp of the last successful DB save.
If there wasn't any successful save, it returns the startup timestamp.
Because of this, the operation never fails.

```sh
LASTSAVE
```

### SIZEOF

**Available since**: 0.1.0\
**Time complexity**: O(1)

Returns the size of the specified key based on its type. `SIZEOF` is the
zcached name for the string-length operation commonly called `STRLEN`.
The size is calculated according to the following criteria:

| Type                       | Description                           |
|----------------------------|---------------------------------------|
| String / Simple string     | Length of the string.                 |
| Array                      | Number of elements in the array.      |
| Map                        | The count of key-value pairs.         |
| Ordered / unordered set    | Number of elements in the set.        |
| Integer                    | Number of bytes the integer occupies. |
| Float                      | Number of bytes the float occupies.   |
| Null                       | Always zero.                          |
| Boolean                    | Always one.                           |

```sh
SIZEOF <KEY>
```

### ECHO

**Available since**: 0.1.0\
**Time complexity**: O(1)

The `ECHO` command is used to return the given string as a response.
For example: `ECHO Hello Neptun!` should return `Hello Neptun!`.

```sh
ECHO <Message>
```

### RENAME

**Available since**: 0.1.0\
**Time complexity**: O(M), where M is the copied nested value size; O(1) for
scalar values

The `RENAME` command renames an existing key to a new key. 
If the new key already exists, it will be overwritten by the old key's value.

```sh
RENAME <Old key> <New key>
```

### COPY

**Available since**: 0.1.0\
**Time complexity**: O(N) where N is the number of nested items. O(1) for string values.

This command copies the value stored at the source key to the destination key.
The command returns error when the destination key already exists. 
The optional `REPLACE` param removes the destination key before copying the value to it.

```sh
COPY <source> <destination> [REPLACE]
```