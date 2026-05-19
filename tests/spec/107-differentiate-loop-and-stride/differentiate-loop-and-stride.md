In the 101 endeavor I had meant to make sure that our auto-differentiation was expanded
across the board for our tests. And we did, making sure that our differentiation is mathematically
correct even for integer types. 

But I forgot that our 092-dotimes tests and 093-loop-vector-stride tests had a bunch of kernels
declared 'forward-only', and I had also forgotten to proscribe the use of the declaration in our tests.  Oh well.  

The main thrust of this endeavor is to get the A|D system working such that the tests from 092, 093 and 105 that have forward-only declarations can have those removed and pass.  
We should also likely add some 'on metal' testing for some of them, so add the VERIFY-AUTODIFF directive and expectation to select tests.

A secondary thrus of this endeavor is to remove 'forward-only' declarations from nearly all the tests and instead use the SKIP-WITH[--differentiate]: "reason" directive. That way it's easier to scan them. Let's keep 'forward-only' for users and try to not use it ourself so much.


You already looked at the issue of why these stride macros weren't differentiating in the first place:


Claude Discovers
================

The deeper issue: stride macros aren't macros, they're analyzers. tensor-stride, grid-stride, and loop-vector-stride register as expression analyzers (run during the analysis phase). But the AD pipeline (%generate-backward-kernel-ast in src/macros.lisp:669) walks the raw source body through anf-transform before the analyzer phase runs. So when AD sees (tensor-stride A (i) (set! ...)), it never expands the macro — it just walks into the body, hits set! deep inside, and errors.

When I bypass the macro and hand-write the equivalent expansion, AD walks it fine (now that GPU builtins are skip-listed).

Implication

You're right that nearly all my Phase A/B/C kernels should differentiate. They don't because of this structural issue, not because of any per-kernel limitation. The same issue affects 093's loop-vector-stride — that's why all of 093's tests are also forward-only.

Two ways to fix it

Convert stride forms to defmacros. They'd expand at macro-expansion time, before AD's source walk. Risk: stride macros do compile-time inspection of the tensor's static type (for CT direction), which is harder from a defmacro than from an analyzer that has access to the env / semantic graph.

Add a "macro-expand stride forms" pass before anf-transform. Walk the source body, expand any tensor-stride / grid-stride / loop-vector-stride forms (using the same logic as the analyzer), then hand to ANF/AD. Smaller change to the stride code; bigger change to the AD pipeline.