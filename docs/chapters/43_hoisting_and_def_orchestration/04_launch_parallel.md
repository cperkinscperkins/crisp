## launch-parallel


```
(launch-parallel &rest launch-specification)
```

`launch-parallel` is much like `launch-sequential` except that the kernels are all launched parallel to one
another. Crisp will add code to divide the available thread space up between them (excepting `single-task` kernels which just get one thread). Exactly how this is done is target implementation specific. It could use individual queues.

Note the parallel kernels can't safely write to the same vectors (whether marked with `&out` or not). Crisp will 
error if it detects parallel re-use of `&out` vectors, but even if you sneak around the compiler it still won't
work correctly.

