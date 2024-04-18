## zcached supported commands

This documentation page provides a comprehesive guid to the commands supported by zcached, including their usage and sytanx.


### PING

**Available since**: 1.0.0\
**Time complexity**: O(1)

Checks if the server is running.

```sh
PING
```

### GET

**Available since**: 1.0.0\
**Time complexity**: O(1)

Get the value associated with key, returns `not found` error if key not found. Key should be always string.

```sh
GET <key>
```

### SET

**Available since**: 1.0.0\
**Time complexity**: O(1)

Set the value of a key.
```sh
SET <key> <value>
```

### DELETE

**Available since**: 1.0.0\
**Time complexity**: O(N) where N is the number of keys that will be removed. When a key to remove holds a value other than a string, the individual complexity for this key is O(M) where M is the number of elements in the list, set, sorted set or hash. Removing a single key that holds a string value is O(1).

Delete a key and its associated value. If everythings is okay `OK` returned, if not found `not found` error.

```sh
DELETE <key>
```

### FLUSH

**Available since**: 1.0.0\
**Time complexity**: O(N) where N is the total number of keys in databases

Delete all the keys from database. This command never fails.

```sh
FLUSH
```

### DBSIZE

**Available since**: 1.0.0\
**Time complexity**: O(1)

Returns the number of keys in the database.

```sh
DBSIZE
```

### SAVE

**Available since**: 1.0.0\
**Time complexity**: O(N) where N is the total number of keys in databases

The `SAVE` commands performs a `synchronous` save of the dataset producing a point in time snapshot of all the data inside the zcached instance, in the form of an zcpf file.

For asynchronous save check `asave` (not implemented yet).

```
SAVE
```

### MGET

**Available since**: 1.0.0\
**Time complexity**: O(N) where N is the number of keys to retrieve

Returns the values of all specified keys. For every key that does not hold a string value or does not exist, the special value `null` is returned. Because of this, the operation never fails.

```
MGET <key1> <key...>
```

### MSET

**Available since**: 1.0.0\
**Time complexity**: O(N) where N is the number of keys to set

Sets the given keys to their respective values. MSET replaces existing values with new values, just as regular SET. See MSETNX if you don't want to overwrite existing values.

```
MSET key value [key value ...]
```

### KEYS

**Available since**: 1.0.0\
**Time complexity**: O(N) where N is the total number of keys in databases

Returns all keys matching in database.

```
KEYS
```

### LASTSAVE

**Available since**: 1.0.0\
**Time complexity**: O(1)

Returns the Unix timestamp of the last successful DB save during the server runtime. If there wasn't any successful save, it returns the startup timestamp.
Because of this, the operation never fails.

```
LASTSAVE
```
