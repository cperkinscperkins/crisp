Extend auto-diff to include def-record appearing on the kernel boundary.  
========================================================================

The last feature we just added was to support records (def-record) appearing directly on the 
kernel boundary.  Each property is individually enqueued, nested records collapsed down to the 
basic types (int, float, etc)


Chris Wonders
-------------

When auto differentiating, we have the whole "argument mirroring" thing that occurs for other arguments, righ? So if the kernel has an int arg "v" , then the backwards variant has both int v and float v_grad.   That seems like that could be the same approach to records.  Just need to make sure the chain transformations map someRecord.v  to v_grad.   
OR we sould makea  new ADRecord that has the same properties, but everything is a float.  Dunno.


Claude Opines
-------------

Two main approaches, both reasonable:

Option A — Mirror the record as-is (your "argument mirroring" idea)

vp_GRAD stays type v-point. The adjoint accumulation works field-by-field: vp_ADJ is initialized to a zero-constructed v-point (e.g. (make-v-point 0.0 0)), and when the backward walk accumulates into vp_ADJ, it needs to know that the ANF variable came from (x~ vp) or (y~ vp) — so the adjoint of the accessor result flows back into the corresponding field of vp_ADJ. The final emission is already (set! vp_GRAD vp_ADJ) which would work. The hard part is teaching generate-backward-walk that vp_x_ADJ maps back to the x field of vp_ADJ.

Option B — Explode to scalars before AD ("ADRecord flattening")

Before the backward walk, explode record params to their scalar fields: vp → vp_x : float, vp_y : int. Run AD on the flat scalar kernel. Each scalar gets its own _GRAD. Then the backward kernel implodes the grad scalars back into a v-point_GRAD. This mirrors exactly what %explode-kernel-args already does at the ABI level — you'd just be doing it earlier, at the ANF level. Cleaner conceptually because the AD system only ever sees scalars.

Option A is closer to the current architecture but requires generate-backward-walk to understand struct field accessors (x~, y~) as special forms. Option B is more principled — records at kernel boundaries are already "really" scalars, so the AD system never needs to learn about structs. The ANF transform (anf-transform) runs before generate-backward-walk, so you could insert an "explode records" step between them.

Option B aligns better with the existing "records explode at kernel boundaries" philosophy.



Chris
=====
Looping back to our auto-diff of def-record at kernel boundary topic.  

def-record supports overloaded property accessor functions.  So (x~ somePoint)   COULD be overridden. Is that going to be problem with Option A or Option B?

Users can also write functions that take records as arguments, generally. But we already explode those when compiling, so those probably are not an issue.


Claude
======
Overloadble accessors create challenges for both approaches.   


Chris
=====
The ~x~  function ( for a property named "x") is also Crisp generated and is NOT overloadable.  The usual scenario is that a user overloading ~x just uses ~x~ to get the value and then manipulates it before returning.

Of course, they don't have to. Or they could "swap" and call some other ~y~ accessor.

To my mind, its seems like we can maybe just worry about ~x~ , right?  I'm not sure about the implementation, but I bet good money that the default x~ just calls ~x~.  

Even if the user "lies" with x~ , they cannot lie with ~y~.  So we'd get the right gradient if we only worry about ~x~ forms, wouldn't we?


Claude
======

Yes, exactly right — if the AD system only processes ~x~ forms (the raw accessors), it's always correct because ~x~ cannot lie. Even if the user's x~ swaps fields or does something exotic, ~x~ is always the direct %extract-struct-member with no user code in the path.

The consequence of that policy: if a kernel uses (x~ vp) where x~ is overloaded, the AD system simply won't see a ~x~ form in the ANF for that access — and therefore won't accumulate a gradient through it. That's wrong in the sense of "incomplete gradient", but it's the user's problem: they brought an overloaded accessor into a differentiable kernel. You could warn or error, but you'd never silently produce a gradient that claims it's correct while computing something else.

The cleaner version of Option B then becomes:

In the ANF body, scan for (~field~ record-param) forms
For any that reference a kernel boundary record param, substitute (~x~ vp) → vp_x
Treat (x~ vp) (non-raw form) as an opaque scalar — no gradient flows through it — same as any other unrecognized function call
That's a simple, correct, and conservative implementation. Worth noting in the plan file.