# `def-foreign-function` ✅

```
(def-foreign-function <C_name> <arrow-signature>)
```

```
;; example someKernel.crisp
(def-foreign-function my_add #'(float float => float))

(def-kernel invoke_my_add (a b &out c)
  (declare #'(float float &out (cell float :address-space :global)))
  (let ((res (my_add a b)))
    (set! (~ c) res)))

;; invocation
$ crisp-compile.exe myLib.bc someKernel.crisp --ir-target=ptx
```

The `def-foreign-function` form has two arguments: the "C name" of the function and its signature in Crisp arrow form. 

