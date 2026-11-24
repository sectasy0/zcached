# Protocol and stored value types

The protocol codec supports scalar and compound values. Commands are sent as
arrays; values may be nested inside arrays, maps, and sets. Storage keys must be
strings. Stored values support strings, simple strings, integers, floats,
booleans, nulls, arrays, maps, ordered sets, and unordered sets. Error values
are protocol response data and cannot be stored.

## Scalar values

### Bulk strings

Bulk strings use the `$` marker and a byte length:

```text
$<length>\r\n<content>\r\n
```

The encoder supports empty strings. The current request parser only accepts
non-empty, line-terminated content and does not validate the declared length;
embedded CRLF and empty bulk strings are therefore not supported in requests.
Do not rely on bulk strings being binary-safe until the parser is fixed.

### Simple strings

Simple strings use the `+` marker:

```text
+<content>\r\n
```

They are line-oriented, non-empty values. They are primarily used for simple
protocol responses.

### Integers

Signed 64-bit decimal integers use the `:` marker:

```text
:[+|-]<value>\r\n
```

### Floats

Floats are IEEE 754 double-precision values. Fractional and exponent parts are
optional:

```text
,[+|-]<value>[.<fraction>][e[+|-]<exponent>]\r\n
```

### Booleans

Booleans use `#t` and `#f`:

```text
#t\r\n
#f\r\n
```

### Null

Null values use the `_` marker:

```text
_\r\n
```

## Compound values

### Arrays

Arrays contain a count followed by that many recursively encoded values:

```text
*<count>\r\n<value>...
```

Empty arrays are supported. Client commands are arrays whose first value is the
command name.

### Maps

Maps contain a count followed by string-key/value pairs. Values can be nested
compound types:

```text
%<count>\r\n<key>\r\n<value>...
```

Map keys must be bulk or simple strings. The current parser rejects empty maps.

### Ordered sets

Ordered sets contain unique values and preserve insertion order:

```text
/<count>\r\n<value>...
```

### Unordered sets

Unordered sets contain unique values with no guaranteed iteration order:

```text
~<count>\r\n<value>...
```

Both set types can be stored and retrieved as values, but there are no
set-specific commands for modifying their members.

## Errors

Server errors use a code-only response followed by the zcached frame
terminator:

```text
-<ERROR_CODE>\r\n
```

The protocol parser also has an error-value variant for client-side
compatibility. It is not a storable value.
