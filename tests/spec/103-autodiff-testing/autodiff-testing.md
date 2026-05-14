We've spent a lot of effort on the Crisp A|D functionality. But we have, and will likely continue to,
deferred the hoisting of the differentiated kernels. This is because the audience that is 
doing and using kernel differentiation today most likely already has a setup and don't necessarily
"need" example code.  Perhaps that is misguided, but regardless, hoisting of differentiated kernels
is not a critical need at this time.

BUT, the A|D functionality does need to be tested, and it should be tested "on metal".  In the past
we've just used an ersatz script for that ( sbcl --non-interactive --load scripts/verify_autodiff.lisp ).  Ironically, that script is failing. Awesome.

For this endeavor we want to bring some testing of the A|D system into the test running system.

My current proposal is:

- get that verify_autodiff.lisp script working again
- introduce a new test directive ( VERIFY-AUTODIFF ) and maybe some sort of "expectation" like
  we have for hoisting (e.g. ;; HOIST-EXPECT: BUFFER out: 0 1 2 3 )
- - perhaps the directive could put the expectation after the colon, rather than introduce a second directive
- realize that directive.  I think just using Common Lisp and OpenCL would suffice, since it's the 
  math that we are checking.  But if you think testing with L0 and/or C++ is important, we'll discuss.
- select SOME existing tests that we think should be tested on metal and add the directive/expectations to them.
- write some tests that we know we want to test various aspects of the A|D on metal.
- - where to put them?  Here in 103 is good, but in some cases maybe with a different endeavor if it has more gravity.

