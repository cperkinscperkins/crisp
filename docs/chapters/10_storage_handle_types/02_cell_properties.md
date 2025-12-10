## Cell Properties


A `cell` has these mutable properties:

| Property | Type    | Description |
| ---------|---------|-------------|
| parent   | storage | address of a "parent" storage |
| offset   | ulong   | offset into parent. |

`(offset~ someCell)` `(parent~ someCell)` can be used to access (or change) the `cell` view.
Note that out-of-bounds checks are not enabled by default. Certain compiler flags (like `--runtime-checks`) will enable them.

These property access functions are overloadable. It would be unwise to overload them for all `cell`s. Use `def-derived-type` 
to define your own cell type and overload those property accesses. The `~offset~` and `~parent~` functions
can also be used, and those cannot be overloaded. 


