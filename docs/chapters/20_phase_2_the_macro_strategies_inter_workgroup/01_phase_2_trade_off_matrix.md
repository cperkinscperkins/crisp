# **Phase 2 Trade-off Matrix**


| Strategy | Supported Operations | Extra Global Memory Needed | Performance Profile |
| --- | --- | --- | --- |
| **`grid-reduce-atomic!`** | `#'+`, `#'min`, `#'max` only | **None** | **Fast.** Hardware optimized atomics. |
| **`grid-reduce-last-man!`** | Any Commutative | Size of `num_workgroups` | **Very Fast.** Single pass, zero contention. |
| **`grid-reduce-cas!`** | Any Commutative | **None** | **Slow (High Contention).** CAS loop serializes grid. |
| **`grid-reduce-second-stage!`** | Any Commutative | Size of `num_workgroups` | **Moderate.** Safe, but requires manual 2nd kernel launch. |

#### Launching the Kernel Again

A host program usually launches the same kernel many times. What each strategy needs between launches:

| Strategy | Before every launch | Why |
| --- | --- | --- |
| `grid-reduce-atomic!` | the return cell must hold the **identity** | the atomics combine *into* it |
| `grid-reduce-cas!` | the return cell must hold the **identity** | the CAS loop combines *into* it |
| `grid-reduce-last-man!` | nothing | it *overwrites* the return cell, and the elected workgroup puts its ticket counter back to zero after the final sweep |
| `grid-reduce-second-stage!` | nothing | the partials are overwritten every launch |

The kernel cannot initialise an `:atomic` or `:cas` return cell itself: deciding which workgroup is first would need a grid-wide synchronisation, the very thing these strategies avoid. So the compiler records the requirement in the kernel's `.metacrisp`, on the output parameter:

```lisp
(:name "out" :type out-c :direction :out ... :launch-init (:identity 0.0))
```

The value is the reduction's identity as a number (`(type-max float)` is written out as `3.4028235e38`), `:infinity` / `:-infinity` for `(type-infinity T)`, or `(:identity-form "...")` when the identity is not a constant the compiler can see. The annotation is only possible when the return cell is the kernel's own parameter; otherwise the compiler logs a warning.

An implicit `:atomic-counter` must be zero before the **first** launch only; the generated host code arranges that. A counter you pass yourself is your responsibility, once.

