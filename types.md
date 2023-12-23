## zcached supported data types

### Simple strings
Simple strings are encoded as (+) followed by the string content and terminated by CRLF (\r\n). To send binary-safe strings, use bulk strings.
```
+<content>\r\n
```

### Strings
Represents a binary-safe strings. They are encoded as follows:

```
$<length>\r\n<content>\r\n
```

The empty string's encoding is:

```
$0\r\n\r\n
```

### Integers
CRLF terminated strings that represent a base-10, 64-bit signed integer. They are encoded as follows:
```
:[<+|->]<value>\r\n
```

### Floats
Float type is a double precision 64-bit floating point number. Fractional part is optional. They are encoded as follows:
```
,[<+|->]<integral>[.<fractional>][<E|e>[sign]<exponent>]\r\n
```

### Booleans
Booleans are encoded as follows:
```
#<t|f>\r\n
```

### Null
The `null` type represents a non-existent value. It is encoded as follows:
```
_\r\n
```

### Arrays
Client requests are sent as arrays of bulk strings. The first element of the array is the command name, the rest are the arguments.
```
*<length>\r\n<first>\r\n<second>
```

So an empty Array is just the following:
```
*0\r\n
```

### Maps aka HashMaps
Maps are encoded as arrays of key-value pairs. The first element of the pair is the key, the second is the value.
```
%<length>\r\n<first key>\r\n<first value>\r\n<second key>\r\n<second value>
```

### Errors
```
-<error message>\r\n
```
