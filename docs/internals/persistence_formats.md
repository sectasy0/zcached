# Snapshot and AOF format compatibility

This document describes the on-disk formats currently implemented and sets
the compatibility policy that applies starting with zcached `1.0.0`. Before
`1.0.0`, persistence formats may change without a compatibility guarantee.
For value encodings, see [types.md](types.md).

## Snapshots

Snapshots are named `dump_<timestamp>.zcpf`. The reader selects the validly
named file with the newest timestamp in the configured snapshot directory.
The payload is one count-bearing format:

```text
zcpf%N\r\n
:<crc32>\r\n
<key><value>:<deadline>\r\n
...
```

`N` is the entry count. The CRC-32 is an eight-digit hexadecimal checksum of
all key, value, and deadline bytes after the checksum header. Every entry
includes an absolute Unix-millisecond deadline; `0` means no expiry. The
reader requires this header and checksum and rejects legacy or incomplete
files. It falls back to the newest older snapshot that passes validation.

## Append-only file

The current AOF format is **AOF v1**. It is intentionally headerless for
compatibility with existing files. It consists of serialized command arrays,
each terminated by the byte `0x03`. An empty file is a valid empty journal.

An AOF rewrite creates a full-state baseline beginning with `FLUSH`, followed
by `SET` records for stored values. Values with an expiry use the `PXAT`
absolute Unix-millisecond deadline argument. Subsequent mutations are appended
as command records.

AOF replay terminates at record boundaries, skips malformed command records,
and truncates an unterminated torn tail left by an interrupted write before
accepting new writes. If truncation or syncing fails, startup aborts.
Successful AOF writes are synced before the buffered bytes are discarded.
After a write or sync failure, retrying a buffered AOF flush first removes
the incomplete or unconfirmed batch and writes it again from its original
offset. If the process crashes before retrying, a fully written record whose
sync failed may still be replayed; its durability was not confirmed.
AOF rewrites are written and synced to a separate file before an atomic
rename replaces the previous journal.

## Compatibility guarantees

Starting with `1.0.0`, compatible 1.x releases must continue to read the
single `zcpf` snapshot format with its CRC header and AOF v1. Older binaries
are not guaranteed to read files written by newer releases, so downgrading
with existing persistence files is unsupported; back up data before upgrades.

An incompatible format must not silently reuse an existing identifier. It
requires a new explicit format version and a major release, and must retain a
reader for prior formats or provide a documented migration tool.

These guarantees cover format compatibility, not recovery from corruption.
Snapshot replay requires the CRC header and validates all entries; AOF replay
may skip malformed records.
