# Records Can Hold Storage Handles ✅


A microfloat block needed this, and it works for any `def-record`:

```lisp
(def-type uv (vector uchar :address-space :global :align :compact))
(def-record pair (a uv) (b uv))

(def-function put-a (&out p i v)
  (declare #'(&out pair ulong uchar => nil))
  (set! (~ (a~ p) i) v))

(def-kernel record_handles (&out a b)
  (declare #'(&out uv uv => nil) (global-size :set-to 1))
  (let ((p (make-pair :a a :b b)))
    (put-a p 0ul 5uc)
    (set! (~ (b~ p) 0) 7uc)))
```

As with a block, such a record cannot be a kernel parameter.

