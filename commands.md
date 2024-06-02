```
SIZEOF
```

### SIZEOF

**Available since**: 0.2.0\
**Time complexity**: O(1)

Returns the size of the specified key based on its type. 
The size is calculated according to the following criteria:

| Type                       | Description                           |
|----------------------------|---------------------------------------|
| String / Simple string     | Length of the string.                 |
| Array                      | Number of elements in the array.      |
| Map                        | The count of key-value pairs.         |
| Set (not implemented yet)  | Number of elements in the set.        |
| Integer                    | Number of bytes the integer occupies. |
| Float                      | Number of bytes the float occupies.   |
| Null                       | Always zero.                          |
| Boolean                    | Always one.                           |