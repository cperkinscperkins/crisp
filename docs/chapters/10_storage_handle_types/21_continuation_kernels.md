## Continuation Kernels


A common practice in GPU kernel coding is begin with with one kernel, that perhaps uses a certain
distribution of local and global work sizes, and then to complete that calculation with second kernel, 
that is typically enqueued with a set of local and global work sizes tailored to it. 

This occurs because there is no way to marshall which workgroups execute in which order, and there are
no "global barriers" with which to enforce it. Atomics can be used as ersatz barriers, but overuse often leads to unused GPU cFapacity and stalled threads. The "last man standing" strategy (see `when-is-last-workgroup`)
is an example of working around these limitations. 

When an algorithm has clearly defined stages, and those stages might benefit from a separate enqueue, then 
Crisp has two choices: `def-orchestration` and "continuation kernels". 

`def-orchestration` is simple to use and lets you easily configure hoisting code for launching
kernels sequentially and moving data between them, or launching them isolated in parallel, or even
doing data interleaving with overlapping kernel-invocation/memory-copies. See the [Hoisting and def-orchestration](#hoisting-and-def-orchestration) section for more.

While `def-orchestration` provides a general framework for sequencing kernels, continuation kernels 
offer a unique advantage in specific scenarios: compile-time capture.  This superpower allows
 a macro using `let-kernel` to capture a function arg at compile time, which means
that BOTH kernel stages can use some same common worker function without having to "pass" that across the
host-device barrier. 

### `let-kernel`

`let-kernel` is a binding special form similar to `labels` in Common Lisp. It defines a new kernel
function.  You can invoke that kernel in the "last place" of some other kernel.  No operations should
be performed AFTER a continuation kernel is invoked. The compiler will warn you if you do.

`let-kernel` can be used anywhere a `let` binding could, but its primary and safest use is for 
defining a continuation kernel inside a `def-kernel`.  To ensure a clear execution model, the 
compiler requires that the declarative invocation of the continuation kernel must be the **final expression**
in its scope.  A warning will be issued if any code follows this invocation. 
This is typicallly done with `launch-kernel` (see below).

The launch-kernel directive used to specify the continuation is not executed by the initial kernel; it compiles to a NOP. Its purpose is purely declarative: it signals to the hoisting code generator which kernel to launch next.  
The hoisting code that the Crisp generates will demonstrate loading and enqueueing the first kernel,
waiting on it complete, and then enqueing the second one, typically sharing memory args between them.

If using `let-kernel` it is a good practice to `declare` the desired local and global work sizes so the
hoisting code will be optimal.


### Variable Capture
It is important to note that `let-kernel` does not create a lexical closure. Any variables from the 
surrounding scope that are used inside the `let-kernel` body must have their values known at compile time. 
This allows the compiler to "bake in" or inline these values (such as a constant identity value or a known `#'someFunction`) directly into the new kernel's definition.

If a value is only known at runtime (for example, a variable passed as an argument to the outer kernel), 
it cannot be captured. Instead, it must be passed as an explicit argument to the continuation kernel itself.


#### `kernel-name` 

`(declare (kernel-name "some_name"))` 

The `let-kernel` binding will determine the name of the kernel that is generated. But if you need to
name it relative to some other function argument, `declare` a `kernel-name`.  

If this declaration is missing, the kernel will take the name of the binding itself. 

Regardless of the method, remember that kernel names have to obey C identifier naming rules.

#### `launch-kernel`

`(launch-kenrnel (continue-later A C ) :copyback (A C))`

It is not possible to invoke any kernel function from any other. But `launch-kernel` CAN 
appear in your code with a kernel invocation.  It should appear as the **final expression**
of your kernel execution.

The compiler will simply NOP out the actual `launch-kernel` invocation from the calling kernel.
It does nothing and doesn't effect the compilation of the kernel in which it appears.

But the hoisting code that is generated WILL respect it, and will hoist that target invocation
after your own kernel.

It supports an optional `:copyback` key which can be used to list the arguments that should be 
copied back to the host when the continuation kernel is done. Only paramters to the continuation 
kernel itself OR the original kernel can be named in the copyback list. 

example
```
; define two kernels, one launches the other.
(def-kernel something-else (V) ...)

(def-kernel first-this (A B &out C))
   ... ;; do something
   (launch-kernel (something-else C)))
```

`launch-kernel` is also how "continuation kernel" invocations are specified
and realized. Additionally, it can appear in a `def-orchestration` context (see below).


### Continuation Kernel Example

```
;; -- two_stage_operation --
(def-kernel two_stage_operation (A B C)
    (declare #(my-v-t my-v-t my-v-t => nil)
             (local-size :derive-from B :msg "two_stage_operation local work size should be the same as the length of B")
             (global-size :set-to (+ (length~ A) (length~ B) (length~ C)) :msg "two_stage_operation global work size
             should be big enough for all three vector arguments"))
    (let-kernel ((continue-later (a &out c)
                  (declare (kernel-name "last_stage_op")
                          #(my-v-t my-v-t => nil)
                          (local-size :derive-from A :msg "last_stage_op requires a local work size at least as long as A")
                          (global-size :derive-from C :msg  "be sure to set global workd size big enough to accomodate C"))
                    ;; perform operations in continuation kernel
                      ... ))
        ;; do operations for first stage
        ...
        ;; this isn't a real invocation.  It just demonstrates to the hoisting code
        ;; HOW this function expects the continuation kernel to be called
        (launch-kernel (continue-later A C) :copyback (B C))))
```



