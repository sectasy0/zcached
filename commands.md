## zcached supported commands

This documentation page provides a comprehesive guid to the commands supported by zcached, including their usage and sytanx.


### PING

Checks if the server is running.

```sh
PING
```

### GET

Get the value associated with key, returns `not found` error if key not found.

```sh
GET <key>
```

### SET

Set the value of a key.
```sh
SET <key> <value>
```

### DELETE

Delete a key and its associated value. If everythings is okay `OK` returned, if not found `not found` error.

```sh
DELETE <key>
```

### FLUSH

Remove all keys and their values from the database.

```sh
FLUSH
```

### DBSIZE

Returns the number of keys in the database.

```sh
DBSIZE
```

### SAVE

Saves actuall database schema with data into disk.

```
SAVE
```
