# `base-ptr~` accessor ✅


`(base-ptr~ <storage-handle>)` returns the handle's underlying pointer in its
NATIVE address space (e.g. a global cell → a `(c-pointer :address-space :global)`).
Like `byte-size~` it is a pass-through: `(base-ptr~ someCell)` works as well as
`(base-ptr~ (parent~ someCell))`. Passing it to a foreign param of the same
address space needs no cast; differing spaces are reconciled by an
`addrspacecast` in the existing value-coercion path.

