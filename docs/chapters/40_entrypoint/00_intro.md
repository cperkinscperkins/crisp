# `entrypoint`

```
(def-grid-function foo (...)
  (declare (entrypoint))
   ...)
```

`entrypoint` is a declaration that can appear in any non-kernel function. It is similar to `DllExport`, in that it
tells the compiler that function is a top-level API function that should not be optimized away.
Further `entrypoint` functions are compiled "library-wise", meaning the function and all its dependencies get
bundled together (typically in a .bc file). This results in fast compilation for any kernel that uses it.




