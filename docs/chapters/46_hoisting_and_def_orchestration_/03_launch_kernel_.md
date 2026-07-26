# launch-kernel 📝


```
(launch-kernel launch-specification &key :pipeline-stages <int>)
```
Launches exactly one kernel invocation. Multiple invocations mean serial enqueues.

Multiple `launch-kernel` invocations are NOT the same as `launch-sequential`, because `launch-kernel` invocations return to the host after each kernel operation completes, but  `launch-sequential` does not.

The `:pipeline-stages` keyword is advanced. See "Out of Core Orchestration" in `topology.md` 

```
(launch-kernel (VADD A B C))
(launch-kernel (VSUM C RES))
(copy-back RES)
```

