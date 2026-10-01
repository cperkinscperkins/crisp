# layout and alignment


Crisp structs follow a strict "scalar" layout.
- Basci scalar types are aligned to a multiple of their own size ( a 1-byte `char` aligns to 1, a 4-byte `float` aligns to 4, an 8-byte `double` aligns to 8).
-  A struct's overall alignment is equal to the alignment of its most strictly aligned member.  If a struct contains a `char` and a `float`, the struct's alignment is 4.
- Padding: Members are placed at the lowest available offset that satisfies their alignment. The total size of the struct is padded at the end to be a multiple of its overall alignment.
- Storage Handles - (ie `(vector someStruct)` ) The stride of a storage handle is exactly the size of the struct. Zero extra padding between elements.



