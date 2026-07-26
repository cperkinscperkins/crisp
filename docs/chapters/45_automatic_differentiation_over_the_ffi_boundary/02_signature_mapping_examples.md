# Signature mapping examples



| Forward FFI signature                                | Derived VJP signature                                                      |
|------------------------------------------------------|-----------------------------------------------------------------------------|
| `#'(float float => float)`                           | `#'(float float  float  => float float)`                                    |
| `#'(float int => int float)`                         | `#'(float int  float float  => float float)`                                |
| `#'(float => long)`                                  | `#'(float  double  => float)`  ← long-return seed is **double**             |
| `#'(float int voidp (c-handle ptr-t) => int)`        | `#'(float int voidp (c-handle ptr-t)  float  voidp  => float float)`        |
| `#'(float int voidp (c-handle ptr-t) => nil)`        | `#'(float int voidp (c-handle ptr-t)  voidp  => float float)`               |
| `#'(float int (c-handle ptr-t) => voidp)`            | DEFERRED (active-memory return)                                             |

Reading the fourth row: primals `float int voidp handle`; one `float` seed for the `int` return;
one `voidp` shadow for the `voidp` input (the handle is passive, no shadow); returns `float float`
for the `float` and `int` inputs.


