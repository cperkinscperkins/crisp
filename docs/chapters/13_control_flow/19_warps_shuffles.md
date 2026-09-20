# Warps & Shuffles 📝

Witchcraft.

The shuffle primitives are special hardware instructions that let threads within a single
warp exchange register values directly with one another — no shared memory, no barrier.
They are very powerful and very fast operations.

A *warp* (Intel calls it a *subgroup*) is the set of lanes that execute in lockstep.
Shuffles reach across a warp, never across a workgroup, and workgroups are very often
BIGGER than a single warp — so plan your algorithm accordingly.

#### How many lanes is a warp? 📝

This is the one portability question that actually matters, and the vendors disagree:

- **NVIDIA** — 32 lanes, on every architecture shipped to date.
- **Intel** — 8, 16, or 32, **chosen by the driver** unless the kernel pins it.

So do not hardcode 32. Ask for `(warp-size)`.

##### warp-size 📝
`(warp-size) -> uint`

`warp-size` is a **compile-time constant**. It resolves from the active hardware profile's
`:simd-width`, and to 32 when no profile is active. Because it folds to a literal, it is
legal anywhere a constant is legal: as a loop limit, inside a `(local-size :set-to ...)`
declaration, or as the operand of a `+` (uniformity-checked) loop form.

```
(def-hardware-profile bmg :simd-width 16)   ; (warp-size) is now 16
```

Do not confuse it with `(warp-count)`, which is how many warps there are in the workgroup.
`warp-size` is how many lanes there are in a warp.

> **On SPIR-V, a kernel that shuffles must have a pinned warp size.** Crisp emits the
> SubgroupSize execution mode only when it can: a hardware profile names a `:simd-width`,
> the kernel's `local-size` is compile-time known, and the work-item count is a whole
> multiple of that width. If a kernel uses a shuffle and those cannot be satisfied, that is
> a **compile error**, not a guess at 32. A reduction written for 16 lanes that silently
> runs on 32 does not crash — it returns a wrong answer, which is worse.

#### Sizing the workgroup 📝

For some algorithms, making the workgroup exactly one warp makes the algorithm much easier
to write. Be careful, though: multiple warps in a workgroup take up the slack whenever one
of them stalls on a memory access, and a single-warp workgroup surrenders that advantage.
The compensation is that shuffles are wicked fast compared to the shared memory and
barriers you would otherwise need.

If you do take that route, make sure the `local_work_size` used when enqueueing matches. A
declaration with a nice message communicates that to whoever writes the hoisting:

```
(local-size :set-to (warp-size)
            :msg "this kernel requires the local work size to equal the warp size")
```

#### Shuffles are warp collectives 📝

**Every lane in the warp must reach the shuffle.** A shuffle placed inside a
thread-divergent conditional is a compile error: the lanes that do arrive are asking for
data from lanes that never will. On NVIDIA that is undefined or a hang, and on SPIR-V a
non-uniform group operation is undefined outright.

The idiom is to shuffle unconditionally and gate only what you do with the result:

```
(let* ((v (compute-something))
       (r (shuffle-xor v 1ul)))      ; every lane, always
  (when (< (warp-lane) 4ul)          ; only the store is conditional
    (set! (~ out (warp-lane)) r)))
```

#### The width argument: segmenting a warp 📝

Every shuffle takes an optional trailing `width`, defaulting to `(warp-size)`.

`width` **is not a query of the hardware** — that is what `(warp-size)` is for. It
subdivides the warp into contiguous, aligned blocks of `width` lanes, and confines the
shuffle to its own block. It exists so you can run several independent small reductions
inside one warp — one per matrix row, say. At the default it is a no-op.

The rules, all checked at compile time:

- `width` must be a **compile-time constant**. PTX would tolerate a register here, but a
  lane-varying width is meaningless (the lanes would disagree about who they are talking
  to), and the remaining two rules are only checkable statically.
- `width` must be a **power of two**. The hardware divides the warp into aligned blocks;
  a width of 3 has no lowering at all.
- `width` must not be **wider than `(warp-size)`**. A segment cannot exceed the warp that
  contains it.

Writing `k` for a lane's index within its block, the four operations segment like this:

| expression | result | when the source leaves the block |
|---|---|---|
| `(shuffle v n width)` | the value in block-lane `n mod width` | wraps, by construction |
| `(shuffle-up v d width)` | the value `d` lanes lower, when `k >= d` | keeps its **own** value |
| `(shuffle-down v d width)` | the value `d` lanes higher, when `k + d < width` | keeps its **own** value |
| `(shuffle-xor v m width)` | the value in block-lane `k XOR m` | rejected — see below |

#### shuffle 📝
`(shuffle <someVar> target-lane-id &optional (width (warp-size)))`

Evaluates to the current value of `someVar` as it is in another lane. The target lane id is
given directly. Every lane may name a different target, and several lanes may name the same
one — a lane that every other lane reads is a broadcast.

If the target index falls outside the segment it is taken modulo `width`, so it always names
a lane in the caller own block.

