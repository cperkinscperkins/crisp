## launch-kernel ⚠️


```
(launch-kernel launch-specification &key copyback)
```
Launches exactly one kernel invocation, a `:copyback` key can specify the variables that should be copied back.

These can be useful if you need host-side processing in-between kernel calls, however this is quite suboptimal and should be considered an anti-pattern.

If you need to launch multiple kernels, the other `launch-XXXX` with an explicit `(copyback ...)` call at the end will be superior.

```
(launch-kernel (VADD A B C) :copyback (C))
;; host does something here with C? Possible, but bad idea.
(launch-kernel (VSUM C RES) :copyback (RES))
```

