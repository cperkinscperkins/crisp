# Per-Variable vs. Per-Reduction Arguments


Every resource a reduction uses belongs either to one variable or to the reduction as a whole.
Resources that carry the variable's type go in that variable's clause. Everything else is a
trailing key on the call.

| Argument | Where it goes | Why |
| --- | --- | --- |
| `return-cell` | clause | One destination per variable, of that variable's type. |
| `:return-vec` (`reduce-workgroup`) | clause key | One per-workgroup result vector per variable. |
| `:local-scratch-vec` | clause key | Typed like the variable. |
| `:global-scratch-vec` | clause key | Typed like the variable. |
| `active-threads` (`reduce-warp`) | trailing `&optional` | One shuffle sweep covers every variable. |
| `:strategy` | trailing key | One Phase 2 strategy for the whole call. |
| `:atomic-counter` | trailing key | One ticket covers every variable (see below). |
| `:election-flag-cell` | trailing key | Always `uint`, never follows a variable's type. |
| `:message` | trailing key | Describes the call's allocations. |

Like their single-variable counterparts, all scratch arguments are optional. If you leave one
out, Crisp generates it for you, typed from that clause's identity -- so, as above, each clause's
identity must have a visible type.

A variable may appear in only one clause of a call. Naming the same variable twice is a
compilation error.