#### shuffle-up  / shuffle-down 📝
`(shuffle-up   <someVar> delta &optional (width (warp-size)))`
`(shuffle-down <someVar> delta &optional (width (warp-size)))`

These evaluate to the value of `someVar` in the lane `delta` lanes below or above the
caller.

The `-up` / `-down` names do not have an intuitive reading. The direction is where the data
is GOING, not the arithmetic performed on the delta. `shuffle-up` SUBTRACTS `delta` from the
current lane id and returns the value from that lower lane (the data shuffles "up" to our
higher lane). `shuffle-down` ADDS `delta` and returns the value from that higher lane (the
data shuffles "down" to us). Whatever.

Unlike `shuffle` and `shuffle-xor`, a shift is **not a permutation**: some lanes have no
source. A lane whose source falls outside the warp — or outside its segment, under a
`width` — **keeps its own value** rather than receiving anything. That edge rule is easy to
forget and easy to get wrong, and an algorithm that sums the results will not notice.

#### shuffle-xor 📝
`(shuffle-xor <someVar> lane-id-mask:ulong &optional (width (warp-size)))`

Those other shuffle operations do cool tricks. But `shuffle-xor` is where the real sorcery
occurs.

It evaluates to the value of `someVar` as it is in one other lane, whose id is the caller
own lane id XOR the `lane-id-mask`. You give it the value and the mask; it gets the current
lane id itself.

XOR by a fixed mask is an **involution**: if lane `a` reads lane `b`, then lane `b` reads
lane `a`, and applying it twice returns the original. Every lane both gives and receives,
which is exactly what makes it the reduction primitive — and, as it happens, what makes it
free to differentiate.

`lane-id-mask` must be **less than `width`**. A mask smaller than the segment can never
leave it (XOR only flips low bits inside an aligned block), so a segmented xor and an
unsegmented one are the same instruction. A mask greater than or equal to `width` is asking
to read a lane the segmentation forbids, so Crisp rejects it rather than inheriting whatever
the clamp hardware happens to do.

`shuffle-xor` is what you want for tree reduction. See the `sum_vector_warp` example below.
The magic is in the interaction between the descending-by-half mask from `dec-times-by-half+`
and `shuffle-xor`: it gives a butterfly communication pattern, letting every lane contribute
to a reduction in a logarithmic number of steps.

```
(dec-times-by-half+ (s (/ (warp-size) 2))   ; half the warp size, then 8, 4, 2, 1
        ... (shuffle-xor someVal s))
```

#### Ballot Operations 📝
The ballot primitives allow the warp to vote on a predicate.


##### warp-ballot 📝
`(warp-ballot predicate:bool) -> uint`
Returns a bitmask where the Nth bit is set if the Nth thread in the warp evaluated `predicate` to true.

Think of `warp-ballot` as a bitwise poll of the warp. Every thread passes in a boolean (the predicate). 
The hardware collects these booleans from all active threads simultaneously and packs 
them into a single 32-bit integer.
If Thread 0 says true, the 0th bit of the integer is 1.
If Thread 1 says false, the 1st bit of the integer is 0.

Each thread receives this same composite integer containing the votes of everyone in the warp.

This is a very useful operation often used in conjunction with the `popcount` bit operation. (See the Bit Twiddling section)

##### warp-any? / warp-all? 📝
`(warp-any? predicate:bool) -> bool`
`(warp-all? predicate:bool) -> bool`
Returns true if any (or all) active threads in the warp evaluate `predicate` to true. These are extremely fast hardware reductions.

#### Supported Types 📝
The hardware shuffle instruction moves **32 bits**. Crisp natively supports the 32-bit
types (`int`, `uint`, `float`) and decomposes anything larger for you: a 64-bit value
(`long`, `ulong`, `double`) is split into two 32-bit halves, shuffled separately, and
recombined; aggregates are shuffled field by field.

Decomposition is not a detail to ignore when reading performance numbers — a `double`
shuffle is two instructions, not one — but it is not something you have to write.

#### Differentiating a shuffle 📝

A shuffle is a **gather across lanes**, so its adjoint is a **scatter-add across lanes**.
How cheap that is depends entirely on which shuffle you used:

- **`shuffle-xor` is free.** It is its own inverse, so the adjoint of
  `(shuffle-xor v m width)` is `(shuffle-xor adj m width)` — the same instruction, the same
  mask. This is the one reductions are built from, and it differentiates at no cost.
- **`shuffle-up` and `shuffle-down` transpose into each other,** plus a correction: the
  edge lanes that kept their own value in the forward pass contribute to their own adjoint
  rather than to a neighbour. Exact, and still cheap.
- **`shuffle` with a runtime target is a compile error under `--differentiate`.** When the
  target index is a compile-time constant the shuffle is a known permutation and inverts
  exactly. When it is computed at runtime the transpose is a genuine scatter-add — several
  lanes may read the same source, so the adjoint must sum an unknown number of
  contributions, which is no longer a shuffle at all. Crisp says so plainly rather than
  silently dropping a gradient term.

