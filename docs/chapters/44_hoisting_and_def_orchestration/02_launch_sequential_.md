# launch-sequential ⚠️


```
(launch-sequential  &rest launch-specification)
```
`launch-sequential` takes a series of "launch-specifications" and the hoisting code that is
generated will enqueue them all and prepare a device-side event based synchronization.
The CPU is free to do other things while the sequence of kernels run, and it does not need to do participate during the sequence.

### launch specification

A "launch specification" is simply a kernel _variable_ and the correct number of arguments. eg. `(VADD A B C)` or
`(VADD _ _ _)` or `(VADD _ B _)` etc

