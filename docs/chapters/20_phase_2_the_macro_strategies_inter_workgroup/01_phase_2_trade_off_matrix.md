# **Phase 2 Trade-off Matrix**


| Strategy | Supported Operations | Extra Global Memory Needed | Performance Profile |
| --- | --- | --- | --- |
| **`grid-reduce-atomic!`** | `#'+`, `#'min`, `#'max` only | **None** | **Fast.** Hardware optimized atomics. |
| **`grid-reduce-last-man!`** | Any Commutative | Size of `num_workgroups` | **Very Fast.** Single pass, zero contention. |
| **`grid-reduce-cas!`** | Any Commutative | **None** | **Slow (High Contention).** CAS loop serializes grid. |
| **`grid-reduce-second-stage!`** | Any Commutative | Size of `num_workgroups` | **Moderate.** Safe, but requires manual 2nd kernel launch. |

