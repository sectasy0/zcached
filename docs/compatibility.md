# Backward-compatibility policy

This policy defines the compatibility contract for public commands, wire
responses, and documented configuration fields. Persistence files and the C
API have separate compatibility requirements.

## Versioning

Starting with `1.0.0`, zcached follows semantic versioning:

- **Patch** releases fix defects without intentionally changing documented
  behavior or compatibility.
- **Minor** releases may add commands, response details, and configuration
  fields, provided existing clients and configurations continue to work.
- **Major** releases may make documented breaking changes and must include
  migration notes.

Before `1.0.0`, compatibility is not guaranteed. Breaking changes should still
be called out in release notes when practical.

## Commands and responses

- Existing public command names, syntax, argument behavior, semantics, and
  documented complexity are stable within a major version.
- A command may be deprecated in a minor release, but remains available until
  the next major release. Deprecation and its replacement must be documented.
- Adding a new command or an optional argument is compatible only if existing
  invocations retain their behavior.
- Existing response types, framing, and meanings are stable within a major
  version. Changing a command's response type or changing the meaning of an
  existing field is a breaking change.
- Existing error codes and the `-<CODE>` error response form are stable. New
  error codes may be added; clients should handle unrecognized codes
  generically.
- Additive response fields may be introduced in a minor release. Clients
  should ignore fields they do not recognize.

## Configuration

- Documented configuration fields and their meanings are stable within a major
  version.
- New fields may be added in a minor release only when their defaults preserve
  existing behavior.
- Renaming or removing a field, changing its meaning, or changing its default
  in a way that changes behavior is a breaking change.
- Breaking configuration changes require migration notes that identify the
  old and replacement fields and explain any required value changes.
- Undocumented fields and the handling of malformed or unknown configuration
  entries are not part of the compatibility contract.
