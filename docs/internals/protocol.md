# Wire protocol specification

This document freezes the zcached 1.0 request and response wire protocol.
The encoding is RESP-compatible at the value level, with one zcached-specific
outer frame delimiter described below.

## Terminology

A **value** is one typed protocol unit such as a bulk string, integer, array, or
map. A **frame** is exactly one top-level value followed by the zcached frame
delimiter byte `0x03` (ETX).

CRLF means the two bytes `0x0d 0x0a`.

## Transport and framing

- TCP carries a byte stream in either plaintext or TLS, according to server
  configuration. TLS begins at connection establishment; there is no STARTTLS.
- Each request is encoded as a frame ending in ETX:

  ```text
  <encoded-value>\x03
  ```

- Each response is encoded as a value followed by the same ETX delimiter.
  The delimiter is not part of the encoded value and must not be interpreted as
  application data.
- Requests may be fragmented across reads or pipelined by concatenating frames.
  A response is produced in request order.
- `0x03` cannot occur as raw framing-independent protocol data because the
  current outer transport delimiter is not length-aware. Bulk strings may
  otherwise contain arbitrary bytes, including CRLF, `0x00`, and non-UTF-8.
- Incomplete frames remain buffered until more data arrives or a configured
  timeout closes the connection. Empty frames are invalid.

## Value encoding

Lengths and counts are non-negative decimal ASCII integers. Counts cannot
exceed addressable limits. Integers are signed 64-bit decimal values.

### Simple string

```text
+<non-empty text>\r\n
```

The payload must not contain CR or LF. Simple strings are primarily status
replies such as `OK` and `PONG`.

### Bulk string

```text
$<byte-length>\r\n<payload>\r\n
```

`<byte-length>` is measured in bytes. The declared number of bytes is consumed
before the final CRLF, so payloads may contain embedded CRLF or arbitrary
binary bytes except the outer ETX delimiter. An empty payload is valid:
`$0\r\n\r\n`.

### Error

```text
-<CODE>\r\n
```

Error payloads sent by the server are stable uppercase code names. Clients may
also encode an error value, but such values cannot be stored. Server-visible
error codes are listed in [commands.md](commands.md).

### Integer

```text
:<decimal integer>\r\n
```

Values must fit in a signed 64-bit integer.

### Float

```text
,<decimal floating-point value>\r\n
```

Floats are IEEE 754 double-precision values and may use fractional and exponent
notation accepted by the zcached decimal parser.

### Boolean

```text
#t\r\n
#f\r\n
```

The request parser accepts lower- or upper-case `t` and `f`; the encoder emits
lower-case values.

### Null

```text
_\r\n
```

### Array

```text
*<count>\r\n<value-1>...<value-count>
```

Elements are recursively encoded values. Empty arrays are valid.

### Map

```text
%<pair-count>\r\n<key-1><value-1>...<key-n><value-n>
```

Each key must be a bulk string or simple string. Values may use any supported
type. Duplicate keys are resolved by the last parsed value. Empty maps are
encodable, but rejected as request values by the 1.0 parser.

### Ordered set

```text
/<count>\r\n<value-1>...<value-count>
```

Values are unique and returned in insertion order.

### Unordered set

```text
~<count>\r\n<value-1>...<value-count>
```

Values are unique, with no iteration-order guarantee.

## Commands

A client request must be an array. Its first element must be a bulk string
containing the command name; command matching is case-insensitive. Remaining
elements are command arguments:

```text
*3\r\n
$3\r\nSET\r\n
$3\r\nkey\r\n
$5\r\nvalue\r\n
\x03
```

Non-array top-level values produce `UNKNOWN_COMMAND`. Arity and argument
validation rules are command-specific and documented in
[commands.md](commands.md). `PEXPIREAT` is an internal persistence record and
is not part of the public command protocol.

## Responses

A successful command writes the type encoded by that command, followed by ETX.
Examples:

```text
+OK\r\n\x03
:42\r\n\x03
$5\r\nhello\r\n\x03
_\r\n\x03
```

Errors use:

```text
-<CODE>\r\n\x03
```

Protocol errors do not close the connection. A client may continue sending
additional frames after receiving one. Transport, timeout, and I/O failures
may close the connection.

## Limits and malformed input

- The configured request-size limit applies to a complete accumulated frame
  and returns `PAYLOAD_EXCEEDED`.
- The configured bulk-string limit applies to every parsed bulk length and
  returns `PAYLOAD_EXCEEDED`.
- Missing or incorrect CRLF, invalid numeric syntax, truncated payloads,
  unsupported type markers, and malformed values return the documented stable
  error code for that parser failure.
- An encoder error rolls back any partial response for the current command and
  emits an error response instead.

## 1.x compatibility

Type markers, value layouts, CRLF rules, the outer ETX frame delimiter,
response order, and documented command response types are stable through the
1.x major line.
