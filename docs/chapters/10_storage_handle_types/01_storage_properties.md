## Storage Properties


 `storage` has the following immutable properties:

| Property      | Type          |              |     Description |
| --------------|---------------|--------------|-----------------|
| bytes         | ulong         | runtime      | the number of bytes in the `storage`. This is immutable.|
| address-space | address-space | compile-time | one of `:global`, `:local`, `:constant` |
| access        | access        | compile-time | one of `:read_only` `:write_only` `:read_write` `:readable` `:writeable` |


The `bytes` property for a `storage` is sometimes known at compile time, but is most often a runtime property.
However the other properties are all known and evaluable at compile time. 

