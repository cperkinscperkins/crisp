## Helper Functions


`(element-type~ someStorageHandle)`  a type expression that returns the type of the elements in the Storage Handle.

`(byte-size~ someStorageHandle)`  a helper function that calculates the current number of bytes in the Storage Handle.
Note that this is NOT a passthrough. If you want the total number of bytes in the parent `storage`
you'll need `(byte-size~ (parent~ someStorageHandle))`

`(num-dims-of someStorageHandle)`  returns the number of dimensions of a storage handle.
Very useful for the `tensor` type, less so for the others.

| type | dims | 
|------|------|
| cell   | 0 |
| vector | 1 | 
| matrix | 2 | 
| tensor | N | 

