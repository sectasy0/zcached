# Snapshot and AOF format compatibility

This document describes the on-disk formats currently implemented and sets
the compatibility policy that applies starting with zcached `1.0.0`. Before
`1.0.0`, persistence formats may change without a compatibility guarantee.
For value encodings, see [types.md](types.md).

## Snapshots

Snapshots are named `dump_<timestamp>.zcpf`. The reader selects the validly
named file with the newest timestamp in the configured snapshot directory.
The payload is a count-bearing header followed by each key and value encoded
with the zcached protocol codec.

Two snapshot formats are supported:

- **`zcpf` (version 1):** header `zcpf%N\r\n`, followed by `N` key/value pairs.
  Entries have no expiry metadata.
- **`zcpf2` (version 2):** header `zcpf2%N\r\n`, followed by `N` key/value
  pairs. Each pair is followed by `:<deadline>\r\n`, where the deadline is an
  absolute Unix timestamp in milliseconds. Zero means no expiry.

The writer uses version 1 when no entry has an expiry and version 2 when
expiry metadata is present. The reader accepts both versions. Other or
malformed formats are not supported.

## Append-only file

The current AOF format is **AOF v1**. It is intentionally headerless for
compatibility with existing files. It consists of serialized command arrays,
each terminated by the byte `0x03`. An empty file is a valid empty journal.

An AOF rewrite creates a full-state baseline beginning with `FLUSH`, followed
by `SET` records for stored values. Values with an expiry use the `PXAT`
absolute Unix-millisecond deadline argument. Subsequent mutations are appended
as command records.

## Compatibility guarantees

Starting with `1.0.0`, compatible 1.x releases must continue to read snapshot
versions 1 and 2 and AOF v1. They may write either supported snapshot version
according to the rules above; AOF writes remain v1. Older binaries are not
guaranteed to read files written by newer releases, so downgrading with
existing persistence files is unsupported; back up data before upgrades.

An incompatible format must not silently reuse an existing identifier. It
requires a new explicit format version and a major release, and must retain a
reader for prior formats or provide a documented migration tool.

These guarantees cover format compatibility, not recovery from corruption.
The current formats do not include checksums, and AOF replay may skip
malformed records; see the roadmap's separate corruption-handling goal.
