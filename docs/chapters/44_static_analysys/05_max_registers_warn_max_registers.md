# max-registers / warn-max-registers 📝


```
;; in a kernel or function progn:
(declare (max-registers 64))
(declare (warn-max-registers 64))
```

This analysis cannot be elected in `declaim`. It is function or kernel specific.

`max-registers` and `warn-max-registers` are advanced checks. These checks are slightly 
easier to use if you have performed compilations already
and are looking at the register usage enumerated in the metadata file. 

These check set a "performance budget" that sets an upper bound on how many registers a function or kernel requires.
The compiler can estimate how many registers a function will require. If its estimate exceeds
the declared budget, a warning is issued.

For example:

> WARNING: Register pressure for 'my_kernel' is estimated at 72, exceeding the declared budget of 64. 
> This may lead to reduced occupancy.


For `warn-max-registers`, there is only the warning emitted, no other change occurs.

`max-registers`, on the other hand, is NORMATIVE. In addition to the warning, 
the compiler will TRY TO FIT the kernel 
to `max-registers`, which may mean that other variables will experience "register spill"
and be moved to local memory. Only use `max-registers` if you know what you are about.


